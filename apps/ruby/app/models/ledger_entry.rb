class LedgerEntry < ApplicationRecord
  ACCOUNTS = %w[psp_balance bank ticket_revenue processing_fees].freeze

  belongs_to :ledger_transaction

  composed_of :money,
              class_name: "Money",
              mapping: [%w[amount amount], %w[currency currency]]

  validates :account, inclusion: { in: ACCOUNTS }

  def readonly? = persisted?
end
