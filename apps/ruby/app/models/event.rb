class Event < ApplicationRecord
  STATUSES = %w[draft on_sale sold_out cancelled completed].freeze

  belongs_to :organiser
  has_many :ticket_types, dependent: :destroy
  has_many :orders, dependent: :restrict_with_error

  validates :slug, :name, :starts_at, :venue_name, presence: true
  validates :slug, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  scope :on_sale, -> { where(status: "on_sale") }

  def to_param = slug

  def price_from
    ticket_types.map(&:price).min
  end
end
