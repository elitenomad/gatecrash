#!/usr/bin/env python3
"""
fake-psp — an offline stand-in for Stripe, for the Modern Payments book.

Why this exists
---------------
Readers who stall at "first, create an account and retrieve your API keys" never
reach chapter 5. Every chapter in this book runs against this server with no
network, no account, and no secrets. CI is free and deterministic.

It implements the small slice of Stripe that Volume 1 actually touches, and it is
*deliberately faithful* on the parts the book teaches:

  - form-encoded request bodies with Stripe's bracket notation
  - `Idempotency-Key` handling on the provider side
  - `Stripe-Signature: t=<ts>,v1=<hmac>` over the exact raw response body, signed
    afresh for every delivery attempt, with one v1 per active secret during a roll
  - webhook redelivery, so at-least-once is a fact you can observe
  - fees on a separate balance transaction, not on the session
  - declines as hosted Checkout does them for cards: the session stays open, the
    customer may try another card, and the only event is payment_intent.payment_failed
  - session expiry: only an open session can be expired, and a refusal says no more
    than that — the caller re-fetches to learn whether it completed or lapsed

Where it is unfaithful, it says so in a comment. It is a teaching tool, not a
Stripe emulator.

Run:
    WEBHOOK_URL=http://localhost:3000/api/webhooks/stripe python3 server.py

Stdlib only. No dependencies, on purpose.
"""

import copy
import hashlib
import hmac
import json
import os
import random
import secrets
import string
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, parse_qsl, urlparse

PORT = int(os.environ.get("FAKE_PSP_PORT", "4242"))
PUBLIC_URL = os.environ.get("FAKE_PSP_PUBLIC_URL", f"http://localhost:{PORT}")
WEBHOOK_URL = os.environ.get("WEBHOOK_URL", "http://localhost:3000/api/webhooks/stripe")
WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET", "whsec_fake_psp_secret")
# The one API version this fake speaks. Its Checkout Sessions have no
# payment_method_types parameter — 2026-09-30.endive removed it.
API_VERSION = "2026-09-30.endive"

# UK card pricing, so the ledger chapter has plausible numbers to reconcile.
FEE_PERCENT = 0.015
FEE_FIXED = 20

# What a session offers when the caller does not pin payment_method_types. Real
# Stripe offers whatever the account's dashboard has enabled, which this cannot
# know; one delayed method stands in for "something the caller did not choose".
UNPINNED_METHODS = ["card", "sepa_debit"]


# --------------------------------------------------------------------------- #
# state
# --------------------------------------------------------------------------- #

class Store:
    """In-memory, lock-guarded. Restarting the server is the reset button."""

    def __init__(self):
        self.lock = threading.RLock()
        self.sessions = {}
        self.intents = {}           # payment_intent id -> PaymentIntent
        self.charges = {}           # charge id -> Charge
        self.fee_pending = {}       # charge id -> (balance transaction id, ready at)
        self.intent_metadata = {}   # session id -> payment_intent_data[metadata]
        self.balance_transactions = {}
        self.events = []            # every event we generated, in order
        self.deliveries = []        # every delivery attempt, for assertions
        self.idempotency = {}       # provider-side Idempotency-Key -> response
        self.failures = []          # queued failure responses, see /_control/fail_next

    def take_failure(self):
        """Pop one queued failure, if the suite asked us to misbehave.

        Off unless a test turns it on. Real providers rate-limit and fall over;
        a client that has never met a 429 has an untested retry policy.
        """
        with self.lock:
            return self.failures.pop(0) if self.failures else None

    def reset(self):
        with self.lock:
            self.sessions.clear()
            self.intents.clear()
            self.charges.clear()
            self.fee_pending.clear()
            self.intent_metadata.clear()
            self.balance_transactions.clear()
            self.events.clear()
            self.deliveries.clear()
            self.idempotency.clear()
            self.failures.clear()


STORE = Store()


def _id(prefix, n=24):
    alphabet = string.ascii_letters + string.digits
    return prefix + "".join(random.choice(alphabet) for _ in range(n))


# --------------------------------------------------------------------------- #
# Stripe's form encoding
# --------------------------------------------------------------------------- #

