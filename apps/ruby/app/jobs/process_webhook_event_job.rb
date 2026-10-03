class ProcessWebhookEventJob < ApplicationJob
  queue_as :default

  # The provider redelivers on non-2xx, so a job that fails permanently should
  # not also keep the provider retrying. We already answered 200; retries here
  # are ours to manage.
  retry_on Psp::Error, wait: :polynomially_longer, attempts: 5

  def perform(webhook_event_id)
    event = WebhookEvent.find_by(id: webhook_event_id)
    return if event.nil? || event.processed_at.present?

    Payments::HandleEvent.call(webhook_event: event)
  end
end
