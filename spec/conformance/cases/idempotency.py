"""C1-C3 — chapter 7.

All three count seats as well as responses, on a tier no other case touches. A
response can be exactly right while the request behind it did the work again:
an app that holds the seats a second time and then answers with the stored
body passes every check that only reads bodies.
"""

from _common import EARLY, availability, get_order, order_body
from harness import case, expect, expect_status, in_parallel


def _held_once(ctx, before, qty, what):
    after = availability(ctx, EARLY)
    expect(after == before - qty,
           f"{what} Availability should have dropped by {qty}, once. A key that replays "
           "the response but repeats the work holds seats nobody can buy, for an order "
           "nobody will pay for, until the hold lapses.",
           f"before={before} after={after}")


@case("C1", "Replaying an Idempotency-Key returns byte-identical status and body", "ch7")
def c1(ctx):
    body = order_body(ctx, EARLY)
    k = "c1-" + body["email"]
    before = availability(ctx, EARLY)

    first = ctx.app.post("/api/orders", body=body, headers={"Idempotency-Key": k})
    expect_status(first, 201, "on first create")

    second = ctx.app.post("/api/orders", body=body, headers={"Idempotency-Key": k})

    expect(second.status == first.status,
           "replay must return the ORIGINAL status, not 200",
           f"first={first.status} replay={second.status}")
    expect(second.raw == first.raw,
           "replay must return a byte-identical body. Re-rendering the order is not "
           "enough: timestamps and association ordering drift, and clients diff it.",
           f"first={first.raw[:200]!r} replay={second.raw[:200]!r}")
    _held_once(ctx, before, 1, "the replay held the seats again.")


@case("C2", "Same key with a different payload is rejected, original untouched", "ch7")
def c2(ctx):
    body = order_body(ctx, EARLY)
    k = "c2-" + body["email"]
    before = availability(ctx, EARLY)

    first = ctx.app.post("/api/orders", body=body, headers={"Idempotency-Key": k})
    expect_status(first, 201)
    order_id = first.json["id"]

    mutated = dict(body)
    mutated["items"] = [{**body["items"][0], "quantity": body["items"][0]["quantity"] + 3}]
    clash = ctx.app.post("/api/orders", body=mutated, headers={"Idempotency-Key": k})

    expect(clash.status == 422,
           "reusing a key for a different request is a client bug and must be loud. "
           "Silently serving the stale response hides it.", clash)

    after = get_order(ctx, order_id)
    expect(after["items"][0]["quantity"] == body["items"][0]["quantity"],
           "the rejected request changed the original order. The client's first request "
           "is the one it meant; a 422 has to mean nothing was done.", after)
    _held_once(ctx, before, body["items"][0]["quantity"],
               "the rejected request held seats of its own.")


@case("C3", "Concurrent identical creates produce exactly one order", "ch7")
def c3(ctx):
    body = order_body(ctx, EARLY)
    k = "c3-" + body["email"]
    n = 8
    before = availability(ctx, EARLY)

    responses = in_parallel(
        lambda _: ctx.app.post("/api/orders", body=body, headers={"Idempotency-Key": k}), n)

    errs = [r for r in responses if isinstance(r, Exception)]
    expect(not errs, "no request may error outright", errs[:2])

    created = [r for r in responses if r.status == 201]
    inflight = [r for r in responses if r.status == 409]
    expect(len(created) >= 1, "at least one request must succeed",
           [r.status for r in responses])
    expect(len(created) + len(inflight) == n,
           "every concurrent request must be either the winner, a replay, or 409 in-flight",
           [r.status for r in responses])

    ids = {r.json["id"] for r in created}
    expect(len(ids) == 1,
           "concurrent replays created MORE THAN ONE order. The idempotency record "
           "must be inserted under a uniqueness constraint, not checked-then-written.",
           ids)
    _held_once(ctx, before, 1, f"{n} concurrent requests with one key held seats more than once.")
