# Conformance suite

Black-box tests, run over HTTP against the app. Nothing here knows it is talking to
Rails — it speaks the contract in [`../openapi.yaml`](../openapi.yaml) and nothing else,
and it is written in a different language from the app so that it never can.

This is what makes the book's claims checkable. Every invariant a chapter states is
pinned by a case here, and the same suite runs unchanged against the in-memory
[`../reference/`](../reference/), so a broken harness can be told apart from a broken
app.

## Run

```sh
# 1. start the provider
WEBHOOK_URL=http://localhost:3000/api/webhooks/stripe python3 ../fake-psp/server.py &

# 2. start your app, seeded from ../fixtures/seed.json
# 3. run
python3 run.py --base-url http://localhost:3000
```

```
--only C1,C7        run a subset
--list              show the catalogue
--psp-url URL       fake-psp control plane (default http://localhost:4242)
--admin-token TOK   bearer for /api/admin routes
--allow-skips       exit 0 even if a case skipped
```

**Reseed before every run.** Several cases consume inventory; `C7` drains a tier on purpose.

`C10`, `C15` and `C17` need a short hold TTL. Set `HOLD_TTL_SECONDS=6` on *both* the app and
the suite, or they skip. A skip fails the run — it is a case that did not run — unless you
pass `--allow-skips`.

## The cases

| | chapter | |
|---|---|---|
| C12 | 3 | Money is never a float and never a bare number |
| C12b | 3 | Zero-decimal currencies survive without a hardcoded `/100` |
| C16 | 5 | Starting a new checkout closes the one before it |
| C1 | 7 | Replaying an `Idempotency-Key` returns byte-identical status and body |
| C2 | 7 | Same key, different payload is rejected; the original is untouched |
| C3 | 7 | Concurrent identical creates produce exactly one order |
| C4 | 8 | A replayed webhook is accepted but processed exactly once |
| C5 | 8 | A forged signature is rejected and never processed |
| C6 | 8 | A stale timestamp is rejected even when correctly signed |
| C11 | 8 | A payment succeeds only via webhook, never via the redirect |
| C13 | 8 | A decline delivered late does not undo the payment that followed it |
| C18 | 8 | A webhook signed during a secret roll is accepted, on v1 alone |
| C7 | 9 | Overselling is impossible under concurrency |
| C9 | 9 | Tickets exist if and only if the order is paid |
| C10 | 9 | An expired hold returns inventory exactly once |
| C15 | 9 | A declined customer keeps their seats until the hold lapses |
| C17 | 9 | A customer who pays as the hold lapses keeps their seats |
| C8 | 10 | Every paid order books ledger entries summing to zero per currency |
| C14 | 10 | The provider's fee is booked as its own transaction, exactly once, for the amount the provider reports |

## Is the suite itself any good?

A test that has never failed proves nothing. The suite is checked in both directions:

- it passes, 19/19, against [`../reference/`](../reference/) — and `mutation_test.py`
  checks that first, because a mutation "caught" by a suite that fails anyway proves
  nothing
- it is mutation-tested: the reference is broken thirty-three ways — signatures,
  idempotency, money, concurrency, the redirect, the sweeper, declines, checkout and the
  reconciler, each listed in `MUTATIONS` — and **33/33 are caught by the expected case,
  failing with the message written for that bug**. A mutation caught by some other
  assertion reports `WRONG`, because the check meant for it has still never fired

Re-run that check after adding or editing a case.

## Adding a case

```python
from harness import case, expect

@case("C16", "Short imperative statement of the invariant", "ch9")
def c16(ctx):
    ...
    expect(condition,
           "what went wrong AND why it matters — this string is the only "
           "explanation a failing reader gets",
           actual_value)
```

`ctx` gives you `ctx.app`, `ctx.psp`, `ctx.seed`, and `ctx.ticket_type(name)`. If a case
can only be written by reaching inside one stack, it does not belong here.
