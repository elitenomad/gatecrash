class ProcessWebhookEventJob < ApplicationJob
  queue_as :default

  # The provider redelivers on non-2xx, but we answered 200 before this ran, so
  # retries here are ours. Nothing on this path calls the provider. What fails
  # is the database: a deadlock, a lock timeout, a dropped connection. All
  # three are worth another go, and fulfilment is idempotent, so a retry that
  # finds the work already done does nothing.
  retry_on ActiveRecord::Deadlocked,
           ActiveRecord::LockWaitTimeout,
           ActiveRecord::ConnectionNotEstablished,
           ActiveRecord::ConnectionFailed,
           wait: :polynomially_longer, attempts: 5

  def perform(webhook_event_id)
    event = WebhookEvent.find_by(id: webhook_event_id)
    return if event.nil? || event.processed_at.present?

    Payments::HandleEvent.call(webhook_event: event)
  end
end
