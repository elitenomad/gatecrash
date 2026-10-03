"""C12 — chapter 3."""

from _common import YEN, buy, create_order, order_body
from harness import case, expect, expect_status, walk


MONEY_ISH = {"amount", "total", "price", "unit_price", "price_from", "fee", "net"}


def _audit(doc, where, problems):
    """
    Two distinct failures, and they must not be confused:

      - a float anywhere in a money document
      - a money-ish key holding a bare number with no currency beside it

    The second check must NOT fire on the `amount` field of a well-formed
    {amount, currency} object, which is exactly where a naive implementation of
    this test trips over itself.
    """
    def visit(node, path):
        if isinstance(node, float):
            problems.append(f"{where}{path} is a float ({node})")

        if isinstance(node, dict):
            is_money = "amount" in node and "currency" in node
            if is_money:
                amt = node["amount"]
                if isinstance(amt, bool) or not isinstance(amt, int):
                    problems.append(f"{where}{path}.amount is {type(amt).__name__} ({amt!r})")
                cur = node["currency"]
                if not (isinstance(cur, str) and len(cur) == 3 and cur.isupper()):
                    problems.append(f"{where}{path}.currency is not ISO 4217 upper ({cur!r})")

            for k, v in node.items():
                bare = (k in MONEY_ISH
                        and isinstance(v, (int, float))
                        and not isinstance(v, bool)
                        and not (is_money and k == "amount"))
                if bare:
                    problems.append(f"{where}{path}.{k} is a bare number — money needs a currency")
                visit(v, f"{path}.{k}")

        elif isinstance(node, list):
            for i, v in enumerate(node):
                visit(v, f"{path}[{i}]")

    visit(doc, "")


@case("C12", "Money is never a float and never a bare number", "ch3")
def c12(ctx):
    problems = []

    r = ctx.app.get("/api/events")
    expect_status(r, 200)
    _audit(r.json, "GET /api/events ", problems)

    for ev in ctx.seed["events"]:
        r = ctx.app.get(f"/api/events/{ev['slug']}")
        expect_status(r, 200)
        _audit(r.json, f"GET /api/events/{ev['slug']} ", problems)

    order = buy(ctx)
    _audit(order, "paid order ", problems)

    r = ctx.app.get(f"/api/admin/orders/{order['id']}/ledger", admin=True)
    if r.status == 200:
        _audit(r.json, "ledger ", problems)

    expect(not problems,
           "money must be an integer count of minor units plus an ISO 4217 currency. "
           "Floats cannot represent 0.10 exactly and will silently lose pennies at "
           "scale; bare numbers break the moment a second currency appears.",
           "\n             ".join(problems[:12]))


@case("C12b", "Zero-decimal currencies are handled without a hardcoded /100", "ch3")
def c12b(ctx):
    """JPY has no minor unit. 4000 JPY is four thousand yen, not forty."""
    ev, tt = ctx.ticket_type(YEN)
    r = ctx.app.get(f"/api/events/{ev['slug']}")
    expect_status(r, 200)

    tier = next(t for t in r.json["ticket_types"] if t["id"] == tt["id"])
    expect(tier["price"]["currency"] == "JPY", "currency must round-trip", tier)
    expect(tier["price"]["amount"] == 4000,
           "the seeded JPY price must survive unscaled. An implementation that "
           "converts through a 2-decimal 'major units' representation returns 40 here.",
           tier["price"])

    resp, _, _ = create_order(ctx, order_body(ctx, YEN, qty=2))
    total = resp.json["total"]
    expect(total == {"amount": 8000, "currency": "JPY"},
           "order total must be computed in minor units of the order's own currency",
           total)
