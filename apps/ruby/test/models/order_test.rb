require "test_helper"

class OrderTest < ActiveSupport::TestCase
  setup { @order = place_order }

  test "starts pending with inventory held" do
    assert_predicate @order, :pending?
    assert_equal 1, @order.items.first.ticket_type.reload.quantity_held
  end

  test "permits every edge in the transition table" do
    Order::TRANSITIONS.each do |from, targets|
      targets.each do |to|
        order = place_order
        order.update_column(:status, from)
        assert order.reload.try_transition_to!(to), "#{from} -> #{to} should be allowed"
        assert_equal to, order.reload.status
      end
    end
  end

  # The valuable half. A state machine that only proves its happy edges is a
  # list of method calls.
  test "rejects every edge NOT in the transition table" do
    Order::STATUSES.each do |from|
      allowed = Order::TRANSITIONS.fetch(from)
      (Order::STATUSES - allowed).each do |to|
        order = place_order
        order.update_column(:status, from)
        assert_raises(Order::InvalidTransition, "#{from} -> #{to} should be rejected") do
          order.reload.transition_to!(to)
        end
        assert_equal from, order.reload.status, "#{from} must be unchanged after a rejected #{to}"
      end
    end
  end

  test "paid and expired are terminal" do
    assert_empty Order::TRANSITIONS.fetch("paid")
    assert_empty Order::TRANSITIONS.fetch("expired")
  end

  test "awaiting_payment leads only to paid or expired" do
    # No `failed`: hosted Checkout keeps a declined card on its own page, and
    # a customer who gives up is released by the clock like any other.
    assert_equal %w[paid expired], Order::TRANSITIONS.fetch("awaiting_payment")
  end

  test "try_transition_to! returns false instead of raising on a stale race" do
    @order.update_column(:status, "expired")
    assert_not @order.reload.try_transition_to!("paid")
    assert_equal "expired", @order.reload.status
  end

  test "payable? covers exactly the states checkout accepts" do
    assert_equal %w[pending awaiting_payment],
                 Order::STATUSES.select { |s| Order.new(status: s, hold_expires_at: 1.minute.from_now).payable? }
  end

  test "a lapsed hold is not payable, even before the sweeper gets to it" do
    @order.update_column(:hold_expires_at, 1.second.ago)
    assert_not @order.payable?
  end

  test "an order has many payments" do
    # One per payment page. Only one page may be open at a time, so the first
    # is closed before the second.
    build_payment(order: @order).update!(status: "cancelled")
    build_payment(order: @order)
    assert_equal 2, @order.reload.payments.count
  end

  test "total is a Money, not a number" do
    assert_kind_of Money, @order.total
    assert_equal "GBP", @order.total.currency
  end
end
