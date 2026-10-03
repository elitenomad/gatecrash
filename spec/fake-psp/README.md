# fake-psp

An offline stand-in for Stripe. Stdlib Python, no dependencies, one file.

Readers who stall at *"first, create an account and retrieve your API keys"* never reach
chapter 5. Every chapter runs against this instead: no network, no account, no secrets,
deterministic CI.

## Run

```sh
WEBHOOK_URL=http://localhost:3000/api/webhooks/stripe python3 server.py
# listening on http://localhost:4242
```

| env | default |
|---|---|
| `FAKE_PSP_PORT` | `4242` |
| `WEBHOOK_URL` | `http://localhost:3000/api/webhooks/stripe` |
| `WEBHOOK_SECRET` | `whsec_fake_psp_secret` |

## What it implements

**Stripe-compatible surface**

| | |
|---|---|
| `POST /v1/checkout/sessions` | form-encoded with bracket notation, honours `Idempotency-Key` |
| `GET /v1/checkout/sessions/{id}` | `?expand[]=payment_intent.latest_charge.balance_transaction`, as Stripe expands it |
| `GET /v1/payment_intents/{id}`, `GET /v1/charges/{id}` | the hops between a session and its fee |
| `POST /v1/checkout/sessions/{id}/expire` | only an `open` session; anything else is refused without saying why, so callers re-fetch. Honours `Idempotency-Key`, and sends `checkout.session.expired` |
| `GET /v1/balance_transactions/{id}` | where the fee actually lives |
| `GET /checkout/{id}` | a hosted payment page with Pay / Decline / Cancel. Decline keeps you on the page, as Checkout does |

**Control plane, for the conformance suite**

| | |
|---|---|
| `POST /_control/sessions/{id}/complete` | `?succeed=0` declines one card (the session stays open) · `?hold=1` records the event without sending it · `?roll=before\|after` adds the second `v1` a secret roll produces · `?scheme=v0` signs under the wrong scheme · `?fee_delay=N` keeps the charge's balance transaction null for N seconds · `?bad_signature=1` · `?age=900` |
| `POST /_control/replay` | deliver an event — again, or for the first time if it was held. `?event_id=` picks one; default is the latest |
| `POST /_control/fail_next` | `?count=2` `?status=429` `?retry_after=5` `?should_retry=true\|false` — queue failures for the next N `/v1/*` calls, so a client's retry policy can be watched rather than assumed |
| `GET /_control/events` | every event and delivery attempt |
| `POST /_control/reset` | |

## Where it is deliberately faithful

These are the parts the book teaches, so they match Stripe exactly:

- **Signatures.** `Stripe-Signature: t=<ts>,v1=<hmac_sha256(secret, "{ts}.{raw_body}")>`,
  computed over the raw bytes. An implementation that re-serialises the JSON before
  hashing will fail here, intermittently, exactly as it would in production. Every
  delivery attempt is signed afresh with its own timestamp, and `?roll=` adds the
  second `v1` a secret roll produces.
- **Fees are not on the session.** They live on a separate `balance_transaction`, so
  chapter 10's *"estimate the fee now or book it later?"* stays a real decision.
- **Redelivery.** Non-2xx responses are retried, so at-least-once is observable rather
  than merely asserted.
- **Provider-side idempotency**, the same contract readers implement for their own API:
  a replay carries `Idempotent-Replayed: true`, and a key reused with different
  parameters is a `400 idempotency_error`.
- **API version `2026-09-30.endive`.** Events carry it, and `payment_method_types` on a
  Checkout Session is a `400`, as it is in that version; `allowed_payment_method_types`
  filters what the "dashboard" offers.
- **The fee is three hops from the session** — payment intent, latest charge, balance
  transaction — and the last can be null for a while, as with asynchronous capture.
- **Declines, for cards on hosted Checkout.** The session stays `open` and the customer
  can try another card; the only event is `payment_intent.payment_failed`, carrying the
  PaymentIntent with `last_payment_error`. No `checkout.session.*` event says a card
  was declined.
- **`payment_intent` is null until the first attempt**, as on a real session.

## Where it is not

Single process, in-memory, no persistence — restarting is the reset button. No 3DS, no
Payment Element, no disputes, one currency per session; those arrive with the Volume 2
chapters that need them. No async payment methods at all — Gatecrash takes cards only.
A session created without `allowed_payment_method_types` reports `["card", "sepa_debit"]`, a
stand-in for "whatever the dashboard enables", so an unpinned session is visible.

One event per action: a successful payment sends `checkout.session.completed` and not
the `payment_intent.succeeded` and `charge.succeeded` that Stripe also sends, and a fee
that arrives late sends no `charge.updated` — the reconciler polls for it instead.

It is a teaching tool, not a Stripe emulator. Do not point it at anything real.
