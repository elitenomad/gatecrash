#!/usr/bin/env python3
"""
An in-memory reference implementation of the Gatecrash contract.

THIS IS A TEST FIXTURE, NOT A TEACHING ARTIFACT.

It exists for exactly two reasons:

  1. to validate the conformance suite itself — tests that have never passed
     against anything are not a spec, they are a wish list
  2. to give readers of any track a known-good target, so they can tell a broken
     harness setup apart from a broken implementation

It stores everything in dictionaries, runs in one process, and would be a
terrible way to build this for real. The four book implementations are the
real ones. Do not copy from here.

Run:
    WEBHOOK_URL=http://localhost:3000/api/webhooks/stripe python3 ../fake-psp/server.py &
    python3 app.py
"""

import hashlib
import hmac
import json
import os
import pathlib
import secrets
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

PORT = int(os.environ.get("PORT", "3000"))
PSP_URL = os.environ.get("PSP_URL", "http://localhost:4242")
WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET", "whsec_fake_psp_secret")
ADMIN_TOKEN = os.environ.get("ADMIN_TOKEN", "dev-admin-token")
HOLD_TTL = int(os.environ.get("HOLD_TTL_SECONDS", "900"))
TOLERANCE = 300

SEED = pathlib.Path(__file__).resolve().parent.parent / "fixtures" / "seed.json"

LOCK = threading.RLock()
DB = {"events": {}, "ticket_types": {}, "orders": {}, "payments": {}, "tickets": {},
      "webhook_events": {}, "idempotency": {}, "ledger": {}}


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def money(amount, currency):
    return {"amount": int(amount), "currency": currency.upper()}


def load_seed():
    data = json.loads(SEED.read_text())
    with LOCK:
        for ev in data["events"]:
            DB["events"][ev["id"]] = {k: v for k, v in ev.items() if k != "ticket_types"}
            for tt in ev["ticket_types"]:
                DB["ticket_types"][tt["id"]] = {
                    **{k: v for k, v in tt.items() if not k.startswith("_")},
                    "event_id": ev["id"], "quantity_held": 0, "quantity_sold": 0}
    print(f"seeded {len(DB['events'])} events, {len(DB['ticket_types'])} ticket types")


# --------------------------------------------------------------------------- #
# serialisation
# --------------------------------------------------------------------------- #

def tt_json(tt):
    return {"id": tt["id"], "name": tt["name"],
            "price": money(tt["price_amount"], tt["price_currency"]),
            "available": tt["quantity_total"] - tt["quantity_held"] - tt["quantity_sold"]}


def event_json(ev, detail=False):
    tts = [t for t in DB["ticket_types"].values() if t["event_id"] == ev["id"]]
    out = {"id": ev["id"], "slug": ev["slug"], "name": ev["name"],
           "starts_at": ev["starts_at"], "venue_name": ev["venue_name"],
           "status": ev["status"],
           "price_from": money(min(t["price_amount"] for t in tts),
                               tts[0]["price_currency"]) if tts else None}
    if detail:
        out["ticket_types"] = [tt_json(t) for t in tts]
    return out


def order_json(o):
    return {
        "id": o["id"], "event_id": o["event_id"], "email": o["email"],
        "status": o["status"],
        "total": money(o["total_amount"], o["total_currency"]),
        "hold_expires_at": o["hold_expires_at"],
        "items": [{"id": i["id"], "ticket_type_id": i["ticket_type_id"],
                   "ticket_type_name": DB["ticket_types"][i["ticket_type_id"]]["name"],
                   "quantity": i["quantity"],
                   "unit_price": money(i["unit_price_amount"], i["unit_price_currency"])}
                  for i in o["items"]],
        "payments": [{"id": p["id"], "provider": p["provider"], "status": p["status"],
                      "amount": money(p["amount"], p["currency"]),
                      "created_at": p["created_at"]}
                     for p in DB["payments"].values() if p["order_id"] == o["id"]],
        "created_at": o["created_at"]}


