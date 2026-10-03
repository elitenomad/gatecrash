require "test_helper"

class WebhookEventTest < ActiveSupport::TestCase
  def record(id: "evt_1", type: "checkout.session.completed")
    WebhookEvent.record_once(provider: "stripe", provider_event_id: id,
                             event_type: type, payload: { "id" => id })
  end

  test "records a first sighting" do
    event = record
    assert_predicate event, :persisted?
    assert_nil event.processed_at
  end

  test "returns nil for a duplicate instead of raising" do
    assert_not_nil record
    assert_nil record, "a second sighting of the same event id must be reported as a duplicate"
    assert_equal 1, WebhookEvent.count
  end

  test "deduplicates per provider, not globally" do
    record
    other = WebhookEvent.record_once(provider: "adyen", provider_event_id: "evt_1",
                                     event_type: "x", payload: {})
    assert_not_nil other, "the same event id from a different provider is a different event"
  end

  test "stores the payload verbatim for the audit trail" do
    payload = { "id" => "evt_9", "data" => { "object" => { "amount_total" => 4500 } } }
    event = WebhookEvent.record_once(provider: "stripe", provider_event_id: "evt_9",
                                     event_type: "checkout.session.completed", payload:)
    assert_equal payload, event.reload.payload
  end

  test "marks processed" do
    event = record
    event.processed!
    assert_not_nil event.reload.processed_at
    assert_empty WebhookEvent.unprocessed
  end
end
