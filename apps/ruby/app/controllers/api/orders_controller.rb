module Api
  class OrdersController < ApplicationController
    include Idempotent

    def create
      # The whole action runs inside the idempotency wrapper, which stores the
      # rendered bytes and replays them verbatim on a repeat key.
      idempotent do
        # The parsed body as the client sent it, types included, so the service
        # can hold it to the contract: a quantity of "5" is not a quantity.
        body = request.request_parameters
        result = Orders::Create.call(event_id: body["event_id"], email: body["email"], items: body["items"])

        if result.ok?
          render json: OrderSerializer.new(result.order).as_json, status: :created
        else
          problem(result.status || 422, "Order rejected", result.error, errors: result.errors)
        end
      end
    end

    def show
      order = Order.includes(:items, :payments).find(params[:id])
      render json: OrderSerializer.new(order).as_json
    end

    def checkout
      order = Order.find(params[:id])
      result = Payments::StartCheckout.call(order:)
      return problem(result.status, "Checkout unavailable", result.error) unless result.ok?

      render status: :created, json: {
        payment_id: result.payment.id,
        checkout_url: result.checkout_url,
        expires_at: result.expires_at.iso8601
      }
    end

    def tickets
      order = Order.find(params[:id])
      unless order.paid?
        return problem(409, "Order not paid",
                       "Tickets exist only for paid orders (this one is #{order.status})")
      end

      render json: {
        data: order.tickets.includes(:ticket_type).order(:issued_at).map do |t|
          { id: t.id, ticket_type_id: t.ticket_type_id, ticket_type_name: t.ticket_type.name,
            code: t.code, issued_at: t.issued_at.iso8601 }
        end
      }
    end
  end
end
