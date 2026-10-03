# Gatecrash

A ticketing platform for live events that takes money correctly — the application
built in the book *Modern Payments with Ruby on Rails*.

Rails 8 · Ruby 3.4 · PostgreSQL · Solid Queue. Postgres is the only infrastructure:
no Redis, no Docker.

## What is here

```
apps/ruby/          the Rails app the book builds
spec/DOMAIN.md      the domain model, field by field: states, invariants, the ledger
spec/DIAGRAMS.md    the same model as pictures
spec/openapi.yaml   the HTTP contract the app exposes
spec/conformance/   black-box tests that hold an implementation to that contract
spec/fake-psp/      an offline stand-in for Stripe — no account, no keys, no network
spec/reference/     an in-memory implementation the suite is validated against
spec/fixtures/      the seed data every run starts from
```

The conformance suite is stdlib Python and speaks only HTTP, so it can test an
implementation in any language, yours included; the book's Appendix C shows how.

`spec/reference/` passes the suite only because one process holding one lock
serialises everything, which is not how any of it is solved against Postgres. It
is a test fixture. Never copy from it.

## Running it

You need Ruby 3.4, Python 3 (stdlib only), and PostgreSQL 13 or later running
locally with its headers — the Gemfile builds `pg` from source.

```sh
make ruby-setup        # create the databases, migrate, seed
make psp               # terminal 1 — the offline payment provider, :4242
make ruby-server       # terminal 2 — the app, :3000
make ruby-jobs         # terminal 3 — the Solid Queue worker
make ruby-conformance  # terminal 4 — reseed, then run the suite; every case should pass
```

The worker is not optional: fulfilment is a job, so without it webhooks are
recorded and never acted on. `make ruby-test` runs the unit tests, which need no
provider, no worker and no network. `make help` lists everything else.

## How this repository is made

Every code sample in the book names its file relative to the root of this
repository, and is extracted from it rather than pasted. This repository is
exported from the book's source: each commit names the revision it came from,
and changes made here directly are overwritten by the next export.

## Licence

MIT — see [LICENSE](LICENSE).
