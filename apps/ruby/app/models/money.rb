# An amount of money: an integer count of minor units, plus the currency those
# units belong to. Never a float, never a bare integer.
#
# Floats cannot represent 0.10 exactly. Summing a few thousand of them drifts,
# and the drift lands in a ledger that is supposed to balance to zero. A bare
# integer is only marginally better — it works right up until a second currency
# appears, and then silently adds yen to pounds.
class Money
  include Comparable

  class CurrencyMismatch < StandardError; end

  # Minor-unit scale is a property of the currency, not a universal 2.
  # An implementation that hardcodes /100 reports ¥4000 as ¥40.
  EXPONENTS = Hash.new(2).merge(
    "BIF" => 0, "CLP" => 0, "DJF" => 0, "GNF" => 0, "ISK" => 0, "JPY" => 0,
    "KMF" => 0, "KRW" => 0, "PYG" => 0, "RWF" => 0, "UGX" => 0, "UYI" => 0,
    "VND" => 0, "VUV" => 0, "XAF" => 0, "XOF" => 0, "XPF" => 0,
    "BHD" => 3, "IQD" => 3, "JOD" => 3, "KWD" => 3, "LYD" => 3, "OMR" => 3, "TND" => 3,
    "CLF" => 4, "UYW" => 4
  ).freeze

  attr_reader :amount, :currency

  def initialize(amount, currency)
    raise ArgumentError, "amount must be an Integer, got #{amount.class}" unless amount.is_a?(Integer)

    @amount = amount
    @currency = currency.to_s.upcase
    raise ArgumentError, "currency must be a three-letter code, got #{currency.inspect}" unless @currency.match?(/\A[A-Z]{3}\z/)

    freeze
  end

  def self.zero(currency) = new(0, currency)

  def +(other) = self.class.new(amount + compatible(other).amount, currency)
  def -(other) = self.class.new(amount - compatible(other).amount, currency)
  def -@ = self.class.new(-amount, currency)
  def *(factor)
    raise ArgumentError, "can only scale money by an Integer" unless factor.is_a?(Integer)

    self.class.new(amount * factor, currency)
  end

  # nil, Ruby's "these cannot be compared", for another currency or a bare
  # number — so `<` raises rather than guessing whether £1 is more than ¥1.
  def <=>(other) = other.is_a?(Money) && currency == other.currency ? amount <=> other.amount : nil
  def ==(other) = other.is_a?(Money) && amount == other.amount && currency == other.currency
  alias eql? ==
  def hash = [amount, currency].hash

  def zero? = amount.zero?
  def negative? = amount.negative?

  # Split into n parts that sum EXACTLY back to this amount.
  #
  # Largest-remainder: divide, then hand the leftover minor units out one at a
  # time. Naive division loses pennies — split £10.00 three ways with rounding
  # and you get £9.99 or £10.02, and the difference has to come from somewhere.
  def allocate(n)
    raise ArgumentError, "n must be positive" unless n.positive?

    base, remainder = amount.divmod(n)
    Array.new(n) { |i| self.class.new(base + (i < remainder ? 1 : 0), currency) }
  end

  def exponent = EXPONENTS[currency]

  def to_h = { amount:, currency: }
  def as_json(*) = to_h

  # Integers to the end. Dividing by a float would print the wrong digit for
  # any amount past 2**53 minor units, which a bigint column can hold.
  def to_s
    return "#{amount} #{currency}" if exponent.zero?

    major, minor = amount.abs.divmod(10**exponent)
    "#{'-' if negative?}#{major}.#{minor.to_s.rjust(exponent, '0')} #{currency}"
  end

  def inspect = "#<Money #{self}>"

  private

  def compatible(other)
    unless other.is_a?(Money) && other.currency == currency
      raise CurrencyMismatch, "cannot combine #{currency} with #{other.is_a?(Money) ? other.currency : other.class}"
    end

    other
  end
end
