# Gatecrash — Ruby on Rails

Rails 8.0 · Ruby 3.4 · PostgreSQL 17 · Solid Queue. Passes the shared conformance
suite 19/19.

## Run

```sh
make ruby-setup      # create databases, migrate, seed from spec/fixtures/seed.json
make psp             # terminal 1 — offline payment provider
make ruby-server     # terminal 2
make ruby-jobs       # terminal 3 — Solid Queue worker
make ruby-conformance # terminal 4
```

`HOLD_TTL_SECONDS=6` must be set on the server, the worker and the suite for `C10`,
`C15` and `C17`. The make targets do this.

| env | default |
|---|---|
| `PSP_URL` | `http://localhost:4242` |
| `PSP_WEBHOOK_SECRET` | `whsec_fake_psp_secret` |
| `PSP_RETRY_BASE_DELAY` | `0.25` |
| `IDEMPOTENCY_RETENTION_SECONDS` | `86400` |
| `IDEMPOTENCY_LOCK_TTL_SECONDS` | `300` |
| `ADMIN_TOKEN` | `dev-admin-token` |
| `HOLD_TTL_SECONDS` | `900` |
| `FRONTEND_URL` | `http://localhost:5173` |

## Dependencies

Rails 8 defaults and nothing else — no AASM, no money gem, no HTTP client, no
serializer library. That is deliberate. The parts most worth teaching are also the
parts most worth owning, and every dependency is one more thing that can be abandoned
under a book that has to keep running.

- **State machine** — four states and six edges, written out in `Order::TRANSITIONS`.
  It does not need a DSL.
- **Money** — `app/models/money.rb`, a frozen value object wired in with `composed_of`.
- **Provider client** — `app/clients/psp.rb`, `Net::HTTP` against the raw REST API.
  No SDK, so a provider change breaks exactly one file.

### `pg` is built from source, on purpose

The Gemfile pins `force_ruby_platform: true` on `pg`, so `bundle install` compiles it
against your local libpq instead of downloading the precompiled binary gem.

That gem ships its own libpq — 18.0.1 at the time of writing — and on macOS the
combination crash-loops the Solid Queue worker: forked children segfault inside
`PG::Connection#connect_start`, the supervisor respawns them, and `make ruby-jobs`
writes hundreds of megabytes of crash dumps while still, confusingly, processing jobs.
A twenty-line script that forks and connects, with no Rails and no Solid Queue
involved, reproduces it.

Building from source links the libpq that matches the server you are actually running,
and the worker goes silent. The cost is that you need libpq headers and a compiler:
Postgres.app and Homebrew both provide them, and on Debian it is `libpq-dev`.

## Where the interesting parts are

| | |
|---|---|
| `app/models/money.rb` | minor units, currency exponents, largest-remainder `allocate` |
| `app/controllers/concerns/idempotent.rb` | claim-by-INSERT, byte-identical replay |
| `app/services/idempotency_keys/prune.rb` | retention, and reclaiming keys a dead process left claimed |
| `app/clients/psp.rb` | HMAC verification over the raw body, constant-time compare |
| `app/controllers/api/webhooks_controller.rb` | verify → dedupe → 200 → enqueue |
| `app/services/payments/fulfil.rb` | the only path to `paid` |
| `app/services/payments/handle_event.rb` | a late failure event must not speak for the whole order |
| `app/services/ledger/record_sale.rb` | double-entry, fee read from the balance transaction |
| `app/services/orders/create.rb` | `FOR UPDATE` before reading availability |
| `db/migrate/` | the constraints that catch what the application logic misses |

## Two things the database enforces, not the app

Application code is correct today and gets refactored tomorrow. These survive that:

- `ticket_types_inventory_within_capacity` — a check constraint making
  `held + sold > total` unrepresentable. If the row lock is ever lost in a refactor,
  the transaction dies instead of selling a seat that does not exist.
- `index_one_ticket_sale_per_order` — a partial unique index, so a redelivered webhook
  cannot double-book revenue even if every application guard fails.

Both are verified as real, not decorative:

```sh
bin/rails runner 'TicketType.first.update_column(:quantity_held, 10_000)'
# => PG::CheckViolation: ticket_types_inventory_within_capacity
```

## Tests

```sh
make ruby-test    # 127 runs, 442 assertions — no PSP, no worker, no network
```

Minitest, no factories, no mocking library. The conformance suite is black-box and
says nothing about units, so these cover what it cannot reach:

| | |
|---|---|
| `test/models/money_test.rb` | allocation never loses a minor unit, across many splits; JPY formats as `4000 JPY` not `40.00` |
| `test/models/order_test.rb` | every edge in the transition table, **and every edge not in it** |
| `test/clients/psp_test.rb` | forged signatures, tampered bodies, malformed headers, stale and future timestamps, re-serialised JSON; any `v1` during a secret roll, and no other scheme |
| `test/clients/psp_transport_test.rb` | retries 5xx, 429 and 409, believes `Stripe-Should-Retry` either way, reuses one idempotency key across a retry, pins `Stripe-Version`, sends ISK and UGX in hundredths, reads the fee through `expand` — against a real socket |
| `test/models/ledger_transaction_test.rb` | balances **per currency** — +100 GBP against −100 JPY is not balanced |
| `test/services/orders/expire_holds_test.rb` | repeated sweeps release inventory exactly once; the payment page is closed first, and a customer who paid as the hold lapsed keeps their seats |
| `test/services/idempotency_keys/prune_test.rb` | sweeps abandoned claims, never steals a key from a slow request |
| `test/services/payments/fulfil_test.rb` | redelivery issues nothing further; refuses an already-expired order; issues nothing for a session completed unpaid; records a second payment for a paid order |
| `test/services/payments/handle_event_test.rb` | a decline changes nothing, even when it arrives after the card that worked |
| `test/services/payments/start_checkout_test.rb` | a provider outage leaves the order untouched; coming back closes the old session first, and opens nothing if it was already paid |
| `test/integration/` | byte-identical replay, RFC 9457 shape, webhook 400 vs 200 |

Two design notes:

- **No mocking library.** `minitest/mock` is not loadable under Ruby 3.4's bundled-gem
  rules, and rather than add a gem, `Ledger::RecordSale` takes an injected `fee_reader`.
  The only part of that service touching the network became an explicit collaborator,
  which is better design than reaching for a global and stubbing it.
- **Tests are not parallelised.** They exercise row locks and exactly-once semantics;
  serial execution keeps failures reproducible and avoids a second queue database per
  worker.

## Not yet built

Volume 1 scope only. No Payment Element or 3DS, no refunds, disputes, subscriptions,
marketplace payouts, or tax.
