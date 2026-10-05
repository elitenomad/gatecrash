require "test_helper"

class TicketTypeTest < ActiveSupport::TestCase
  setup { @tt = build_ticket_type(total: 10) }

  test "available subtracts both held and sold" do
    @tt.update!(quantity_held: 3, quantity_sold: 2)
    assert_equal 5, @tt.available
  end

  test "an event sells in one currency" do
    yen = TicketType.new(event: @tt.event, name: "Yen", price_amount: 4000, price_currency: "JPY",
                         quantity_total: 1, quantity_held: 0, quantity_sold: 0)
    assert_not_predicate yen, :valid?
    assert_includes yen.errors[:price_currency], "must match the event's other ticket types"
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
    # in the same sequence, or they deadlock against each other. Asked for in
    # descending order, it must still lock in ascending order, in one statement.
    a = build_ticket_type(event: @tt.event)
    ids = [@tt.id, a.id].sort.reverse
    locked = nil
    locks = tier_locks do
      ActiveRecord::Base.transaction { locked = TicketType.lock_for_update(ids) }
    end

    assert_match(/ORDER BY "ticket_types"."id" ASC FOR UPDATE/, locks.sole)
    assert_equal ids.sort, locked.keys
  end
end
