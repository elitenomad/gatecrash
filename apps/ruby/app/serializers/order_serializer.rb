class OrderSerializer
  def initialize(order)
    @order = order
  end

  def as_json(*)
    {
      id: @order.id,
      event_id: @order.event_id,
      email: @order.email,
      status: @order.status,
      total: @order.total.to_h,
      hold_expires_at: @order.hold_expires_at&.iso8601,
      items: @order.items.map do |item|
        {
          id: item.id,
          ticket_type_id: item.ticket_type_id,
          ticket_type_name: item.ticket_type.name,
          quantity: item.quantity,
          unit_price: item.unit_price.to_h
        }
      end,
      payments: @order.payments.map do |payment|
        {
          id: payment.id,
          provider: payment.provider,
          status: payment.status,
          amount: payment.money.to_h,
          created_at: payment.created_at.iso8601
        }
      end,
      created_at: @order.created_at.iso8601
    }
  end
end
