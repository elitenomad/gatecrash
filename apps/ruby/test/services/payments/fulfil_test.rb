require "test_helper"

module Payments
  class FulfilTest < ActiveSupport::TestCase
    setup do
      @tt = build_ticket_type(total: 10)
      @order = place_order(ticket_type: @tt, quantity: 3)
      @order.transition_to!("awaiting_payment")
      @payment = build_payment(order: @order)
    end

    def session(**over) = { "id" => @payment.provider_ref, "payment_status" => "paid" }.merge(over.transform_keys(&:to_s))

    test "moves held inventory to sold and issues one ticket per admission" do
      assert_equal :fulfilled, Fulfil.call(session: session)

      assert_predicate @order.reload, :paid?
      assert_predicate @payment.reload, :succeeded?
      assert_equal 0, @tt.reload.quantity_held
      assert_equal 3, @tt.quantity_sold
      assert_equal 3, @order.tickets.count
      assert_nil @order.hold_expires_at
    end

    test "issues unguessable, unique ticket codes" do
      Fulfil.call(session: session)
      codes = @order.reload.tickets.map(&:code)
      assert_equal 3, codes.uniq.size
      codes.each { |c| assert_operator c.length, :>=, 16 }
    end

    test "books the sale, balanced, and nothing else" do
      Fulfil.call(session: session)
      txn = @order.reload.ledger_transactions.sole
      assert_equal "ticket_sale", txn.kind
      assert_equal 0, txn.entries.sum(&:amount)
    end

    test "is not paid at all if the sale cannot be booked" do
      # One transaction. Either the order is paid AND the sale is on the books,
      # or neither — a job retry will find the order still awaiting payment.
      # A sale that somehow already exists is the simplest way to make the
      # ledger write fail: the partial unique index refuses the second one.
      LedgerTransaction.insert!({ kind: "ticket_sale", order_id: @order.id, occurred_at: Time.current,
                                  created_at: Time.current, updated_at: Time.current })

      assert_raises(ActiveRecord::RecordNotUnique) { Fulfil.call(session: session) }
      assert_predicate @order.reload, :awaiting_payment?
      assert_predicate @payment.reload, :requires_payment?
      assert_empty @order.tickets
      assert_equal 3, @tt.reload.quantity_held
    end

    test "is idempotent — a redelivery issues nothing further" do
      assert_equal :fulfilled, Fulfil.call(session: session)
      assert_equal :already_fulfilled, Fulfil.call(session: session)
      assert_equal :already_fulfilled, Fulfil.call(session: session)

      assert_equal 3, @order.reload.tickets.count
      assert_equal 3, @tt.reload.quantity_sold
      assert_equal 0, @tt.quantity_held
      assert_equal 1, @order.ledger_transactions.count
    end

    test "a second session paying an order already paid is recorded, not ignored" do
      # Two sessions, both completed. Asking "is the order paid?" would answer
      # yes and walk away from money that arrived; the guard is on the payment.
      Fulfil.call(session: session)
      second = build_payment(order: @order)

      assert_equal :duplicate_payment,
                   Fulfil.call(session: { "id" => second.provider_ref, "payment_status" => "paid" })
      assert_predicate second.reload, :succeeded?, "the money arrived, and the row says so"
      assert_equal 3, @order.tickets.count, "nothing further issued"
      assert_equal 1, @order.ledger_transactions.where(kind: "ticket_sale").count
    end

    test "locks the order's tiers in id order, whatever order they were listed in" do
      # Item by item would lock them as listed — here, largest id first — and
      # an order listing the same tiers the other way round would hold one lock
      # each and wait for the other. Postgres kills one; its payment is stranded.
      order, = place_two_tier_order
      order.transition_to!("awaiting_payment")
      payment = build_payment(order:)

      locks = tier_locks do
        assert_equal :fulfilled, Fulfil.call(session: { "id" => payment.provider_ref, "payment_status" => "paid" })
      end

      assert_match(/ORDER BY "ticket_types"."id" ASC FOR UPDATE/, locks.sole)
      assert_equal 2, order.reload.tickets.count
    end

    test "ignores a session it has no payment for" do
      assert_equal :unknown_payment, Fulfil.call(session: { "id" => "cs_never_seen" })
      assert_predicate @order.reload, :awaiting_payment?
    end

    test "issues nothing for a session that completed unpaid" do
      # What a bank debit looks like: authorised, not yet paid. Cards only means
      # it should never arrive; if it does, it must not issue tickets.
      assert_equal :not_paid, Fulfil.call(session: session(payment_status: "unpaid"))
      assert_predicate @order.reload, :awaiting_payment?
      assert_predicate @payment.reload, :requires_payment?
      assert_empty @order.tickets
    end

    test "refuses to fulfil an order that already expired" do
      # The sweeper won the race. Fulfilling now would sell inventory that has
      # already been handed back to someone else.
      @order.update_columns(status: "expired", hold_expires_at: nil)
      assert_equal :not_fulfillable, Fulfil.call(session: session)
      assert_empty @order.reload.tickets
      assert_equal 0, @tt.reload.quantity_sold
    end

    test "records the payment as succeeded even when it cannot be fulfilled" do
      # The customer was charged. Whether we can deliver is a separate question,
      # and the answer must not erase the fact that the money arrived — which is
      # what an early `return` inside the transaction did on Rails 7.0.
      @order.update_columns(status: "expired", hold_expires_at: nil)

      assert_equal :not_fulfillable, Fulfil.call(session: session)
      assert_predicate @payment.reload, :succeeded?
    end
  end
end
