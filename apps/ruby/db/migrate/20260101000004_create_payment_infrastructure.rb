class CreatePaymentInfrastructure < ActiveRecord::Migration[8.0]
  def change
    # Deliberately no foreign key into orders. A webhook must be recordable
    # before we know whether the thing it references exists or is even valid.
    create_table :webhook_events, id: :uuid do |t|
      t.string   :provider,          null: false
      t.string   :provider_event_id, null: false
      t.string   :event_type,        null: false
      t.jsonb    :payload,           null: false, default: {}
      t.datetime :received_at,       null: false
      t.datetime :processed_at
      t.timestamps
    end

    # This index IS the replay guard. Deduplication is an insert that either
    # succeeds or violates a constraint — never a SELECT followed by an INSERT,
    # which races under concurrent redelivery.
    add_index :webhook_events, %i[provider provider_event_id], unique: true

    create_table :idempotency_keys, primary_key: :key, id: :string do |t|
      t.string   :request_fingerprint, null: false
      t.integer  :response_status
      t.jsonb    :response_body
      t.datetime :locked_at
      t.timestamps
    end
  end
end
