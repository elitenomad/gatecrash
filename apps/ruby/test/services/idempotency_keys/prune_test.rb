require "test_helper"

module IdempotencyKeys
  class PruneTest < ActiveSupport::TestCase
    def finished(key, age:)
      record = IdempotencyKey.create!(key:, request_fingerprint: "f",
                                      response_status: 201, response_body: { "raw" => "{}" })
      record.update_column(:updated_at, age.ago)
      record
    end

    def claimed(key, age:)
      IdempotencyKey.create!(key:, request_fingerprint: "f", locked_at: age.ago)
    end

    test "deletes finished keys past the retention window" do
      finished("old", age: 25.hours)
      finished("fresh", age: 1.hour)

      assert_equal 1, Prune.call[:expired]
      assert_equal %w[fresh], IdempotencyKey.pluck(:key)
    end

    test "keeps a finished key for as long as a client might still replay it" do
      # Deleting early turns a legitimate replay into a second order.
      finished("recent", age: Prune::RETENTION - 1.minute)

      assert_equal 0, Prune.call[:expired]
      assert_equal 1, IdempotencyKey.count
    end

    test "deletes claims abandoned by a process that died mid-request" do
      # Nothing will ever write a response for this one, and until it goes the
      # client's honest retry gets 409 forever.
      claimed("crashed", age: 10.minutes)

      assert_equal 1, Prune.call[:abandoned]
      assert_empty IdempotencyKey.all
    end

    test "never steals a key from a request that is merely slow" do
      claimed("in-flight", age: 5.seconds)

      assert_equal 0, Prune.call[:abandoned]
      assert_equal 1, IdempotencyKey.count
    end

    test "leaves a finished key alone however old its claim was" do
      # locked_at is cleared on completion, so a slow-but-successful request
      # must not be swept by the abandoned-claim rule.
      record = finished("slow-success", age: 1.minute)
      record.update_column(:locked_at, 2.hours.ago)

      assert_equal({ expired: 0, abandoned: 0 }, Prune.call)
      assert_equal 1, IdempotencyKey.count
    end

    test "reports what it removed" do
      finished("gone", age: 2.days)
      claimed("dead", age: 1.hour)

      assert_equal({ expired: 1, abandoned: 1 }, Prune.call)
    end
  end
end
