module IdempotencyKeys
  # Keys are a cache, not a ledger. They answer "have I already done this?" for
  # as long as a client might sensibly ask, and then they are rubbish.
  #
  # Two different things get deleted here, for two different reasons.
  class Prune
    # How long a client can still replay a finished request. Providers commonly
    # publish 24 hours; past that a repeat key is treated as a new request.
    RETENTION = Integer(ENV.fetch("IDEMPOTENCY_RETENTION_SECONDS", 86_400)).seconds

    # A claim with no response, held longer than any request could legitimately
    # take, is a process that died mid-flight. Left alone it answers 409 to that
    # key forever, and the client's honest retry can never succeed.
    ABANDONED_AFTER = Integer(ENV.fetch("IDEMPOTENCY_LOCK_TTL_SECONDS", 300)).seconds

    def self.call(...) = new(...).call

    def initialize(now: Time.current)
      @now = now
    end

    def call
      { expired: delete_finished, abandoned: delete_abandoned }
    end

    private

    def delete_finished
      IdempotencyKey.completed.where(updated_at: ...@now - RETENTION).delete_all
    end

    def delete_abandoned
      IdempotencyKey.in_flight.where(locked_at: ...@now - ABANDONED_AFTER).delete_all
    end
  end
end
