require "test_helper"

module Payments
  # Two deliveries of one payment, fulfilled at once on two connections.
  #
  # Every other test runs inside one transaction on one connection, where a row
  # lock can never be contended and two "concurrent" calls simply take turns.
  # This one turns that off, so it commits for real and cleans up after itself.
  class FulfilConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    setup do
      @tt = build_ticket_type(total: 10)
      @order = place_order(ticket_type: @tt, quantity: 3)
      @order.transition_to!("awaiting_payment")
      @payment = build_payment(order: @order)
    end

    teardown do
      event = @tt.event
      LedgerEntry.where(ledger_transaction_id: LedgerTransaction.where(order_id: @order.id).select(:id)).delete_all
      LedgerTransaction.where(order_id: @order.id).delete_all
      Ticket.where(order_id: @order.id).delete_all
      Payment.where(order_id: @order.id).delete_all
      OrderItem.where(order_id: @order.id).delete_all
      Order.where(id: @order.id).delete_all
      TicketType.where(id: @tt.id).delete_all
      Event.where(id: event.id).delete_all
      Organiser.where(id: event.organiser_id).delete_all
    end

    test "two deliveries at once issue one set of tickets, and the second says so" do
      # Each delivery re-reads the payment once it holds the order's lock. The
      # first to get there waits, up to half a second, for the other to read
      # it too. Without the lock both read "not yet succeeded", both go on, and
      # the second fails trying to sell seats that are already sold. With it the
      # second cannot read until the first has committed: the wait runs out,
      # and the second finds the payment already succeeded.
      reads = Queue.new
      count = 0
      gate = Mutex.new
      watch = lambda do |*, payload|
        next unless Thread.current[:racing] && payload[:sql].match?(/FROM "payments" WHERE "payments"."id" =/)

        first = gate.synchronize { (count += 1) == 1 }
        first ? reads.pop(timeout: 0.5) : reads << :read
      end

      session = { "id" => @payment.provider_ref, "payment_status" => "paid" }
      outcomes = ActiveSupport::Notifications.subscribed(watch, "sql.active_record") do
        Array.new(2) do
          Thread.new do
            Thread.current[:racing] = true
            ActiveRecord::Base.connection_pool.with_connection { Fulfil.call(session:) }
          rescue StandardError => e
            e
          end
        end.map(&:value)
      end

      assert_equal %i[already_fulfilled fulfilled], outcomes.sort_by(&:to_s), outcomes.inspect
      assert_equal 3, @order.tickets.count
      assert_equal 3, @tt.reload.quantity_sold
      assert_equal 0, @tt.quantity_held
    end
  end
end
