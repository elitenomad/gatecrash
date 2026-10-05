#!/usr/bin/env python3
"""
Mutation test for the conformance suite.

A suite that has only ever passed proves nothing. This breaks spec/reference/ in
known ways and asserts the expected case catches each one. Re-run after adding or
editing a case:

    make mutation-test

First the unmutated reference runs the whole suite, and must pass it: a
mutation "caught" by a suite that fails anyway proves nothing. Then every
mutation must report CAUGHT:

    CAUGHT  the expected case failed, with the message that names this bug
    WRONG   the expected case failed, but for some other reason — the mutation
            is caught by accident, and the check written for it is untested
    MISSED  the app was broken and the suite did not notice — the case is weak,
            OR the mutation does not actually produce the broken behaviour
    NOBOOT  the mutant never started, or the suite crashed; the harness is
            broken, not the suite
    SKIP    a mutation pattern no longer matches app.py — update it

A mutation that flickers between CAUGHT and MISSED across runs is a bug in the
mutation, not a flaky test. Three of these bit us already:

  - removing webhook dedupe alone changes nothing, because fulfil() carries its
    own `already paid` guard — and, since the reference learned the state
    machine, an `only awaiting_payment can be fulfilled` guard that refuses a
    replay just as well. Defence in depth masked the mutation, so the mutation
    must remove ALL the guards to genuinely represent "no dedupe".
  - dragging the order to `failed` on a superseded failure event went unnoticed
    while fulfil() would happily move any order to paid. The reference had to
    refuse `failed → paid`, as the app does, before C13 could catch anything.
    (`failed` is gone since Volume 1 went cards-only; the lesson is not.)
  - removing the availability lock alone rarely races, because the read and the
    write sit a few lines apart and CPython seldom preempts there. The mutation
    widens the window with a sleep, which is what a real database round-trip
    does anyway.

Mutants are written to spec/reference/_mutant.py (gitignored) so their relative
path to ../fixtures/seed.json still resolves, then deleted.
"""

import os
import pathlib
import re
import socket
import subprocess
import sys
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
APP = ROOT / "spec/reference/app.py"
MUTANT = ROOT / "spec/reference/_mutant.py"
SRC = APP.read_text()

