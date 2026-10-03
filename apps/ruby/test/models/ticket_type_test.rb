require "test_helper"

class TicketTypeTest < ActiveSupport::TestCase
  setup { @tt = build_ticket_type(total: 10) }

  test "available subtracts both held and sold" do
    @tt.update!(quantity_held: 3, quantity_sold: 2)
    assert_equal 5, @tt.available
  end

  test "price is a Money" do
    assert_equal Money.new(4500, "GBP"), @tt.price
  end

  test "the database makes overselling unrepresentable" do
    # Belt and braces. Application code takes a row lock, but locks get lost in
    # refactors and check constraints do not.
    assert_raises(ActiveRecord::StatementInvalid) do
      @tt.update_column(:quantity_held, 11)
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      @tt.update_columns(quantity_held: 6, quantity_sold: 6)
    end
  end

  test "the database refuses negative counters" do
    assert_raises(ActiveRecord::StatementInvalid) { @tt.update_column(:quantity_held, -1) }
  end

  test "lock_for_update orders by id to avoid deadlocks" do
    # Two concurrent orders touching the same pair of tiers must take the locks
    # in the same sequence, or they deadlock against each other.
    a = build_ticket_type(event: @tt.event)
    ids = [@tt.id, a.id]
    locked = nil
    ActiveRecord::Base.transaction { locked = TicketType.lock_for_update(ids) }
    assert_equal ids.sort, locked.keys.sort
  end
end
