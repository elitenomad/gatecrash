# Gatecrash — Domain Model

The canonical domain for the book. Authored once; every track implements it and every
track's prose describes it. Scoped to **Volume 1**, but deliberately shaped so Volumes 2
and 3 extend it rather than rewrite it.

---

## 1. The business

Gatecrash sells tickets to live events for independent organisers. A customer picks an
event, chooses ticket types and quantities, pays, and receives tickets.

Volume 1 covers exactly one path end-to-end and covers it properly:

> browse → order (inventory held) → hosted Checkout → webhook → tickets issued → ledger balanced

**Cards only.** A ticket is issued the moment its payment succeeds, against seats held
for minutes. Bank debits and other delayed methods confirm days later and can honour
neither, so Volume 1 accepts cards and nothing else — and says so in code, on every
Checkout Session (`allowed_payment_method_types: ["card"]`). Left out, the provider offers
whatever its dashboard has enabled, which is a setting someone else can change.

The same decision means a decline is never a state change here. Hosted Checkout shows
the decline to the customer, who tries another card on the same page, against the same
session; no session-level event is sent.

Deliberately **not** in Volume 1 — each is a Volume 2/3 chapter, but the model below
must not preclude them: refunds, cancellations, disputes, auth-and-capture at the door,
season passes (subscriptions), organiser payouts and splits, tax, multi-currency.

---

## 2. Money

**One rule, no exceptions: money is an integer count of minor units plus an ISO 4217
currency code. Never a float. Never a bare integer without its currency.**

```
{ "amount": 4500, "currency": "GBP" }   // £45.00
```

Every track implements a `Money` value object enforcing:

- construction requires both amount and currency
- arithmetic between different currencies raises, never coerces
- no division that silently loses remainder — splitting money returns a list whose
  parts sum exactly to the original (largest-remainder allocation)
- serialises to the shape above at every API boundary

> Minor units are not always 2 decimal places. JPY has 0, KWD has 3. Storing "pounds as
> a decimal" breaks the moment a second currency appears, which is why this is a
> chapter-3 topic and not an appendix.

---

> Diagrams for everything below — entity relationships, the end-to-end payment
> sequence, and the order lifecycle — are in [`DIAGRAMS.md`](DIAGRAMS.md).
> This file is the field-level spec; that one is the picture.

## 3. Entities

### Organiser
Sells events. Volume 1: little more than a name and contact. Volume 3 attaches a
connected account and payout schedule.

| field | type | notes |
|---|---|---|
| `id` | uuid | |
| `name` | string | |
| `email` | string | |

### Event
| field | type | notes |
|---|---|---|
| `id` | uuid | |
| `organiser_id` | uuid | |
| `slug` | string | unique; public URL key |
| `name` | string | |
| `starts_at` | timestamptz | |
| `venue_name` | string | Volume 1 keeps venue as a flat field |
| `status` | enum | `draft`, `on_sale`, `sold_out`, `cancelled`, `completed` |

### TicketType
A priced tier within an event. **This row owns inventory.**

| field | type | notes |
|---|---|---|
| `id` | uuid | |
| `event_id` | uuid | |
| `name` | string | "Early Bird", "General Admission" |
| `price_amount` | bigint | minor units |
| `price_currency` | char(3) | |
| `quantity_total` | int | |
| `quantity_held` | int | reserved by unpaid orders |
| `quantity_sold` | int | paid |

Availability is `quantity_total - quantity_held - quantity_sold`. Keeping *held* and
*sold* as separate counters — rather than one `quantity_remaining` — is what makes hold
expiry recoverable without guessing, and it is the hook Volume 2's concurrency chapter
hangs off.

### Order
The aggregate root for a purchase attempt. One customer, one event, one or more items.

| field | type | notes |
|---|---|---|
| `id` | uuid | |
| `event_id` | uuid | |
| `email` | string | buyer; no account required in Volume 1 |
| `status` | enum | see §4 |
| `total_amount` | bigint | minor units |
| `total_currency` | char(3) | |
| `hold_expires_at` | timestamptz | null once paid |
| `created_at` / `updated_at` | timestamptz | |

