"""C4-C6, C11, C13, C18 — chapter 8."""

from _common import await_status, create_order, get_order, psp_complete, start_checkout
from harness import case, expect, expect_status, steady


def _tickets(ctx, order_id):
    r = ctx.app.get(f"/api/orders/{order_id}/tickets")
    return r.json.get("data", []) if r.status == 200 else []


def _sales(ctx, order_id):
    """Only the ticket_sale rows. The reconciler may legitimately add a provider_fee
    between two reads; a replay must never add a second SALE."""
    r = ctx.app.get(f"/api/admin/orders/{order_id}/ledger", admin=True)
    data = r.json.get("data", []) if r.status == 200 else []
    return [t for t in data if t["kind"] == "ticket_sale"]


@case("C4", "A replayed webhook is accepted but processed exactly once", "ch8")
def c4(ctx):
    r, _, _ = create_order(ctx)
    order_id = r.json["id"]
    _, sid = start_checkout(ctx, order_id)

    delivery = psp_complete(ctx, sid)["delivery"]
    first = delivery["attempts"][0]["status"] if delivery["attempts"] else None
    expect(first is not None and 200 <= first < 300,
           "a genuinely signed event was rejected. The provider signed the exact bytes it "
           "sent: verify over the raw request body. Parsed and re-serialised JSON has "
           "different whitespace and different escapes, so its digest never matches.",
           delivery["attempts"])
    event_id = delivery["event_id"]
    await_status(ctx, order_id, "paid")
    before_tickets, before_sales = _tickets(ctx, order_id), _sales(ctx, order_id)

    replay = ctx.psp.post(f"/_control/replay?event_id={event_id}")
    expect_status(replay, 200, "from fake-psp replay")
    attempts = replay.json["delivery"]["attempts"]
    expect(200 <= attempts[0]["status"] < 300,
           "a duplicate event must be answered 200. It is a true statement we have "
           "already acted on — 4xx makes the provider retry it forever.", attempts)

    def nothing_more():
        expect(len(_tickets(ctx, order_id)) == len(before_tickets),
               "the replay issued MORE TICKETS. Deduplicate on provider_event_id with a "
               "uniqueness constraint before doing any work.",
               f"{len(before_tickets)} -> {len(_tickets(ctx, order_id))}")
        expect(len(_sales(ctx, order_id)) == len(before_sales),
               "the replay double-booked the sale",
               f"{len(before_sales)} -> {len(_sales(ctx, order_id))}")
    steady(nothing_more)


@case("C5", "A webhook with a bad signature is rejected and never processed", "ch8")
def c5(ctx):
    r, _, _ = create_order(ctx)
    order_id = r.json["id"]
    _, sid = start_checkout(ctx, order_id)

    result = psp_complete(ctx, sid, bad_signature=1)
    statuses = [a["status"] for a in result["delivery"]["attempts"]]
    expect(all(s == 400 for s in statuses),
           "every delivery attempt with a forged signature must be rejected 400", statuses)

    def unpaid():
        order = get_order(ctx, order_id)
        expect(order["status"] != "paid",
               "an unsigned event marked the order PAID. This is the whole ballgame: "
               "anyone who can reach your webhook URL can now mint free tickets.", order)
        expect(_tickets(ctx, order_id) == [], "no tickets may be issued")
    steady(unpaid)


@case("C6", "A webhook outside the timestamp tolerance is rejected", "ch8")
def c6(ctx):
    r, _, _ = create_order(ctx)
    order_id = r.json["id"]
    _, sid = start_checkout(ctx, order_id)

    result = psp_complete(ctx, sid, age=900)
    statuses = [a["status"] for a in result["delivery"]["attempts"]]
    expect(all(s == 400 for s in statuses),
           "a correctly-signed but stale event must still be rejected. The signature "
           "proves authorship, not freshness — without a timestamp check a captured "
           "request can be replayed indefinitely.", statuses)

    steady(lambda: expect(get_order(ctx, order_id)["status"] != "paid",
                          "stale event must not fulfil"))


