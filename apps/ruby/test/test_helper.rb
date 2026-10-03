ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "support/fake_psp"

module ActiveSupport
  class TestCase
    # Not parallelised. These tests exercise row locks, transactional guards and
    # exactly-once semantics; running them serially keeps failures reproducible
    # and avoids juggling a second queue database per worker.
    fixtures :all

    # Plain builders rather than a factory gem. The whole app is Rails 8 and
    # nothing else, and these are six lines.
    def build_organiser(**attrs)
      Organiser.create!({ name: "Hackney Nights", email: "promoter@example.test" }.merge(attrs))
    end

    def build_event(**attrs)
      Event.create!({
        organiser: build_organiser, slug: "ev-#{SecureRandom.hex(4)}", name: "A Show",
        starts_at: 30.days.from_now, venue_name: "The Moth Club", status: "on_sale"
      }.merge(attrs))
    end

    def build_ticket_type(event: nil, amount: 4500, currency: "GBP", total: 100, **attrs)
      TicketType.create!({
        event: event || build_event, name: "General Admission",
        price_amount: amount, price_currency: currency,
        quantity_total: total, quantity_held: 0, quantity_sold: 0
      }.merge(attrs))
    end

    # Goes through the real service so held inventory and copied prices are set
    # up exactly as production would.
    def place_order(ticket_type: nil, quantity: 1, email: "buyer@example.test")
      tt = ticket_type || build_ticket_type
      result = Orders::Create.call(
        event_id: tt.event_id, email:,
        items: [{ "ticket_type_id" => tt.id, "quantity" => quantity }]
      )
      raise "order setup failed: #{result.error}" unless result.ok?

      result.order
    end

    def build_payment(order:, ref: "cs_test_#{SecureRandom.hex(6)}")
      order.payments.create!(provider: "stripe", provider_ref: ref,
                             amount: order.total.amount, currency: order.total.currency,
                             status: "requires_payment")
    end

    def sign_payload(body, secret: Psp.webhook_secret, timestamp: Time.current.to_i)
      digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}")
      "t=#{timestamp},v1=#{digest}"
    end
  end
end
