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

  # The length the contract allows. A key of several kilobytes is not a key; it
  # is a request to index something larger than a btree entry can hold.
  KEY_LENGTH = 8..255

  def idempotent
    key = request.headers["Idempotency-Key"].presence
    return problem(422, "Idempotency-Key required",
                   "Every request that creates money-moving state must carry one") if key.nil?
    unless KEY_LENGTH.cover?(key.length)
      return problem(422, "Idempotency-Key invalid",
                     "A key must be #{KEY_LENGTH.min} to #{KEY_LENGTH.max} characters; a UUID is ideal")
    end

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

    # The work and its stored response commit together, or not at all. Stored
    # afterwards, an error between the two would leave an order with no answer
    # on file, and the client's retry would make a second one.
    begin
      ActiveRecord::Base.transaction do
        yield
        record.update!(response_status: response.status,
                       response_body: { "raw" => response.body, "media_type" => response.media_type },
                       locked_at: nil)
      end
    rescue StandardError
      # Nothing was committed, so release the claim: left behind, it would
      # answer 409 to the client's honest retry until the prune clears it.
      record.destroy
      raise
    end
  end

  private

  def replay(record, fingerprint)
    return problem(409, "Request in flight", "Retry shortly") if record.nil?

    unless ActiveSupport::SecurityUtils.secure_compare(record.request_fingerprint, fingerprint)
      return problem(422, "Idempotency key reused",
                     "This key was already used for a different request body")
    end

    return problem(409, "Request in flight", "The original request has not finished") unless record.completed?

    # Byte-for-byte, and with the media type it was first sent with: a stored
    # 422 is a problem document, and a client that branches on the content type
    # must not see it change on the replay.
    render status: record.response_status,
           body: record.response_body.fetch("raw"),
           content_type: record.response_body.fetch("media_type", "application/json")
  end
end
