class BookFeesJob < ApplicationJob
  queue_as :default

  def perform
    Ledger::BookFees.call
  end
end
