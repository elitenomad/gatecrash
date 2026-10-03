class Ticket < ApplicationRecord
  belongs_to :order
  belongs_to :ticket_type

  validates :code, presence: true, uniqueness: true

  # Scanned at the door, so it must be unguessable. A sequential id lets anyone
  # who bought one ticket walk in with a hundred.
  def self.generate_code = SecureRandom.urlsafe_base64(16)
end
