require "test_helper"

module Ledger
  class RecordSaleTest < ActiveSupport::TestCase
    setup do
      @order = place_order(ticket_type: build_ticket_type(amount: 4500))
    end

    test "books psp_balance against revenue, balancing to zero" do
      txn = Ledger::RecordSale.call(order: @order)

      entries = txn.entries.index_by(&:account)
      assert_equal 4500,   entries["psp_balance"].amount
      assert_equal(-4500,  entries["ticket_revenue"].amount)
      assert_equal 0, txn.entries.sum(&:amount)
      assert_predicate txn, :balances?
    end

    test "credits revenue the FULL total — the fee is not its business" do
      # Netting the fee off revenue understates what you sold and hides the fee
      # from anyone reading the accounts. The sale does not even know the fee.
      txn = Ledger::RecordSale.call(order: @order)
      assert_equal(-@order.total.amount, txn.entries.find { |e| e.account == "ticket_revenue" }.amount)
      assert_empty txn.entries.select { |e| e.account == "processing_fees" }
    end

    test "the database refuses a second ticket_sale for one order" do
      Ledger::RecordSale.call(order: @order)
      assert_raises(ActiveRecord::RecordNotUnique) { Ledger::RecordSale.call(order: @order) }
      assert_equal 1, LedgerTransaction.where(kind: "ticket_sale", order: @order).count
    end

    test "entries carry the order's currency" do
      yen_order = place_order(ticket_type: build_ticket_type(amount: 4000, currency: "JPY"))
      txn = Ledger::RecordSale.call(order: yen_order)
      assert_equal ["JPY"], txn.entries.map(&:currency).uniq
      assert_equal(-4000, txn.entries.find { |e| e.account == "ticket_revenue" }.amount)
    end
  end
end
