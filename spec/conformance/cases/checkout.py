"""C16 — chapter 5."""

from _common import await_status, create_order, get_order, psp_complete, start_checkout
from harness import case, expect, expect_status


@case("C16", "Starting a new checkout closes the one before it", "ch5")
def c16(ctx):
    """
    A customer who leaves the payment page and comes back gets a fresh session.
    If the old one is still open they now hold two pages that can take their
    money, and a customer with two tabs will sooner or later pay both. So a new
    checkout must close the old session at the provider — and if the old one was
    paid in the meantime, that payment must be honoured, not replaced.
    """
    # The customer left and came back: the first session must stop taking money.
    r, _, _ = create_order(ctx)
    order_id = r.json["id"]
    _, first = start_checkout(ctx, order_id)
    _, second = start_checkout(ctx, order_id)

    old = ctx.psp.get(f"/v1/checkout/sessions/{first}").json
    expect(old.get("status") == "expired",
           "starting a new checkout left the previous session OPEN. The customer now "
           "has two pages that can take payment for one order; pay both and they are "
           "charged twice. Expire the old session at the provider first.",
           old.get("status"))

    order = get_order(ctx, order_id)
    expect(sorted(p["status"] for p in order["payments"]) == ["cancelled", "requires_payment"],
           "the replaced session's payment must say it was cancelled, and the new one "
           "that it is waiting — one row per session, each telling the truth",
           order["payments"])

    psp_complete(ctx, second)
    await_status(ctx, order_id, "paid")

    # The customer paid, then came back before the confirmation arrived.
    r, _, _ = create_order(ctx)
    order_id = r.json["id"]
    _, sid = start_checkout(ctx, order_id)
    held = psp_complete(ctx, sid, hold=1)["delivery"]["event_id"]

    again = ctx.app.post(f"/api/orders/{order_id}/checkout")
    expect(again.status == 409,
           "a new checkout was opened for an order whose previous session had already "
           "been PAID. The provider refused to expire it, and that refusal was the "
           "answer: the money is in, and its confirmation is on the way.",
           again.status)

    late = ctx.psp.post(f"/_control/replay?event_id={held}")
    expect_status(late, 200, "from fake-psp replay")
    paid = await_status(ctx, order_id, "paid")
    expect([p["status"] for p in paid["payments"]] == ["succeeded"],
           "the payment made before the customer came back must be the one that pays "
           "the order — exactly one payment, succeeded", paid["payments"])
