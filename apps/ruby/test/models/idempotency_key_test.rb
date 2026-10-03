require "test_helper"

class IdempotencyKeyTest < ActiveSupport::TestCase
  test "fingerprint is stable for identical requests" do
    a = IdempotencyKey.fingerprint("POST", "/api/orders", '{"a":1}')
    b = IdempotencyKey.fingerprint("POST", "/api/orders", '{"a":1}')
    assert_equal a, b
  end

  test "fingerprint changes with body, path or method" do
    base = IdempotencyKey.fingerprint("POST", "/api/orders", '{"a":1}')
    assert_not_equal base, IdempotencyKey.fingerprint("POST", "/api/orders", '{"a":2}')
    assert_not_equal base, IdempotencyKey.fingerprint("POST", "/api/other", '{"a":1}')
    assert_not_equal base, IdempotencyKey.fingerprint("PUT",  "/api/orders", '{"a":1}')
  end

  test "completed? reflects whether a response was stored" do
    key = IdempotencyKey.create!(key: "k1", request_fingerprint: "f", locked_at: Time.current)
    assert_not_predicate key, :completed?
    key.update!(response_status: 201, response_body: { "raw" => "{}" })
    assert_predicate key, :completed?
  end

  test "the key is the primary key, so claiming twice is a constraint violation" do
    IdempotencyKey.create!(key: "k2", request_fingerprint: "f")
    assert_raises(ActiveRecord::RecordNotUnique) do
      IdempotencyKey.create!(key: "k2", request_fingerprint: "f")
    end
  end
end
