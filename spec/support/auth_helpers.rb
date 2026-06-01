# Helpers for building Supabase-style access tokens in request specs.
#
# Tokens are signed with the shared ES256 test key (SupabaseTestKeys), whose
# public half is served from the stubbed JWKS the Verifier reads, so there is a
# single source of truth for signing across the suite.
module AuthHelpers
  # Build a valid Supabase JWT. Pass `overrides` to merge/replace top-level
  # claims (e.g. exp:, aud:, sub:, user_metadata:, app_metadata:). Pass `key:`
  # to sign with a different key (for negative tests).
  def valid_supabase_jwt(overrides = {})
    payload = {
      "sub" => "supabase-user-123",
      "aud" => "authenticated",
      "exp" => 1.hour.from_now.to_i,
      "email" => "octocat@example.com",
      "user_metadata" => {
        "full_name" => "The Octocat",
        "user_name" => "octocat"
      },
      "app_metadata" => {
        "provider_token" => "gho_app_metadata_token"
      }
    }.merge(stringify(overrides))

    encode(payload, key: overrides.fetch(:key, SupabaseTestKeys::EC_KEY))
  end

  def auth_headers(token)
    { "Authorization" => "Bearer #{token}" }
  end

  private

  def encode(payload, key:)
    JWT.encode(payload, key, "ES256", { kid: SupabaseTestKeys::KID })
  end

  def stringify(hash)
    hash.each_with_object({}) do |(k, v), out|
      next if k == :key

      out[k.to_s] = v
    end
  end
end

RSpec.configure do |config|
  config.include AuthHelpers, type: :request
end
