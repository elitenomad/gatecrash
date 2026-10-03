# Loads spec/fixtures/seed.json verbatim.
#
# Every implementation in this repository seeds from the same file, so the
# conformance suite can reference fixed UUIDs without an app-specific setup API.
require "json"

FIXTURE = Rails.root.join("../../spec/fixtures/seed.json").cleanpath

data = JSON.parse(File.read(FIXTURE))

ActiveRecord::Base.transaction do
  LedgerEntry.delete_all
  LedgerTransaction.delete_all
  Ticket.delete_all
  Payment.delete_all
  OrderItem.delete_all
  Order.delete_all
  WebhookEvent.delete_all
  IdempotencyKey.delete_all
  TicketType.delete_all
  Event.delete_all
  Organiser.delete_all

  data["organisers"].each do |o|
    Organiser.create!(id: o["id"], name: o["name"], email: o["email"])
  end

  data["events"].each do |e|
    event = Event.create!(
      id: e["id"], organiser_id: e["organiser_id"], slug: e["slug"], name: e["name"],
      starts_at: e["starts_at"], venue_name: e["venue_name"], status: e["status"]
    )
    e["ticket_types"].each do |t|
      TicketType.create!(
        id: t["id"], event:, name: t["name"],
        price_amount: t["price_amount"], price_currency: t["price_currency"],
        quantity_total: t["quantity_total"], quantity_held: 0, quantity_sold: 0
      )
    end
  end
end

puts "seeded #{Event.count} events, #{TicketType.count} ticket types from #{FIXTURE}"
