#!/usr/bin/env python3
"""
Mutation test for the conformance suite.

A suite that has only ever passed proves nothing. This breaks spec/reference/ in
known ways and asserts the expected case catches each one. Re-run after adding or
editing a case:

    make mutation-test

Every mutation must report CAUGHT:

    CAUGHT  the expected case failed, as it should have
    MISSED  the app was broken and the suite did not notice — the case is weak,
            OR the mutation does not actually produce the broken behaviour
    NOBOOT  the mutant never started; the harness is broken, not the suite
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
import socket
import subprocess
import sys
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
APP = ROOT / "spec/reference/app.py"
MUTANT = ROOT / "spec/reference/_mutant.py"
SRC = APP.read_text()

# (name, [(find, replace), ...], cases expected to fail)
MUTATIONS = [
    ("skip signature verification", [
        ("if not any(hmac.compare_digest(expected, s) for s in v1s):", "if False:"),
    ], ["C5"]),

    # A hash keeps one value per key. Caught only when ours is not the last v1,
    # which is why C18 delivers with the extra signature on both sides.
    ("only the last v1 signature is checked", [
        ('        v1s = [v for k, v in pairs if k == "v1"]',
         '        v1s = [dict(pairs).get("v1", "")]'),
    ], ["C18"]),

    ("a valid signature under any scheme is accepted", [
        ('        v1s = [v for k, v in pairs if k == "v1"]',
         '        v1s = [v for k, v in pairs if k != "t"]'),
    ], ["C18"]),

    ("skip timestamp tolerance check", [
        ("if abs(time.time() - ts) > TOLERANCE:", "if False:"),
    ], ["C6"]),

    # Must remove ALL the guards. The webhook-level dedupe alone is masked by the
    # idempotent fulfil() — both its "payment already succeeded" return and its
    # "only awaiting_payment has an edge to paid" return refuse a replay on their own —
    # which is precisely why C4 asserts on ticket and ledger counts rather than
    # on the HTTP response.
    ("no deduplication anywhere (webhook + fulfil guards)", [
        ('if event["id"] in DB["webhook_events"]:', "if False:"),
        ('        if payment["status"] == "succeeded":\n            return\n', ""),
        ('        if order["status"] != "awaiting_payment":\n            return\n', ""),
    ], ["C4"]),

    ("no idempotency replay (always create fresh)", [
        ('stored = DB["idempotency"].get(key)', "stored = None"),
    ], ["C1", "C3"]),

    ("money as floats", [
        ('return {"amount": int(amount), "currency": currency.upper()}',
         'return {"amount": float(amount), "currency": currency.upper()}'),
    ], ["C12"]),

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
    ], ["C7"]),

    ("mark paid at checkout instead of on webhook", [
        ('DB["orders"][order_id]["status"] = "awaiting_payment"',
         'DB["orders"][order_id]["status"] = "paid"'),
    ], ["C11"]),

    # The fee is debited to revenue instead of to an expense — netted off the top.
    # Every transaction still sums to zero and psp_balance is even right, so only
    # a whole-ledger view catches it.
    ("net the provider fee off revenue", [
        ('{"account": "processing_fees", "amount": money(bt["fee"], cur)},',
         '{"account": "ticket_revenue", "amount": money(bt["fee"], cur)},'),
    ], ["C14"]),

    ("sweeper skips awaiting_payment (a walked-away customer holds seats forever)", [
        ('if o["status"] in ("pending", "awaiting_payment") and _lapsed(o)]',
         'if o["status"] in ("pending",) and _lapsed(o)]'),
    ], ["C15"]),

    # Both sweeper mutations must also drop the re-check under the lock. A
    # payment still `requires_payment` holds the order on its own — a paid
    # session's payment is still waiting for its webhook — so with the re-check
    # in place the first mutant never releases anything (C15 then fails for the
    # wrong reason) and the second is masked entirely.
    ("sweeper releases seats without closing the payment page", [
        ("                if not close_open_sessions(oid):", "                if False:"),
        ('                if any(p["order_id"] == oid and p["status"] == "requires_payment"\n                       for p in DB["payments"].values()):\n                    continue                         # a session opened since; next run\n', ""),
    ], ["C15"]),

    # Closes the sessions, but does not listen to the answer. The refusal was
    # the provider saying the customer had already paid.
    ("sweeper releases seats the customer has already paid for", [
        ("                if not close_open_sessions(oid):\n                    continue\n",
         "                close_open_sessions(oid)\n"),
        ('                if any(p["order_id"] == oid and p["status"] == "requires_payment"\n                       for p in DB["payments"].values()):\n                    continue                         # a session opened since; next run\n', ""),
    ], ["C17"]),

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
    ], ["C15"]),

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
    ], ["C13"]),

    ("a new checkout leaves the previous session open", [
        ("            if not close_open_sessions(order_id):", "            if False:"),
    ], ["C16"]),

    # The naive version of the fix: expire, and carry on whatever the provider
    # said. A refusal is the provider saying the session was already paid.
    ("a refused expiry is ignored and a new session opened anyway", [
        ('        if not _psp_expire(p["provider_ref"]):',
         '        if not _psp_expire(p["provider_ref"]) and False:'),
    ], ["C16"]),

    ("checkout session not pinned to cards", [
        ('                f"&allowed_payment_method_types[0]=card"\n', ""),
    ], ["C15"]),

    # The tempting shortcut: the fake charges 1.5% + 20p, so write that down
    # rather than wait. It even matches the provider for this card.
    ("reconciler books an estimate before the provider reports the fee", [
        ("        if not bt:\n            continue                                     # not reported yet; next run\n",
         '        if not bt:\n            bt = {"id": None, "fee": round(payment["amount"] * 0.015) + 20,\n'
         '                  "currency": payment["currency"], "created": int(time.time())}\n'),
    ], ["C14"]),

    ("reconciler never books the fee", [
        ("    booked = 0\n    for order_id in todo:", "    booked = 0\n    for order_id in []:"),
    ], ["C14"]),

    # Must remove BOTH guards, as with dedupe: the worklist query and the re-check
    # under the lock each hide the absence of the other.
    ("reconciler books the fee on every run (worklist ignores the ledger)", [
        ('if o["status"] == "paid" and o["id"] not in booked_for]',
         'if o["status"] == "paid"]'),
        ('            if any(t["order_id"] == order_id and t["kind"] == "provider_fee"\n'
         '                   for t in DB["ledger"].values()):\n'
         '                continue                                 # another run beat us to it\n',
         ''),
    ], ["C14"]),
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


def main():
    if busy := ports_in_use(3000, 4242):
        print(f"\n  ports already in use: {', '.join(str(p) for p in busy)}")
        print("  stop the app, the worker and the fake provider first — otherwise")
        print("  this harness tests whatever is already listening and reports every")
        print("  mutation missed.\n")
        return 2

    results = []
    for name, edits, expect_fail in MUTATIONS:
        mutated, missing = SRC, [f for f, _ in edits if f not in SRC]
        if missing:
            results.append((name, "SKIP", f"pattern gone: {missing[0][:45]}"))
            continue
        for find, replace in edits:
            mutated = mutated.replace(find, replace, 1)
        MUTANT.write_text(mutated)

        psp, app = start(3000)
        try:
            r = subprocess.run(
                [sys.executable, "run.py", "--only", ",".join(expect_fail),
                 "--base-url", "http://127.0.0.1:3000"],
                cwd=ROOT / "spec/conformance", capture_output=True, text=True,
                env={**os.environ, "HOLD_TTL_SECONDS": "6"}, timeout=300)
            status = {2: "NOBOOT", 1: "CAUGHT"}.get(r.returncode, "MISSED")
            detail = ((r.stdout + r.stderr)[-160:].replace("\n", " ")
                      if status == "NOBOOT" else ",".join(expect_fail))
            results.append((name, status, detail))
        except subprocess.TimeoutExpired:
            results.append((name, "TIMEOUT", ",".join(expect_fail)))
        finally:
            app.terminate()
            psp.terminate()
            time.sleep(0.8)
            MUTANT.unlink(missing_ok=True)

    print("\n  mutation                                                expect   result")
    print("  " + "-" * 76)
    missed = 0
    for name, status, detail in results:
        mark = {"CAUGHT": "✓", "MISSED": "✗", "SKIP": "○",
                "TIMEOUT": "✗", "NOBOOT": "!"}[status]
        if status != "CAUGHT":
            missed += 1
        print(f"  {mark} {name:<53} {detail:<8} {status}")
    print(f"\n  {len(results) - missed}/{len(results)} mutations caught\n")
    return 1 if missed else 0


if __name__ == "__main__":
    sys.exit(main())
