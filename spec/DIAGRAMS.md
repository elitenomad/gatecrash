# Gatecrash at a glance

The pictures that go with [`DOMAIN.md`](DOMAIN.md): how the models relate, one
payment from click to ledger, and the order lifecycle. `DOMAIN.md` is the
field-level spec; this is the picture.

## Model relationships

```mermaid
erDiagram
    ORGANISER ||--o{ EVENT : runs
    EVENT ||--o{ TICKET_TYPE : offers
    EVENT ||--o{ ORDER : receives
    ORDER ||--|{ ORDER_ITEM : contains
    TICKET_TYPE ||--o{ ORDER_ITEM : "priced into"
    ORDER ||--o{ PAYMENT : "attempted via"
    ORDER ||--o{ TICKET : "issues on success"
    TICKET_TYPE ||--o{ TICKET : admits
    ORDER ||--o{ LEDGER_TXN : books
    LEDGER_TXN ||--|{ LEDGER_ENTRY : "balances across"

    ORGANISER {
        uuid id PK
        string name
        string email
    }
    EVENT {
        uuid id PK
        uuid organiser_id FK
        string slug UK
        string name
        timestamptz starts_at
        string venue_name
        enum status "draft on_sale sold_out cancelled completed"
    }
    TICKET_TYPE {
        uuid id PK
        uuid event_id FK
        string name
        bigint price_amount "minor units"
        char price_currency
        int quantity_total
        int quantity_held "reserved by unpaid orders"
        int quantity_sold "paid"
    }
    ORDER {
        uuid id PK
        uuid event_id FK
        string email
        enum status "pending awaiting_payment paid expired"
        bigint total_amount
        char total_currency
        timestamptz hold_expires_at "null once paid"
    }
    ORDER_ITEM {
        uuid id PK
        uuid order_id FK
        uuid ticket_type_id FK
        int quantity
        bigint unit_price_amount "COPIED at order time"
        char unit_price_currency
    }
    PAYMENT {
        uuid id PK
        uuid order_id FK
        string provider "stripe adyen"
        string provider_ref UK
        bigint amount
        char currency
        enum status "requires_payment succeeded cancelled"
    }
    TICKET {
        uuid id PK
        uuid order_id FK
        uuid ticket_type_id FK
        string code UK "unguessable, scanned at door"
        timestamptz issued_at
    }
    LEDGER_TXN {
        uuid id PK
        uuid order_id FK "nullable"
        enum kind "ticket_sale provider_fee payout"
        string provider_ref "nullable, their id for the fact"
        timestamptz occurred_at "when money moved"
    }
    LEDGER_ENTRY {
        uuid id PK
        uuid transaction_id FK
        enum account "psp_balance bank ticket_revenue processing_fees"
        bigint amount "signed, debit + credit -"
        char currency
    }
```

Two tables sit deliberately **outside** the graph, with no foreign keys to anything:

```mermaid
erDiagram
    WEBHOOK_EVENT {
        uuid id PK
        string provider
        string provider_event_id UK "unique with provider, the replay guard"
        string type
        jsonb payload "raw body as received"
        timestamptz received_at
        timestamptz processed_at "null until handled"
    }
    IDEMPOTENCY_KEY {
        string key PK "client-supplied"
        string request_fingerprint "hash of method path body"
        int response_status
        jsonb response_body
        timestamptz locked_at "in-flight guard"
    }
```

They are infrastructure, not domain. `WEBHOOK_EVENT` is a log of what the provider told
us, kept verbatim so we can replay history and settle arguments; `IDEMPOTENCY_KEY` is a
response cache. Giving either a foreign key into `ORDER` is tempting and wrong — both
must be writable *before* we know whether the thing they refer to exists or is valid.

**Reading the cardinalities**, three are load-bearing and worth stating plainly:

- `ORDER ||--o{ PAYMENT` — one order, **many** payment attempts, one per provider
  session. A customer who leaves the payment page and comes back is two payments and
  one order. A declined card retried on the same Checkout page is not: that happens
  inside one session.
