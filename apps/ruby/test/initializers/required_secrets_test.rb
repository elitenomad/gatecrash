require "test_helper"

class RequiredSecretsTest < ActiveSupport::TestCase
  PRODUCTION = ActiveSupport::EnvironmentInquirer.new("production")
  ALL_SET = { "PSP_SECRET_KEY" => "sk_live_x", "PSP_WEBHOOK_SECRET" => "whsec_x", "ADMIN_TOKEN" => "t0ken" }.freeze

  test "development and test run on the book's defaults" do
    assert_nothing_raised { RequiredSecrets.check!(env: ActiveSupport::EnvironmentInquirer.new("development"), vars: {}) }
    assert_nothing_raised { RequiredSecrets.check!(env: ActiveSupport::EnvironmentInquirer.new("test"), vars: {}) }
  end

  test "production refuses to boot on a secret the book has published" do
    error = assert_raises(RuntimeError) { RequiredSecrets.check!(env: PRODUCTION, vars: ALL_SET.except("PSP_WEBHOOK_SECRET")) }
    assert_match "PSP_WEBHOOK_SECRET", error.message
  end

  test "an empty secret counts as missing" do
    assert_raises(RuntimeError) { RequiredSecrets.check!(env: PRODUCTION, vars: ALL_SET.merge("ADMIN_TOKEN" => "")) }
  end

  test "production boots with every secret set" do
    assert_nothing_raised { RequiredSecrets.check!(env: PRODUCTION, vars: ALL_SET) }
  end
end
