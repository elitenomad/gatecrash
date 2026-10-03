require "test_helper"
require "socket"

class PspTransportTest < ActiveSupport::TestCase
  # A real socket on a real port. Net::HTTP is the thing under test here, so
  # stubbing it out would leave the retry policy — the whole subject of chapter
  # 6 — unexercised. Twenty lines of server is cheaper than a mocking library.
  class StubProvider
    Recorded = Struct.new(:verb, :path, :headers, :body)

    attr_reader :received

    def initialize(&responder)
      @responder = responder
      @received = []
      @server = TCPServer.new("127.0.0.1", 0)
      @thread = Thread.new { accept_loop }
    end

    def url = "http://127.0.0.1:#{@server.addr[1]}"

    def close
      @server.close unless @server.closed?
      @thread.join(1)
    end

    private

    def accept_loop
      loop { respond(@server.accept) }
    rescue IOError, Errno::EBADF, Errno::EINVAL
      nil # the test finished and closed the server
    end

    def respond(socket)
      verb, path, = socket.gets.to_s.split(" ")
      headers = {}
      while (line = socket.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.to_s.downcase] = value.to_s.strip
      end
      length = headers["content-length"].to_i
      @received << Recorded.new(verb, path, headers, length.positive? ? socket.read(length) : nil)

      status, extra, body = @responder.call(@received.size)
      socket.write("HTTP/1.1 #{status} Status\r\n")
      extra.each { |key, value| socket.write("#{key}: #{value}\r\n") }
      socket.write("Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    ensure
      socket.close
    end
  end

  SESSION = '{"id":"cs_test_1","url":"http://psp.test/pay","expires_at":1800}'.freeze

  setup do
    @env = ENV.to_h.slice("PSP_URL", "PSP_RETRY_BASE_DELAY")
    ENV["PSP_RETRY_BASE_DELAY"] = "0" # the policy is under test, not the clock
  end

  teardown do
    @provider&.close
    ENV["PSP_URL"] = @env["PSP_URL"]
    ENV["PSP_RETRY_BASE_DELAY"] = @env["PSP_RETRY_BASE_DELAY"]
  end

  def provider(&responder)
    @provider = StubProvider.new(&responder)
    ENV["PSP_URL"] = @provider.url
    @provider
  end

  test "a 5xx is retried, and the retry is believed" do
    stub = provider { |n| n == 1 ? [503, {}, "{}"] : [200, {}, '{"fee":88}'] }

    assert_equal({ "fee" => 88 }, Psp.checkout_session("cs_1"))
    assert_equal 2, stub.received.size
  end

  test "a 4xx is a decision rather than a hiccup, and is never retried" do
    body = '{"error":{"code":"parameter_invalid_empty","message":"line_items must not be empty"}}'
    stub = provider { [400, {}, body] }

    error = assert_raises(Psp::RequestError) { Psp.checkout_session("cs_1") }

    assert_equal 1, stub.received.size, "sending a rejected request again only wastes everyone's time"
    assert_equal 400, error.status
    assert_equal "parameter_invalid_empty", error.code
    assert_match "line_items must not be empty", error.message
  end

  test "a 429 waits as long as the provider asked before trying again" do
    stub = provider { |n| n == 1 ? [429, { "Retry-After" => "0" }, "{}"] : [200, {}, "{}"] }

    assert_equal({}, Psp.checkout_session("cs_1"))
    assert_equal 2, stub.received.size
  end

  test "a Retry-After longer than a request can afford ends the attempt immediately" do
    stub = provider { [429, { "Retry-After" => "60" }, "{}"] }

    error = assert_raises(Psp::TransientError) { Psp.checkout_session("cs_1") }

    assert_equal 1, stub.received.size, "sleeping a minute inside a web request is a queue with no name"
    assert_equal "60", error.retry_after
  end

  test "gives up after MAX_ATTEMPTS instead of hammering a provider that is down" do
    stub = provider { [502, {}, "{}"] }

    assert_raises(Psp::TransientError) { Psp.checkout_session("cs_1") }
    assert_equal Psp::MAX_ATTEMPTS, stub.received.size
  end

  test "a refused connection is transient" do
    ENV["PSP_URL"] = "http://127.0.0.1:1" # nothing is listening here

    assert_raises(Psp::TransientError) { Psp.checkout_session("cs_1") }
  end

  test "every POST carries an idempotency key, and a retry reuses it" do
    order = place_order
    stub = provider { |n| n == 1 ? [500, {}, "{}"] : [200, {}, SESSION] }

    Psp.create_checkout_session(order:, success_url: "https://x.test/ok", cancel_url: "https://x.test/no")

    keys = stub.received.map { |r| r.headers["idempotency-key"] }
    assert_equal 2, keys.size
    assert_predicate keys.first, :present?
    assert_equal keys.first, keys.last,
                 "a retry carrying a fresh key is a second charge waiting to happen"
  end

  test "authenticates every request as a bearer token" do
    stub = provider { [200, {}, "{}"] }

    Psp.checkout_session("cs_1")

    assert_equal "Bearer #{Psp.secret_key}", stub.received.sole.headers["authorization"]
  end

  test "money crosses the wire in minor units, with the currency lowercased" do
    order = place_order(ticket_type: build_ticket_type(amount: 4000, currency: "JPY"))
    stub = provider { [200, {}, SESSION] }

    Psp.create_checkout_session(order:, success_url: "https://x.test/ok", cancel_url: "https://x.test/no")

    form = URI.decode_www_form(stub.received.sole.body).to_h
    assert_equal "4000", form["line_items[0][price_data][unit_amount]"], "no /100 anywhere"
    assert_equal "jpy", form["line_items[0][price_data][currency]"]
    assert_equal order.id, form["client_reference_id"], "the thread that leads the webhook home"
  end

  test "every session is opened for cards only" do
    stub = provider { [200, {}, SESSION] }

    Psp.create_checkout_session(order: place_order, success_url: "https://x.test/ok", cancel_url: "https://x.test/no")

    form = URI.decode_www_form(stub.received.sole.body).to_h
    assert_equal "card", form["allowed_payment_method_types[0]"]
    assert_nil form["allowed_payment_method_types[1]"],
               "left to the dashboard, a bank debit can confirm after the hold has lapsed"
    assert_nil form["payment_method_types[0]"], "removed in 2026-09-30.endive: sending it is a 400"
  end

  test "every request names the API version it was written against" do
    stub = provider { [200, {}, SESSION] }

    Psp.checkout_session("cs_1")
    Psp.create_checkout_session(order: place_order, success_url: "https://x.test/ok", cancel_url: "https://x.test/no")

    assert_equal [Psp::API_VERSION] * 2, stub.received.map { |r| r.headers["stripe-version"] }
  end

  test "a 409 — the same key still in flight — is retried with the same key" do
    stub = provider { |n| n == 1 ? [409, {}, '{"error":{"type":"idempotency_error"}}'] : [200, {}, SESSION] }

    Psp.create_checkout_session(order: place_order, success_url: "https://x.test/ok", cancel_url: "https://x.test/no")

    keys = stub.received.map { |r| r.headers["idempotency-key"] }
    assert_equal 2, keys.size
    assert_equal keys.first, keys.last
  end

  test "Stripe-Should-Retry: false is believed over a status that looks retryable" do
    # A 500 on a POST is stored under its key; retrying with that key only
    # replays it, and the provider says so.
    stub = provider { [500, { "Stripe-Should-Retry" => "false" }, "{}"] }

    assert_raises(Psp::RequestError) { Psp.checkout_session("cs_1") }
    assert_equal 1, stub.received.size
  end

  test "Stripe-Should-Retry: true is believed over a status that looks final" do
    stub = provider { |n| n == 1 ? [400, { "Stripe-Should-Retry" => "true" }, "{}"] : [200, {}, SESSION] }

    assert_equal "cs_test_1", Psp.checkout_session("cs_1")["id"]
    assert_equal 2, stub.received.size
  end

  test "ISK and UGX cross the wire in hundredths, as Stripe still wants them" do
    stub = provider { [200, {}, SESSION] }
    order = place_order(ticket_type: build_ticket_type(amount: 5000, currency: "ISK"))

    Psp.create_checkout_session(order:, success_url: "https://x.test/ok", cancel_url: "https://x.test/no")

    form = URI.decode_www_form(stub.received.sole.body).to_h
    assert_equal "500000", form["line_items[0][price_data][unit_amount]"]
    assert_equal Money.new(5000, "ISK"), Psp.money_from_provider(500_000, "isk")
    assert_equal Money.new(4000, "JPY"), Psp.money_from_provider(4000, "jpy"), "everyone else is ISO"
    assert_raises(Psp::Error) { Psp.money_from_provider(500_050, "isk") }
  end

  test "the fee is read through the expanded path, and null means not yet" do
    bt = { id: "txn_1", fee: 88, currency: "gbp", created: 1_800_000_000 }
    session = ->(fee) { { id: "cs_1", payment_intent: { latest_charge: { balance_transaction: fee } } }.to_json }
    stub = provider { |n| [200, {}, session.call(n == 1 ? nil : bt)] }
    payment = Struct.new(:provider_ref).new("cs_1")

    assert_nil Ledger::BookFees::DEFAULT_FEE_READER.call(payment), "paid, fee not reported yet"
    fee = Ledger::BookFees::DEFAULT_FEE_READER.call(payment)

    assert_equal "/v1/checkout/sessions/cs_1?expand%5B%5D=payment_intent.latest_charge.balance_transaction",
                 stub.received.last.path
    assert_equal({ ref: "txn_1", fee: Money.new(88, "GBP"), occurred_at: Time.zone.at(1_800_000_000) }, fee)
  end

  test "expiring a session is a POST to its expire path, with an idempotency key" do
    stub = provider { [200, {}, SESSION] }

    Psp.expire_checkout_session("cs_test_old")

    request = stub.received.sole
    assert_equal "/v1/checkout/sessions/cs_test_old/expire", request.path
    assert_predicate request.headers["idempotency-key"], :present?
  end

  test "a refused expiry is a RequestError — a decision, not a blip" do
    provider { [400, {}, { error: { type: "invalid_request_error", message: "nope" } }.to_json] }

    assert_raises(Psp::RequestError) { Psp.expire_checkout_session("cs_test_done") }
  end

  test "a success body that is not JSON is an error, not a silent nil" do
    provider { [200, {}, "<html>maintenance</html>"] }

    error = assert_raises(Psp::Error) { Psp.checkout_session("cs_1") }
    assert_match "unparseable", error.message
  end
end
