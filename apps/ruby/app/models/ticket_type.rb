class TicketType < ApplicationRecord
  belongs_to :event
  has_many :order_items, dependent: :restrict_with_error
  has_many :tickets, dependent: :restrict_with_error

  composed_of :price,
              class_name: "Money",
              mapping: [%w[price_amount amount], %w[price_currency currency]]

  validates :name, presence: true
  validates :quantity_total, :quantity_held, :quantity_sold,
            numericality: { greater_than_or_equal_to: 0 }

  # Held and sold are tracked separately, not collapsed into one "remaining"
  # counter. Expiry has to know how much to give back, and reconciliation has to
  # be able to tell a lapsed hold apart from a completed sale.
  def available = quantity_total - quantity_held - quantity_sold

  # Take a row lock BEFORE reading availability. Reading first and locking after
  # is the classic oversell: two requests both see 1 remaining and both proceed.
  def self.lock_for_update(ids)
    where(id: ids).order(:id).lock("FOR UPDATE").index_by(&:id)
  end
end
