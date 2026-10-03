# Idempotency for our own API.
#
# The contract:
#   - unseen key                  -> process, store the rendered bytes
#   - same key, same fingerprint  -> replay those bytes verbatim
#   - same key, different body    -> 422, loudly. Reusing a key for a different
#                                    request is a client bug; silently serving
#                                    the old response hides it.
#   - same key, still in flight   -> 409
module Idempotent
  extend ActiveSupport::Concern

  def idempotent
    key = request.headers["Idempotency-Key"].presence
    return problem(422, "Idempotency-Key required",
                   "Every request that creates money-moving state must carry one") if key.nil?

    fingerprint = IdempotencyKey.fingerprint(request.method, request.path, request.raw_post)

    # Claim the key by INSERT, not by SELECT-then-INSERT. The unique primary key
    # is what makes concurrent replays safe: exactly one request wins the insert,
    # every other one takes the RecordNotUnique branch. A read-then-write check
    # passes every hand test and duplicates orders under real concurrency.
    record = begin
      IdempotencyKey.create!(key:, request_fingerprint: fingerprint, locked_at: Time.current)
    rescue ActiveRecord::RecordNotUnique
      return replay(IdempotencyKey.find_by(key:), fingerprint)
    end

    begin
      yield
    rescue StandardError
      # Never leave a claimed-but-unanswered key behind: it would 409 forever.
      record.destroy
      raise
    end

    record.update!(response_status: response.status,
                   response_body: { "raw" => response.body },
                   locked_at: nil)
  end

  private

  def replay(record, fingerprint)
    return problem(409, "Request in flight", "Retry shortly") if record.nil?

    unless ActiveSupport::SecurityUtils.secure_compare(record.request_fingerprint, fingerprint)
      return problem(422, "Idempotency key reused",
                     "This key was already used for a different request body")
    end

    return problem(409, "Request in flight", "The original request has not finished") unless record.completed?

    # Byte-for-byte. Re-serialising the order is not enough — timestamps and
    # association ordering drift, and clients diff these responses.
    render status: record.response_status,
           body: record.response_body.fetch("raw"),
           content_type: "application/json"
  end
end
