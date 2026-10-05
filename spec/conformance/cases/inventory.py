"""C7, C10, C15, C17 — chapter 9."""

import os
import time

from _common import (PROBE, TINY, availability, await_status, create_order, get_order,
                     order_body, psp_complete, start_checkout)
from harness import Skip, case, expect, expect_status, in_parallel, steady


@case("C7", "Overselling is impossible under concurrency", "ch9")
def c7(ctx):
    """
    The seeded 'Limited Capacity' tier holds 5. Twelve buyers arrive at once.

    This is the case that separates a correct implementation from one that merely
    looks correct in manual testing. Read-then-write without a row lock passes
    every hand test and fails here every time.
    """
    start = availability(ctx, TINY)
    expect(start >= 0, "availability must never go negative — something oversold this "
           "tier before the case even began", start)
    if start == 0:
        raise Skip("tier already exhausted — reseed before running")

    n = 12
    responses = in_parallel(
        lambda i: ctx.app.post(
            "/api/orders",
            body=order_body(ctx, TINY, qty=1, email=f"rush-{i}-{time.time()}@example.test"),
            headers={"Idempotency-Key": f"c7-{i}-{time.time()}"}), n)

    errs = [r for r in responses if isinstance(r, Exception)]
    expect(not errs, "no request may error outright — a request that times out or drops "
           "under load is one the customer will retry, against a tier that may by then "
           "have held their seat for them", errs[:2])

    created = [r for r in responses if r.status == 201]
    rejected = [r for r in responses if r.status == 422]

    expect(len(created) + len(rejected) == n,
           "every request must either succeed or be cleanly rejected 422. A 500 under "
           "contention tells the customer nothing, and their retry joins the queue again.",
           sorted(r.status for r in responses))
    expect(len(created) <= start,
           f"OVERSOLD: {len(created)} orders held against {start} available. "
           "Lock the ticket_type row inside the transaction before checking "
           "availability — SELECT ... FOR UPDATE, or an equivalent.",
           [r.status for r in responses])

    expect(len(created) == min(start, n),
           f"UNDERSOLD: {len(created)} orders for {start} seats and {n} buyers. The lock "
           "should queue buyers, not turn them away — everyone who reaches a seat that is "
           "still free must get it. Rejecting under contention (NOWAIT, or a serialisation "
           "failure answered as 422) is a sold-out page with seats still on sale.",
           [r.status for r in responses])

    remaining = availability(ctx, TINY)
    expect(remaining >= 0, "availability must never go negative", remaining)
    expect(remaining == start - len(created),
           "availability must reconcile exactly with orders created",
           f"start={start} created={len(created)} remaining={remaining}")


@case("C10", "An expired hold returns inventory exactly once", "ch9")
def c10(ctx):
    """
    Requires the app to run with a short hold TTL. Set both:
        HOLD_TTL_SECONDS=6   on the app
        HOLD_TTL_SECONDS=6   in this suite's environment
    """
    ttl = os.environ.get("HOLD_TTL_SECONDS")
    if not ttl:
        raise Skip("HOLD_TTL_SECONDS unset — run the app with a short hold TTL to exercise this")
    ttl = int(ttl)

    before = availability(ctx, PROBE)
    if before < 1:
        raise Skip("tier exhausted — reseed before running")

    r, _, _ = create_order(ctx, order_body(ctx, PROBE, qty=1))
    order_id = r.json["id"]
    held = availability(ctx, PROBE)
    expect(held == before - 1, "creating an order must hold inventory immediately",
           f"{before} -> {held}")

    time.sleep(ttl + 8)

    order = get_order(ctx, order_id)
    expect(order["status"] == "expired",
           "the sweeper must expire a lapsed hold. Inventory that is never released "
           "is indistinguishable from a sold-out show.", order)

    after = availability(ctx, PROBE)
    expect(after == before,
           "expiry must return the held inventory exactly once — no more, no less. "
           "Decrementing quantity_held without guarding on the state transition "
           "double-releases when the sweeper runs twice.",
           f"before={before} after={after}")


