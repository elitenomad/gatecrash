# Cache of our own API responses, keyed by a client-supplied Idempotency-Key.
# Not a domain object — infrastructure, with no foreign keys into the domain.
class IdempotencyKey < ApplicationRecord
  self.primary_key = :key

  validates :request_fingerprint, presence: true

  scope :completed, -> { where.not(response_status: nil) }
  scope :in_flight, -> { where(response_status: nil) }

  def self.fingerprint(method, path, body) = Digest::SHA256.hexdigest([method, path, body].join("\n"))

  def completed? = response_status.present?
end
