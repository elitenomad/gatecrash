class PruneIdempotencyKeysJob < ApplicationJob
  queue_as :default

  def perform
    result = IdempotencyKeys::Prune.call
    return unless result.values.sum.positive?

    Rails.logger.info("pruned idempotency keys: #{result[:expired]} expired, " \
                      "#{result[:abandoned]} abandoned")
  end
end
