class CreateCatalogue < ActiveRecord::Migration[8.0]
  def change
    create_table :organisers, id: :uuid do |t|
      t.string :name,  null: false
      t.string :email, null: false
      t.timestamps
    end

    create_table :events, id: :uuid do |t|
      t.references :organiser, null: false, foreign_key: true, type: :uuid
      t.string   :slug,       null: false, index: { unique: true }
      t.string   :name,       null: false
      t.datetime :starts_at,  null: false
      t.string   :venue_name, null: false
      t.string   :status,     null: false, default: "draft"
      t.timestamps
    end
    add_check_constraint :events,
      "status IN ('draft','on_sale','sold_out','cancelled','completed')",
      name: "events_status_valid"

    create_table :ticket_types, id: :uuid do |t|
      t.references :event, null: false, foreign_key: true, type: :uuid
      t.string  :name,           null: false
      t.bigint  :price_amount,   null: false
      t.string  :price_currency, null: false, limit: 3
      t.integer :quantity_total, null: false, default: 0
      t.integer :quantity_held,  null: false, default: 0
      t.integer :quantity_sold,  null: false, default: 0
      t.timestamps
    end

    # The last line of defence against overselling.
    #
    # Application code holds a row lock before checking availability, and that is
    # what the book teaches. But locks are easy to lose in a refactor, and a
    # constraint is not. If the application logic is ever wrong, the transaction
    # dies here instead of selling a seat that does not exist.
    add_check_constraint :ticket_types,
      "quantity_held >= 0 AND quantity_sold >= 0 AND quantity_held + quantity_sold <= quantity_total",
      name: "ticket_types_inventory_within_capacity"
    add_check_constraint :ticket_types, "price_amount >= 0", name: "ticket_types_price_non_negative"
  end
end
