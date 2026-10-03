require "test_helper"

class LedgerTransactionTest < ActiveSupport::TestCase
  def entry(account, amount, currency = "GBP")
    LedgerEntry.new(account:, amount:, currency:)
  end

  def txn(entries, kind: "ticket_sale", order: nil)
    LedgerTransaction.new(kind:, order:, occurred_at: Time.current, entries:)
  end

  test "accepts a balanced transaction" do
    assert_predicate txn([entry("psp_balance", 4412), entry("processing_fees", 88),
                          entry("ticket_revenue", -4500)]), :valid?
  end

  test "refuses a transaction that does not sum to zero" do
    t = txn([entry("psp_balance", 4412), entry("ticket_revenue", -4500)])
    assert_not_predicate t, :valid?
    assert_match(/sum.*zero/i, t.errors.full_messages.join)
  end

  test "refuses a single-sided entry" do
    # One entry is a log line, not double-entry bookkeeping.
    assert_not_predicate txn([entry("psp_balance", 0)]), :valid?
  end

  test "balances PER CURRENCY, not in aggregate" do
    # +100 GBP and -100 JPY sums to zero if you ignore currency. It is not
    # balanced, and treating it as such silently invents an FX position.
    t = txn([entry("psp_balance", 100, "GBP"), entry("ticket_revenue", -100, "JPY")])
    assert_not_predicate t, :valid?
  end

  test "accepts a multi-currency transaction where each currency balances" do
    t = txn([entry("psp_balance", 100, "GBP"), entry("ticket_revenue", -100, "GBP"),
             entry("psp_balance", 400, "JPY"), entry("ticket_revenue", -400, "JPY")])
    assert_predicate t, :valid?
  end

  test "rejects an unknown account" do
    assert_not_predicate txn([entry("slush_fund", 1), entry("psp_balance", -1)]), :valid?
  end

  test "is append-only once persisted" do
    order = place_order
    t = Ledger::RecordSale.call(order:)
    assert_raises(ActiveRecord::ReadOnlyRecord) { t.update!(kind: "payout") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { t.entries.first.update!(amount: 1) }
  end

  test "the database refuses a second ticket_sale for one order" do
    order = place_order
    Ledger::RecordSale.call(order:)
    assert_raises(ActiveRecord::RecordNotUnique) do
      LedgerTransaction.insert!({ kind: "ticket_sale", order_id: order.id,
                                  occurred_at: Time.current,
                                  created_at: Time.current, updated_at: Time.current })
    end
  end
end
