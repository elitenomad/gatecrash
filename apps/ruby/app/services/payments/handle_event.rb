module Payments
  # Dispatch for verified provider events. Called from the job, never inline.
  class HandleEvent
    def self.call(...) = new(...).call

    def initialize(webhook_event:)
      @webhook_event = webhook_event
    end

    def call
      payload = @webhook_event.payload
      object = payload.dig("data", "object") || {}

      case @webhook_event.event_type
      when "checkout.session.completed"
        Fulfil.call(session: object)
      when "checkout.session.async_payment_succeeded", "checkout.session.async_payment_failed"
        # Only a delayed payment method sends these, and Volume 1 pins every
        # session to cards. One arriving means a session got through unpinned,
        # with money that settles days after its hold — say so, loudly.
        Rails.logger.error("DELAYED PAYMENT: #{@webhook_event.event_type} for session " \
                           "#{object['id']}; cards only should make this impossible")
        :ignored
      else
        # Everything else is recorded and ignored on purpose. Stripe emits
        # dozens of types; treating an unknown one as an error means the
        # provider retries something we were never going to act on.
        #
        # That includes payment_intent.payment_failed. On hosted Checkout a
        # decline is one attempt on the session's PaymentIntent, and the
        # customer is still on the page, trying another card. The event is a
        # snapshot of the intent at the moment of the decline — out of date as
        # soon as the next card works, and it can arrive after that one. It
        # changes neither the payment, which is the session, nor the order.
        :ignored
      end.tap { @webhook_event.processed! }
    end
  end
end
