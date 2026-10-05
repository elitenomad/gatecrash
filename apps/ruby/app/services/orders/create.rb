module Orders
  # Creates an order and holds inventory, exactly once per Idempotency-Key.
  class Create
    Result = Struct.new(:order, :error, :status, :errors, keyword_init: true) do
      def ok? = error.nil?
    end

    HOLD_TTL = Integer(ENV.fetch("HOLD_TTL_SECONDS", 900)).seconds

    # What openapi.yaml allows for one line of an order.
    QUANTITY = 1..10

    def self.call(...) = new(...).call

    def initialize(event_id:, email:, items:)
      @event_id = event_id
      @email = email
      @items = items
    end

    def call
      if (errors = malformed).any?
        return Result.new(error: "The request does not match the contract", status: 422, errors:)
      end

      event = Event.find_by(id: @event_id)
      return failure("Unknown event", 422) if event.nil?
      return failure("#{event.name} is not on sale (it is #{event.status})") unless event.status == "on_sale"

      order = nil
      # A savepoint, not a transaction of its own: the idempotency wrapper holds
      # one open around this so the order and its stored response commit
      # together. A rejection here must undo the hold, and only the hold.
      ActiveRecord::Base.transaction(requires_new: true) do
        requested = @items.group_by { |i| i["ticket_type_id"] }
                          .transform_values { |rows| rows.sum { |r| r["quantity"] } }

        # Lock every ticket_type row BEFORE reading availability, ordered by id
        # so concurrent orders touching the same tiers cannot deadlock.
        locked = TicketType.lock_for_update(requested.keys)

        lines = requested.map do |ticket_type_id, quantity|
          tt = locked[ticket_type_id]
          raise Rejected.new("Unknown ticket type") if tt.nil? || tt.event_id != event.id
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

    # The body checked against CreateOrderRequest before anything is looked up.
    # `to_i` would quietly turn "5" into 5 and 1.9 into 1; a body that is not
    # what the contract says is a client bug, and it is worth naming each part.
    def malformed
      errors = []
      errors << error("email", "must be an email address") unless @email.is_a?(String) && @email.match?(URI::MailTo::EMAIL_REGEXP)
      errors << error("event_id", "is required") unless @event_id.is_a?(String) && @event_id.present?
      return errors << error("items", "must be a list of at least one item") unless @items.is_a?(Array) && @items.any?

      @items.each_with_index do |item, i|
        unless item.is_a?(Hash) && item.keys.sort == %w[quantity ticket_type_id]
          errors << error("items[#{i}]", "must have a ticket_type_id and a quantity, and nothing else")
          next
        end
        errors << error("items[#{i}].ticket_type_id", "must be a string") unless item["ticket_type_id"].is_a?(String)
        unless item["quantity"].is_a?(Integer) && QUANTITY.cover?(item["quantity"])
          errors << error("items[#{i}].quantity", "must be a whole number from #{QUANTITY.min} to #{QUANTITY.max}")
        end
      end
      errors
    end

    def error(field, message) = { field:, message: }

    def failure(message, status = 422) = Result.new(error: message, status:)
  end
end
