class ApplicationController < ActionController::API
  include Authenticatable

  # Scoping every lookup through current_user means a missing record and another
  # user's record both raise RecordNotFound. Returning 404 (not 403) keeps the
  # two indistinguishable, so the API never leaks whether a resource exists.
  rescue_from ActiveRecord::RecordNotFound do
    render json: { error: "not_found" }, status: :not_found
  end
end