### OrderItem
| field | type | notes |
|---|---|---|
| `id` | uuid | |
| `order_id` | uuid | |
| `ticket_type_id` | uuid | |
| `quantity` | int | |
| `unit_price_amount` | bigint | **copied at order time, never read live** |
| `unit_price_currency` | char(3) | |

> Prices are copied onto the order, not joined from `TicketType`. If the organiser
> changes the price tomorrow, what the customer actually paid must not change. This is
> the single most common modelling mistake in commerce systems.

### Payment
A payment *attempt* against an order. **An order has many payments.**

| field | type | notes |
|---|---|---|
| `id` | uuid | |
| `order_id` | uuid | |
| `provider` | string | `stripe`, later `adyen`/`mollie` |
| `provider_ref` | string | e.g. `cs_test_...` / `pi_...`; unique per provider |
| `amount` / `currency` | bigint / char(3) | |
| `status` | enum | see §4 |
| `created_at` / `updated_at` | timestamptz | |

> Modelling `Payment` separately from `Order` is not over-engineering. A customer who
> leaves the payment page and comes back starts a second session — two payments, one
> order. Each session is a separate object the provider reports on, and either can still
> be paid; one row per session is what lets every report land somewhere. Collapse them
> and refunds in Volume 2 have nothing to attach to.
>
> A `Payment` is one provider **session**, not one card. A declined card followed by a
> good one on the same Checkout page is *one* payment: the decline happens inside the
> session, and the session is what succeeds.
>
> Many payments, but at most one still `requires_payment` — one open page — per order
> (§6, Paying). The database enforces it with a partial unique index.

### Ticket
Issued **only** on payment success, one row per admitted person.

| field | type | notes |
|---|---|---|
| `id` | uuid | |
| `order_id` | uuid | |
| `ticket_type_id` | uuid | |
| `code` | string | unique, unguessable; the thing scanned at the door |
| `issued_at` | timestamptz | |

### WebhookEvent
Received provider events. Exists for replay protection and for the audit trail.

| field | type | notes |
|---|---|---|
| `id` | uuid | |
| `provider` | string | |
| `provider_event_id` | string | **unique with provider** — this is the replay guard |
| `type` | string | |
| `payload` | jsonb | raw body as received |
| `received_at` | timestamptz | |
| `processed_at` | timestamptz? | null until handled successfully |

### IdempotencyKey
For **our own inbound API**, not the provider's. Chapter 7.

| field | type | notes |
|---|---|---|
| `key` | string | client-supplied, unique |
| `request_fingerprint` | string | hash of method + path + body |
| `response_status` | int | |
| `response_body` | jsonb | |
| `locked_at` | timestamptz? | in-flight guard for concurrent replays |
| `created_at` | timestamptz | |

Same key + different fingerprint ⇒ `422`. Reusing a key for a different request is a
client bug and must be loud, not silently served a stale response.

### LedgerAccount / LedgerEntry
See §5.

---

## 4. State machines

### Order

```
  (new) ──▶ pending ──▶ awaiting_payment ──▶ paid
               │               │
               └───────────────┴──▶ expired
```

| state | meaning |
|---|---|
| `pending` | created, inventory held, no payment started |
| `awaiting_payment` | checkout session created, customer sent to provider. Stays here through declines and through starting a new session |
| `paid` | payment succeeded, tickets issued, ledger written |
| `expired` | hold lapsed before payment; inventory returned |

There is no `failed`. A declined card is the provider's to handle (§1), and a customer
who gives up after one is indistinguishable from one who closed the tab: both are
holding seats, and the clock releases both.

`paid` is terminal in Volume 1. Volume 2 adds `refunded`, `partially_refunded`,
`disputed`, and reopens the diagram.

### Payment

```
  (new) ──▶ requires_payment ──▶ succeeded
                    │
                    └──▶ cancelled
```

A status, not a second state machine. The diagram is what the provider's lifecycle
produces, not a set of edges the app enforces: the order's transitions are ours to
refuse, but a payment's status is a transcription of what the provider says happened
to an object it owns, and a transcription that refused to record what it was told
would be a log with holes in it.

Provider-neutral by design. Stripe's `requires_action` / `requires_confirmation` /
`succeeded` map onto these; so do Adyen's. The mapping table lives in the book,
chapter 9.