@case("C11", "A payment succeeds only via webhook, never via the redirect", "ch8")
def c11(ctx):
    r, _, _ = create_order(ctx)
    order_id = r.json["id"]
    _, sid = start_checkout(ctx, order_id)

    order = get_order(ctx, order_id)
    expect(order["status"] == "awaiting_payment",
           "creating a checkout session must not mark the order paid", order)

    # The customer pays and is sent back to the success page, which polls. The
    # provider already says the session is paid; its webhook is held back.
    held = psp_complete(ctx, sid, hold=1)["delivery"]["event_id"]

    steady(lambda: expect(
        get_order(ctx, order_id)["status"] == "awaiting_payment",
        "the order was marked paid before its webhook arrived. The customer has paid and "
        "been redirected back, and the provider would say so if asked — but the redirect "
        "is a hint the customer controls, and a read on demand skips the one signal that "
        "is signed, recorded and redelivered. Only the webhook may move an order to paid.",
        get_order(ctx, order_id)["status"]))

    late = ctx.psp.post(f"/_control/replay?event_id={held}")
    expect_status(late, 200, "from fake-psp replay")
    paid = await_status(ctx, order_id, "paid")
    succeeded = [p for p in paid["payments"] if p["status"] == "succeeded"]
    expect(len(succeeded) == 1, "exactly one payment should have succeeded", paid["payments"])


@case("C13", "A decline delivered late does not undo the payment that followed it", "ch8")
def c13(ctx):
    """Events do not arrive in the order they happened.

    On hosted Checkout a declined customer tries another card on the same page,
    so the decline and the success belong to ONE session. The provider does not
    promise to deliver their events in order. A late decline allowed to speak
    for the session overwrites a payment that succeeded with one that did not.
    """
    r, _, _ = create_order(ctx)
    order_id = r.json["id"]
    _, sid = start_checkout(ctx, order_id)

    # The first card is declined. Its event is held back.
    declined = psp_complete(ctx, sid, succeed=0, hold=1)["delivery"]["event_id"]

    # The second card, on the same page, succeeds — and its event arrives first.
    psp_complete(ctx, sid)
    await_status(ctx, order_id, "paid")

    # Only now does the decline arrive.
    late = ctx.psp.post(f"/_control/replay?event_id={declined}")
    expect_status(late, 200, "from fake-psp replay")
    attempts = late.json["delivery"]["attempts"]
    expect(attempts and 200 <= attempts[0]["status"] < 300,
           "the late decline must be answered 2xx. It is a true event with nothing "
           "left to do — a 4xx makes the provider redeliver it for days.", attempts)

    def still_paid():
        order = get_order(ctx, order_id)
        expect(order["status"] == "paid",
               "a late decline moved a paid order. The decline is about one card, on a "
               "page the customer had already moved past.", order)
        expect(len(order["payments"]) == 1,
               "a decline retried on the same Checkout page is ONE payment — one session "
               "— not two", order["payments"])
        expect(order["payments"][0]["status"] == "succeeded",
               "the late decline overwrote a payment that SUCCEEDED. The money moved; the "
               "record now says it did not — and the fee reconciler, which looks for the "
               "succeeded payment, will never book this order's fee.", order["payments"])
    steady(still_paid)
    order = get_order(ctx, order_id)

    tickets = ctx.app.get(f"/api/orders/{order_id}/tickets")
    issued = tickets.json.get("data", []) if tickets.status == 200 else []
    expect(len(issued) == sum(i["quantity"] for i in order["items"]),
           "the order is paid but its tickets are gone", issued)


@case("C18", "A webhook signed during a secret roll is accepted, on v1 alone", "ch8")
def c18(ctx):
    """
    While a webhook secret is being rolled, the provider signs each event once per
    active secret, so a genuine header carries more than one v1 — for up to a
    day. A receiver that checks only one of them rejects real events for as long
    as the roll lasts. A receiver that checks every value regardless of scheme
    accepts a signature it was supposed to ignore.
    """
    for where in ("before", "after"):
        r, _, _ = create_order(ctx)
        order_id = r.json["id"]
        _, sid = start_checkout(ctx, order_id)

        result = psp_complete(ctx, sid, roll=where)
        statuses = [a["status"] for a in result["delivery"]["attempts"]]
        expect(statuses and 200 <= statuses[0] < 300,
               f"a genuine event was rejected because its header carried a second v1 "
               f"signature ({where} ours). During a secret roll the provider signs with "
               "every active secret: check each v1 and accept if any matches. Otherwise "
               "every webhook fails until the roll ends — up to a day of customers who "
               "have paid and have no tickets.", statuses)
        await_status(ctx, order_id, "paid")

    # The right signature, under the wrong scheme.
    r, _, _ = create_order(ctx)
    order_id = r.json["id"]
    _, sid = start_checkout(ctx, order_id)

    result = psp_complete(ctx, sid, scheme="v0")
    statuses = [a["status"] for a in result["delivery"]["attempts"]]
    expect(all(s == 400 for s in statuses),
           "a signature under a scheme other than v1 was accepted. Only v1 is valid; a "
           "receiver that takes any scheme lets an attacker pick the weakest one the "
           "provider has ever used.", statuses)

    steady(lambda: expect(get_order(ctx, order_id)["status"] != "paid",
                          "an event signed only under v0 marked the order paid"))
