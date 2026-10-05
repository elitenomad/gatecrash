"""C9 — chapter 9."""

from _common import (await_status, create_order, expect_charged, order_body, psp_complete,
                     start_checkout)
from harness import case, expect, expect_status


@case("C9", "Tickets exist if and only if the order is paid", "ch9")
def c9(ctx):
    qty = 3
    r, _, body = create_order(ctx, order_body(ctx, qty=qty))
    order_id = r.json["id"]

    early = ctx.app.get(f"/api/orders/{order_id}/tickets")
    expect(early.status == 409,
           "tickets must not be readable before payment succeeds — a 200 with an "
           "empty list is not the same contract and hides fulfilment bugs", early)

    _, sid = start_checkout(ctx, order_id)
    expect_charged(ctx, sid, r.json["total"])
    still = ctx.app.get(f"/api/orders/{order_id}/tickets")
    expect(still.status == 409, "starting checkout must not issue tickets", still)

    psp_complete(ctx, sid)
    order = await_status(ctx, order_id, "paid")

    r = ctx.app.get(f"/api/orders/{order_id}/tickets")
    expect_status(r, 200, "once the order is paid")
    tickets = r.json["data"]

    expect(len(tickets) == qty,
           f"expected one ticket per admitted person ({qty})", len(tickets))
    codes = {t["code"] for t in tickets}
    expect(len(codes) == qty, "ticket codes must be unique", codes)
    for t in tickets:
        expect(len(t["code"]) >= 12,
               "ticket codes are scanned at the door and must be unguessable — a "
               "sequential id lets anyone walk in", t["code"])
        expect(t["ticket_type_id"] == body["items"][0]["ticket_type_id"],
               "ticket must reference the tier that was bought", t)