Three statuses, and Volume 1 writes all three: `requires_payment` when a session is
created, `succeeded` from the webhook, `cancelled` when the session is expired. There is
no `processing` — that is a bank debit, accepted and not yet settled, and Gatecrash
takes cards only. And there is no `failed`: a declined card is something that happens
*inside* a session that stays open (§1), an event rather than a state. A provider or a
flow that needs either adds it then; widening a check constraint is one migration.

> **Only the webhook moves a payment to `succeeded`.** Not the redirect back from
> Checkout, not a polled API read. The redirect is a UX hint the customer controls and
> can be forged or simply never happen — they close the tab. The webhook is the
> authoritative signal. Getting this wrong is how a real business ships tickets that
> were never paid for.

---

## 5. The ledger

Double-entry, because "trust and verify" needs something to verify *against*. Every
financial fact is a **transaction** made of two or more **entries** that sum to zero.

Convention: **debits positive, credits negative. `sum(entries) == 0` per transaction.**

### Accounts (Volume 1)

| account | type | meaning |
|---|---|---|
| `psp_balance` | asset | money the provider holds on our behalf |
| `bank` | asset | money that has landed in our bank |
| `ticket_revenue` | revenue | what we sold |
| `processing_fees` | expense | what the provider charged us |

### Worked example — one £45.00 ticket, £0.88 provider fee

On `payment.succeeded`, inside the same database transaction that marks the order
`paid` — a `ticket_sale`:

| account | debit | credit |
|---|---|---|
| `psp_balance` | 4500 | |
| `ticket_revenue` | | 4500 |

Stored as: `[+4500, -4500]` → sums to `0`. ✓

When the provider reports what it charged — a `provider_fee`, written by the
reconciler, never by fulfilment:

| account | debit | credit |
|---|---|---|
| `processing_fees` | 88 | |
| `psp_balance` | | 88 |

Later, when the provider pays out:

| account | debit | credit |
|---|---|---|
| `bank` | 4412 | |
| `psp_balance` | | 4412 |

### Why the fee is its own transaction

The sale is *our* fact: we know the total the moment the webhook arrives. The fee is
the *provider's* fact: it depends on the card that was used, lives on a separate
balance transaction, and arrives on the provider's schedule. Booking the two together
would mean either guessing the fee or holding a database transaction open across a
network call. Booking the fee on its own means:

- fulfilment never touches the network, so the sale is written atomically with `paid`;
- a fee that is not yet known is simply *absent*, and "paid orders with no
  `provider_fee`" is a query on the ledger — the ledger tells the reconciler what it is
  missing, without a flag anywhere;
- the ledger only ever contains facts. An estimate that later needed correcting would
  have been a fact we invented.

### Schema

**LedgerTransaction**

| field | type | notes |
|---|---|---|
| `id` | uuid | |
| `kind` | string | `ticket_sale`, `provider_fee`, `payout`, later `refund`, `dispute` |
| `order_id` | uuid? | |
| `provider_ref` | string? | the provider's id for the fact this records — a balance transaction id on a `provider_fee`; null for facts we originate |
| `occurred_at` | timestamptz | when the money moved, not when we wrote the row |
| `created_at` | timestamptz | |

**LedgerEntry**

| field | type | notes |
|---|---|---|
| `id` | uuid | |
| `transaction_id` | uuid | |
| `account` | string | |
| `amount` | bigint | signed minor units; debit +, credit − |
| `currency` | char(3) | |

Enforced invariants — these are conformance tests, not documentation:

1. entries for a transaction sum to zero, **per currency**
2. a transaction has at least two entries
3. entries are append-only; corrections are new reversing transactions, never updates
4. every `paid` order has exactly one `ticket_sale` transaction
5. every `paid` order has at most one `provider_fee` transaction — and, once the
   provider has reported it, exactly one, whose amount is the provider's, not ours

---

## 6. The critical paths

### Creating an order (chapter 7 — idempotency)

```
POST /api/orders  { event_id, email, items[] }   Idempotency-Key: <uuid>
  ├─ key seen, same fingerprint  ──▶ replay stored response verbatim
  ├─ key seen, diff fingerprint  ──▶ 422
  └─ new key
       └─ transaction:
            ├─ lock ticket_type rows
            ├─ check availability
            ├─ increment quantity_held
            ├─ insert order (pending) + order_items with copied prices
            ├─ set hold_expires_at = now + 15 min
            └─ store idempotency response
```

