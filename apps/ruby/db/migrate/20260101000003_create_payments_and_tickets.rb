class CreatePaymentsAndTickets < ActiveRecord::Migration[8.0]
  def change
    # An order has MANY payments, one per provider session. A customer who left
    # the payment page and came back is two payments and one order.
    create_table :payments, id: :uuid do |t|
      t.references :order, null: false, foreign_key: true, type: :uuid
      t.string :provider,     null: false
      t.string :provider_ref, null: false
      t.bigint :amount,       null: false
      t.string :currency,     null: false, limit: 3
      t.string :status,       null: false, default: "requires_payment"
      t.timestamps
    end
    add_index :payments, %i[provider provider_ref], unique: true
    add_check_constraint :payments,
      "status IN ('requires_payment','succeeded','cancelled')",
      name: "payments_status_valid"

    create_table :tickets, id: :uuid do |t|
      t.references :order,       null: false, foreign_key: true, type: :uuid
      t.references :ticket_type, null: false, foreign_key: true, type: :uuid
      t.string   :code,      null: false
      t.datetime :issued_at, null: false
      t.timestamps
    end
    add_index :tickets, :code, unique: true
  end
end
