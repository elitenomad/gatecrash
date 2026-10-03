"""Shared helpers. Anything an implementation could special-case does not belong here."""

import uuid
from harness import Failure, expect, expect_status, poll_until

GA = "General Admission"
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


def get_order(ctx, order_id):
    r = ctx.app.get(f"/api/orders/{order_id}")
    expect_status(r, 200, f"from GET /api/orders/{order_id}")
    return r.json


def await_status(ctx, order_id, want, timeout=20):
    return poll_until(
        lambda: (lambda o: o if o["status"] == want else None)(get_order(ctx, order_id)),
        timeout=timeout, what=f"order {order_id} to reach {want!r}")


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
