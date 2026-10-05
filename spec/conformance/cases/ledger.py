"""C8, C14 — chapter 10."""

import time
from collections import defaultdict

from _common import await_status, buy, create_order, order_body, psp_complete, start_checkout
from harness import case, expect, expect_status


@case("C8", "Every paid order books ledger entries summing to zero per currency", "ch10")
def c8(ctx):
    order = buy(ctx)
    r = ctx.app.get(f"/api/admin/orders/{order['id']}/ledger", admin=True)
    expect_status(r, 200, "from GET /api/admin/orders/{id}/ledger")

    txns = r.json["data"]
    expect(len(txns) >= 1, "a paid order must book at least one ledger transaction", txns)

    sales = [t for t in txns if t["kind"] == "ticket_sale"]
    expect(len(sales) == 1, "exactly one ticket_sale transaction per paid order", txns)

    for t in txns:
        expect(len(t["entries"]) >= 2,
               f"transaction {t['id']} has fewer than two entries — that is not "
               "double-entry, it is a log line", t)

        per_currency = defaultdict(int)
        for e in t["entries"]:
            per_currency[e["amount"]["currency"]] += e["amount"]["amount"]

        for currency, total in per_currency.items():
            expect(total == 0,
                   f"transaction {t['id']} does not balance in {currency}. Every "
                   "financial fact must sum to zero, or the ledger cannot be trusted "
                   "to verify anything.", dict(per_currency))

        accounts = {e["account"] for e in t["entries"]}
        expect(accounts <= {"psp_balance", "bank", "ticket_revenue", "processing_fees"},
               f"unknown account in transaction {t['id']}", accounts)

    revenue = sum(e["amount"]["amount"] for t in sales for e in t["entries"]
                  if e["account"] == "ticket_revenue")
    expect(revenue == -order["total"]["amount"],
           "ticket_revenue must be credited the full order total. Netting the "
           "provider fee off revenue understates what you actually sold.",
           f"revenue_entry={revenue} order_total={order['total']['amount']}")


def ledger_for(ctx, order_id):
    r = ctx.app.get(f"/api/admin/orders/{order_id}/ledger", admin=True)
    expect_status(r, 200, "from GET /api/admin/orders/{id}/ledger")
    return r.json["data"]


def account_total(txns, account):
    return sum(e["amount"]["amount"] for t in txns for e in t["entries"]
               if e["account"] == account)


FEE_DELAY = 5
REPORTED_FEE = 97


def _reported_fee(ctx, sid):
    """The balance transaction behind a session, or None while it is not there.
    Three hops — session, payment intent, latest charge — folded into one read."""
    path = "payment_intent.latest_charge.balance_transaction"
    session = ctx.psp.get(f"/v1/checkout/sessions/{sid}?expand[]={path}").json
    charge = (session.get("payment_intent") or {}).get("latest_charge") or {}
    return charge.get("balance_transaction")


@case("C14", "The provider's fee is booked as its own transaction, exactly once, "
             "for the amount the provider reports", "ch10")
def c14(ctx):
    r, _, _ = create_order(ctx, order_body(ctx))
    order_id = r.json["id"]
    _, sid = start_checkout(ctx, order_id)

    # Paid — but the capture has not settled, so the balance transaction that
    # carries the fee is still null. With Stripe's asynchronous capture that can
    # last up to an hour; here it lasts FEE_DELAY seconds.
    # A fee no pricing formula produces: 1.5% + 20p of £45 is 88p, and this is 97p.
    # An app that computes the fee instead of reading it cannot agree with it.
    psp_complete(ctx, sid, fee_delay=FEE_DELAY, fee=REPORTED_FEE)
    order = await_status(ctx, order_id, "paid")
    total = order["total"]["amount"]

    r = ctx.app.post("/api/admin/ledger/reconcile", admin=True)
    expect_status(r, 200, "from POST /api/admin/ledger/reconcile")
    early = [t for t in ledger_for(ctx, order_id) if t["kind"] == "provider_fee"]
    if _reported_fee(ctx, sid) is None:   # otherwise the app was slow and this proves nothing
        expect(early == [],
               "a provider_fee was booked before the provider had reported one. Whatever "
               "number that is, it is an estimate — and it will disagree with the provider "
               "for every card priced differently from the one you tested with. Book the "
               "fee when it arrives; until then the order simply has none.", early)

    time.sleep(FEE_DELAY + 0.5)

    # What the provider says it charged. The suite reads it from the provider,
    # not from the app, so an app that invents a fee cannot agree with itself.
    bt = _reported_fee(ctx, sid)
    expect(bt is not None, "the fake provider never reported the fee", sid)
    expect(bt["amount"] == total,
           f"the provider charged {bt['amount']} for an order of {total}. The fee is a "
           "share of what was charged, so a wrong charge makes every number after it wrong.",
           {"charged": bt["amount"], "order_total": total})

    r = ctx.app.post("/api/admin/ledger/reconcile", admin=True)
    expect_status(r, 200, "from POST /api/admin/ledger/reconcile")

    txns = ledger_for(ctx, order_id)
    fees = [t for t in txns if t["kind"] == "provider_fee"]
    expect(len(fees) == 1,
           "after reconciling, a paid order must carry exactly one provider_fee "
           "transaction — none means the fee is invisible to the accounts; more than "
           "one means the reconciler is not idempotent", txns)
    fee = fees[0]
    expect(fee.get("provider_ref") == bt["id"],
           "provider_fee.provider_ref must be the provider's balance transaction id — "
           "that link is what makes the ledger reconcilable against their report",
           {"provider_ref": fee.get("provider_ref"), "expected": bt["id"]})
    accounts = sorted({e["account"] for e in fee["entries"]})
    expect("processing_fees" in accounts,
           "the provider_fee transaction has no processing_fees entry. The fee is an "
           "expense; booked anywhere else — ticket_revenue, say — it is netted off the top "
           "and the books can no longer say what the provider costs.", accounts)
    expect(account_total([fee], "processing_fees") == bt["fee"],
           f"the fee booked must be the fee the provider reports ({bt['fee']} here, which "
           "no pricing formula gives) — not an estimate, and not a percentage worked out "
           "on our side",
           {"booked": account_total([fee], "processing_fees"), "provider": bt["fee"]})

    expect(account_total(txns, "ticket_revenue") == -total,
           "ticket_revenue across the whole ledger must still be the full order total. "
           "The fee is an expense — booking it against revenue nets it off the top.",
           {"revenue": account_total(txns, "ticket_revenue"), "total": total})
    expect(account_total(txns, "psp_balance") == total - bt["fee"],
           "psp_balance must be total minus fee: that is what the provider is holding "
           "for us, and what the payout will eventually have to match",
           {"psp_balance": account_total(txns, "psp_balance"),
            "expected": total - bt["fee"]})

    # Run it again. The worklist is a query on the ledger, so a second pass has
    # nothing to do — if it books again, the fee will be counted twice at payout.
    r = ctx.app.post("/api/admin/ledger/reconcile", admin=True)
    expect_status(r, 200, "from a second POST /api/admin/ledger/reconcile")
    again = [t for t in ledger_for(ctx, order_id) if t["kind"] == "provider_fee"]
    expect(len(again) == 1,
           "reconciling twice must not book the fee twice", again)
