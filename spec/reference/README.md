# Reference implementation

**A test fixture, not a teaching artifact. Do not copy from here.**

An in-memory implementation of the Gatecrash contract, existing for two reasons:

1. **To validate the conformance suite.** Tests that have never passed against anything
   are not a spec, they are a wish list. This is what they were developed against — and
   it caught two real bugs in the suite on first run.
2. **To give readers a known-good target**, so a broken harness setup can be told apart
   from a broken implementation.

## Run

```sh
WEBHOOK_URL=http://localhost:3000/api/webhooks/stripe python3 ../fake-psp/server.py &
python3 app.py
```

| env | default |
|---|---|
| `PORT` | `3000` |
| `PSP_URL` | `http://localhost:4242` |
| `WEBHOOK_SECRET` | `whsec_fake_psp_secret` |
| `ADMIN_TOKEN` | `dev-admin-token` |
| `HOLD_TTL_SECONDS` | `900` |

## Why you should not learn from it

It stores everything in Python dictionaries behind one global lock, has no database, no
migrations, no persistence, no real concurrency, and no error handling worth the name.
It passes `C3` and `C7` because a single process holding a mutex trivially serialises —
which is emphatically *not* how you solve those problems against Postgres.

The Rails app in `apps/ruby/` is the real one. This exists so the tests that judge it
are themselves trustworthy.
