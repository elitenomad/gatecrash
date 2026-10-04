module Api
  module Admin
    class LedgerController < ApplicationController
      before_action :authenticate_admin!

      def show
        order = Order.find(params[:order_id])
        transactions = order.ledger_transactions.includes(:entries).order(:occurred_at)

        render json: {
          data: transactions.map do |t|
            {
              id: t.id, kind: t.kind, order_id: t.order_id, provider_ref: t.provider_ref,
              occurred_at: t.occurred_at.iso8601,
              entries: t.entries.map { |e| { account: e.account, amount: money(e.money) } }
            }
          end
        }
      end

      # "Run the reconciler now." The same work runs on a schedule; this is for
      # operators, and for the conformance suite, which cannot wait on a clock.
      # Synchronous on purpose — the answer IS the point of asking.
      def reconcile
        render json: { data: { booked: Ledger::BookFees.call } }
      end

      private

      def authenticate_admin!
        expected = ENV.fetch("ADMIN_TOKEN", "dev-admin-token")
        given = request.headers["Authorization"].to_s.delete_prefix("Bearer ")
        # An empty token would match an empty header, which is no header at all.
        return if expected.present? && ActiveSupport::SecurityUtils.secure_compare(expected, given)

        problem(401, "Unauthorized")
      end
    end
  end
end
