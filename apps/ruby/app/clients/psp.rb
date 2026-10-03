require "net/http"

# Thin port over the payment provider.
#
# Everything provider-shaped lives behind this class so the rest of the
# application talks about checkout sessions and events, not about Stripe. When
# a second provider arrives, this is the only file that grows a sibling.
#
# Deliberately no SDK. Speaking the HTTP directly is a chapter of its own, and
# it means the only thing that can break on a provider upgrade is right here.
class Psp
  # One error class per decision the caller has to make. A single flat error
  # forces every call site to parse a message string to work out whether trying
  # again is sensible.
  class Error < StandardError
    attr_reader :status, :code, :retry_after

    def initialize(message, status: nil, code: nil, retry_after: nil)
      super(message)
      @status = status
      @code = code
      @retry_after = retry_after
    end
  end

  # The provider understood the request and said no. Sending it again unchanged
  # produces the same answer.
  class RequestError < Error; end

  # Nobody said no. The answer never arrived, or arrived as a 429 or a 5xx.
  # The identical request may well succeed.
  class TransientError < Error; end

  class SignatureError < Error; end

  TOLERANCE = 300 # seconds
  MAX_ATTEMPTS = 3

  # The API version every request here was written and tested against. Leave
  # the header off and each request gets the account's default version, which
  # moves when anyone upgrades it in the dashboard — and versions do break
  # things: this one removed Checkout's `payment_method_types`.
  API_VERSION = "2026-09-30.endive"

  # 409, 429 and 5xx say "not now", not "no". 400-class statuses are decisions.
  # A 409 at Stripe is another request with the same idempotency key still
  # executing; the same key a moment later gets that request's answer.
  RETRYABLE_STATUSES = [408, 409, 425, 429, 500, 502, 503, 504].freeze

  # Where Stripe and ISO 4217 disagree. ISO gives these currencies no minor
  # unit, and so does Money; Stripe still wants them in hundredths, ending 00,
  # for backward compatibility. The translation happens here and nowhere else.
  PROVIDER_SCALE = { "ISK" => 100, "UGX" => 100 }.freeze

  # Failures below HTTP. From here they are indistinguishable: the request may
  # never have arrived, or it may have been executed and the reply lost.
  TRANSPORT_ERRORS = [
    Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::EPIPE,
    EOFError, IOError, SocketError, Net::OpenTimeout, Net::ReadTimeout
  ].freeze

  # A web request cannot afford to sleep longer than this. A provider asking for
  # more is telling you to do the work somewhere else.
  MAX_BACKOFF = 5.0

  class << self
    def base_url    = ENV.fetch("PSP_URL", "http://localhost:4242")
    def retry_base_delay = Float(ENV.fetch("PSP_RETRY_BASE_DELAY", 0.25))
    def secret_key  = ENV.fetch("PSP_SECRET_KEY", "sk_test_fake")
    def webhook_secret = ENV.fetch("PSP_WEBHOOK_SECRET", "whsec_fake_psp_secret")

    def create_checkout_session(order:, success_url:, cancel_url:, idempotency_key: nil)
      post("/v1/checkout/sessions", {
        "mode" => "payment",
        # Cards only, stated here rather than left to the dashboard, where
        # someone else can switch on a bank debit that confirms after the
        # hold has lapsed and the seats have gone.
        "allowed_payment_method_types[0]" => "card",
        "line_items[0][price_data][currency]" => order.total.currency.downcase,
        "line_items[0][price_data][unit_amount]" => provider_amount(order.total),
        "line_items[0][price_data][product_data][name]" => order.event.name,
        "line_items[0][quantity]" => 1,
        "client_reference_id" => order.id,
        "customer_email" => order.email,
        "success_url" => success_url,
        "cancel_url" => cancel_url
      }, idempotency_key:)
    end

    def checkout_session(id, expand: [])
      query = URI.encode_www_form(expand.map { |path| ["expand[]", path] })
      get("/v1/checkout/sessions/#{id}#{"?#{query}" unless query.empty?}")
    end

    def expire_checkout_session(id) = post("/v1/checkout/sessions/#{id}/expire", {})

    def provider_amount(money) = money.amount * PROVIDER_SCALE.fetch(money.currency, 1)

    # Back the other way. A fraction of a króna is a fact Money cannot hold, so
    # it is refused rather than rounded.
    def money_from_provider(amount, currency)
      code = currency.to_s.upcase
      scale = PROVIDER_SCALE.fetch(code, 1)
      raise Error, "#{amount} is not a whole number of #{code}" unless (amount % scale).zero?

      Money.new(amount / scale, code)
    end

    # Verify over the RAW body. Anything that parses the JSON and re-serialises
    # before hashing produces a different digest — and fails intermittently, as
    # key order and unicode escaping shift.
    def verify_signature!(raw_body, header, now: Time.current)
      raise SignatureError, "missing signature header" if header.blank?

      # Keep only well-formed k=v pairs. A header of pure garbage must produce a
      # clean rejection, not an exception — anything that escapes as a 500 is
      # an unauthenticated caller crashing the endpoint.
      pairs = header.split(",").filter_map { |pair|
        kv = pair.split("=", 2)
        kv if kv.size == 2
      }
      timestamp = Integer(pairs.assoc("t")&.last, exception: false)
      # Every v1, not one. While a secret is being rolled the provider signs
      # with each secret still active, so a genuine header can carry several —
      # and folding the pairs into a hash keeps only the last. Any other scheme
      # is ignored however valid it looks: accepting it would be a downgrade.
      given = pairs.filter_map { |scheme, signature| signature if scheme == "v1" && signature.present? }
      raise SignatureError, "malformed signature header" if timestamp.nil?
      raise SignatureError, "no v1 signature" if given.empty?

      expected = OpenSSL::HMAC.hexdigest("SHA256", webhook_secret, "#{timestamp}.#{raw_body}")

      # Constant-time, against each one. A byte-by-byte compare leaks the
      # secret through timing.
      unless given.any? { |signature| ActiveSupport::SecurityUtils.secure_compare(expected, signature) }
        raise SignatureError, "signature mismatch"
      end

      # A signature proves authorship, not freshness. Without this a captured
      # request can be replayed forever.
      raise SignatureError, "timestamp outside tolerance" if (now.to_i - timestamp).abs > TOLERANCE

      true
    end

    private

    def get(path)
      request(Net::HTTP::Get.new(uri_for(path)))
    end

    def post(path, form, idempotency_key: nil)
      uri = uri_for(path)
      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/x-www-form-urlencoded"
      # Generated once, OUTSIDE the retry loop. That is the whole trick: a retry
      # carrying the same key is recognisable to the provider as the same
      # request, so a lost reply cannot become a second charge.
      req["Idempotency-Key"] = idempotency_key || SecureRandom.uuid
      req.body = URI.encode_www_form(form)
      request(req)
    end

    def uri_for(path) = URI.join(base_url, path)

    def request(req)
      attempt = 0
      begin
        attempt += 1
        perform(req)
      rescue TransientError => e
        raise if attempt >= MAX_ATTEMPTS

        delay = backoff(attempt, e.retry_after)
        # Waiting longer than a request can afford is not resilience, it is a
        # queue with no name. Give up and let the caller decide.
        raise if delay > MAX_BACKOFF

        Rails.logger.warn("psp #{req.method} #{req.path}: #{e.message} — retrying in #{delay.round(2)}s")
        sleep delay
        retry
      end
    end

    def perform(req)
      req["Authorization"] = "Bearer #{secret_key}"
      req["Stripe-Version"] = API_VERSION
      uri = req.uri
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
                                 read_timeout: 10, open_timeout: 5) do |http|
        http.request(req)
      end
      interpret(response)
    rescue *TRANSPORT_ERRORS => e
      raise TransientError, "#{e.class}: #{e.message}"
    end

    def interpret(response)
      status = response.code.to_i
      return response.body.presence && JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)

      error = error_envelope(response.body)
      message = "#{status} #{error["code"] || "http_error"}: " \
                "#{error["message"] || response.body.to_s.truncate(200)}"

      if retryable?(status, response["Stripe-Should-Retry"])
        raise TransientError.new(message, status:, code: error["code"],
                                 retry_after: response["Retry-After"])
      end

      raise RequestError.new(message, status:, code: error["code"])
    rescue JSON::ParserError => e
      # Only a 2xx body reaches here: a success we cannot read is a real
      # problem, where an error body we cannot read is a proxy having a bad day.
      raise Error, "unparseable provider response: #{e.message}"
    end

    # When the provider says whether to retry, believe it: `false` on a 500
    # whose idempotency key will only ever replay it, `true` where the status
    # alone would look final. When it is silent, the status code decides.
    def retryable?(status, should_retry)
      return should_retry == "true" if %w[true false].include?(should_retry)

      RETRYABLE_STATUSES.include?(status)
    end

    # Providers return a structured envelope, `{"error": {"code", "message"}}`.
    # Whatever sits in front of them returns an HTML holding page. Only the
    # first is worth reading, and neither is worth crashing over.
    def error_envelope(body)
      parsed = JSON.parse(body.to_s)
      parsed.is_a?(Hash) ? parsed["error"].to_h : {}
    rescue JSON::ParserError, TypeError
      {}
    end

    # Exponential, with jitter. Without the jitter every client that failed
    # during the same outage comes back in the same instant and extends it.
    def backoff(attempt, retry_after)
      seconds = retry_after.presence && Float(retry_after, exception: false)
      return seconds if seconds

      base = retry_base_delay * (2**(attempt - 1))
      base + (rand * base)
    end
  end
end
