class ExpireHoldsJob < ApplicationJob
  queue_as :default

  def perform
    count = Orders::ExpireHolds.call
    Rails.logger.info("expired #{count} lapsed holds") if count.positive?
  end
end
