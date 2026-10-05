module Ledger
  # The reconciler. For every paid order that has no provider_fee yet, asks the
  # provider what it charged and books it:
  #
  #   Dr processing_fees   fee      (expense)
  #     Cr psp_balance     fee      (the provider kept it)
  #
  # The worklist is a query on the ledger itself — `Order.awaiting_fee` — so
  # the moment a fee is booked the order stops matching. That is what makes
  # this safe to run every few seconds, from a schedule and from an operator's
  # request at once, without a "reconciled" flag anywhere.
  class BookFees
    def self.call(...) = new(...).call

    # The fee is NOT on the checkout session. It is on the balance transaction
    # of the session's payment intent's latest charge — three hops, folded into
    # one request by `expand` — and it is null until the capture settles, which
    # with Stripe's asynchronous capture can take up to an hour. Injected, as
    # StartCheckout's provider is, so the accounting is testable without one.
    FEE_PATH = "payment_intent.latest_charge.balance_transaction".freeze

    DEFAULT_FEE_READER = lambda do |payment|
      session = Psp.checkout_session(payment.provider_ref, expand: [FEE_PATH])
      bt = session.dig(*FEE_PATH.split("."))
      return nil if bt.blank? # paid, but the provider has not reported the fee yet

      { ref: bt.fetch("id"), fee: Psp.money_from_provider(bt.fetch("fee"), bt.fetch("currency")),
        occurred_at: Time.zone.at(bt.fetch("created")) }
    end

    def initialize(fee_reader: DEFAULT_FEE_READER, limit: 200)
      @fee_reader = fee_reader
      @limit = limit
    end

    # Returns how many fees it booked. Anything it could not book this time —
    # provider down, fee not reported yet — is simply still on the worklist
    # next time.
    def call
      Order.awaiting_fee.order(:created_at).limit(@limit).to_a.count { |order| book(order) }
    end

    private

    def book(order)
      payment = order.payments.find_by(status: "succeeded")
      return false if payment.nil?

      reported = @fee_reader.call(payment)
      return false if reported.nil?

      fee = reported.fetch(:fee)
      LedgerTransaction.create!(
        kind: "provider_fee", order:, provider_ref: reported.fetch(:ref),
        occurred_at: reported.fetch(:occurred_at),
        entries: [
          LedgerEntry.new(account: "processing_fees", amount: fee.amount,  currency: fee.currency),
          LedgerEntry.new(account: "psp_balance",     amount: -fee.amount, currency: fee.currency)
        ]
      )
      true
    rescue Psp::Error => e
      Rails.logger.warn("could not read provider fee for order #{order.id}: #{e.message}")
      false
    rescue ActiveRecord::RecordNotUnique => e
      # Another worker booked it between our query and our insert. The partial
      # unique index on (order_id) where kind = 'provider_fee' decided who won.
      return false if e.message.include?("index_one_provider_fee_per_order")

      # The other index fired: this balance transaction is already booked to a
      # different order. That is not a race, it is two orders claiming one
      # charge, and every run will fail the same way until someone looks.
      Rails.logger.error("FEE NOT BOOKED: order #{order.id}: #{reported.fetch(:ref)} " \
                         "is already booked to another order")
      false
    end
  end
end
