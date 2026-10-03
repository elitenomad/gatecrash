class CreateLedger < ActiveRecord::Migration[8.0]
  def change
    create_table :ledger_transactions, id: :uuid do |t|
      t.string     :kind, null: false
      t.references :order, foreign_key: true, type: :uuid, null: true
      # The provider's id for the fact this row records — a balance transaction
      # id on a provider_fee. Null for facts we originate, such as the sale.
      t.string     :provider_ref
      t.datetime   :occurred_at, null: false
      t.timestamps
    end
    add_check_constraint :ledger_transactions,
      "kind IN ('ticket_sale','provider_fee','payout')", name: "ledger_transactions_kind_valid"

    # One ticket_sale per order, enforced by the database rather than by hoping
    # the webhook only ever fires once.
    add_index :ledger_transactions, :order_id,
      unique: true, where: "kind = 'ticket_sale'",
      name: "index_one_ticket_sale_per_order"

    # One provider_fee per order. This is what makes the reconciler safe to run
    # from two workers at once: the loser gets a constraint violation, not a
    # second fee.
    add_index :ledger_transactions, :order_id,
      unique: true, where: "kind = 'provider_fee'",
      name: "index_one_provider_fee_per_order"
    add_index :ledger_transactions, :provider_ref,
      unique: true, where: "provider_ref IS NOT NULL"

    create_table :ledger_entries, id: :uuid do |t|
      t.references :ledger_transaction, null: false, foreign_key: true, type: :uuid
      t.string :account,  null: false
      t.bigint :amount,   null: false   # signed: debit positive, credit negative
      t.string :currency, null: false, limit: 3
      t.timestamps
    end
    add_check_constraint :ledger_entries,
      "account IN ('psp_balance','bank','ticket_revenue','processing_fees')",
      name: "ledger_entries_account_valid"
  end
end
