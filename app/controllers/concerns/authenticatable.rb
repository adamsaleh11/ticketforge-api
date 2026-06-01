# Authenticates requests against Supabase-issued JWTs. Include in a controller
# (e.g. ApplicationController) to require a valid Bearer token on every action
# and expose `current_user`.
module Authenticatable
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_user!
  end

  private

  # The User resolved from the request's Bearer token, or nil if the token is
  # missing or invalid. Memoized per request, including a legitimate nil so a
  # failed lookup is not retried on each call.
  def current_user
    return @current_user if defined?(@current_user)

    @current_user = resolve_current_user
  end

  def authenticate_user!
    render_unauthorized if current_user.nil?
  end

  def resolve_current_user
    payload = SupabaseAuth::Verifier.call(bearer_token)
    User.from_supabase_payload(payload)
  rescue SupabaseAuth::InvalidTokenError
    nil
  end

  def bearer_token
    header = request.headers["Authorization"]
    header[/\ABearer (.+)\z/, 1] if header
  end

  def render_unauthorized
    render json: { error: "unauthorized" }, status: :unauthorized
  end
end
