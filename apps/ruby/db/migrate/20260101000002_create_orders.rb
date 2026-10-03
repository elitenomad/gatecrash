class CreateOrders < ActiveRecord::Migration[8.0]
  def change
    create_table :orders, id: :uuid do |t|
      t.references :event, null: false, foreign_key: true, type: :uuid
      t.string   :email,           null: false
      t.string   :status,          null: false, default: "pending"
      t.bigint   :total_amount,    null: false, default: 0
      t.string   :total_currency,  null: false, limit: 3
      t.datetime :hold_expires_at
      t.timestamps
    end
    add_check_constraint :orders,
      "status IN ('pending','awaiting_payment','paid','expired')",
      name: "orders_status_valid"

    # The sweeper scans exactly this predicate every minute; without the partial
    # index it degrades into a sequential scan over every order ever placed.
    add_index :orders, :hold_expires_at,
      where: "status IN ('pending','awaiting_payment')",
      name: "index_orders_on_active_holds"

    create_table :order_items, id: :uuid do |t|
      t.references :order,       null: false, foreign_key: true, type: :uuid
      t.references :ticket_type, null: false, foreign_key: true, type: :uuid
      t.integer :quantity, null: false

      # Copied at order time, never joined live from ticket_types. What the
      # customer paid must not move when the organiser edits a price tomorrow.
      t.bigint  :unit_price_amount,   null: false
      t.string  :unit_price_currency, null: false, limit: 3
      t.timestamps
    end
    add_check_constraint :order_items, "quantity > 0", name: "order_items_quantity_positive"
  end
end
