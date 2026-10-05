require "test_helper"

module Orders
  class ExpireHoldsTest < ActiveSupport::TestCase
    setup do
      @tt = build_ticket_type(total: 10)
      @order = place_order(ticket_type: @tt, quantity: 3)
    end

    def lapse!(order = @order) = order.update_column(:hold_expires_at, 1.minute.ago)

    test "leaves live holds alone" do
      assert_equal 0, Orders::ExpireHolds.call
      assert_predicate @order.reload, :pending?
      assert_equal 3, @tt.reload.quantity_held
    end

    test "expires a lapsed hold and returns its inventory" do
      lapse!
      assert_equal 1, Orders::ExpireHolds.call
      assert_predicate @order.reload, :expired?
      assert_equal 0, @tt.reload.quantity_held
      assert_nil @order.hold_expires_at
    end

    test "releases inventory exactly once when the sweeper runs repeatedly" do
      # Back to back, the second run never sees the order: `lapsed` only
      # selects holding states. The overlap is the next test.
      lapse!
      3.times { Orders::ExpireHolds.call }
      assert_equal 0, @tt.reload.quantity_held
      assert_equal 10, @tt.available
    end

    test "releases inventory exactly once when two runs overlap" do
      # Both runs select the order. The provider call comes between selecting
      # and locking, so that is where the second run lands: it expires the
      # order while the first is still closing the page. The first must then
      # find the hold gone. Without the re-read under the lock it checks its
      # own stale copy and releases the seats a second time, and only the
      # counter's own validation stops it going negative.
      psp = FakePsp.new
      Payments::StartCheckout.call(order: @order, psp:)
      lapse!
      psp.on_expire = lambda do
        psp.on_expire = nil
        assert_equal 1, Orders::ExpireHolds.call(psp:), "the second run expires it"
      end

      assert_equal 0, Orders::ExpireHolds.call(psp:), "the first run finds nothing left to do"
      assert_predicate @order.reload, :expired?
      assert_equal 0, @tt.reload.quantity_held
      assert_equal 10, @tt.available
    end

    test "locks the order's tiers in id order, whatever order they were listed in" do
      # The same order Orders::Create and Payments::Fulfil take them in, or this
      # can deadlock against either.
      order, tiers = place_two_tier_order
      lapse!(order)

      locks = tier_locks { Orders::ExpireHolds.call }

      assert_match(/ORDER BY "ticket_types"."id" ASC FOR UPDATE/, locks.sole)
      assert_predicate order.reload, :expired?
      assert_equal [0, 0], tiers.map { |tt| tt.reload.quantity_held }
    end

    test "never touches a paid order" do
      @order.update_columns(status: "paid", hold_expires_at: 1.minute.ago)
      assert_equal 0, Orders::ExpireHolds.call
      assert_predicate @order.reload, :paid?
      assert_equal 3, @tt.reload.quantity_held
    end

    test "expires orders awaiting payment as well as pending ones" do
      # A customer who was declined and gave up sends no event. The clock is
      # the only thing that will ever give their seats back.
      @order.update_column(:status, "awaiting_payment")
      lapse!
      assert_equal 1, Orders::ExpireHolds.call
      assert_predicate @order.reload, :expired?
      assert_equal 0, @tt.reload.quantity_held
    end

    test "closes the payment page before giving the seats back" do
      # A hold released while its session is open puts the seats back on sale
      # while the customer can still pay for them.
      psp = FakePsp.new
      payment = Payments::StartCheckout.call(order: @order, psp:).payment
      lapse!

      assert_equal 1, Orders::ExpireHolds.call(psp:)
      assert_equal "expired", psp.statuses[payment.provider_ref]
      assert_predicate payment.reload, :cancelled?
      assert_predicate @order.reload, :expired?
      assert_equal 0, @tt.reload.quantity_held
    end

    test "a customer who paid as the hold lapsed keeps their seats" do
      # The provider refuses to expire a session that has been paid, and the
      # refusal is the answer: the webhook is on its way, and the order is theirs.
      psp = FakePsp.new
      payment = Payments::StartCheckout.call(order: @order, psp:).payment
      psp.statuses[payment.provider_ref] = "complete"
      lapse!

      assert_equal 0, Orders::ExpireHolds.call(psp:)
      assert_predicate @order.reload, :awaiting_payment?
      assert_equal 3, @tt.reload.quantity_held

      completed = { "id" => payment.provider_ref, "payment_status" => "paid" }
      assert_equal :fulfilled, Payments::Fulfil.call(session: completed)
    end

    test "keeps the seats held while the provider cannot be reached" do
      psp = FakePsp.new
      payment = Payments::StartCheckout.call(order: @order, psp:).payment
      psp.statuses[payment.provider_ref] = :unreachable
      lapse!

      assert_equal 0, Orders::ExpireHolds.call(psp:)
      assert_predicate @order.reload, :awaiting_payment?
      assert_equal 3, @tt.reload.quantity_held
    end

    test "expired inventory becomes available to someone else" do
      full = build_ticket_type(total: 1)
      first = place_order(ticket_type: full)
      assert_equal 0, full.reload.available

      lapse!(first)
      Orders::ExpireHolds.call

      assert_equal 1, full.reload.available
      assert_nothing_raised { place_order(ticket_type: full) }
    end
  end
end
