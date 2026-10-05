class Order < ApplicationRecord
  class InvalidTransition < StandardError; end

  STATUSES = %w[pending awaiting_payment paid expired].freeze

  # The state machine, written out rather than pulled from a gem. Four states
  # and four edges do not need a DSL, and a DSL is one more dependency that
  # can go unmaintained under a payments system.
  #
  # Note there is no `failed`. Hosted Checkout keeps a declined card on its own
  # page, where the customer tries another; nothing about the ORDER changes.
  TRANSITIONS = {
    "pending"          => %w[awaiting_payment expired],
    "awaiting_payment" => %w[paid expired],
    "paid"             => [],
    "expired"          => []
  }.freeze

  belongs_to :event
  has_many :items, -> { order(:created_at) }, class_name: "OrderItem", dependent: :destroy
  has_many :payments, -> { order(:created_at) }, dependent: :destroy
  has_many :tickets, dependent: :destroy
  # Restrict, not nullify: nullifying rewrites ledger rows, which are never
  # edited, and a provider_fee with no order hides every order's missing fee.
  has_many :ledger_transactions, dependent: :restrict_with_exception

  composed_of :total,
              class_name: "Money",
              mapping: [%w[total_amount amount], %w[total_currency currency]]

  validates :email, presence: true
  validates :status, inclusion: { in: STATUSES }

  # Every state that is sitting on unpaid seats. `awaiting_payment` belongs
  # here: a customer who was declined and gave up, or just closed the tab, sends
  # no event, and must not hold their tickets forever.
  scope :holding, -> { where(status: %w[pending awaiting_payment]) }
  scope :lapsed,  ->(at = Time.current) { holding.where(hold_expires_at: ...at) }

  # Paid, but the ledger has no provider_fee for it yet. The reconciler's
  # worklist: a query, not a flag, so booking the fee is what empties it.
  # The NULLs are left out on purpose: `id NOT IN (…, NULL)` is never true,
  # so a single fee row with no order would empty the list for everyone.
  scope :awaiting_fee, -> {
    where(status: "paid")
      .where.not(id: LedgerTransaction.where(kind: "provider_fee").where.not(order_id: nil).select(:order_id))
  }

  STATUSES.each { |s| define_method("#{s}?") { status == s } }

  # A hold that has lapsed is not a hold, whether or not the sweeper has got
  # to it yet.
  def payable? = %w[pending awaiting_payment].include?(status) && hold_expires_at&.future?

  def transition_to!(next_status, **attrs)
    unless TRANSITIONS.fetch(status, []).include?(next_status)
      raise InvalidTransition, "order #{id}: #{status} -> #{next_status}"
    end

    update!(status: next_status, **attrs)
  end

  # Returns false instead of raising when the transition is simply no longer
  # applicable — a webhook arriving after the sweeper already expired the order
  # is a race we expect, not an error worth paging anyone about.
  def try_transition_to!(next_status, **attrs)
    transition_to!(next_status, **attrs)
    true
  rescue InvalidTransition
    false
  end
end