def parse_stripe_form(body: str) -> dict:
    """
    Stripe accepts application/x-www-form-urlencoded with bracket notation:

        line_items[0][price_data][currency]=gbp
        metadata[order_id]=abc

    becomes

        {"line_items": [{"price_data": {"currency": "gbp"}}],
         "metadata": {"order_id": "abc"}}

    Numeric keys become list indices. This is the encoding the official SDKs
    speak, which is exactly why chapter 6 has readers hand-roll it once.
    """
    out = {}
    for raw_key, value in parse_qsl(body, keep_blank_values=True):
        parts, buf, depth = [], "", 0
        for ch in raw_key:
            if ch == "[":
                depth += 1
                if depth == 1:
                    parts.append(buf)
                    buf = ""
                    continue
            elif ch == "]":
                depth -= 1
                if depth == 0:
                    parts.append(buf)
                    buf = ""
                    continue
            buf += ch
        if buf:
            parts.append(buf)
        parts = [p for p in parts if p != ""]

        cursor = out
        for i, part in enumerate(parts):
            last = i == len(parts) - 1
            nxt = parts[i + 1] if not last else None
            want_list = nxt is not None and nxt.isdigit()

            if part.isdigit() and isinstance(cursor, list):
                idx = int(part)
                while len(cursor) <= idx:
                    cursor.append({})
                if last:
                    cursor[idx] = value
                else:
                    cursor = cursor[idx]
                continue

            if last:
                cursor[part] = value
            else:
                if part not in cursor or not isinstance(cursor[part], (dict, list)):
                    cursor[part] = [] if want_list else {}
                cursor = cursor[part]
    return out


# --------------------------------------------------------------------------- #
# webhook signing and delivery
# --------------------------------------------------------------------------- #

# A secret the receiver has not been given yet: what the provider also signs
# with while an endpoint's secret is being rolled.
ROLLED_SECRET = "whsec_rolled_not_yet_deployed"


def sign(payload: bytes, timestamp: int, secret: str = WEBHOOK_SECRET) -> str:
    """
    Stripe's scheme, reproduced exactly:

        signed_payload = f"{timestamp}.{raw_body}"
        v1             = hex(HMAC_SHA256(secret, signed_payload))

    Note it signs the *raw bytes*. Any implementation that parses the JSON and
    re-serialises before hashing will produce a different digest — and will fail
    intermittently, as key order and unicode escaping shift. That failure mode is
    the entire point of chapter 8.
    """
    signed = f"{timestamp}.".encode() + payload
    return hmac.new(secret.encode(), signed, hashlib.sha256).hexdigest()


def signature_header(payload: bytes, timestamp: int, *, secret=WEBHOOK_SECRET,
                     roll=None, scheme="v1") -> str:
    """
    `t=<ts>,v1=<sig>` — and, faithfully, one `v1` per active secret while a
    secret is being rolled (`roll` puts the extra one "before" or "after" ours,
    so a receiver that keeps only the first or only the last is caught either
    way). `scheme` relabels our signature, to prove a receiver ignores every
    scheme but v1.
    """
    sigs = [f"{scheme}={sign(payload, timestamp, secret)}"]
    if roll:
        other = f"v1={sign(payload, timestamp, ROLLED_SECRET)}"
        sigs = [other, *sigs] if roll == "before" else [*sigs, other]
    return f"t={timestamp}," + ",".join(sigs)


def build_event(event_type: str, obj: dict) -> dict:
    return {
        "id": _id("evt_"),
        "object": "event",
        "api_version": API_VERSION,
        "created": int(time.time()),
        "livemode": False,
        "type": event_type,
        "data": {"object": obj},
        "request": {"id": None, "idempotency_key": None},
    }


