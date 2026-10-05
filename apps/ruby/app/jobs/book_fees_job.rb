class BookFeesJob < ApplicationJob
  queue_as :default

  # As ExpireHoldsJob: overlapping runs only queue more provider calls.
  limits_concurrency key: "book_fees", duration: 15.minutes, on_conflict: :discard

  def perform
    Ledger::BookFees.call
  end
end
