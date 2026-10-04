require "test_helper"

class OrdersTest < ActionDispatch::IntegrationTest
  setup { @tt = build_ticket_type(total: 10) }

  def payload(quantity: 1)
    { event_id: @tt.event_id, email: "buyer@example.test",
      items: [{ ticket_type_id: @tt.id, quantity: }] }
  end

  def create_order(body = payload, key: SecureRandom.uuid)
    post "/api/orders", params: JSON.generate(body),
         headers: { "Idempotency-Key" => key, "CONTENT_TYPE" => "application/json" }
  end

  test "creates an order and returns money as minor units plus currency" do
    create_order
    assert_response :created
    total = response.parsed_body["total"]
    assert_equal({ "amount" => 4500, "currency" => "GBP" }, total)
    assert_kind_of Integer, total["amount"]
  end

  test "requires an Idempotency-Key" do
    post "/api/orders", params: JSON.generate(payload),
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :unprocessable_content
    assert_equal "application/problem+json", response.media_type
  end

  test "replays a repeated key byte for byte" do
    key = SecureRandom.uuid
    create_order(key: key)
    first_status, first_body = response.status, response.body

    create_order(key: key)
    assert_equal first_status, response.status
    assert_equal first_body, response.body, "replay must be byte-identical, not re-rendered"
    assert_equal 1, Order.count
  end

  test "rejects the same key with a different body and leaves the original intact" do
    key = SecureRandom.uuid
    create_order(payload(quantity: 1), key: key)
    original = response.parsed_body["id"]

    create_order(payload(quantity: 5), key: key)
    assert_response :unprocessable_content
    assert_equal 1, Order.find(original).items.first.quantity
    assert_equal 1, Order.count
  end

  test "errors are RFC 9457 problem documents" do
    create_order(payload(quantity: 999))
    assert_response :unprocessable_content
    assert_equal "application/problem+json", response.media_type
    problem = response.parsed_body
    assert problem["type"].start_with?("https://")
    assert_equal 422, problem["status"]
    assert problem["title"].present?
  end

  test "a failed create does not leave the key claimed" do
    # Otherwise a transient failure poisons that key with a permanent 409.
    key = SecureRandom.uuid
    create_order(payload(quantity: 999), key: key)
    assert_response :unprocessable_content

    # The stored 422 replays; the key is answered, not stuck in flight.
    create_order(payload(quantity: 999), key: key)
    assert_response :unprocessable_content
  end

  test "tickets are 409 until the order is paid" do
    create_order
    id = response.parsed_body["id"]
    get "/api/orders/#{id}/tickets"
    assert_response :conflict
  end

  test "unknown order is 404" do
    get "/api/orders/#{SecureRandom.uuid}"
    assert_response :not_found
  end

  test "admin ledger requires the bearer token" do
    create_order
    id = response.parsed_body["id"]
    get "/api/admin/orders/#{id}/ledger"
    assert_response :unauthorized

    get "/api/admin/orders/#{id}/ledger",
        headers: { "Authorization" => "Bearer #{ENV.fetch('ADMIN_TOKEN', 'dev-admin-token')}" }
    assert_response :success
  end

  test "an empty admin token lets nobody in" do
    # secure_compare("", "") is true, and an empty header is what no header is.
    original = ENV["ADMIN_TOKEN"]
    ENV["ADMIN_TOKEN"] = ""
    post "/api/admin/ledger/reconcile"
    assert_response :unauthorized
  ensure
    ENV["ADMIN_TOKEN"] = original
  end

  test "admin reconcile requires the bearer token and reports what it booked" do
    post "/api/admin/ledger/reconcile"
    assert_response :unauthorized

    post "/api/admin/ledger/reconcile",
         headers: { "Authorization" => "Bearer #{ENV.fetch('ADMIN_TOKEN', 'dev-admin-token')}" }
    assert_response :success
    assert_equal({ "data" => { "booked" => 0 } }, response.parsed_body)
  end
end