def deliver(event: dict, *, bad_signature=False, age_seconds=0, attempts=3,
            roll=None, scheme="v1") -> dict:
    """
    POST an event to the configured webhook URL.

    Retries on non-2xx, because at-least-once delivery is something the book
    wants readers to *see* rather than be told about. Each attempt is signed
    afresh, with its own timestamp, as Stripe does. `bad_signature`,
    `age_seconds`, `roll` and `scheme` exist so the conformance suite can prove
    what a receiver must accept and what it must refuse.
    """
    payload = json.dumps(event, separators=(",", ":")).encode()
    secret = "whsec_wrong_secret" if bad_signature else WEBHOOK_SECRET

    result = {"event_id": event["id"], "type": event["type"], "attempts": []}
    for attempt in range(1, attempts + 1):
        ts = int(time.time()) - age_seconds
        header = signature_header(payload, ts, secret=secret, roll=roll, scheme=scheme)
        req = urllib.request.Request(
            WEBHOOK_URL,
            data=payload,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "Stripe-Signature": header,
                "User-Agent": "fake-psp/1.0",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                status = resp.status
        except urllib.error.HTTPError as e:
            status = e.code
        except Exception as e:  # connection refused, timeout, ...
            status = 0
            result["attempts"].append({"n": attempt, "status": status, "error": str(e)})
            time.sleep(0.5 * attempt)
            continue

        result["attempts"].append({"n": attempt, "status": status})
        if 200 <= status < 300:
            break
        time.sleep(0.5 * attempt)

    with STORE.lock:
        STORE.deliveries.append(result)
    return result


# --------------------------------------------------------------------------- #
# domain
# --------------------------------------------------------------------------- #

class ParamError(Exception):
    pass


def create_session(params: dict) -> dict:
    if "payment_method_types" in params:
        # Faithful to 2026-09-30.endive, which made this a 400.
        raise ParamError("Received unknown parameter: payment_method_types. Use "
                         "allowed_payment_method_types to restrict a session's methods.")
    allowed = params.get("allowed_payment_method_types")
    # A filter on what the "dashboard" offers, as Stripe's is: the response's
    # payment_method_types is what survives it.
    methods = [m for m in UNPINNED_METHODS if not allowed or m in allowed]

    amount, currency = 0, "gbp"
    for li in params.get("line_items") or []:
        pd = li.get("price_data") or {}
        qty = int(li.get("quantity", 1))
        amount += int(pd.get("unit_amount", 0)) * qty
        currency = pd.get("currency", currency)
    if "amount_total" in params:  # convenience escape hatch, not a Stripe field
        amount = int(params["amount_total"])

    sid = _id("cs_test_")
    session = {
        "id": sid,
        "object": "checkout.session",
        "amount_total": amount,
        "currency": currency,
        "client_reference_id": params.get("client_reference_id"),
        "customer_email": params.get("customer_email"),
        "expires_at": int(time.time()) + 30 * 60,
        "livemode": False,
        "metadata": params.get("metadata") or {},
        "mode": params.get("mode", "payment"),
        # Faithful: null until the customer first tries to pay. Nothing may
        # assume a PaymentIntent exists the moment a session does.
        "payment_intent": None,
        "payment_method_types": methods,
        "payment_status": "unpaid",
        "status": "open",
        "success_url": params.get("success_url", ""),
        "cancel_url": params.get("cancel_url", ""),
        "url": f"{PUBLIC_URL}/checkout/{sid}",
    }
    with STORE.lock:
        STORE.sessions[sid] = session
        STORE.intent_metadata[sid] = (params.get("payment_intent_data") or {}).get("metadata") or {}
    return session


class SessionNotOpen(Exception):
    pass


def expire_session(sid: str):
    """POST /v1/checkout/sessions/{id}/expire.

    Faithful: only an `open` session can be expired, and once it is, the customer
    can no longer pay on it. Anything else is refused — and the refusal does not
    say whether the session completed or had already expired, so a caller has to
    re-fetch the session to find out. Which is the right habit anyway.
    """
    with STORE.lock:
        session = STORE.sessions.get(sid)
        if session is None:
            return None, None
        if session["status"] != "open":
            return session, False
        session["status"] = "expired"
        session["url"] = None
        event = build_event("checkout.session.expired", dict(session))
        STORE.events.append(event)
    # Sent on its own thread, as Stripe would send it: the caller is still
    # waiting for this response, and may be the very server the event goes to.
    threading.Thread(target=deliver, args=(event,), daemon=True).start()
    return session, True


def _intent_for(session: dict) -> dict:
    """The PaymentIntent behind a session, created on the first attempt to pay.
    Every card the customer tries on the page is an attempt on this one intent.
    Call with STORE.lock held."""
    pid = session["payment_intent"]
    if pid is None:
        pid = _id("pi_")
        STORE.intents[pid] = {
            "id": pid,
            "object": "payment_intent",
            "amount": session["amount_total"],
            "currency": session["currency"],
            "last_payment_error": None,
            "livemode": False,
            "metadata": dict(STORE.intent_metadata.get(session["id"], {})),
            "status": "requires_payment_method",
        }
        session["payment_intent"] = pid
    return STORE.intents[pid]


def decline_card(sid: str, *, decline_code="generic_decline", hold=False, **kw):
    """One card declined on the hosted page.

    Faithful to hosted Checkout with cards: the customer sees the decline and may
    try another card, so the session stays `open` and nothing at the session level
    changes. The intent goes back to requires_payment_method — Stripe has no
    failed state for it — and the only event is payment_intent.payment_failed.
    """
    with STORE.lock:
        session = STORE.sessions.get(sid)
        if session is None:
            return None, None
        if session["status"] != "open":
            raise SessionNotOpen(session["status"])
        intent = _intent_for(session)
        intent["status"] = "requires_payment_method"
        intent["last_payment_error"] = {
            "type": "card_error",
            "code": "card_declined",
            "decline_code": decline_code,
            "message": "Your card was declined.",
        }
        event = build_event("payment_intent.payment_failed", dict(intent))
        STORE.events.append(event)
    return session, _held(event) if hold else deliver(event, **kw)


def _held(event: dict) -> dict:
    """Recorded, not sent. POST /_control/replay?event_id=… delivers it later —
    which is how a case makes an event arrive after one that happened after it."""
    return {"event_id": event["id"], "type": event["type"], "attempts": [], "held": True}


def complete_session(sid: str, *, succeed=True, hold=False, fee_delay=0, **kw):
    if not succeed:
        return decline_card(sid, hold=hold, **kw)

    with STORE.lock:
        session = STORE.sessions.get(sid)
        if session is None:
            return None, None
        if session["status"] == "expired":
            raise SessionNotOpen(session["status"])
        already = session["status"] == "complete"

    if not already:
        fee = round(session["amount_total"] * FEE_PERCENT) + FEE_FIXED
        bt = {
            "id": _id("txn_"),
            "object": "balance_transaction",
            "amount": session["amount_total"],
            "currency": session["currency"],
            "fee": fee,
            "net": session["amount_total"] - fee,
            "status": "pending",
            "created": int(time.time()),
            # Faithful detail: Stripe does NOT put the fee on the session. It
            # lives here, three hops away — session → payment intent → latest
            # charge → balance transaction — and may not exist yet when the
            # payment succeeds. That is what makes chapter 10's "estimate now
            # or book it when it arrives?" a real decision.
        }
        with STORE.lock:
            STORE.balance_transactions[bt["id"]] = bt
            intent = _intent_for(session)
            charge = {
                "id": _id("ch_"),
                "object": "charge",
                "amount": session["amount_total"],
                "currency": session["currency"],
                "captured": True,
                "payment_intent": intent["id"],
                # Null until the capture settles, as with Stripe's asynchronous
                # capture — the default in current API versions. `fee_delay`
                # stretches that out so a case can watch it.
                "balance_transaction": None if fee_delay else bt["id"],
                "status": "succeeded",
            }
            STORE.charges[charge["id"]] = charge
            if fee_delay:
                STORE.fee_pending[charge["id"]] = (bt["id"], time.time() + fee_delay)
            intent["status"] = "succeeded"
            intent["latest_charge"] = charge["id"]
            session["status"] = "complete"
            session["payment_status"] = "paid"

    # Unfaithful by omission: Stripe also sends payment_intent.succeeded and
    # charge.succeeded here. One event per action keeps /_control/replay, which
    # redelivers the latest, pointed at the event the book is about.
    event = build_event("checkout.session.completed", dict(session))
    with STORE.lock:
        STORE.events.append(event)
    return session, _held(event) if hold else deliver(event, **kw)


def _settle(charge: dict):
    """Link a charge to its balance transaction once the delay has passed.
    Unfaithful by omission: Stripe would also send charge.updated here; this
    application polls for the fee instead, so nothing listens for it.
    Call with STORE.lock held."""
    pending = STORE.fee_pending.get(charge["id"])
    if pending and time.time() >= pending[1]:
        charge["balance_transaction"] = pending[0]
        del STORE.fee_pending[charge["id"]]


EXPANDABLE = {"payment_intent": "intents", "latest_charge": "charges",
              "balance_transaction": "balance_transactions"}


def expanded(obj: dict, paths) -> dict:
    """`expand[]=payment_intent.latest_charge.balance_transaction`, as Stripe
    does it: each id along the path is replaced by the object it names, and a
    null stays null. Call with STORE.lock held."""
    obj = copy.deepcopy(obj)
    for path in paths:
        node, fields = obj, path.split(".")
        for field in fields:
            ref = node.get(field) if isinstance(node, dict) else None
            if isinstance(ref, str) and field in EXPANDABLE:
                target = getattr(STORE, EXPANDABLE[field]).get(ref)
                if target is None:
                    break
                if target.get("object") == "charge":
                    _settle(target)
                node[field] = copy.deepcopy(target)
                node = node[field]
            elif isinstance(ref, dict):
                node = ref
            else:
                break
    return obj


# How a currency's amount reads on the hosted page. Amounts arrive in Stripe's
# minor units, which are ISO 4217's except for ISK and UGX: no minor unit, but
# sent in hundredths. Integer arithmetic only — the page shows money, and the
# book's rule about floats does not stop at the edge of the fake.
ZERO_DECIMAL = {"bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "pyg", "rwf",
                "uyi", "vnd", "vuv", "xaf", "xof", "xpf"}
THREE_DECIMAL = {"bhd", "iqd", "jod", "kwd", "lyd", "omr", "tnd"}
HUNDREDTHS_OF_A_WHOLE = {"isk", "ugx"}


def display_amount(amount: int, currency: str) -> str:
    cur = currency.lower()
    if cur in HUNDREDTHS_OF_A_WHOLE:
        amount, exponent = amount // 100, 0
    else:
        exponent = 0 if cur in ZERO_DECIMAL else 3 if cur in THREE_DECIMAL else 2
    whole, minor = divmod(amount, 10 ** exponent)
    digits = f"{whole:,}" + (f".{minor:0{exponent}d}" if exponent else "")
    return f"{digits} {cur.upper()}"


# --------------------------------------------------------------------------- #
# http
# --------------------------------------------------------------------------- #

CHECKOUT_PAGE = """<!doctype html>
<meta charset="utf-8"><title>fake-psp checkout</title>
<style>
 body{{font:16px/1.5 system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem}}
 .amt{{font-size:2.5rem;font-weight:600;margin:.5rem 0 2rem}}
 button{{font:inherit;padding:.7rem 1.2rem;border-radius:.5rem;border:1px solid #ccc;
        cursor:pointer;margin-right:.5rem}}
 .pay{{background:#0a7;color:#fff;border-color:#0a7}}
 .warn{{background:#fff8e1;border:1px solid #ffe08a;padding:.75rem 1rem;
        border-radius:.5rem;font-size:.9rem;margin-top:2rem}}
 .declined{{background:#fdecea;border:1px solid #f5b5ae;padding:.75rem 1rem;
        border-radius:.5rem;margin-bottom:1.5rem}}
</style>
<h1>fake-psp</h1>
<p>Simulated hosted checkout &mdash; no real card, no network.</p>
<div class="amt">{amount}</div>
{notice}<form method="post" action="/checkout/{sid}/complete">
  <button class="pay" name="outcome" value="succeed">Pay</button>
  <button name="outcome" value="fail">Decline card</button>
  <button name="outcome" value="cancel">Cancel</button>
</form>
<div class="warn">
  Paying here fires a signed <code>checkout.session.completed</code> webhook at
  <code>{hook}</code>. That webhook &mdash; not the redirect you are about to
  follow &mdash; is what marks the order paid.
</div>
"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print(f"  fake-psp  {self.command:6} {self.path:50} {args[1] if len(args) > 1 else ''}")

    # -- helpers ----------------------------------------------------------- #

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n).decode() if n else ""

    def _params(self):
        raw = self._body()
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip()
        if ctype == "application/json":
            return json.loads(raw) if raw else {}
        return parse_stripe_form(raw)

    def _json(self, status, obj, headers=None):
        body = json.dumps(obj, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, str(value))
        self.end_headers()
        self.wfile.write(body)

    def _injected_failure(self):
        """Serve a queued failure instead of doing the work. Returns True if it did."""
        failure = STORE.take_failure()
        if failure is None:
            return False
        headers = {"Retry-After": failure["retry_after"]} if failure.get("retry_after") else {}
        if failure.get("should_retry") in ("true", "false"):
            headers["Stripe-Should-Retry"] = failure["should_retry"]
        self._json(failure["status"], {"error": {
            "type": "api_error", "code": failure["code"],
            "message": "Injected by /_control/fail_next"}}, headers=headers)
        return True

    def _html(self, status, text):
        body = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _redirect(self, url):
        self.send_response(303)
        self.send_header("Location", url)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _err(self, status, code, message):
        self._json(status, {"error": {"type": "invalid_request_error",
                                      "code": code, "message": message}})

    # -- routing ----------------------------------------------------------- #

    def do_GET(self):
        path = urlparse(self.path).path

        if path == "/_control/health":
            return self._json(200, {"ok": True, "webhook_url": WEBHOOK_URL})

        if path == "/_control/events":
            with STORE.lock:
                return self._json(200, {"events": STORE.events,
                                        "deliveries": STORE.deliveries})

        if path.startswith("/v1/") and self._injected_failure():
            return None

        expand = parse_qs(urlparse(self.path).query).get("expand[]", [])
        for prefix, table, noun in (("/v1/checkout/sessions/", "sessions", "checkout session"),
                                    ("/v1/payment_intents/", "intents", "payment intent"),
                                    ("/v1/charges/", "charges", "charge")):
            if path.startswith(prefix):
                with STORE.lock:
                    obj = getattr(STORE, table).get(path.rsplit("/", 1)[-1])
                    if obj is not None and table == "charges":
                        _settle(obj)
                    body = expanded(obj, expand) if obj is not None else None
                return (self._json(200, body) if body is not None
                        else self._err(404, "resource_missing", f"No such {noun}"))

        if path.startswith("/v1/balance_transactions/"):
            tid = path.rsplit("/", 1)[-1]
            with STORE.lock:
                bt = STORE.balance_transactions.get(tid)
            return self._json(200, bt) if bt else self._err(404, "resource_missing", "No such balance transaction")

        if path.startswith("/checkout/"):
            sid = path.split("/")[2]
            with STORE.lock:
                s = STORE.sessions.get(sid)
            if not s:
                return self._html(404, "<h1>No such session</h1>")
            if s["status"] == "expired":
                return self._html(200, "<h1>This Checkout Session has expired</h1>")
            amount = display_amount(s["amount_total"], s["currency"])
            return self._html(200, CHECKOUT_PAGE.format(
                amount=amount, sid=sid, hook=WEBHOOK_URL, notice=""))

        return self._err(404, "resource_missing", f"Unknown route {path}")

    def do_POST(self):
        path = urlparse(self.path).path
        query = dict(parse_qsl(urlparse(self.path).query))

        # ---- Stripe-compatible API ---------------------------------------- #
        if path.startswith("/v1/") and self._injected_failure():
            return None

        if path.startswith("/v1/checkout/sessions/") and path.endswith("/expire"):
            sid = path.split("/")[4]
            key = self.headers.get("Idempotency-Key")
            if key:
                with STORE.lock:
                    stored = STORE.idempotency.get(f"{path}:{key}")
                if stored:
                    return self._json(*stored)
            session, expired = expire_session(sid)
            if session is None:
                answer = (404, {"error": {"type": "invalid_request_error", "code": "resource_missing",
                                          "message": "No such checkout session"}})
            elif not expired:
                answer = (400, {"error": {"type": "invalid_request_error", "code": None,
                                          "message": "This Checkout Session can no longer be expired."}})
            else:
                answer = (200, session)
            if key:
                with STORE.lock:
                    STORE.idempotency[f"{path}:{key}"] = answer
            return self._json(*answer)

        if path == "/v1/checkout/sessions":
            params = self._params()
            fingerprint = json.dumps(params, sort_keys=True)
            key = self.headers.get("Idempotency-Key")
            if key:
                with STORE.lock:
                    stored = STORE.idempotency.get(key)
                if stored:
                    # Provider-side idempotency, the same contract chapter 7 asks
                    # readers to implement for their own API — including the
                    # refusal when a key comes back with different parameters.
                    if stored[0] != fingerprint:
                        return self._json(400, {"error": {
                            "type": "idempotency_error", "code": None,
                            "message": f"Keys for idempotent requests can only be used with "
                                       f"the same parameters they were first used with. Try "
                                       f"a key other than '{key}' for a different request."}})
                    return self._json(200, stored[1], headers={"Idempotent-Replayed": "true"})
            try:
                session = create_session(params)
            except ParamError as e:
                return self._err(400, "parameter_unknown", str(e))
            if key:
                with STORE.lock:
                    STORE.idempotency[key] = (fingerprint, session)
            return self._json(200, session)

        # ---- hosted page ---------------------------------------------------#
        if path.startswith("/checkout/") and path.endswith("/complete"):
            sid = path.split("/")[2]
            outcome = parse_stripe_form(self._body()).get("outcome", "succeed")
            with STORE.lock:
                s = STORE.sessions.get(sid)
            if not s:
                return self._html(404, "<h1>No such session</h1>")
            if outcome == "cancel":
                return self._redirect(s["cancel_url"] or "/")
            try:
                if outcome == "fail":
                    # Stay on the page, as hosted Checkout does: the customer is
                    # still here, and the next card goes against the same session.
                    decline_card(sid)
                    amount = display_amount(s["amount_total"], s["currency"])
                    return self._html(200, CHECKOUT_PAGE.format(
                        amount=amount, sid=sid, hook=WEBHOOK_URL,
                        notice='<div class="declined">Your card was declined. '
                               'Try another card.</div>\n'))
                complete_session(sid)
            except SessionNotOpen as e:
                return self._html(409, f"<h1>This session is {e}</h1>")
            target = s["success_url"]
            return self._redirect((target or "/").replace("{CHECKOUT_SESSION_ID}", sid))

        # ---- control plane, for the conformance suite ---------------------- #
        if path == "/_control/reset":
            STORE.reset()
            return self._json(200, {"ok": True})

        if path.startswith("/_control/sessions/") and path.endswith("/complete"):
            # ?succeed=0 declines one card instead; the session stays open.
            # ?hold=1 records the event without sending it — see _held().
            # ?roll=before|after and ?scheme=v0 — see signature_header().
            # ?fee_delay=N keeps the charge's balance transaction null for N seconds.
            sid = path.split("/")[3]
            try:
                session, delivery = complete_session(
                    sid,
                    succeed=query.get("succeed", "1") != "0",
                    hold=query.get("hold") == "1",
                    bad_signature=query.get("bad_signature") == "1",
                    roll=query.get("roll"),
                    fee_delay=float(query.get("fee_delay", "0")),
                    scheme=query.get("scheme", "v1"),
                    age_seconds=int(query.get("age", "0")),
                )
            except SessionNotOpen as e:
                return self._err(409, "checkout_session_not_open", f"Session is {e}")
            if session is None:
                return self._err(404, "resource_missing", "No such session")
            return self._json(200, {"session": session, "delivery": delivery})

        if path == "/_control/fail_next":
            # Queue N failures for the next N calls to /v1/*, so a client's
            # retry policy can be watched rather than assumed.
            count = int(query.get("count", "1"))
            failure = {"status": int(query.get("status", "500")),
                       "code": query.get("code", "api_error"),
                       "retry_after": query.get("retry_after"),
                       "should_retry": query.get("should_retry")}
            with STORE.lock:
                STORE.failures.extend([dict(failure) for _ in range(count)])
                queued = len(STORE.failures)
            return self._json(200, {"ok": True, "queued": queued, "failure": failure})

        if path == "/_control/replay":
            # Deliver an event again — C4: the receiver must accept it (200) and
            # process it exactly once — or for the first time, if it was held
            # back with ?hold=1, which is how C13 delivers events out of order.
            with STORE.lock:
                if not STORE.events:
                    return self._err(400, "no_events", "Nothing to replay")
                event = STORE.events[-1] if "event_id" not in query else next(
                    (e for e in STORE.events if e["id"] == query["event_id"]), None)
            if event is None:
                return self._err(404, "resource_missing", "No such event")
            return self._json(200, {"delivery": deliver(event)})

        return self._err(404, "resource_missing", f"Unknown route {path}")


def main():
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"fake-psp listening on {PUBLIC_URL}")
    print(f"  webhooks -> {WEBHOOK_URL}")
    print(f"  secret    = {WEBHOOK_SECRET}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
