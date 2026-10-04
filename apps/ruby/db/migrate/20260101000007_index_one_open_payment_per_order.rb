class IndexOneOpenPaymentPerOrder < ActiveRecord::Migration[8.0]
  def change
    # One page that can take the customer's money per order. StartCheckout
    # re-checks this under the order lock; the index is what still holds if
    # that check is ever lost, the way the inventory check constraint backs up
    # the row lock.
    add_index :payments, :order_id,
      unique: true,
      where: "status = 'requires_payment'",
      name: "index_one_open_payment_per_order"
  end
end
