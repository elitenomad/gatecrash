require "test_helper"

module Payments
  class HandleEventTest < ActiveSupport::TestCase
    setup do
      @order = place_order
      @order.transition_to!("awaiting_payment")
      @payment = build_payment(order: @order)
    end

    # A PaymentIntent, as Stripe sends it: no session id, nothing of ours unless
    # we put it in metadata. Checkout's decline lands on this, not on the session.
    def decline
      { "id" => "pi_#{SecureRandom.hex(6)}", "object" => "payment_intent",
        "status" => "requires_payment_method",
        "last_payment_error" => { "code" => "card_declined", "decline_code" => "generic_decline" } }
    end

    def event(type, object)
      WebhookEvent.create!(provider: "stripe", provider_event_id: "evt_#{SecureRandom.hex(4)}",
                           event_type: type, received_at: Time.current,
                           payload: { "type" => type, "data" => { "object" => object } })
    end

    test "fulfils on checkout.session.completed" do
      e = event("checkout.session.completed", { "id" => @payment.provider_ref, "payment_status" => "paid" })
      assert_equal :fulfilled, HandleEvent.call(webhook_event: e)
      assert_predicate @order.reload, :paid?
      assert_not_nil e.reload.processed_at
    end

    test "a decline changes nothing — the customer is still on the page" do
      e = event("payment_intent.payment_failed", decline)
      assert_equal :ignored, HandleEvent.call(webhook_event: e)
      assert_not_nil e.reload.processed_at, "recorded and done with, so it is not retried"
      assert_predicate @order.reload, :awaiting_payment?
      assert_predicate @payment.reload, :requires_payment?
    end

    test "a decline that arrives after the card that worked does not undo it" do
      # One session, two cards: the first declined, the second accepted on the
      # same page. Delivery order is not promised, so the decline can land
      # last. If it were allowed to speak for the session it would overwrite
      # a payment that succeeded — and the reconciler, which books the fee
      # against the succeeded payment, would never find one.
      completed = event("checkout.session.completed", { "id" => @payment.provider_ref, "payment_status" => "paid" })
      assert_equal :fulfilled, HandleEvent.call(webhook_event: completed)

      late = event("payment_intent.payment_failed", decline)
      HandleEvent.call(webhook_event: late)

      assert_predicate @payment.reload, :succeeded?
      assert_predicate @order.reload, :paid?
      assert_equal @order.items.sum(&:quantity), @order.tickets.count
    end

    test "a delayed payment method's events are ignored, loudly" do
      # Cards only should make these impossible. If one arrives, a session got
      # through unpinned, and somebody needs to know.
      e = event("checkout.session.async_payment_succeeded", { "id" => @payment.provider_ref })

      logged = capture_log { assert_equal :ignored, HandleEvent.call(webhook_event: e) }

      assert_match(/DELAYED PAYMENT/, logged)
      assert_predicate @order.reload, :awaiting_payment?
      assert_not_nil e.reload.processed_at
    end

    test "ignores unhandled event types but still marks them processed" do
      # Stripe emits dozens of types. Treating an unknown one as an error makes
      # the provider retry something we were never going to act on.
      e = event("customer.subscription.trial_will_end", { "id" => "sub_1" })
      assert_equal :ignored, HandleEvent.call(webhook_event: e)
      assert_not_nil e.reload.processed_at
    end
  end
end
