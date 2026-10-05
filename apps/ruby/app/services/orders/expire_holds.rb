module Orders
  # Returns inventory from holds that lapsed before payment.
  #
  # Inventory that is never released is indistinguishable from a sold-out show,
  # so this runs on a schedule rather than being triggered by traffic.
  class ExpireHolds
    def self.call(...) = new(...).call

    def initialize(now: Time.current, psp: Psp)
      @now = now
      @psp = psp
    end

    def call
      expired = 0
      Order.lapsed(@now).find_each do |order|
        next unless payment_page_closed?(order)

        ActiveRecord::Base.transaction do
          # Waits for any other run holding this row, then re-reads it. The
          # re-read is what makes the release exactly-once: a run that loaded
          # this order before another expired it would otherwise check the copy
          # it loaded, which still says the hold is live.
          order.lock!
          next unless order.hold_expires_at && order.hold_expires_at <= @now
          # A session recorded since the page was closed can still take money.
          # Leave it for the next run, which will close it first.
          next if order.payments.where(status: "requires_payment").exists?
          # The backstop. Every edge out of a holding state clears
          # hold_expires_at, so the check above has already turned a second run
          # away; this refuses it anyway if some future edge forgets to.
          next unless order.try_transition_to!("expired", hold_expires_at: nil)

          # Through lock_for_update, in id order, like every path that locks tiers.
          tiers = TicketType.lock_for_update(order.items.map(&:ticket_type_id))
          order.items.each do |item|
            tt = tiers.fetch(item.ticket_type_id)
            tt.update!(quantity_held: tt.quantity_held - item.quantity)
          end
          expired += 1
        end
      end
      expired
    end

    private

    # Close the payment page before giving the seats back. If the customer paid
    # first, the provider refuses, and the order is theirs: its webhook is on
    # the way. If the provider cannot be reached, the seats stay held too —
    # releasing them is the one step here that cannot be taken back.
    def payment_page_closed?(order)
      Payments::CloseOpenSessions.call(order:, psp: @psp)
    rescue Psp::Error => e
      Rails.logger.warn("kept the hold on order #{order.id}: could not close its session (#{e.message})")
      false
    end
  end
end