# (name, [(find, replace), ...], cases expected to fail, words their failure must contain)
MUTATIONS = [
    ("skip signature verification", [
        ("if not any(hmac.compare_digest(expected, s) for s in v1s):", "if False:"),
    ], ["C5"], "forged signature must be rejected"),

    # A hash keeps one value per key. Caught only when ours is not the last v1,
    # which is why C18 delivers with the extra signature on both sides.
    ("only the last v1 signature is checked", [
        ('        v1s = [v for k, v in pairs if k == "v1"]',
         '        v1s = [dict(pairs).get("v1", "")]'),
    ], ["C18"], "carried a second v1"),

    ("a valid signature under any scheme is accepted", [
        ('        v1s = [v for k, v in pairs if k == "v1"]',
         '        v1s = [v for k, v in pairs if k != "t"]'),
    ], ["C18"], "scheme other than v1 was accepted"),

    ("skip timestamp tolerance check", [
        ("if abs(time.time() - ts) > TOLERANCE:", "if False:"),
    ], ["C6"], "stale event must still be rejected"),

    # Must remove ALL the guards. The webhook-level dedupe alone is masked by the
    # idempotent fulfil() — both its "payment already succeeded" return and its
    # "only awaiting_payment has an edge to paid" return refuse a replay on their own —
    # which is precisely why C4 asserts on ticket and ledger counts rather than
    # on the HTTP response.
    ("no deduplication anywhere (webhook + fulfil guards)", [
        ('if event["id"] in DB["webhook_events"]:', "if False:"),
        ('        if payment["status"] == "succeeded":\n            return\n', ""),
        ('        if order["status"] != "awaiting_payment":\n            return\n', ""),
    ], ["C4"], "the replay issued MORE TICKETS"),

    ("no idempotency replay (always create fresh)", [
        ('stored = DB["idempotency"].get(key)', "stored = None"),
    ], ["C1", "C3"], "byte-identical body"),

    ("money as floats", [
        ('return {"amount": int(amount), "currency": currency.upper()}',
         'return {"amount": float(amount), "currency": currency.upper()}'),
    ], ["C12"], "money must be an integer count of minor units"),

    # Drop the lock AND widen the read-then-write window, which is what a real
    # database round-trip does. Without the sleep the GIL hides the bug.
    ("read-then-write availability (no lock, widened window)", [
        ('        with LOCK:\n            stored = DB["idempotency"].get(key)',
         '        if True:\n            stored = DB["idempotency"].get(key)'),
        ('            for it in items:\n'
         '                DB["ticket_types"][it["ticket_type_id"]]["quantity_held"] += it["quantity"]',
         '            time.sleep(0.05)\n'
         '            for it in items:\n'
         '                DB["ticket_types"][it["ticket_type_id"]]["quantity_held"] += it["quantity"]'),
    ], ["C7"], "OVERSOLD"),

    ("mark paid at checkout instead of on webhook", [
        ('DB["orders"][order_id]["status"] = "awaiting_payment"',
         'DB["orders"][order_id]["status"] = "paid"'),
    ], ["C11"], "must not mark the order paid"),

    # The fee is debited to revenue instead of to an expense — netted off the top.
    # Every transaction still sums to zero and psp_balance is even right, so only
    # a whole-ledger view catches it.
    ("net the provider fee off revenue", [
        ('{"account": "processing_fees", "amount": money(bt["fee"], cur)},',
         '{"account": "ticket_revenue", "amount": money(bt["fee"], cur)},'),
    ], ["C14"], "has no processing_fees entry"),

    ("sweeper skips awaiting_payment (a walked-away customer holds seats forever)", [
        ('if o["status"] in ("pending", "awaiting_payment") and _lapsed(o)]',
         'if o["status"] in ("pending",) and _lapsed(o)]'),
    ], ["C15"], "must lapse like any other hold"),

    # Both sweeper mutations must also drop the re-check under the lock. A
    # payment still `requires_payment` holds the order on its own — a paid
    # session's payment is still waiting for its webhook — so with the re-check
    # in place the first mutant never releases anything (C15 then fails for the
    # wrong reason) and the second is masked entirely.
    ("sweeper releases seats without closing the payment page", [
        ("                if not close_open_sessions(oid):", "                if False:"),
        ('                if any(p["order_id"] == oid and p["status"] == "requires_payment"\n                       for p in DB["payments"].values()):\n                    continue                         # a session opened since; next run\n', ""),
    ], ["C15"], "payment page is still OPEN"),

    # Closes the sessions, but does not listen to the answer. The refusal was
    # the provider saying the customer had already paid.
    ("sweeper releases seats the customer has already paid for", [
        ("                if not close_open_sessions(oid):\n                    continue\n",
         "                close_open_sessions(oid)\n"),
        ('                if any(p["order_id"] == oid and p["status"] == "requires_payment"\n                       for p in DB["payments"].values()):\n                    continue                         # a session opened since; next run\n', ""),
    ], ["C17"], "had already been PAID. The seats"),

    # The handler a reader writes after learning "record failures": find the
    # order through the intent's metadata and release its seats. Delivered in
    # order, it takes the seats from a customer who is still typing.
    ("a decline expires the order and releases its seats", [
        ("            pass\n",
         '            oid = event["data"]["object"]["metadata"].get("order_id")\n'
         "            with LOCK:\n"
         '                o = DB["orders"].get(oid)\n'
         '                if o and o["status"] == "awaiting_payment":\n'
         '                    o["status"], o["hold_expires_at"] = "expired", None\n'
         '                    for item in o["items"]:\n'
         '                        DB["ticket_types"][item["ticket_type_id"]]["quantity_held"] -= item["quantity"]\n'),
    ], ["C15"], "a decline moved the order"),

    # The same instinct, aimed at the payment instead of the order. Harmless when
    # the decline arrives first; when it arrives late it overwrites `succeeded`.
    ("a decline marks the session's payment failed", [
        ("            pass\n",
         '            pi = event["data"]["object"]\n'
         "            with LOCK:\n"
         '                ps = [p for p in DB["payments"].values()\n'
         '                      if p["order_id"] == pi["metadata"].get("order_id")]\n'
         "                if ps:\n"
         '                    ps[-1]["status"] = "failed"\n'),
    ], ["C13"], "overwrote a payment that SUCCEEDED"),

    ("a new checkout leaves the previous session open", [
        ("            if not close_open_sessions(order_id):", "            if False:"),
    ], ["C16"], "left the previous session OPEN"),

    # The naive version of the fix: expire, and carry on whatever the provider
    # said. A refusal is the provider saying the session was already paid.
    ("a refused expiry is ignored and a new session opened anyway", [
        ('        if not _psp_expire(p["provider_ref"]):',
         '        if not _psp_expire(p["provider_ref"]) and False:'),
    ], ["C16"], "previous session had already been PAID"),

    ("checkout session not pinned to cards", [
        ('                f"&allowed_payment_method_types[0]=card"\n', ""),
    ], ["C15"], "opened for cards only"),

    # The tempting shortcut: the fake charges 1.5% + 20p, so write that down
    # rather than wait. It even matches the provider for this card.
    ("reconciler books an estimate before the provider reports the fee", [
        ("        if not bt:\n            continue                                     # not reported yet; next run\n",
         '        if not bt:\n            bt = {"id": None, "fee": round(payment["amount"] * 0.015) + 20,\n'
         '                  "currency": payment["currency"], "created": int(time.time())}\n'),
    ], ["C14"], "booked before the provider had reported one"),

    ("reconciler never books the fee", [
        ("    booked = 0\n    for order_id in todo:", "    booked = 0\n    for order_id in []:"),
    ], ["C14"], "must carry exactly one provider_fee"),

    # Must remove BOTH guards, as with dedupe: the worklist query and the re-check
    # under the lock each hide the absence of the other.
    ("reconciler books the fee on every run (worklist ignores the ledger)", [
        ('if o["status"] == "paid" and o["id"] not in booked_for]',
         'if o["status"] == "paid"]'),
        ('            if any(t["order_id"] == order_id and t["kind"] == "provider_fee"\n'
         '                   for t in DB["ledger"].values()):\n'
         '                continue                                 # another run beat us to it\n',
         ''),
    ], ["C14"], "reconciling twice must not book the fee twice"),
    # -- added with the checks that catch them -------------------------------

    ("a key reused with a different body replays the first response", [
        ('                if stored["fingerprint"] != fingerprint:', "                if False:"),
    ], ["C2"], "reusing a key for a different request"),

    # The response is the stored one, so every check that reads bodies passes.
    # Only counting the seats shows the work was done again.
    ("a replay holds the seats again before answering with the stored body", [
        ('                return self._send(stored["status"], stored["body"])',
         '                for it in json.loads(stored["body"])["items"]:\n'
         '                    DB["ticket_types"][it["ticket_type_id"]]["quantity_held"] += it["quantity"]\n'
         '                return self._send(stored["status"], stored["body"])'),
    ], ["C1", "C3"], "Availability should have dropped"),

    # Off by one, and safe in the sense that it never oversells. It turns away a
    # customer for the last seat on every tier, which is a different bug.
    ("the last seat is never sold", [
        ("                if qty < 1 or qty > available:", "                if qty < 1 or qty >= available:"),
    ], ["C7"], "UNDERSOLD"),

    ("the sale is booked single-entry", [
        ('                {"account": "ticket_revenue", "amount": money(-total, cur)},\n', ""),
    ], ["C8"], "that is not double-entry"),

    ("one ticket per order line, not per admission", [
        ('            for _ in range(item["quantity"]):', "            for _ in range(1):"),
    ], ["C9"], "one ticket per admitted person"),

    ("the provider is asked for one ticket's price, not the order total", [
        ('            amount, currency = order["total_amount"], order["total_currency"]',
         '            amount, currency = order["items"][0]["unit_price_amount"], order["total_currency"]'),
    ], ["C9"], "the provider was asked to charge"),

    # What `(major_units * 100).round` does to a currency with no minor unit.
    ("the provider amount assumes two decimal places", [
        ('                f"&line_items[0][price_data][unit_amount]={amount}"',
         '                f"&line_items[0][price_data][unit_amount]={amount * 100 if currency == \'JPY\' else amount}"'),
    ], ["C12b"], "the provider was asked to charge"),

    ("expiry releases the seats twice", [
        ('                    DB["ticket_types"][item["ticket_type_id"]]["quantity_held"] -= item["quantity"]',
         '                    DB["ticket_types"][item["ticket_type_id"]]["quantity_held"] -= 2 * item["quantity"]'),
    ], ["C10"], "exactly once"),

    # The success page polls, and the app asks the provider instead of waiting
    # for the webhook. The provider is right — and the order moved on a read.
    ("an order read asks the provider and fulfils on its answer", [
        ('            if len(parts) == 3 and parts[:2] == ["api", "orders"]:\n'
         '                o = DB["orders"].get(parts[2])\n',
         '            if len(parts) == 3 and parts[:2] == ["api", "orders"]:\n'
         '                o = DB["orders"].get(parts[2])\n'
         '                for p in [p for p in DB["payments"].values()\n'
         '                          if o and p["order_id"] == o["id"] and p["status"] == "requires_payment"]:\n'
         '                    s = _psp_get(f"/v1/checkout/sessions/{p[\'provider_ref\']}")\n'
         '                    if s.get("payment_status") == "paid":\n'
         '                        fulfil(s)\n'),
    ], ["C11"], "marked paid before its webhook arrived"),

    # The provider reported 97p; the formula says 88p.
    ("reconciler books a computed fee, not the reported one", [
        ('{"account": "processing_fees", "amount": money(bt["fee"], cur)},',
         '{"account": "processing_fees", "amount": money(round(bt["amount"] * 0.015) + 20, cur)},'),
        ('{"account": "psp_balance", "amount": money(-bt["fee"], cur)},',
         '{"account": "psp_balance", "amount": money(-(round(bt["amount"] * 0.015) + 20), cur)},'),
    ], ["C14"], "no pricing formula gives"),

    # What Ruby's JSON.generate(JSON.parse(body)) does: compact, and non-ASCII
    # written back unescaped.
    ("signature verified over re-serialised JSON", [
        ('f"{ts}.".encode() + raw, hashlib.sha256',
         'f"{ts}.".encode() + json.dumps(json.loads(raw), separators=(",", ":"),\n'
         '                            ensure_ascii=False).encode(), hashlib.sha256'),
    ], ["C4"], "genuinely signed event was rejected"),

    # JSON.pretty_generate: the whitespace matches the provider's exactly. Only
    # the escaped cardholder name tells the bytes apart, which is why the fake
    # provider puts one in every completed session.
    ("signature verified over re-serialised JSON, whitespace kept", [
        ('f"{ts}.".encode() + raw, hashlib.sha256',
         'f"{ts}.".encode() + json.dumps(json.loads(raw), indent=2,\n'
         '                            ensure_ascii=False).encode(), hashlib.sha256'),
    ], ["C4"], "genuinely signed event was rejected"),
]


