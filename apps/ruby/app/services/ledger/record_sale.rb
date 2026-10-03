module Ledger
  # Books a completed sale as double-entry.
  #
  #   Dr psp_balance       total    (asset — money the provider now holds for us)
  #     Cr ticket_revenue  total    (revenue)
  #
  # Two entries, and no fee. The sale is OUR fact — we know the total the moment
  # the webhook arrives — so it is written inside the same database transaction
  # that marks the order paid, and needs nothing from the network to do it. The
  # fee is the PROVIDER's fact, and BookFees asks them for it separately.
  #
  # Revenue is credited the FULL total. Netting the fee off revenue understates
  # what you actually sold and makes the fee invisible to anyone reading the
  # accounts.
  class RecordSale
    def self.call(...) = new(...).call

    def initialize(order:)
      @order = order
    end

    def call
      total = @order.total

      LedgerTransaction.create!(
        kind: "ticket_sale", order: @order, occurred_at: Time.current,
        entries: [
          LedgerEntry.new(account: "psp_balance",    amount: total.amount,  currency: total.currency),
          LedgerEntry.new(account: "ticket_revenue", amount: -total.amount, currency: total.currency)
        ]
      )
    end
  end
end
