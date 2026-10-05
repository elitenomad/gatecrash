"""Shared helpers. Anything an implementation could special-case does not belong here."""

import uuid
from harness import Failure, expect, expect_status, poll_until

GA = "General Admission"
EARLY = "Early Bird"     # chapter 7's cases only, so its availability is theirs to count
TINY = "Limited Capacity"
PROBE = "Hold Expiry Probe"
YEN = "Advance"


def key():
    return str(uuid.uuid4())


def order_body(ctx, tt_name=GA, qty=1, email=None):
    ev, tt = ctx.ticket_type(tt_name)
    return {
        "event_id": ev["id"],
        "email": email or f"buyer-{uuid.uuid4().hex[:8]}@example.test",
        "items": [{"ticket_type_id": tt["id"], "quantity": qty}],
    }


def create_order(ctx, body=None, idem=None, expect_created=True):
    body = body or order_body(ctx)
    idem = idem or key()
    r = ctx.app.post("/api/orders", body=body, headers={"Idempotency-Key": idem})
    if expect_created:
        expect_status(r, 201, "from POST /api/orders")
    return r, idem, body


def start_checkout(ctx, order_id):
    r = ctx.app.post(f"/api/orders/{order_id}/checkout")
    expect_status(r, 201, "from POST /api/orders/{id}/checkout")
    url = r.json.get("checkout_url") or ""
    expect(url, "checkout response must carry checkout_url", r.json)
    return r.json, url.rstrip("/").rsplit("/", 1)[-1]


def psp_complete(ctx, session_id, **query):
    q = "&".join(f"{k}={v}" for k, v in query.items())
    path = f"/_control/sessions/{session_id}/complete" + (f"?{q}" if q else "")
    r = ctx.psp.post(path)
    expect_status(r, 200, "from fake-psp complete")
    return r.json


def psp_session(ctx, session_id, expand=None):
    """The session as the provider has it — what was actually asked for."""
    path = f"/v1/checkout/sessions/{session_id}" + (f"?expand[]={expand}" if expand else "")
    r = ctx.psp.get(path)
    expect_status(r, 200, f"from fake-psp GET {path}")
    return r.json


def expect_charged(ctx, session_id, total):
    """The provider must have been asked for exactly the order's total."""
    s = psp_session(ctx, session_id)
    asked = {"amount": s.get("amount_total"), "currency": (s.get("currency") or "").upper()}
    expect(asked == total,
           f"the provider was asked to charge {asked['amount']} {asked['currency']} for an "
           f"order of {total['amount']} {total['currency']}. Every case before this one "
           "could pass with that — the order, the payment row and the ledger all agree with "
           "each other — while the customer's card is charged the wrong amount.",
           {"session": asked, "order_total": total})


def get_order(ctx, order_id):
    r = ctx.app.get(f"/api/orders/{order_id}")
    expect_status(r, 200, f"from GET /api/orders/{order_id}")
    return r.json


def await_status(ctx, order_id, want, timeout=20):
    seen = []

    def reached():
        order = get_order(ctx, order_id)
        seen.append(order["status"])
        return order if order["status"] == want else None

    try:
        return poll_until(reached, timeout=timeout, what=f"order {order_id} to reach {want!r}")
    except Failure:
        hint = (" Fulfilment runs in a background job: if the webhook was answered 200 and "
                "nothing moved, is the worker running? (With Rails, bin/jobs.)"
                if want == "paid" else "")
        raise Failure(f"order {order_id} never reached {want!r} in {timeout}s; it is still "
                      f"{seen[-1]!r}.{hint}") from None


def availability(ctx, tt_name):
    ev, tt = ctx.ticket_type(tt_name)
    r = ctx.app.get(f"/api/events/{ev['slug']}")
    expect_status(r, 200)
    for t in r.json["ticket_types"]:
        if t["id"] == tt["id"]:
            return t["available"]
    raise Failure(f"ticket type {tt['id']} missing from GET /api/events/{ev['slug']}")


def buy(ctx, tt_name=GA, qty=1):
    """Full happy path. Returns the paid order."""
    r, _, _ = create_order(ctx, order_body(ctx, tt_name, qty))
    order_id = r.json["id"]
    _, sid = start_checkout(ctx, order_id)
    psp_complete(ctx, sid)
    return await_status(ctx, order_id, "paid")
