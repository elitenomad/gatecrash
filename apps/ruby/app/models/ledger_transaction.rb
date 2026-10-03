class LedgerTransaction < ApplicationRecord
  KINDS = %w[ticket_sale provider_fee payout].freeze

  belongs_to :order, optional: true
  has_many :entries, class_name: "LedgerEntry", dependent: :destroy,
                     foreign_key: :ledger_transaction_id, inverse_of: :ledger_transaction

  validates :kind, inclusion: { in: KINDS }
  validate  :must_balance

  # Append-only. A correction is a new reversing transaction, never an edit —
  # otherwise the audit trail can be rewritten and stops being evidence.
  def readonly? = persisted?

  def balances?
    entries.group_by(&:currency)
           .all? { |_currency, group| group.sum(&:amount).zero? }
  end

  private

  def must_balance
    return if entries.size >= 2 && balances?

    errors.add(:entries, "must contain at least two entries summing to zero per currency")
  end
end