def start(port):
    psp = subprocess.Popen(
        [sys.executable, str(ROOT / "spec/fake-psp/server.py")],
        env={**os.environ, "WEBHOOK_URL": f"http://127.0.0.1:{port}/api/webhooks/stripe",
             "FAKE_PSP_PORT": "4242"},
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    app = subprocess.Popen(
        [sys.executable, str(MUTANT)],
        env={**os.environ, "PORT": str(port), "HOLD_TTL_SECONDS": "6"},
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(40):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/api/events", timeout=1)
            break
        except Exception:
            time.sleep(0.3)
    return psp, app


def ports_in_use(*ports):
    """Ports we are about to bind that somebody else already holds.

    Without this check a dev stack left running on :3000 silently absorbs every
    request: the mutant never boots, the suite tests the *unmutated* app instead,
    and the harness confidently reports nothing caught. A wrong answer that looks
    like a real regression is worse than a crash.
    """
    busy = []
    for port in ports:
        with socket.socket() as probe:
            probe.settimeout(0.3)
            if probe.connect_ex(("127.0.0.1", port)) == 0:
                busy.append(port)
    return busy


def run_suite(cases=None):
    """Run the suite against whatever is on :3000. Returns (exit code, output)."""
    args = [sys.executable, "run.py", "--base-url", "http://127.0.0.1:3000"]
    if cases:
        args += ["--only", ",".join(cases)]
    r = subprocess.run(args, cwd=ROOT / "spec/conformance", capture_output=True, text=True,
                       env={**os.environ, "HOLD_TTL_SECONDS": "6"}, timeout=300)
    return r.returncode, r.stdout + r.stderr


FAILED = re.compile(r"^\s*✗ (C\w+)\s", re.M)


def verdict(code, output, expect_fail, why):
    """CAUGHT only when an expected case failed, and failed saying why."""
    failed = [c for c in FAILED.findall(output) if c in expect_fail]
    if code == 2 or (code not in (0, 1)) or (not failed and "Traceback" in output):
        return "NOBOOT", output[-160:].replace("\n", " ")
    if not failed:
        return "MISSED", ",".join(expect_fail)
    if why not in output:
        return "WRONG", ",".join(failed)
    return "CAUGHT", ",".join(failed)


def with_app(source, fn):
    MUTANT.write_text(source)
    psp, app = start(3000)
    try:
        return fn()
    finally:
        app.terminate()
        psp.terminate()
        time.sleep(0.8)
        MUTANT.unlink(missing_ok=True)


def main():
    if busy := ports_in_use(3000, 4242):
        print(f"\n  ports already in use: {', '.join(str(p) for p in busy)}")
        print("  stop the app, the worker and the fake provider first — otherwise")
        print("  this harness tests whatever is already listening and reports every")
        print("  mutation missed.\n")
        return 2

    # The unmutated reference must pass everything, or a "caught" below may only
    # mean the suite was failing anyway.
    code, output = with_app(SRC, run_suite)
    if code != 0:
        print("\n  the UNMUTATED reference does not pass the suite, so no mutation")
        print("  result would mean anything. Its run ended:\n")
        print("\n".join("    " + line for line in output.strip().splitlines()[-25:]))
        return 2
    print("\n  baseline: the unmutated reference passes every case")

    results = []
    for name, edits, expect_fail, why in MUTATIONS:
        mutated, missing = SRC, [f for f, _ in edits if f not in SRC]
        if missing:
            results.append((name, "SKIP", f"pattern gone: {missing[0][:45]}"))
            continue
        for find, replace in edits:
            mutated = mutated.replace(find, replace, 1)
        try:
            code, output = with_app(mutated, lambda: run_suite(expect_fail))
            status, detail = verdict(code, output, expect_fail, why)
        except subprocess.TimeoutExpired:
            status, detail = "TIMEOUT", ",".join(expect_fail)
        results.append((name, status, detail))

    print("\n  mutation                                                        caught by  result")
    print("  " + "-" * 84)
    missed = 0
    for name, status, detail in results:
        mark = {"CAUGHT": "✓", "WRONG": "✗", "MISSED": "✗", "SKIP": "○",
                "TIMEOUT": "✗", "NOBOOT": "!"}[status]
        if status != "CAUGHT":
            missed += 1
        print(f"  {mark} {name:<62} {detail:<10} {status}")
    print(f"\n  {len(results) - missed}/{len(results)} mutations caught\n")
    return 1 if missed else 0


if __name__ == "__main__":
    sys.exit(main())
