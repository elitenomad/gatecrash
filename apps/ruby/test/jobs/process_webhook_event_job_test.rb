require "test_helper"

class ProcessWebhookEventJobTest < ActiveJob::TestCase
  setup do
    @order = place_order
    @order.transition_to!("awaiting_payment")
    payment = build_payment(order: @order)
    @event = WebhookEvent.record_once(
      provider: "stripe", provider_event_id: "evt_#{SecureRandom.hex(4)}",
      event_type: "checkout.session.completed",
      payload: { "data" => { "object" => { "id" => payment.provider_ref, "payment_status" => "paid" } } }
    )
  end

  # Fails the first call to HandleEvent with the given error, then behaves.
  def failing_once(error)
    original = Payments::HandleEvent.method(:call)
    failed = false
    Payments::HandleEvent.define_singleton_method(:call) do |**kw|
      next original.call(**kw) if failed

      failed = true
      raise error
    end
    yield
  ensure
    Payments::HandleEvent.define_singleton_method(:call, original)
  end

  test "a deadlock is retried, not dropped" do
    # The provider already has its 200 and will not redeliver. A job that died
    # on its first deadlock would leave a paid order unfulfilled for good.
    failing_once(ActiveRecord::Deadlocked.new("deadlock detected")) do
      assert_enqueued_with(job: ProcessWebhookEventJob) { ProcessWebhookEventJob.perform_now(@event.id) }
      assert_nil @event.reload.processed_at
      perform_enqueued_jobs
    end

    assert_predicate @order.reload, :paid?
    assert_predicate @event.reload, :processed_at?
  end

  test "a lost connection is retried too" do
    failing_once(ActiveRecord::ConnectionNotEstablished.new("connection lost")) do
      assert_enqueued_with(job: ProcessWebhookEventJob) { ProcessWebhookEventJob.perform_now(@event.id) }
    end
  end

  test "an event already processed is not processed again" do
    ProcessWebhookEventJob.perform_now(@event.id)
    tickets = @order.reload.tickets.count

    ProcessWebhookEventJob.perform_now(@event.id)

    assert_equal tickets, @order.reload.tickets.count
  end
end