@case("C15", "A declined customer keeps their seats until the hold lapses", "ch9")
def c15(ctx):
    """
    On hosted Checkout a decline is not the end of anything: the customer is still
    on the page, about to try another card. So it must not move the order or give
    the seats back — which leaves the clock as the only thing that will, if the
    customer gives up instead. Needs the same short HOLD_TTL_SECONDS as C10.
    """
    ttl = os.environ.get("HOLD_TTL_SECONDS")
    if not ttl:
        raise Skip("HOLD_TTL_SECONDS unset — run the app with a short hold TTL to exercise this")
    ttl = int(ttl)

    before = availability(ctx, PROBE)
    if before < 1:
        raise Skip("tier exhausted — reseed before running")

    r, _, _ = create_order(ctx, order_body(ctx, PROBE, qty=1))
    order_id = r.json["id"]
    _, sid = start_checkout(ctx, order_id)

    session = ctx.psp.get(f"/v1/checkout/sessions/{sid}").json
    expect(session.get("payment_method_types") == ["card"],
           "the Checkout Session must be opened for cards only. Everything below — a "
           "decline the customer retries on the page — is true of cards. Left unpinned, "
           "the provider offers whatever its dashboard enables, including bank debits "
           "that confirm days after this hold has lapsed and the seats have been resold.",
           session.get("payment_method_types"))

    psp_complete(ctx, sid, succeed=0)

    def unmoved():
        order = get_order(ctx, order_id)
        expect(order["status"] == "awaiting_payment",
               "a decline moved the order. The customer is still on the payment page and "
               "the next card goes against the same session.", order)
        now = availability(ctx, PROBE)
        expect(now == before - 1,
               "a decline gave the seats back. During a sell-out, someone else takes them "
               "while this customer is typing in their second card.",
               f"before={before} now={now}")
    steady(unmoved)

    time.sleep(ttl + 8)

    order = get_order(ctx, order_id)
    expect(order["status"] == "expired",
           "a declined customer who walks away must lapse like any other hold. No event "
           "will ever say they gave up, so a sweeper that skips awaiting_payment leaves "
           "their seats held forever.", order)

    after = availability(ctx, PROBE)
    expect(after == before,
           "expiring the order must return its inventory exactly once",
           f"before={before} after={after}")

    page = ctx.psp.get(f"/v1/checkout/sessions/{sid}").json
    expect(page.get("status") == "expired",
           "the hold lapsed and the seats went back on sale, but the payment page is "
           "still OPEN. The customer can still pay — for seats someone else may now "
           "hold. Close the session at the provider before releasing the hold.",
           page.get("status"))


@case("C17", "A customer who pays as the hold lapses keeps their seats", "ch9")
def c17(ctx):
    """
    The hold lapses at the same moment the customer presses Pay, and the webhook
    is a few seconds behind. A sweeper that releases the seats first has sold them
    twice; one that closes the payment page first is refused — the session is
    already paid — and that refusal is the answer: leave the order for the
    webhook. Needs the same short HOLD_TTL_SECONDS as C10.
    """
    ttl = os.environ.get("HOLD_TTL_SECONDS")
    if not ttl:
        raise Skip("HOLD_TTL_SECONDS unset — run the app with a short hold TTL to exercise this")
    ttl = int(ttl)

    before = availability(ctx, PROBE)
    if before < 1:
        raise Skip("tier exhausted — reseed before running")

    r, _, _ = create_order(ctx, order_body(ctx, PROBE, qty=1))
    order_id = r.json["id"]
    _, sid = start_checkout(ctx, order_id)

    # Paid at the provider; the webhook saying so is held back.
    held = psp_complete(ctx, sid, hold=1)["delivery"]["event_id"]

    time.sleep(ttl + 8)

    order = get_order(ctx, order_id)
    expect(order["status"] == "awaiting_payment",
           "the sweeper expired an order whose session had already been PAID. The seats "
           "are back on sale and the customer's money has nothing to buy. Close the "
           "session first: the provider refuses, because it is paid, and that refusal "
           "means leave the order alone.", order)
    expect(availability(ctx, PROBE) == before - 1,
           "the seats of a customer who has paid were given back",
           f"before={before} now={availability(ctx, PROBE)}")

    late = ctx.psp.post(f"/_control/replay?event_id={held}")
    expect_status(late, 200, "from fake-psp replay")
    paid = await_status(ctx, order_id, "paid")

    tickets = ctx.app.get(f"/api/orders/{order_id}/tickets")
    issued = tickets.json.get("data", []) if tickets.status == 200 else []
    expect(len(issued) == sum(i["quantity"] for i in paid["items"]),
           "the order is paid but the tickets were never issued", issued)
