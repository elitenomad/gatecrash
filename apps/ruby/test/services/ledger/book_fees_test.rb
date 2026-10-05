require "test_helper"

module Ledger
  class BookFeesTest < ActiveSupport::TestCase
    setup do
      @order = paid_order(amount: 4500)
    end

    # Through the real fulfilment path, so the sale is on the books exactly as
    # production would have left it.
    def paid_order(amount:, currency: "GBP")
      order = place_order(ticket_type: build_ticket_type(amount:, currency:))
      order.transition_to!("awaiting_payment")
      payment = build_payment(order:)
      Payments::Fulfil.call(session: { "id" => payment.provider_ref, "payment_status" => "paid" })
      order.reload
    end

    # A fee reader that answers like the provider would, without a provider.
    def reports(fee, ref: nil, at: Time.zone.at(1_800_000_000))
      lambda do |payment|
        { ref: ref || "txn_#{SecureRandom.hex(4)}", fee: Money.new(fee, payment.currency), occurred_at: at }
      end
    end

    test "books the provider's fee as its own transaction, against psp_balance" do
      assert_equal 1, Ledger::BookFees.call(fee_reader: reports(88))

      fee = @order.ledger_transactions.find_by!(kind: "provider_fee")
      entries = fee.entries.index_by(&:account)
      assert_equal 88,   entries["processing_fees"].amount
      assert_equal(-88,  entries["psp_balance"].amount)
      assert_predicate fee, :balances?

      # The whole ledger for the order now says what the provider holds for us.
      assert_equal 4500 - 88, @order.ledger_transactions.flat_map(&:entries)
                                    .select { |e| e.account == "psp_balance" }.sum(&:amount)
      assert_equal(-4500, @order.ledger_transactions.flat_map(&:entries)
                                .select { |e| e.account == "ticket_revenue" }.sum(&:amount))
    end

    test "records the provider's reference and the provider's time, not ours" do
      at = Time.zone.at(1_800_000_000)
      Ledger::BookFees.call(fee_reader: reports(88, ref: "txn_abc", at:))
      fee = @order.ledger_transactions.find_by!(kind: "provider_fee")
      assert_equal "txn_abc", fee.provider_ref
      assert_equal at, fee.occurred_at
    end

    test "is idempotent — the worklist is the ledger, so a second run has nothing to do" do
      assert_equal 1, Ledger::BookFees.call(fee_reader: reports(88))
      assert_equal 0, Ledger::BookFees.call(fee_reader: reports(88))
      assert_equal 1, @order.ledger_transactions.where(kind: "provider_fee").count
    end

    test "leaves the order on the worklist when the provider is down" do
      down = ->(_) { raise Psp::TransientError, "provider down" }
      assert_equal 0, Ledger::BookFees.call(fee_reader: down)
      assert_includes Order.awaiting_fee, @order

      assert_equal 1, Ledger::BookFees.call(fee_reader: reports(88))
      assert_not_includes Order.awaiting_fee, @order
    end

    test "leaves the order on the worklist when the provider has not reported the fee yet" do
      assert_equal 0, Ledger::BookFees.call(fee_reader: ->(_) { nil })
      assert_includes Order.awaiting_fee, @order
    end

    test "ignores orders that are not paid" do
      place_order.transition_to!("awaiting_payment")
      asked = []
      Ledger::BookFees.call(fee_reader: ->(payment) { asked << payment.order_id; reports(88).call(payment) })
      assert_equal [@order.id], asked
    end

    test "books in the currency the provider reports" do
      yen = paid_order(amount: 4000, currency: "JPY")
      assert_equal 2, Ledger::BookFees.call(fee_reader: reports(80))
      fee = yen.ledger_transactions.find_by!(kind: "provider_fee")
      assert_equal ["JPY"], fee.entries.map(&:currency).uniq
      assert_equal 80, fee.entries.find { |e| e.account == "processing_fees" }.amount
    end

    test "a charge already booked to another order is not booked again, and says so" do
      Ledger::BookFees.call(fee_reader: reports(88, ref: "txn_same"))
      other = paid_order(amount: 4500)

      logged = capture_log { assert_equal 0, Ledger::BookFees.call(fee_reader: reports(88, ref: "txn_same")) }

      assert_includes Order.awaiting_fee, other
      assert_match(/FEE NOT BOOKED: order #{other.id}: txn_same/, logged)
    end

    test "one fee row with no order does not hide everyone else's" do
      # `NOT IN` over a list containing NULL is never true. Left in, the row
      # below would empty the worklist and no fee would be booked for anyone.
      LedgerTransaction.insert!({ kind: "provider_fee", order_id: nil, occurred_at: Time.current,
                                  created_at: Time.current, updated_at: Time.current })
      assert_includes Order.awaiting_fee, @order
    end

    test "the database refuses a second provider_fee for one order" do
      Ledger::BookFees.call(fee_reader: reports(88))
      assert_raises(ActiveRecord::RecordNotUnique) do
        LedgerTransaction.insert!({ kind: "provider_fee", order_id: @order.id,
                                    occurred_at: Time.current,
                                    created_at: Time.current, updated_at: Time.current })
      end
    end
  end
end
