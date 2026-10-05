# A log of every event the provider sent us, as parsed JSON: what it said, not
# the bytes it said it in. The raw body is checked against the signature and
# then let go — jsonb keeps neither whitespace nor key order.
#
# Deliberately has no foreign key into orders: an event must be recordable
# before we know whether the thing it references exists or is even valid.
class WebhookEvent < ApplicationRecord
  validates :provider, :provider_event_id, :event_type, presence: true

  scope :unprocessed, -> { where(processed_at: nil) }

  # Deduplication is an INSERT that either succeeds or violates the unique
  # index — never a SELECT followed by an INSERT, which races under concurrent
  # redelivery. Returns nil when we have seen this event before.
  def self.record_once(provider:, provider_event_id:, event_type:, payload:)
    create!(provider:, provider_event_id:, event_type:, payload:, received_at: Time.current)
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def processed! = update!(processed_at: Time.current)
end
