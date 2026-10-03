module Api
  class WebhooksController < ApplicationController
    # Answer fast, then do the work. Everything below the record step happens in
    # a job; a provider that waits on our fulfilment will time out and redeliver.
    def stripe
      raw = request.raw_post

      begin
        Psp.verify_signature!(raw, request.headers["Stripe-Signature"])
      rescue Psp::SignatureError => e
        Rails.logger.warn("rejected webhook: #{e.message}")
        return head :bad_request
      end

      payload = JSON.parse(raw)

      event = WebhookEvent.record_once(
        provider: "stripe",
        provider_event_id: payload.fetch("id"),
        event_type: payload.fetch("type"),
        payload:
      )

      # nil means the unique index rejected it: we have seen this event and
      # already acted on it. 200 is the honest answer — a 4xx would make the
      # provider retry something true, for days.
      return head :ok if event.nil?

      ProcessWebhookEventJob.perform_later(event.id)
      head :ok
    rescue JSON::ParserError, KeyError => e
      Rails.logger.warn("unparseable webhook: #{e.message}")
      head :bad_request
    end
  end
end
