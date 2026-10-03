class ApplicationController < ActionController::API
  rescue_from ActiveRecord::RecordNotFound do |e|
    problem(404, "Not found", e.message)
  end

  private

  # RFC 9457 Problem Details. One error shape across the whole API beats each
  # endpoint inventing its own.
  def problem(status, title, detail = nil, **extra)
    render status:,
           content_type: "application/problem+json",
           json: {
             type: "https://gatecrash.dev/problems/#{title.parameterize}",
             title:, status:, detail:, instance: request.path, **extra
           }.compact
  end

  def money(value) = value&.to_h
end
