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

      if event.nil?
        # The unique index rejected it: we have recorded this event before.
        # Recorded is not processed. The row and the job are two writes to two
        # databases, and if the second failed last time the provider got a 5xx
        # and this redelivery is its retry. The job checks processed_at, so
        # queueing it again is harmless.
        event = WebhookEvent.find_by!(provider: "stripe", provider_event_id: payload.fetch("id"))
        ProcessWebhookEventJob.perform_later(event.id) unless event.processed_at?
        # 200 either way. A 4xx would make the provider retry something true,
        # for days.
        return head :ok
      end

      # If this raises, the provider gets a 5xx and redelivers: see above.
      ProcessWebhookEventJob.perform_later(event.id)
      head :ok
    rescue JSON::ParserError, KeyError => e
      Rails.logger.warn("unparseable webhook: #{e.message}")
      head :bad_request
    end
  end
end
