class ExpireHoldsJob < ApplicationJob
  queue_as :default

  # One sweep at a time. While the provider is slow, a run can outlast its
  # schedule; without this the next ones pile up behind it and take every
  # worker thread from the webhook jobs. A run that finds one going is dropped.
  limits_concurrency key: "expire_holds", duration: 15.minutes, on_conflict: :discard

  def perform
    count = Orders::ExpireHolds.call
    Rails.logger.info("expired #{count} lapsed holds") if count.positive?
  end
end
