module Payments
  # No page that can take a customer's money may outlive the seats it is
  # selling. Two callers enforce that: StartCheckout before it opens another
  # session, and Orders::ExpireHolds before it gives the seats back.
  #
  # The provider is the lock. It expires a session only while it is open, so
  # either this lands first and that page can no longer take money, or the
  # customer's payment did and the expiry is refused. A refusal is re-read
  # rather than parsed — the error's wording is not a contract; the session's
  # status is.
  class CloseOpenSessions
    def self.call(...) = new(...).call

    def initialize(order:, psp: Psp)
      @order = order
      @psp = psp
    end

    # True once nothing on the order can take money. False if a session has
    # already been paid — its webhook is on the way, and the order is the
    # customer's. Raises Psp::Error if the provider cannot say either way.
    def call
      @order.payments.where(status: "requires_payment").each do |payment|
        begin
          @psp.expire_checkout_session(payment.provider_ref)
        rescue Psp::RequestError => e
          if e.status == 404
            # The provider has never heard of it — a test provider restarted,
            # or keys from another account. A page that does not exist cannot
            # take money, and keeping the seats for it would keep them forever.
            Rails.logger.warn("session #{payment.provider_ref} is unknown to the provider; treating it as closed")
          else
            session = @psp.checkout_session(payment.provider_ref)
            case session.fetch("status")
            when "complete"
              warn_if_unpaid(session)
              return false
            when "expired" then nil # it lapsed on its own; record that and go on
            else raise
            end
          end
        end
        payment.update!(status: "cancelled")
      end
      true
    end

    private

    # Completed is not paid. Only a delayed payment method completes unpaid,
    # and the cards-only pin should make that impossible; if one gets through,
    # these seats stay held until someone looks, so make sure someone does.
    def warn_if_unpaid(session)
      return if session["payment_status"] == "paid"

      Rails.logger.error("UNPAID COMPLETION: session #{session['id']} on order #{@order.id} is complete " \
                         "with payment_status=#{session['payment_status'].inspect}; its seats stay held")
    end
  end
end
