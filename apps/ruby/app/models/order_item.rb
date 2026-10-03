class OrderItem < ApplicationRecord
  belongs_to :order
  belongs_to :ticket_type

  # Prices are copied here at order time and never joined live from
  # ticket_types. What the customer paid must not change when the organiser
  # edits the price tomorrow.
  composed_of :unit_price,
              class_name: "Money",
              mapping: [%w[unit_price_amount amount], %w[unit_price_currency currency]]

  validates :quantity, numericality: { greater_than: 0 }

  def subtotal = unit_price * quantity
end