# --------------------------------------------------------------------------- #
# fulfilment
# --------------------------------------------------------------------------- #

def fulfil(session):
    """Runs once per payment. Guarded by the caller's dedupe on provider_event_id."""
    ref = session["id"]
    with LOCK:
        payment = next((p for p in DB["payments"].values() if p["provider_ref"] == ref), None)
        if payment is None:
            return
        order = DB["orders"][payment["order_id"]]
        if payment["status"] == "succeeded":
            return
        if session.get("payment_status") != "paid":
            return                              # completed is not the same as paid

        # The money arrived whatever state the order is in. Only awaiting_payment
        # has an edge to paid; an order paid by another session, or whose hold
        # lapsed, is owed a refund, not tickets.
        payment["status"] = "succeeded"
        if order["status"] != "awaiting_payment":
            return
        order["status"] = "paid"
        order["hold_expires_at"] = None

        for item in order["items"]:
            tt = DB["ticket_types"][item["ticket_type_id"]]
            tt["quantity_held"] -= item["quantity"]
            tt["quantity_sold"] += item["quantity"]
            for _ in range(item["quantity"]):
                tid = str(uuid.uuid4())
                DB["tickets"][tid] = {
                    "id": tid, "order_id": order["id"],
                    "ticket_type_id": tt["id"], "ticket_type_name": tt["name"],
                    "code": secrets.token_urlsafe(16), "issued_at": now()}

        # The sale is OUR fact and needs nothing from the network, so it is
        # written under the same lock as `paid`. The provider's fee is theirs;
        # book_fees() asks for it separately.
        cur = order["total_currency"]
        total = order["total_amount"]
        txn_id = str(uuid.uuid4())
        DB["ledger"][txn_id] = {
            "id": txn_id, "kind": "ticket_sale", "order_id": order["id"],
            "provider_ref": None, "occurred_at": now(),
            "entries": [
                {"account": "psp_balance", "amount": money(total, cur)},
                {"account": "ticket_revenue", "amount": money(-total, cur)},
            ]}


def _psp_get(path):
    with urllib.request.urlopen(f"{PSP_URL}{path}", timeout=5) as r:
        return json.loads(r.read())


def _psp_expire(sid):
    """True if the provider expired the session, False if it refused to."""
    req = urllib.request.Request(f"{PSP_URL}/v1/checkout/sessions/{sid}/expire",
                                 data=b"", method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10):
            return True
    except urllib.error.HTTPError as e:
        if 400 <= e.code < 500:
            return False
        raise


def close_open_sessions(order_id):
    """No page that can take money outlives the seats it is selling (C16, C17).

    True once nothing on the order can take money; False if a session was already
    paid. The provider is the lock: it expires only an open session, so a refusal
    means the session completed or lapsed first — re-read it to find out which.
    Raises OSError if the provider cannot be reached."""
    with LOCK:
        still_open = [p for p in DB["payments"].values()
                      if p["order_id"] == order_id and p["status"] == "requires_payment"]
    for p in still_open:
        if not _psp_expire(p["provider_ref"]):
            status = _psp_get(f"/v1/checkout/sessions/{p['provider_ref']}")["status"]
            if status == "complete":
                return False
            if status != "expired":
                raise OSError(f"session {p['provider_ref']} is {status} and would not expire")
        with LOCK:
            p["status"] = "cancelled"
    return True


def _lapsed(order):
    return bool(order["hold_expires_at"]) and time.time() > order["_expires_epoch"]


def _holding(order):
    return order["status"] in ("pending", "awaiting_payment")


