class User < ApplicationRecord
  encrypts :github_access_token

  has_many :projects, dependent: :destroy

  validates :supabase_user_id, presence: true, uniqueness: true
  validates :email, presence: true
  validate :ollama_endpoint_is_http_url

  # Find-or-create the user identified by a verified Supabase JWT payload,
  # keeping profile fields in sync with the token's claims.
  #
  # Fields are only overwritten when the corresponding claim is present, so a
  # refreshed Supabase session that omits provider_token never wipes a stored
  # GitHub token (nor clears other GitHub profile fields).
  def self.from_supabase_payload(payload)
    metadata = SupabaseMetadata.new(payload)

    user = find_or_initialize_by(supabase_user_id: metadata.supabase_user_id)
    user.email = metadata.email if metadata.email
    user.name = metadata.name if metadata.name
    user.github_username = metadata.github_username if metadata.github_username
    user.github_access_token = metadata.github_access_token if metadata.github_access_token
    user.save! if user.new_record? || user.changed?
    user
  rescue ActiveRecord::RecordNotUnique
    find_by!(supabase_user_id: metadata.supabase_user_id)
  end

  private

  # Guarantees a stored ollama_endpoint is always something the HTTP client can
  # actually attempt to connect to: a well-formed http/https URL with a host.
  # Parsing (not a loose regex) so the check matches what HTTParty will dial.
  def ollama_endpoint_is_http_url
    uri = URI.parse(ollama_endpoint.to_s)
    valid = uri.is_a?(URI::HTTP) && uri.host.present?
    errors.add(:ollama_endpoint, "must be a valid http or https URL") unless valid
  rescue URI::InvalidURIError
    errors.add(:ollama_endpoint, "must be a valid http or https URL")
  end

  public

  # Reads the TicketForge-relevant claims out of a Supabase JWT payload, hiding
  # the layout of user_metadata / app_metadata behind named accessors.
  class SupabaseMetadata
    def initialize(payload)
      @payload = payload
      @user_metadata = payload["user_metadata"] || {}
      @app_metadata = payload["app_metadata"] || {}
    end

    def supabase_user_id
      @payload["sub"]
    end

    def email
      @payload["email"] || @user_metadata["email"]
    end

    def name
      @user_metadata["full_name"] || @user_metadata["name"]
    end

    def github_username
      @user_metadata["user_name"] || @user_metadata["preferred_username"]
    end

    # Supabase places the GitHub OAuth token in app_metadata or user_metadata
    # depending on project config; prefer app_metadata.
    def github_access_token
      @app_metadata["provider_token"] || @user_metadata["provider_token"]
    end
  end
end
