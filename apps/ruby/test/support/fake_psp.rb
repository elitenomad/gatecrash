# A stand-in for the provider. No mocking library: minitest/mock is not
# loadable under Ruby 3.4's bundled-gem rules, and an explicit fake reads
# better than a stubbed global anyway.
class FakePsp
  attr_reader :calls, :statuses, :unpaid
  attr_accessor :on_create, :on_expire # something else happening while the provider answers

  def initialize(session: nil, raise_error: nil)
    @session = session
    @raise_error = raise_error
    @calls = []
    @statuses = {} # session id -> what the provider would say it is
    @unpaid = Set.new # completed sessions whose money has not arrived: a delayed method
  end

  def create_checkout_session(order:, success_url:, cancel_url:, idempotency_key: nil)
    @calls << { order:, success_url:, cancel_url:, idempotency_key: }
    raise Psp::Error, @raise_error if @raise_error

    on_create&.call

    session = @session || {
      "id" => "cs_test_#{SecureRandom.hex(6)}",
      "url" => "http://psp.test/checkout/cs_test",
      "expires_at" => 30.minutes.from_now.to_i
    }
    @statuses[session["id"]] = "open"
    session
  end

  # As the provider does it: only an open session can be expired, and the
  # refusal does not say why.
  def expire_checkout_session(id)
    raise Psp::TransientError, "503 api_error" if @statuses[id] == :unreachable
    raise Psp::RequestError.new("404 resource_missing", status: 404, code: "resource_missing") unless @statuses.key?(id)

    on_expire&.call
    raise Psp::RequestError, "400: cannot be expired" unless @statuses[id] == "open"

    @statuses[id] = "expired"
    { "id" => id, "status" => "expired" }
  end

  def checkout_session(id)
    status = @statuses.fetch(id)
    paid = status == "complete" && !@unpaid.include?(id)
    { "id" => id, "status" => status, "payment_status" => paid ? "paid" : "unpaid" }
  end
end
