class IndexIdempotencyKeysForPruning < ActiveRecord::Migration[8.0]
  def change
    # Two partial indexes, one per question the sweeper asks. Without them the
    # sweeper scans every key ever issued, every time it runs — and this is the
    # one table in the schema whose row count tracks total request volume.
    add_index :idempotency_keys, :updated_at,
      where: "response_status IS NOT NULL",
      name: "index_completed_idempotency_keys_by_age"

    add_index :idempotency_keys, :locked_at,
      where: "response_status IS NULL",
      name: "index_in_flight_idempotency_keys_by_claim"
  end
end
