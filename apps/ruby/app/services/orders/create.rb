module Orders
  # Creates an order and holds inventory, exactly once per Idempotency-Key.
  class Create
    Result = Struct.new(:order, :error, :status, keyword_init: true) do
      def ok? = error.nil?
    end

    HOLD_TTL = Integer(ENV.fetch("HOLD_TTL_SECONDS", 900)).seconds

    def self.call(...) = new(...).call

    def initialize(event_id:, email:, items:)
      @event_id = event_id
      @email = email
      @items = items || []
    end

    def call
      return failure("Order must contain at least one item") if @items.empty?

      event = Event.find_by(id: @event_id)
      return failure("Unknown event", 422) if event.nil?

      order = nil
      ActiveRecord::Base.transaction do
        requested = @items.group_by { |i| i["ticket_type_id"] }
                          .transform_values { |rows| rows.sum { |r| r["quantity"].to_i } }

        # Lock every ticket_type row BEFORE reading availability, ordered by id
        # so concurrent orders touching the same tiers cannot deadlock.
        locked = TicketType.lock_for_update(requested.keys)

        lines = requested.map do |ticket_type_id, quantity|
          tt = locked[ticket_type_id]
          raise Rejected.new("Unknown ticket type") if tt.nil? || tt.event_id != event.id
          raise Rejected.new("Quantity must be positive") unless quantity.positive?
          raise Rejected.new("Only #{tt.available} remaining for #{tt.name}") if quantity > tt.available

          [tt, quantity]
        end

        currencies = lines.map { |tt, _| tt.price.currency }.uniq
        raise Rejected.new("An order cannot mix currencies") if currencies.size > 1

        total = lines.sum(Money.zero(currencies.first)) { |tt, qty| tt.price * qty }

        order = Order.create!(
          event:, email: @email, status: "pending",
          total_amount: total.amount, total_currency: total.currency,
          hold_expires_at: HOLD_TTL.from_now
        )

        lines.each do |tt, quantity|
          order.items.create!(ticket_type: tt, quantity:,
                              unit_price_amount: tt.price.amount,
                              unit_price_currency: tt.price.currency)
          tt.increment!(:quantity_held, quantity)
        end
      end

      Result.new(order:)
    rescue Rejected => e
      failure(e.message)
    rescue ActiveRecord::StatementInvalid => e
      # The check constraint fired, meaning application logic let something
      # through it should not have. Surface it as a rejection, not a 500.
      raise unless e.message.include?("ticket_types_inventory_within_capacity")

      failure("Insufficient availability")
    end

    private

    class Rejected < StandardError; end

    def failure(message, status = 422) = Result.new(error: message, status:)
  end
end