def book_fees():
    """The reconciler. Returns how many provider_fee transactions it wrote.

    The worklist is a query on the ledger — paid orders with no provider_fee —
    so once a fee is booked the order stops matching and the job is idempotent
    without a flag. The fee lives on the balance transaction, three hops from
    the session, exactly as with real Stripe — and is null until the capture
    settles, so "not reported yet" is a normal answer, not an error.
    """
    with LOCK:
        booked_for = {t["order_id"] for t in DB["ledger"].values() if t["kind"] == "provider_fee"}
        todo = [o["id"] for o in DB["orders"].values()
                if o["status"] == "paid" and o["id"] not in booked_for]

    booked = 0
    for order_id in todo:
        with LOCK:
            payment = next((p for p in DB["payments"].values()
                            if p["order_id"] == order_id and p["status"] == "succeeded"), None)
        if payment is None:
            continue
        try:
            session = _psp_get(f"/v1/checkout/sessions/{payment['provider_ref']}"
                               "?expand[]=payment_intent.latest_charge.balance_transaction")
        except Exception:
            continue                                     # provider down; next run
        charge = (session.get("payment_intent") or {}).get("latest_charge") or {}
        bt = charge.get("balance_transaction")
        if not bt:
            continue                                     # not reported yet; next run

        with LOCK:
            if any(t["order_id"] == order_id and t["kind"] == "provider_fee"
                   for t in DB["ledger"].values()):
                continue                                 # another run beat us to it
            cur = bt["currency"].upper()
            txn_id = str(uuid.uuid4())
            DB["ledger"][txn_id] = {
                "id": txn_id, "kind": "provider_fee", "order_id": order_id,
                "provider_ref": bt["id"],
                "occurred_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(bt["created"])),
                "entries": [
                    {"account": "processing_fees", "amount": money(bt["fee"], cur)},
                    {"account": "psp_balance", "amount": money(-bt["fee"], cur)},
                ]}
            booked += 1
    return booked


def sweeper():
    while True:
        time.sleep(2)
        book_fees()
        with LOCK:
            lapsed = [o["id"] for o in DB["orders"].values()
                      if o["status"] in ("pending", "awaiting_payment") and _lapsed(o)]
        for oid in lapsed:
            # Close the payment page before giving the seats back. A refusal
            # means the customer paid first: the order is theirs, and its
            # webhook is on the way.
            try:
                if not close_open_sessions(oid):
                    continue
            except OSError:
                continue                             # provider unreachable: keep the seats
            with LOCK:
                o = DB["orders"][oid]
                if not _holding(o) or not _lapsed(o):
                    continue
                if any(p["order_id"] == oid and p["status"] == "requires_payment"
                       for p in DB["payments"].values()):
                    continue                         # a session opened since; next run
                o["status"] = "expired"              # guard: transition first,
                o["hold_expires_at"] = None          # then release, exactly once
                for item in o["items"]:
                    DB["ticket_types"][item["ticket_type_id"]]["quantity_held"] -= item["quantity"]


