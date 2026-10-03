require "test_helper"

module Payments
  class StartCheckoutTest < ActiveSupport::TestCase
    setup do
      @order = place_order(ticket_type: build_ticket_type(amount: 4500), quantity: 2)
    end

    test "records the payment and moves the order to awaiting_payment" do
      psp = FakePsp.new
      result = StartCheckout.call(order: @order, psp:)

      assert_predicate result, :ok?
      assert_equal "awaiting_payment", @order.reload.status
      assert_equal 1, @order.payments.count

      payment = @order.payments.sole
      assert_equal "requires_payment", payment.status
      assert_equal psp.calls.sole[:order], @order
      assert_equal @order.total.amount, payment.amount
      assert_equal @order.total.currency, payment.currency
    end

    test "stores the session id as provider_ref, so the webhook can find it" do
      psp = FakePsp.new(session: { "id" => "cs_test_lookup", "url" => "http://psp.test/c",
                                   "expires_at" => 1.hour.from_now.to_i })
      StartCheckout.call(order: @order, psp:)

      assert_equal "cs_test_lookup", @order.payments.sole.provider_ref
    end

    test "reads the expiry back from the session rather than inventing one" do
      expires = 12.minutes.from_now.to_i
      psp = FakePsp.new(session: { "id" => "cs_test_1", "url" => "http://psp.test/c",
                                   "expires_at" => expires })

      result = StartCheckout.call(order: @order, psp:)

      assert_equal expires, result.expires_at.to_i
    end

    test "a provider failure leaves the order exactly as it was" do
      psp = FakePsp.new(raise_error: "502: upstream on fire")
      result = StartCheckout.call(order: @order, psp:)

      refute_predicate result, :ok?
      assert_equal 502, result.status
      # Nothing half-created: the customer can simply press the button again.
      assert_equal "pending", @order.reload.status
      assert_empty @order.payments
    end

    test "refuses an order that is no longer payable" do
      @order.transition_to!("awaiting_payment")
      @order.transition_to!("expired")

      result = StartCheckout.call(order: @order, psp: FakePsp.new)

      refute_predicate result, :ok?
      assert_equal 409, result.status
      assert_empty @order.reload.payments
    end

    test "coming back to pay again is a second payment on the same order" do
      # The customer left the payment page — cancelled, or closed the tab — and
      # came back. A decline is not this: that is retried on the same page.
      psp = FakePsp.new
      StartCheckout.call(order: @order, psp:)

      result = StartCheckout.call(order: @order, psp:)

      assert_predicate result, :ok?
      assert_equal "awaiting_payment", @order.reload.status
      assert_equal 2, @order.payments.count
      assert_equal 2, @order.payments.map(&:provider_ref).uniq.size,
                   "the second attempt must use a fresh session, not resurrect the dead one"
    end

    test "closes the previous session before opening another" do
      # Two open sessions are two pages that can take the customer's money.
      psp = FakePsp.new
      first = StartCheckout.call(order: @order, psp:).payment

      StartCheckout.call(order: @order, psp:)

      assert_equal "expired", psp.statuses[first.provider_ref], "the old page can no longer be paid"
      assert_predicate first.reload, :cancelled?
      assert_equal 1, @order.payments.where(status: "requires_payment").count
    end

    test "opens nothing new if the previous session has already been paid" do
      # The customer paid, then came back before the webhook arrived. The
      # provider refuses the expiry, and the refusal is the answer.
      psp = FakePsp.new
      first = StartCheckout.call(order: @order, psp:).payment
      psp.statuses[first.provider_ref] = "complete"

      result = StartCheckout.call(order: @order, psp:)

      refute_predicate result, :ok?
      assert_equal 409, result.status
      assert_equal [first], @order.payments.reload.to_a
      assert_predicate first.reload, :requires_payment?, "the webhook decides what it became"
    end

    test "a session that lapsed on its own is recorded as cancelled, and checkout goes on" do
      psp = FakePsp.new
      first = StartCheckout.call(order: @order, psp:).payment
      psp.statuses[first.provider_ref] = "expired"

      result = StartCheckout.call(order: @order, psp:)

      assert_predicate result, :ok?
      assert_predicate first.reload, :cancelled?
    end

    test "a provider that cannot be reached to close the old session opens nothing" do
      psp = FakePsp.new
      first = StartCheckout.call(order: @order, psp:).payment
      psp.statuses[first.provider_ref] = :unreachable

      result = StartCheckout.call(order: @order, psp:)

      assert_equal 502, result.status
      assert_equal 1, psp.calls.size, "no second session while the first may still be payable"
      assert_predicate first.reload, :requires_payment?
    end

    test "refuses a hold that has lapsed, even before the sweeper gets to it" do
      @order.update_column(:hold_expires_at, 1.second.ago)
      psp = FakePsp.new

      result = StartCheckout.call(order: @order, psp:)

      assert_equal 409, result.status
      assert_empty psp.calls, "no session for seats that are no longer held"
    end

    test "an order the sweeper expired mid-checkout gets no URL" do
      # The provider took its time; the hold lapsed and the sweeper ran. The
      # session exists, but its address never leaves the server.
      psp = FakePsp.new
      psp.on_create = -> { @order.update_columns(status: "expired", hold_expires_at: nil) }

      result = StartCheckout.call(order: @order, psp:)

      assert_equal 409, result.status
      assert_nil result.checkout_url
      assert_empty @order.reload.payments
    end

    test "return urls point back at the order" do
      psp = FakePsp.new
      StartCheckout.call(order: @order, return_url_base: "https://gatecrash.test", psp:)

      call = psp.calls.sole
      assert_equal "https://gatecrash.test/orders/#{@order.id}", call[:success_url]
      assert_equal "https://gatecrash.test/orders/#{@order.id}?cancelled=1", call[:cancel_url]
    end
  end
end
