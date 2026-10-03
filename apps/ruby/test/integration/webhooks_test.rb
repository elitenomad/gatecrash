require "test_helper"

class WebhooksTest < ActionDispatch::IntegrationTest
  setup do
    @order = place_order
    @order.transition_to!("awaiting_payment")
    @payment = build_payment(order: @order)
  end

  def body(id: "evt_#{SecureRandom.hex(4)}", type: "checkout.session.completed")
    JSON.generate({ "id" => id, "type" => type,
                    "data" => { "object" => { "id" => @payment.provider_ref, "payment_status" => "paid" } } })
  end

  def post_webhook(raw, header)
    post "/api/webhooks/stripe", params: raw,
         headers: { "Stripe-Signature" => header, "CONTENT_TYPE" => "application/json" }
  end

  test "accepts a valid event and defers the work to a job" do
    raw = body
    assert_enqueued_with(job: ProcessWebhookEventJob) do
      post_webhook(raw, sign_payload(raw))
    end
    assert_response :ok
    assert_equal 1, WebhookEvent.count

    # Crucially, the request itself must NOT have fulfilled anything. A provider
    # waiting on our fulfilment will time out and redeliver.
    assert_predicate @order.reload, :awaiting_payment?
  end

  test "rejects a forged signature without recording or enqueuing" do
    raw = body
    assert_no_enqueued_jobs do
      post_webhook(raw, sign_payload(raw, secret: "whsec_wrong"))
    end
    assert_response :bad_request
    assert_equal 0, WebhookEvent.count
  end

  test "rejects a missing signature header" do
    post "/api/webhooks/stripe", params: body, headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :bad_request
  end

  test "rejects a garbage signature header with 400, not 500" do
    # An unauthenticated caller must not be able to raise an unhandled exception.
    ["garbage", "t=,v1=", "=====", "t=abc,v1=def"].each do |header|
      post_webhook(body, header)
      assert_response :bad_request, "header #{header.inspect} should be a clean 400"
    end
  end

  test "rejects a stale but correctly signed event" do
    raw = body
    post_webhook(raw, sign_payload(raw, timestamp: 20.minutes.ago.to_i))
    assert_response :bad_request
    assert_equal 0, WebhookEvent.count
  end

  test "answers a duplicate 200 and does not enqueue it twice" do
    raw = body(id: "evt_dup")
    post_webhook(raw, sign_payload(raw))
    assert_response :ok

    assert_no_enqueued_jobs do
      post_webhook(raw, sign_payload(raw))
    end
    # 200, not 4xx: the event is true and we have already acted on it. A 4xx
    # would make the provider retry it forever.
    assert_response :ok
    assert_equal 1, WebhookEvent.count
  end

  test "rejects an unparseable body" do
    raw = "{not json"
    post_webhook(raw, sign_payload(raw))
    assert_response :bad_request
  end

  test "rejects a signed payload missing required fields" do
    raw = JSON.generate({ "no_id" => true })
    post_webhook(raw, sign_payload(raw))
    assert_response :bad_request
  end
end
