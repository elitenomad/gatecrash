require "test_helper"

class MoneyTest < ActiveSupport::TestCase
  test "requires an integer amount" do
    assert_raises(ArgumentError) { Money.new(45.0, "GBP") }
    assert_raises(ArgumentError) { Money.new("4500", "GBP") }
    assert_equal 4500, Money.new(4500, "GBP").amount
  end

  test "normalises and freezes" do
    m = Money.new(4500, "gbp")
    assert_equal "GBP", m.currency
    assert_predicate m, :frozen?
  end

  test "refuses to combine different currencies rather than coercing" do
    assert_raises(Money::CurrencyMismatch) { Money.new(1, "GBP") + Money.new(1, "JPY") }
    assert_raises(Money::CurrencyMismatch) { Money.new(1, "GBP") - Money.new(1, "USD") }
  end

  test "arithmetic" do
    assert_equal Money.new(9000, "GBP"), Money.new(4500, "GBP") * 2
    assert_equal Money.new(7000, "GBP"), Money.new(4500, "GBP") + Money.new(2500, "GBP")
    assert_equal Money.new(-4500, "GBP"), -Money.new(4500, "GBP")
    assert_raises(ArgumentError) { Money.new(4500, "GBP") * 1.5 }
  end

  test "comparison only within a currency" do
    assert_operator Money.new(100, "GBP"), :>, Money.new(50, "GBP")
    assert_nil Money.new(100, "GBP") <=> Money.new(50, "JPY")
    assert_equal Money.new(100, "GBP"), Money.new(100, "gbp")
    assert_not_equal Money.new(100, "GBP"), Money.new(100, "USD")
  end

  test "allocate splits without losing a single minor unit" do
    # The whole point: naive division of 1000 by 3 loses a penny, and the penny
    # has to come from somewhere.
    parts = Money.new(1000, "GBP").allocate(3)
    assert_equal [334, 333, 333], parts.map(&:amount)
    assert_equal 1000, parts.sum(&:amount)

    [1, 2, 7, 13, 100].each do |n|
      [1, 99, 4500, 100_003].each do |total|
        split = Money.new(total, "GBP").allocate(n)
        assert_equal n, split.size
        assert_equal total, split.sum(&:amount), "#{total} split #{n} ways"
      end
    end
  end

  test "allocate handles negatives without drift" do
    parts = Money.new(-1000, "GBP").allocate(3)
    assert_equal(-1000, parts.sum(&:amount))
  end

  test "currency exponents are not universally 2" do
    assert_equal 2, Money.new(1, "GBP").exponent
    assert_equal 0, Money.new(1, "JPY").exponent
    assert_equal 3, Money.new(1, "KWD").exponent
    assert_equal 0, Money.new(1, "XOF").exponent
    assert_equal 3, Money.new(1, "IQD").exponent
    assert_equal 4, Money.new(1, "CLF").exponent
  end

  test "formats by the currency's own exponent" do
    assert_equal "45.00 GBP", Money.new(4500, "GBP").to_s
    assert_equal "4000 JPY",  Money.new(4000, "JPY").to_s   # NOT 40.00
    assert_equal "1.500 KWD", Money.new(1500, "KWD").to_s
  end

  test "serialises to minor units and currency, never a float" do
    assert_equal({ amount: 4500, currency: "GBP" }, Money.new(4500, "GBP").to_h)
    assert_kind_of Integer, Money.new(4500, "GBP").as_json[:amount]
  end
end
