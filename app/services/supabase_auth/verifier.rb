module SupabaseAuth
  # Raised for any token that fails verification: blank, malformed, expired,
  # wrong audience, wrongly signed, unknown signing key, or unverifiable
  # because the JWKS could not be loaded. Callers should treat all of these
  # identically (a 401) and must not distinguish the failure mode.
  class InvalidTokenError < StandardError; end

  # Verifies a Supabase-issued access token and returns its decoded payload.
  #
  #   SupabaseAuth::Verifier.call(token) # => { "sub" => "...", ... }
  #
  # Supabase signs access tokens with asymmetric JWT signing keys (ES256), so
  # tokens are verified against the project's public JWKS rather than a shared
  # secret. The JWKS is fetched from SUPABASE_URL and cached in process; an
  # unknown `kid` (e.g. after key rotation) triggers a single refetch.
  #
  # The algorithm is pinned to ES256 so an attacker cannot downgrade to
  # `alg: none` or smuggle in an HS256 token signed with a guessed secret.
  class Verifier
    ALGORITHM = "ES256".freeze
    AUDIENCE = "authenticated".freeze
    LEEWAY = 30 # seconds, to tolerate small clock skew
    JWKS_TIMEOUT = 5 # seconds

    CACHE_MUTEX = Mutex.new

    class << self
      def call(token)
        new.call(token)
      end

      # Drops the cached JWKS. A test seam so suites don't leak key state, and
      # usable operationally to force a refresh.
      def reset_cache!
        CACHE_MUTEX.synchronize { @jwks = nil }
      end

      # Returns the cached JWKS hash, fetching it on first use. Passing
      # invalidate: true forces a refetch (used when a token's kid is unknown).
      def jwks(invalidate: false)
        CACHE_MUTEX.synchronize do
          @jwks = nil if invalidate
          @jwks ||= fetch_jwks
        end
      end

      private

      def fetch_jwks
        response = HTTParty.get(jwks_url, timeout: JWKS_TIMEOUT)
        unless response.success?
          raise InvalidTokenError, "could not load Supabase JWKS (HTTP #{response.code})"
        end

        parsed = JSON.parse(response.body)
        parsed
      rescue HTTParty::Error, SocketError, Timeout::Error, JSON::ParserError => e
        raise InvalidTokenError, "could not load Supabase JWKS: #{e.message}"
      end

      def jwks_url
        "#{ENV.fetch('SUPABASE_URL')}/auth/v1/.well-known/jwks.json"
      end
    end

    def call(token)
      raise InvalidTokenError, "token is missing" if token.blank?

      payload, _header = JWT.decode(
        token,
        nil,
        true,
        algorithms: [ALGORITHM],
        jwks: jwks_loader,
        verify_expiration: true,
        verify_aud: true,
        aud: AUDIENCE,
        leeway: LEEWAY
      )
      payload
    rescue JWT::DecodeError => e
      raise InvalidTokenError, e.message
    end

    private

    # The jwt gem calls this with { kid:, invalidate: } and re-invokes it with
    # invalidate: true if the token's kid isn't found in the returned set —
    # giving us exactly one refetch on key rotation.
    def jwks_loader
      ->(options) { self.class.jwks(invalidate: options[:invalidate]) }
    end
  end
end
