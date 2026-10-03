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
        rescue Psp::RequestError
          case @psp.checkout_session(payment.provider_ref).fetch("status")
          when "complete" then return false
          when "expired"  then nil # it lapsed on its own; record that and go on
          else raise
          end
        end
        payment.update!(status: "cancelled")
      end
      true
    end
  end
end