# --------------------------------------------------------------------------- #
# http
# --------------------------------------------------------------------------- #

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _read(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _send(self, status, body: bytes, ctype="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status, obj):
        self._send(status, json.dumps(obj).encode())

    def _problem(self, status, title, detail=""):
        self._send(status, json.dumps({
            "type": f"https://gatecrash.dev/problems/{title.lower().replace(' ', '-')}",
            "title": title, "status": status, "detail": detail}).encode(),
            "application/problem+json")

    # ---- GET ------------------------------------------------------------- #

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/")
        parts = [p for p in path.split("/") if p]

        with LOCK:
            if path == "/api/events":
                return self._json(200, {"data": [event_json(e) for e in DB["events"].values()
                                                 if e["status"] == "on_sale"]})

            if len(parts) == 3 and parts[:2] == ["api", "events"]:
                ev = next((e for e in DB["events"].values() if e["slug"] == parts[2]), None)
                return self._json(200, event_json(ev, True)) if ev else \
                    self._problem(404, "Event not found")

            if len(parts) == 3 and parts[:2] == ["api", "orders"]:
                o = DB["orders"].get(parts[2])
                return self._json(200, order_json(o)) if o else self._problem(404, "Order not found")

            if len(parts) == 4 and parts[:2] == ["api", "orders"] and parts[3] == "tickets":
                o = DB["orders"].get(parts[2])
                if not o:
                    return self._problem(404, "Order not found")
                if o["status"] != "paid":
                    return self._problem(409, "Order not paid",
                                         "Tickets exist only for paid orders")
                return self._json(200, {"data": [t for t in DB["tickets"].values()
                                                 if t["order_id"] == o["id"]]})

            if len(parts) == 5 and parts[:3] == ["api", "admin", "orders"] and parts[4] == "ledger":
                if self.headers.get("Authorization") != f"Bearer {ADMIN_TOKEN}":
                    return self._problem(401, "Unauthorized")
                o = DB["orders"].get(parts[3])
                if not o:
                    return self._problem(404, "Order not found")
                return self._json(200, {"data": [t for t in DB["ledger"].values()
                                                 if t["order_id"] == o["id"]]})

        return self._problem(404, "Not found", path)

    # ---- POST ------------------------------------------------------------ #

    def do_POST(self):
        path = urlparse(self.path).path.rstrip("/")
        parts = [p for p in path.split("/") if p]
        raw = self._read()

        if path == "/api/webhooks/stripe":
            return self._webhook(raw)

        if path == "/api/orders":
            return self._create_order(raw)

        if len(parts) == 4 and parts[:2] == ["api", "orders"] and parts[3] == "checkout":
            return self._checkout(parts[2])

        if path == "/api/admin/ledger/reconcile":
            if self.headers.get("Authorization") != f"Bearer {ADMIN_TOKEN}":
                return self._problem(401, "Unauthorized")
            return self._json(200, {"data": {"booked": book_fees()}})

        return self._problem(404, "Not found", path)

    # ---- handlers -------------------------------------------------------- #

    def _create_order(self, raw):
        key = self.headers.get("Idempotency-Key")
        if not key:
            return self._problem(422, "Idempotency-Key required")
        fingerprint = hashlib.sha256(b"POST/api/orders" + raw).hexdigest()

        with LOCK:
            stored = DB["idempotency"].get(key)
            if stored:
                if stored["fingerprint"] != fingerprint:
                    return self._problem(422, "Idempotency key reused",
                                         "Same key, different request body")
                return self._send(stored["status"], stored["body"])

            try:
                body = json.loads(raw)
            except Exception:
                return self._problem(422, "Malformed JSON")

            items, total, currency = [], 0, None
            for line in body.get("items", []):
                tt = DB["ticket_types"].get(line.get("ticket_type_id"))
                if tt is None:
                    return self._problem(422, "Unknown ticket type")
                qty = int(line.get("quantity", 0))
                available = tt["quantity_total"] - tt["quantity_held"] - tt["quantity_sold"]
                if qty < 1 or qty > available:
                    return self._problem(422, "Insufficient availability",
                                         f"{available} remaining")
                currency = tt["price_currency"]
                total += tt["price_amount"] * qty
                items.append({"id": str(uuid.uuid4()), "ticket_type_id": tt["id"],
                              "quantity": qty, "unit_price_amount": tt["price_amount"],
                              "unit_price_currency": currency})

            if not items:
                return self._problem(422, "Order must contain at least one item")

            for it in items:
                DB["ticket_types"][it["ticket_type_id"]]["quantity_held"] += it["quantity"]

            oid = str(uuid.uuid4())
            expires = time.time() + HOLD_TTL
            order = {"id": oid, "event_id": body["event_id"], "email": body["email"],
                     "status": "pending", "total_amount": total, "total_currency": currency,
                     "hold_expires_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(expires)),
                     "_expires_epoch": expires, "items": items, "created_at": now()}
            DB["orders"][oid] = order

            payload = json.dumps(order_json(order)).encode()
            DB["idempotency"][key] = {"fingerprint": fingerprint, "status": 201, "body": payload}
            return self._send(201, payload)

    def _checkout(self, order_id):
        with LOCK:
            order = DB["orders"].get(order_id)
            if not order:
                return self._problem(404, "Order not found")
            if not _holding(order) or _lapsed(order):
                return self._problem(409, "Order not payable", order["status"])
            amount, currency = order["total_amount"], order["total_currency"]

        # One open session per order (C16).
        try:
            if not close_open_sessions(order_id):
                return self._problem(409, "Order already paid", "confirmation on its way")
        except OSError:
            return self._problem(502, "Payment provider unavailable")

        form = (f"line_items[0][price_data][currency]={currency.lower()}"
                f"&line_items[0][price_data][unit_amount]={amount}"
                f"&line_items[0][quantity]=1"
                f"&allowed_payment_method_types[0]=card"
                f"&payment_intent_data[metadata][order_id]={order_id}"
                f"&client_reference_id={order_id}"
                f"&success_url=http://localhost:5173/orders/{order_id}"
                f"&cancel_url=http://localhost:5173/orders/{order_id}")
        req = urllib.request.Request(
            f"{PSP_URL}/v1/checkout/sessions", data=form.encode(), method="POST",
            headers={"Content-Type": "application/x-www-form-urlencoded"})
        with urllib.request.urlopen(req, timeout=10) as r:
            session = json.loads(r.read())

        with LOCK:
            # The sweeper may have expired the order while the provider answered.
            # Record nothing and hand out no URL: a page nobody has the address
            # of cannot take money.
            order = DB["orders"][order_id]
            if not _holding(order) or _lapsed(order):
                return self._problem(409, "Order not payable", order["status"])
            pid = str(uuid.uuid4())
            DB["payments"][pid] = {"id": pid, "order_id": order_id, "provider": "stripe",
                                   "provider_ref": session["id"], "amount": amount,
                                   "currency": currency, "status": "requires_payment",
                                   "created_at": now()}
            DB["orders"][order_id]["status"] = "awaiting_payment"

        return self._json(201, {"payment_id": pid, "checkout_url": session["url"],
                                "expires_at": now()})

    def _webhook(self, raw):
        sig = self.headers.get("Stripe-Signature", "")
        pairs = [p.split("=", 1) for p in sig.split(",") if "=" in p]
        try:
            ts = int(next(v for k, v in pairs if k == "t"))
        except Exception:
            return self._send(400, b"bad signature header")

        # Every v1, and only v1 (C18): one per active secret during a roll, and
        # no other scheme, however valid — that would be a downgrade.
        v1s = [v for k, v in pairs if k == "v1"]
        expected = hmac.new(WEBHOOK_SECRET.encode(),
                            f"{ts}.".encode() + raw, hashlib.sha256).hexdigest()
        if not any(hmac.compare_digest(expected, s) for s in v1s):
            return self._send(400, b"signature mismatch")
        if abs(time.time() - ts) > TOLERANCE:
            return self._send(400, b"timestamp outside tolerance")

        event = json.loads(raw)
        with LOCK:
            if event["id"] in DB["webhook_events"]:
                return self._send(200, b"duplicate")     # true, already acted on
            DB["webhook_events"][event["id"]] = {"id": event["id"], "type": event["type"],
                                                 "received_at": now()}

        if event["type"] == "checkout.session.completed":
            threading.Thread(target=fulfil, args=(event["data"]["object"],),
                             daemon=True).start()
        elif event["type"] == "payment_intent.payment_failed":
            # Recorded above, deliberately not acted on. A decline is about one
            # card inside a session the customer is still using: it changes
            # neither the payment, which is the session, nor the order (C13, C15).
            pass
        return self._send(200, b"ok")


def main():
    load_seed()
    threading.Thread(target=sweeper, daemon=True).start()
    print(f"reference app on http://localhost:{PORT}  (psp={PSP_URL}, hold_ttl={HOLD_TTL}s)")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
