# Shared ES256 signing key for the test suite. Request specs mint tokens with
# the private key via AuthHelpers, and the matching public key is served from a
# stubbed Supabase JWKS endpoint. One key pair, one source of truth.
module SupabaseTestKeys
  KID = "test-signing-key".freeze
  EC_KEY = OpenSSL::PKey::EC.generate("prime256v1")
  JWK = JWT::JWK.new(EC_KEY, kid: KID)

  module_function

  def jwks_url
    "#{ENV.fetch('SUPABASE_URL')}/auth/v1/.well-known/jwks.json"
  end

  def jwks_body
    { keys: [JWK.export] }.to_json
  end
end

RSpec.configure do |config|
  # Auth is incidental to request specs: serve the public JWKS so the Verifier
  # can validate the ES256 tokens AuthHelpers signs, and reset the cached set
  # between examples so key state never leaks.
  config.before(:each, type: :request) do
    stub_request(:get, SupabaseTestKeys.jwks_url)
      .to_return(status: 200, body: SupabaseTestKeys.jwks_body,
                 headers: { "Content-Type" => "application/json" })
  end

  config.before(:each) { SupabaseAuth::Verifier.reset_cache! }
end