### Paying (chapter 5)

```
POST /api/orders/{id}/checkout
  ├─ order not pending|awaiting_payment, or its hold has lapsed ──▶ 409
  ├─ for each of the order's payments still requires_payment — an open session:
  │    expire it at the provider
  │      ├─ expired ──▶ payment ──▶ cancelled
  │      └─ refused ──▶ re-fetch the session and read its status
  │           ├─ complete ──▶ 409: already paid, confirmation on its way
  │           ├─ expired  ──▶ payment ──▶ cancelled (it lapsed on its own)
  │           └─ open     ──▶ 502, nothing created
  ├─ create provider Checkout Session: allowed_payment_method_types = [card],
  │    client_reference_id = order id
  └─ transaction:
       ├─ lock the order; re-check it is still payable
       │    └─ not (the sweeper expired it meanwhile) ──▶ 409; record nothing,
       │         and the session's URL never leaves the server
       ├─ re-check no other payment is requires_payment
       │    └─ there is (a second checkout ran while the provider answered this
       │         one) ──▶ 409; record nothing, and this URL never leaves either
       ├─ create Payment (requires_payment, provider_ref = session id)
       └─ order ──▶ awaiting_payment (unless it already is)
     return { checkout_url, expires_at }
```

A second call on an `awaiting_payment` order is legitimate — the customer left the
payment page and came back — and creates a second Payment against a fresh session.

**One open session per order.** Two are two pages that can take the customer's money,
and a customer with two tabs will eventually pay both. The provider is the lock: it
expires a session only while it is `open`, so either the expiry lands first and that
page can no longer be paid, or the payment did and the expiry is refused. A refusal is
re-read, not parsed — the error's wording is not a contract; the session's status is.
The sweeper applies the same rule before it releases a hold (below).

Closing first is not enough on its own. Two calls at once — a double-click, two tabs —
both find nothing to close, both open a session, and both would record one. The re-check
under the order lock is what stops the second, and a partial unique index on
`payments (order_id) WHERE status = 'requires_payment'` is what stops it if the re-check
is ever lost. The session that loses is never recorded and its URL is never returned:
a page nobody has the address of cannot take money.

### The webhook (chapter 8 — where fulfilment actually happens)

```
POST /api/webhooks/stripe
  ├─ verify signature over the RAW body       ──▶ 400 if bad
  │    └─ against every v1 in the header (one per active secret during a roll);
  │       any other scheme is ignored, however valid
  ├─ reject timestamp outside tolerance       ──▶ 400
  ├─ insert WebhookEvent (unique provider_event_id)
  │    └─ conflict ⇒ recorded before ──▶ 200
  │         └─ not yet processed ──▶ queue the job again: this is the retry
  ├─ queue the job                            ──▶ 5xx if that fails
  ├─ 200 immediately
  └─ job — retried on database errors (deadlock, lost connection), never on the
     provider's, which it does not call; acts on
     checkout.session.completed with payment_status = paid, and
     records-and-ignores everything else, payment_intent.payment_failed included:
     that decline is about one card inside a session the customer is still using
       ├─ payment already succeeded ──▶ done (a redelivery)
       ├─ payment ──▶ succeeded   (the money arrived, whatever happens next)
       ├─ order already paid by another payment ──▶ log DUPLICATE: owed a refund
       ├─ order not awaiting_payment (hold lapsed) ──▶ log UNFULFILLABLE: owed a refund or a seat
       ├─ order ──▶ paid
       ├─ quantity_held −n, quantity_sold +n
       ├─ issue Tickets
       ├─ write the ticket_sale ledger transaction   (same DB transaction as ──▶ paid)
       └─ mark processed_at
```

> **Recorded is not processed.** The event row and the job are two writes, and with
> Solid Queue in its own database no transaction covers both. If the second fails the
> provider gets a 5xx and redelivers; that redelivery finds the row already there, and
> must queue the job rather than assume it ran. The job checks `processed_at` and
> fulfilment is idempotent, so queueing it twice is harmless. What the redelivery cannot
> rescue — a job that keeps failing after the provider has its 200 — is what the alert
> on unprocessed events is for.

