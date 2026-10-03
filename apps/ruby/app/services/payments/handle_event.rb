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
      else
        # Everything else is recorded and ignored on purpose. Stripe emits
        # dozens of types; treating an unknown one as an error means the
        # provider retries something we were never going to act on.
        #
        # That includes payment_intent.payment_failed. On hosted Checkout a
        # decline is about one card, inside a session the customer is still
        # using: they see it on the page and try another. It changes neither
        # the payment — which is the session — nor the order, and it can arrive
        # after the card that worked.
        :ignored
      end.tap { @webhook_event.processed! }
    end
  end
end
