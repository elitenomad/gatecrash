class Payment < ApplicationRecord
  STATUSES = %w[requires_payment succeeded cancelled].freeze

  belongs_to :order

  composed_of :money,
              class_name: "Money",
              mapping: [%w[amount amount], %w[currency currency]]

  validates :provider, :provider_ref, presence: true
  validates :provider_ref, uniqueness: { scope: :provider }
  validates :status, inclusion: { in: STATUSES }

  STATUSES.each { |s| define_method("#{s}?") { status == s } }
end
