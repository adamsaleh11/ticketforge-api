require "rails_helper"

RSpec.describe SupabaseAuth::Verifier do
  # A throwaway EC P-256 key pair standing in for Supabase's signing key.
  let(:ec_key) { OpenSSL::PKey::EC.generate("prime256v1") }
  let(:kid) { "test-signing-key" }
  let(:jwk) { JWT::JWK.new(ec_key, kid: kid) }
  let(:jwks_url) { "#{ENV.fetch('SUPABASE_URL')}/auth/v1/.well-known/jwks.json" }

  def stub_jwks(keys: [jwk.export], status: 200)
    stub_request(:get, jwks_url)
      .to_return(status: status, body: { keys: keys }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  def token(payload_overrides: {}, key: ec_key, header: { kid: kid }, alg: "ES256")
    payload = {
      "sub" => "4e7b1179-146d-4445-9300-e4a072882c5e",
      "aud" => "authenticated",
      "exp" => 1.hour.from_now.to_i,
      "email" => "user@example.com"
    }.merge(payload_overrides)
    JWT.encode(payload, key, alg, header)
  end

  before { described_class.reset_cache! }

  it "returns the decoded payload for a valid ES256 token" do
    stub_jwks
    payload = described_class.call(token)
    expect(payload["sub"]).to eq("4e7b1179-146d-4445-9300-e4a072882c5e")
  end

  it "raises for a blank token without fetching the JWKS" do
    expect { described_class.call("") }.to raise_error(SupabaseAuth::InvalidTokenError)
    expect(WebMock).not_to have_requested(:get, jwks_url)
  end

  it "raises for an expired token" do
    stub_jwks
    expect { described_class.call(token(payload_overrides: { "exp" => 1.hour.ago.to_i })) }
      .to raise_error(SupabaseAuth::InvalidTokenError)
  end

  it "raises for a wrong audience" do
    stub_jwks
    expect { described_class.call(token(payload_overrides: { "aud" => "anon" })) }
      .to raise_error(SupabaseAuth::InvalidTokenError)
  end

  it "raises for a token signed by a different key" do
    stub_jwks
    other_key = OpenSSL::PKey::EC.generate("prime256v1")
    expect { described_class.call(token(key: other_key)) }
      .to raise_error(SupabaseAuth::InvalidTokenError)
  end

  it "rejects an HS256 token (no algorithm downgrade)" do
    stub_jwks
    hs = JWT.encode({ "sub" => "x", "aud" => "authenticated", "exp" => 1.hour.from_now.to_i },
                    "shared-secret", "HS256")
    expect { described_class.call(hs) }.to raise_error(SupabaseAuth::InvalidTokenError)
  end

  it "raises when the JWKS endpoint is unavailable" do
    stub_jwks(status: 500)
    expect { described_class.call(token) }.to raise_error(SupabaseAuth::InvalidTokenError)
  end

  it "refetches the JWKS once when the token kid is unknown" do
    stub_jwks(keys: []) # cached set has no matching kid
    expect { described_class.call(token) }.to raise_error(SupabaseAuth::InvalidTokenError)
    expect(WebMock).to have_requested(:get, jwks_url).at_least_once
  end

  it "caches the JWKS across calls" do
    stub_jwks
    2.times { described_class.call(token) }
    expect(WebMock).to have_requested(:get, jwks_url).once
  end
end
