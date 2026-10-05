require "test_helper"

class EventTest < ActiveSupport::TestCase
  test "price_from is the cheapest tier, and nil until there is one" do
    event = build_event
    assert_nil event.price_from

    build_ticket_type(event:, amount: 4500)
    build_ticket_type(event:, amount: 2250, name: "Early Bird")
    assert_equal Money.new(2250, "GBP"), event.reload.price_from
  end
end
