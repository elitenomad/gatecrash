# Development and test default every secret to a value printed in chapter 4,
# so a fresh clone runs with none of them set. A default secret is a published
# one: with these unset, anyone who has read the book could sign a webhook or
# call the admin API. Anywhere else, refuse to boot without them.
module RequiredSecrets
  NAMES = %w[PSP_SECRET_KEY PSP_WEBHOOK_SECRET ADMIN_TOKEN].freeze

  def self.check!(env: Rails.env, vars: ENV)
    return if env.local?

    missing = NAMES.select { |name| vars[name].blank? }
    return if missing.empty?

    raise "#{missing.join(', ')} must be set in #{env}: the development defaults are printed in the book"
  end
end

RequiredSecrets.check!