- `TICKET_TYPE ||--o{ ORDER_ITEM` exists only to identify *which* tier was bought. The
  price is copied onto `ORDER_ITEM`, never read back through this edge.
- `ORDER ||--o{ LEDGER_TXN` is a `ticket_sale` at fulfilment and a `provider_fee`
  when the reconciler books it; refunds add reversing transactions later. The ledger
  is append-only — a correction is a new transaction, never an edit.

## The core flow

Everything Volume 1 teaches, in one picture. The two boxed notes are the chapters
readers most often get wrong.

```mermaid
sequenceDiagram
    autonumber
    actor C as Customer
    participant FE as Front end
    participant API as Gatecrash API
    participant DB as Postgres
    participant W as Job worker
    participant PSP as Stripe

    C->>FE: browse, pick tickets
    FE->>API: GET /api/events/{slug}
    API-->>FE: event + live availability

    rect rgb(238, 244, 252)
    Note over FE,DB: Ch 7 — Idempotency
    FE->>API: POST /api/orders + Idempotency-Key
    API->>DB: lock ticket_type rows
    API->>DB: check availability, quantity_held += n
    API->>DB: insert order pending + items with copied prices
    API->>DB: store idempotency response
    API-->>FE: 201 Order
    end

    FE->>API: POST /api/orders/{id}/checkout
    API->>DB: insert payment requires_payment
    API->>DB: order to awaiting_payment
    API->>PSP: create Checkout Session
    PSP-->>API: checkout_url
    API-->>FE: 201 checkout_url
    FE->>C: redirect to Stripe

    C->>PSP: card details, 3DS if required
    PSP-->>C: redirect back to front end

    Note over C,FE: The redirect is a UX hint only.<br/>The customer controls it and may<br/>close the tab. It proves nothing.

    loop until terminal
        FE->>API: GET /api/orders/{id}
        API-->>FE: status
    end

    rect rgb(232, 246, 236)
    Note over PSP,W: Ch 8 — Webhooks. The authoritative signal.
    PSP->>API: POST /api/webhooks/stripe
    API->>API: verify HMAC over RAW body
    API->>DB: insert webhook_event, unique provider_event_id
    Note right of DB: conflict means already seen,<br/>return 200 and stop
    API-->>PSP: 200 fast
    API->>W: enqueue fulfilment
    W->>DB: payment to succeeded
    W->>DB: order to paid
    W->>DB: quantity_held -= n, quantity_sold += n
    W->>DB: issue tickets
    W->>DB: write ticket_sale, same transaction as paid
    end

    rect rgb(255, 244, 229)
    Note over PSP,W: Ch 10 — The reconciler, on a schedule. Fees are their fact, not ours.
    W->>DB: paid orders with no provider_fee
    W->>PSP: GET balance transaction
    PSP-->>W: fee
    W->>DB: write provider_fee, unique per order
    end

    FE->>API: GET /api/orders/{id}
    API-->>FE: paid
    FE->>API: GET /api/orders/{id}/tickets
    API-->>FE: tickets
    FE->>C: here are your tickets
```

Note what does **not** appear: no path from the customer's redirect to `order = paid`.
Fulfilment hangs entirely off the webhook. That separation is the single most important
structural idea in Volume 1, and it is why chapters 8, 9 and 10 exist.

## Order lifecycle

```mermaid
stateDiagram-v2
    direction LR
    [*] --> pending : order created, inventory held

    pending --> awaiting_payment : checkout session created
    pending --> expired : hold lapsed

    awaiting_payment --> paid : webhook, payment succeeded
    awaiting_payment --> expired : hold lapsed

    paid --> [*]
    expired --> [*]

    note right of paid
        Terminal in Volume 1.
        Volume 2 reopens this with
        refunded, partially_refunded,
        disputed.
    end note

    note left of expired
        Reached by a background job,
        never by a request, and only
        once the provider has closed
        the payment page. Returns
        quantity_held exactly once,
        even if the job runs twice.
    end note
```

There is no `failed`. Under hosted Checkout a declined card never reaches us as a state
change: the customer sees the decline on the provider's page and tries another card in
the same session. An order whose customer gives up is one whose hold lapses, and the
clock expires it like any other.
