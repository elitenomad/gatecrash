module Payments
  # Everything that happens because money actually arrived.
  #
  # Runs in a background job, triggered only by a verified webhook. Idempotent
  # end to end: the guard clauses and unique indexes mean running it twice is a
  # no-op rather than a second set of tickets.
  class Fulfil
    def self.call(...) = new(...).call

    def initialize(session:)
      @session = session
    end

    def call
      payment = Payment.find_by(provider: "stripe", provider_ref: @session["id"])
      return :unknown_payment if payment.nil?
      return :already_fulfilled if payment.succeeded?

      # Completed is not paid. For a card the two arrive together; for a bank
      # debit, `completed` means the customer authorised it and the money
      # follows days later, or never. Volume 1 takes cards only and says so on
      # every session — this is what keeps tickets from being issued if a
      # delayed method gets through anyway.
      unless @session["payment_status"] == "paid"
        Rails.logger.error("UNPAID COMPLETION: session #{@session['id']} completed with " \
                           "payment_status=#{@session['payment_status'].inspect}; nothing issued")
        return :not_paid
      end

      order = payment.order
      outcome = nil
      ActiveRecord::Base.transaction do
        # Lock the order so a redelivery arriving concurrently blocks here
        # rather than racing us to issue a second batch of tickets.
        order.lock!

        # The guard is on the PAYMENT, not the order. The two differ in exactly
        # one case — a second session completing for an order the first one
        # already paid — and that is the case where asking the order hides
        # the money.
        if payment.reload.succeeded?
          outcome = :already_fulfilled
        else
          # The provider says this money arrived, and that is true whether or
          # not we can deliver against it. Note there is no early `return` in
          # this block: Rails 7.0 rolled a transaction back on `return` and 8.0
          # commits it, and the record of a payment must not depend on which
          # version is installed.
          payment.update!(status: "succeeded")

          if order.paid?
            # Paid twice: a second session completed for an order another one
            # already paid. Nothing more to issue; this payment is owed back.
            Rails.logger.error("DUPLICATE PAYMENT: payment #{payment.id} succeeded but order " \
                               "#{order.id} was already paid; owed a refund")
            outcome = :duplicate_payment
          elsif order.try_transition_to!("paid", hold_expires_at: nil)
            issue_tickets(order)
            # Same transaction as `paid`: there is no moment at which the order
            # is paid and the sale is not on the books.
            Ledger::RecordSale.call(order:)
            outcome = :fulfilled
          else
            # Money has arrived and we cannot deliver against it: the hold
            # lapsed first. Like paying twice, it is an outcome nobody may
            # learn about from a customer email.
            Rails.logger.error("UNFULFILLABLE: payment #{payment.id} succeeded but order " \
                               "#{order.id} is #{order.status}; owed tickets or a refund")
            outcome = :not_fulfillable
          end
        end
      end

      outcome
    end

    private

    def issue_tickets(order)
      # Every tier at once, in id order, as Orders::Create takes them. Locking
      # item by item takes them in whatever order the customer listed them, and
      # two orders listing the same pair of tiers the other way round deadlock.
      tiers = TicketType.lock_for_update(order.items.map(&:ticket_type_id))
      order.items.each do |item|
        tt = tiers.fetch(item.ticket_type_id)
        tt.update!(quantity_held: tt.quantity_held - item.quantity,
                   quantity_sold: tt.quantity_sold + item.quantity)

        item.quantity.times do
          order.tickets.create!(ticket_type: tt, code: Ticket.generate_code, issued_at: Time.current)
        end
      end
    end
  end
end
