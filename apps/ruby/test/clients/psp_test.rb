require "test_helper"

class PspTest < ActiveSupport::TestCase
  BODY = '{"id":"evt_123","type":"checkout.session.completed"}'.freeze

  test "accepts a correctly signed, fresh payload" do
    assert Psp.verify_signature!(BODY, sign_payload(BODY))
  end

  test "rejects a forged signature" do
    header = sign_payload(BODY, secret: "whsec_wrong")
    assert_raises(Psp::SignatureError) { Psp.verify_signature!(BODY, header) }
  end

  test "accepts any v1 that matches — during a secret roll there is one per secret" do
    t, ours = sign_payload(BODY).split(",")
    theirs = "v1=#{OpenSSL::HMAC.hexdigest("SHA256", "whsec_rolled", "#{t.delete_prefix("t=")}.#{BODY}")}"

    assert Psp.verify_signature!(BODY, [t, ours, theirs].join(",")), "ours first"
    assert Psp.verify_signature!(BODY, [t, theirs, ours].join(",")), "ours last"
  end

  test "rejects a header whose v1 signatures are all someone else's" do
    t, = sign_payload(BODY).split(",")
    forged = %w[whsec_one whsec_two].map do |secret|
      "v1=#{OpenSSL::HMAC.hexdigest("SHA256", secret, "#{t.delete_prefix("t=")}.#{BODY}")}"
    end
    assert_raises(Psp::SignatureError) { Psp.verify_signature!(BODY, [t, *forged].join(",")) }
  end

  test "ignores every scheme but v1, however valid the signature under it" do
    # Stripe adds a v0 to test events. A verifier that accepted any scheme
    # would let an attacker pick the weakest one the provider ever used.
    t, ours = sign_payload(BODY).split(",")
    assert_raises(Psp::SignatureError) do
      Psp.verify_signature!(BODY, [t, ours.sub("v1=", "v0=")].join(","))
    end
  end

  test "rejects a payload altered after signing" do
    # The exact attack the signature exists to stop: valid header, tampered body.
    header = sign_payload(BODY)
    tampered = BODY.sub("evt_123", "evt_999")
    assert_raises(Psp::SignatureError) { Psp.verify_signature!(tampered, header) }
  end

  test "rejects a missing or malformed header" do
    [nil, "", "garbage", "t=123", "v1=abc", "t=notanumber,v1=abc"].each do |header|
      assert_raises(Psp::SignatureError, "should reject #{header.inspect}") do
        Psp.verify_signature!(BODY, header)
      end
    end
  end

  test "rejects a stale timestamp even when correctly signed" do
    # A signature proves authorship, not freshness. Without this check a
    # captured request can be replayed indefinitely.
    header = sign_payload(BODY, timestamp: 20.minutes.ago.to_i)
    assert_raises(Psp::SignatureError) { Psp.verify_signature!(BODY, header) }
  end

  test "rejects a timestamp too far in the future" do
    header = sign_payload(BODY, timestamp: 20.minutes.from_now.to_i)
    assert_raises(Psp::SignatureError) { Psp.verify_signature!(BODY, header) }
  end

  test "accepts timestamps at the edge of tolerance" do
    inside = sign_payload(BODY, timestamp: (Psp::TOLERANCE - 5).seconds.ago.to_i)
    assert Psp.verify_signature!(BODY, inside)

    outside = sign_payload(BODY, timestamp: (Psp::TOLERANCE + 5).seconds.ago.to_i)
    assert_raises(Psp::SignatureError) { Psp.verify_signature!(BODY, outside) }
  end

  test "signs over raw bytes, so re-serialised JSON does not verify" do
    # The failure mode that bites intermittently in production: parse the body,
    # dump it again, hash that. Key order and spacing shift and the digest moves.
    header = sign_payload(BODY)
    reserialised = JSON.generate(JSON.parse(BODY).transform_keys(&:to_s).to_a.reverse.to_h)
    assert_not_equal BODY, reserialised
    assert_raises(Psp::SignatureError) { Psp.verify_signature!(reserialised, header) }
  end

  test "handles unicode bodies byte-exactly" do
    body = '{"id":"evt_1","venue":"Café Oto ☕"}'
    assert Psp.verify_signature!(body, sign_payload(body))
  end
end
