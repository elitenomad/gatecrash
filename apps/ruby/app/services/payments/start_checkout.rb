module Payments
  class StartCheckout
    Result = Struct.new(:payment, :checkout_url, :expires_at, :error, :status, keyword_init: true) do
      def ok? = error.nil?
    end

    def self.call(...) = new(...).call

    # The provider is injected rather than reached for, the same way
    # Ledger::RecordSale takes its fee reader. It is the only part of this
    # service that touches the network, and a test that wants to check what
    # happens when the provider is down should not have to stub a global.
    def initialize(order:, return_url_base: nil, psp: Psp)
      @order = order
      @psp = psp
      @base = return_url_base || ENV.fetch("FRONTEND_URL", "http://localhost:5173")
    end

    def call
      return failure("Order is not payable", 409) unless @order.payable?
      unless CloseOpenSessions.call(order: @order, psp: @psp)
        return failure("Order already paid; confirmation on its way", 409)
      end

      session = @psp.create_checkout_session(
        order: @order,
        success_url: "#{@base}/orders/#{@order.id}",
        cancel_url: "#{@base}/orders/#{@order.id}?cancelled=1"
      )

      payment = nil
      ActiveRecord::Base.transaction do
        # The sweeper may have expired the order while the provider was
        # answering. If so, record nothing and hand out no URL: a page nobody
        # has the address of cannot take money.
        @order.lock!
        raise ActiveRecord::Rollback unless @order.payable?

        payment = @order.payments.create!(
          provider: "stripe", provider_ref: session.fetch("id"),
          amount: @order.total.amount, currency: @order.total.currency,
          status: "requires_payment"
        )
        # A repeat call is legitimate — the customer left the payment page and
        # came back — and gets a second payment against a fresh session. The
        # order is already where it needs to be.
        @order.try_transition_to!("awaiting_payment") unless @order.awaiting_payment?
      end
      return failure("Order is not payable", 409) if payment.nil?

      # The provider decides when its session dies, so read that back rather
      # than asserting a duration of our own. A locally-invented expiry agrees
      # with the provider right up until the day it quietly does not.
      Result.new(payment:, checkout_url: session.fetch("url"),
                 expires_at: Time.at(session.fetch("expires_at")).utc)
    rescue Psp::Error => e
      Rails.logger.error("psp checkout failed: #{e.message}")
      failure("Payment provider unavailable", 502)
    end

    private

    def failure(message, status) = Result.new(error: message, status:)
  end
end