> Verify against the **raw request body**. Any framework that parses and re-serialises
> JSON before you hash it will break the signature: on every event if its whitespace
> differs from the provider's, and only on some if just the escaping differs — the worse
> case, because it passes testing. Chapter 8 shows exactly how to get the raw
> bytes out of Rails, which makes it awkward in its own particular way.

### Hold expiry (background job)

```
every minute: orders where status = pending|awaiting_payment and hold_expires_at < now
  ├─ close the order's open sessions at the provider, exactly as in Paying
  │    ├─ one was already paid ──▶ leave the order: its webhook is on the way,
  │    │                           and the customer keeps the seats they paid for
  │    └─ provider unreachable  ──▶ leave the order; next run
  └─ transaction: lock; re-check lapsed, still holding, no session opened since
       └─ order ──▶ expired; quantity_held −n
```

**No page that can take money outlives the seats it is selling.** Releasing a hold
while its session is open puts the seats back on sale while the customer can still pay
for them. Closing first makes the provider the referee again: either the page is shut
and the seats can go, or the customer paid first and the order is theirs. The cost is
deliberate — while the provider is unreachable, holds with an open session stay held,
because releasing seats is the one step here that cannot be taken back.

`awaiting_payment` is included on purpose. A customer who was declined and gave up, or
simply closed the tab, is still holding seats, and no event will ever say so; the clock
is the only thing that releases them.

### Booking the fee (background job — chapter 10)

```
every few seconds, and on POST /api/admin/ledger/reconcile:
  orders where status = paid and no ledger transaction with kind = provider_fee
    └─ for each: fetch the session, expanding payment_intent.latest_charge.balance_transaction
         ├─ provider has not reported it yet, or is down ──▶ skip; next run
         └─ append provider_fee: processing_fees +fee, psp_balance −fee, provider_ref = txn id
```

The balance transaction is null until the provider settles the capture — with Stripe's
asynchronous capture, the default, that can take up to an hour. "Not reported yet" is a
normal answer, and the only right response to it is to book nothing.

The worklist is a query on the ledger, so the job is idempotent by construction: once
the row exists the order stops matching. Two workers racing on one order are settled
by the unique index on `(order_id) where kind = 'provider_fee'`.

---

## 7. Conformance invariants

Pinned by `spec/conformance/`, run against the app.

| # | Invariant |
|---|---|
| C1 | Replaying an `Idempotency-Key` returns byte-identical status and body |
| C2 | Same key + different body ⇒ `422`, and the original order is untouched |
| C3 | Concurrent identical create requests produce exactly **one** order |
| C4 | A replayed webhook `event.id` is accepted (`200`) but processed exactly once |
| C5 | A webhook with a bad signature is rejected `400` and never processed |
| C6 | A webhook older than the tolerance window is rejected `400` |
| C7 | Overselling is impossible — availability never goes negative under concurrency |
| C8 | Every `paid` order has ledger entries summing to zero per currency |
| C9 | Tickets exist **iff** the order is `paid`, and count matches item quantities |
| C10 | An expired hold returns inventory exactly once, even if the job runs twice |
| C11 | A payment reaches `succeeded` only via webhook, never via the redirect return |
| C12 | Money is never returned as a float anywhere in the API |
| C13 | A decline delivered after the payment succeeded changes nothing — the order stays `paid`, its tickets stay issued, its payment stays `succeeded` |
| C14 | The provider's fee is booked as its own transaction, exactly once, for the amount the provider reports — and nothing is booked before it reports one |
| C15 | A decline keeps the order `awaiting_payment` and its seats held; if the customer walks away, the hold lapses, the session is expired at the provider, and the seats return exactly once |
| C16 | Starting a new checkout expires the previous session at the provider; if that session has already been paid, no new one is opened and the payment is honoured |
| C17 | A customer who pays as the hold lapses keeps their seats: the order is not expired, and becomes `paid` when the webhook arrives |
| C18 | A webhook whose header carries several `v1` signatures — a secret roll — is accepted if any matches, whichever position it is in; a valid signature under any other scheme is rejected |
