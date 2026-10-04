# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_01_01_000007) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organiser_id", null: false
    t.string "slug", null: false
    t.string "name", null: false
    t.datetime "starts_at", null: false
    t.string "venue_name", null: false
    t.string "status", default: "draft", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organiser_id"], name: "index_events_on_organiser_id"
    t.index ["slug"], name: "index_events_on_slug", unique: true
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying, 'on_sale'::character varying, 'sold_out'::character varying, 'cancelled'::character varying, 'completed'::character varying]::text[])", name: "events_status_valid"
  end

  create_table "idempotency_keys", primary_key: "key", id: :string, force: :cascade do |t|
    t.string "request_fingerprint", null: false
    t.integer "response_status"
    t.jsonb "response_body"
    t.datetime "locked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["locked_at"], name: "index_in_flight_idempotency_keys_by_claim", where: "(response_status IS NULL)"
    t.index ["updated_at"], name: "index_completed_idempotency_keys_by_age", where: "(response_status IS NOT NULL)"
  end

  create_table "ledger_entries", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "ledger_transaction_id", null: false
    t.string "account", null: false
    t.bigint "amount", null: false
    t.string "currency", limit: 3, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ledger_transaction_id"], name: "index_ledger_entries_on_ledger_transaction_id"
    t.check_constraint "account::text = ANY (ARRAY['psp_balance'::character varying, 'bank'::character varying, 'ticket_revenue'::character varying, 'processing_fees'::character varying]::text[])", name: "ledger_entries_account_valid"
  end

  create_table "ledger_transactions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "kind", null: false
    t.uuid "order_id"
    t.string "provider_ref"
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_ledger_transactions_on_order_id"
    t.index ["order_id"], name: "index_one_provider_fee_per_order", unique: true, where: "((kind)::text = 'provider_fee'::text)"
    t.index ["order_id"], name: "index_one_ticket_sale_per_order", unique: true, where: "((kind)::text = 'ticket_sale'::text)"
    t.index ["provider_ref"], name: "index_ledger_transactions_on_provider_ref", unique: true, where: "(provider_ref IS NOT NULL)"
    t.check_constraint "kind::text = ANY (ARRAY['ticket_sale'::character varying, 'provider_fee'::character varying, 'payout'::character varying]::text[])", name: "ledger_transactions_kind_valid"
  end

  create_table "order_items", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "order_id", null: false
    t.uuid "ticket_type_id", null: false
    t.integer "quantity", null: false
    t.bigint "unit_price_amount", null: false
    t.string "unit_price_currency", limit: 3, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_order_items_on_order_id"
    t.index ["ticket_type_id"], name: "index_order_items_on_ticket_type_id"
    t.check_constraint "quantity > 0", name: "order_items_quantity_positive"
  end

  create_table "orders", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "event_id", null: false
    t.string "email", null: false
    t.string "status", default: "pending", null: false
    t.bigint "total_amount", default: 0, null: false
    t.string "total_currency", limit: 3, null: false
    t.datetime "hold_expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_orders_on_event_id"
    t.index ["hold_expires_at"], name: "index_orders_on_active_holds", where: "((status)::text = ANY ((ARRAY['pending'::character varying, 'awaiting_payment'::character varying])::text[]))"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'awaiting_payment'::character varying, 'paid'::character varying, 'expired'::character varying]::text[])", name: "orders_status_valid"
  end

  create_table "organisers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "email", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "payments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "order_id", null: false
    t.string "provider", null: false
    t.string "provider_ref", null: false
    t.bigint "amount", null: false
    t.string "currency", limit: 3, null: false
    t.string "status", default: "requires_payment", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_one_open_payment_per_order", unique: true, where: "((status)::text = 'requires_payment'::text)"
    t.index ["order_id"], name: "index_payments_on_order_id"
    t.index ["provider", "provider_ref"], name: "index_payments_on_provider_and_provider_ref", unique: true
    t.check_constraint "status::text = ANY (ARRAY['requires_payment'::character varying, 'succeeded'::character varying, 'cancelled'::character varying]::text[])", name: "payments_status_valid"
  end

  create_table "ticket_types", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "event_id", null: false
    t.string "name", null: false
    t.bigint "price_amount", null: false
    t.string "price_currency", limit: 3, null: false
    t.integer "quantity_total", default: 0, null: false
    t.integer "quantity_held", default: 0, null: false
    t.integer "quantity_sold", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_ticket_types_on_event_id"
    t.check_constraint "price_amount >= 0", name: "ticket_types_price_non_negative"
    t.check_constraint "quantity_held >= 0 AND quantity_sold >= 0 AND (quantity_held + quantity_sold) <= quantity_total", name: "ticket_types_inventory_within_capacity"
  end

  create_table "tickets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "order_id", null: false
    t.uuid "ticket_type_id", null: false
    t.string "code", null: false
    t.datetime "issued_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_tickets_on_code", unique: true
    t.index ["order_id"], name: "index_tickets_on_order_id"
    t.index ["ticket_type_id"], name: "index_tickets_on_ticket_type_id"
  end

  create_table "webhook_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "provider", null: false
    t.string "provider_event_id", null: false
    t.string "event_type", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "received_at", null: false
    t.datetime "processed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["provider", "provider_event_id"], name: "index_webhook_events_on_provider_and_provider_event_id", unique: true
  end

  add_foreign_key "events", "organisers"
  add_foreign_key "ledger_entries", "ledger_transactions"
  add_foreign_key "ledger_transactions", "orders"
  add_foreign_key "order_items", "orders"
  add_foreign_key "order_items", "ticket_types"
  add_foreign_key "orders", "events"
  add_foreign_key "payments", "orders"
  add_foreign_key "ticket_types", "events"
  add_foreign_key "tickets", "orders"
  add_foreign_key "tickets", "ticket_types"
end
