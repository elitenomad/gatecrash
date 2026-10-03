require "test_helper"

module Orders
  class CreateTest < ActiveSupport::TestCase
    setup { @tt = build_ticket_type(amount: 4500, total: 10) }

    def create(items:, email: "b@example.test", event_id: nil)
      Orders::Create.call(event_id: event_id || @tt.event_id, email:, items:)
    end

    def line(tt = @tt, quantity: 1) = { "ticket_type_id" => tt.id, "quantity" => quantity }

    test "holds inventory and copies the price onto the item" do
      result = create(items: [line(quantity: 2)])
      assert_predicate result, :ok?
      assert_equal 2, @tt.reload.quantity_held
      assert_equal 0, @tt.quantity_sold
      assert_equal Money.new(4500, "GBP"), result.order.items.first.unit_price
      assert_equal Money.new(9000, "GBP"), result.order.total
    end

    test "the copied price does not follow later price changes" do
      order = create(items: [line]).order
      @tt.update!(price_amount: 9999)
      assert_equal Money.new(4500, "GBP"), order.reload.items.first.unit_price
      assert_equal Money.new(4500, "GBP"), order.total
    end

    test "rejects more than is available" do
      result = create(items: [line(quantity: 11)])
      assert_not_predicate result, :ok?
      assert_match(/remaining/, result.error)
      assert_equal 0, @tt.reload.quantity_held
    end

    test "counts held inventory as unavailable" do
      create(items: [line(quantity: 10)])
      result = create(items: [line(quantity: 1)])
      assert_not_predicate result, :ok?
      assert_equal 10, @tt.reload.quantity_held
    end

    test "rejects an empty order" do
      assert_not_predicate create(items: []), :ok?
    end

    test "rejects unknown event and unknown ticket type" do
      assert_not_predicate create(items: [line], event_id: SecureRandom.uuid), :ok?
      bogus = { "ticket_type_id" => SecureRandom.uuid, "quantity" => 1 }
      assert_not_predicate create(items: [bogus]), :ok?
    end

    test "rejects a ticket type belonging to a different event" do
      other = build_ticket_type
      assert_not_predicate create(items: [line(other)]), :ok?
    end

    test "rejects non-positive quantities" do
      [0, -3].each { |q| assert_not_predicate create(items: [line(quantity: q)]), :ok? }
    end

    test "refuses to mix currencies in one order" do
      yen = build_ticket_type(event: @tt.event, amount: 4000, currency: "JPY")
      result = create(items: [line, line(yen)])
      assert_not_predicate result, :ok?
      assert_match(/currenc/i, result.error)
    end

    test "sums duplicate lines for the same tier against one availability check" do
      # Two lines of 6 for a tier with 10 left must be rejected as 12, not
      # accepted as two independent 6s.
      result = create(items: [line(quantity: 6), line(quantity: 6)])
      assert_not_predicate result, :ok?
      assert_equal 0, @tt.reload.quantity_held
    end

    test "a rejected order leaves no partial state behind" do
      other = build_ticket_type(event: @tt.event, total: 1)
      create(items: [line(quantity: 1), line(other, quantity: 5)])
      assert_equal 0, @tt.reload.quantity_held
      assert_equal 0, other.reload.quantity_held
      assert_equal 0, Order.count
    end

    test "sets a hold expiry" do
      assert_not_nil create(items: [line]).order.hold_expires_at
    end
  end
end
