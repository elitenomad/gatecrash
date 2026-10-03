module Api
  class EventsController < ApplicationController
    def index
      events = Event.on_sale.includes(:ticket_types).order(:starts_at)
      render json: { data: events.map { |e| summary(e) } }
    end

    def show
      event = Event.includes(:ticket_types).find_by!(slug: params[:slug])
      render json: summary(event).merge(
        ticket_types: event.ticket_types.order(:price_amount).map { |t| ticket_type(t) }
      )
    end

    private

    def summary(event)
      {
        id: event.id, slug: event.slug, name: event.name,
        starts_at: event.starts_at.iso8601, venue_name: event.venue_name,
        status: event.status, price_from: money(event.price_from)
      }
    end

    def ticket_type(t)
      { id: t.id, name: t.name, price: money(t.price), available: t.available }
    end
  end
end
