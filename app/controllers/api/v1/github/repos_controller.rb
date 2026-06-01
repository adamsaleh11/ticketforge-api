module Api
  module V1
    module Github
      # Read-only GitHub endpoints acting on behalf of current_user via their
      # stored GitHub token. GitHub failures are mapped to actionable statuses
      # here (not on ApplicationController) so they don't collide with the
      # base controller's auth 401/404 semantics.
      class ReposController < ApplicationController
        # rescue_from matches in reverse declaration order, so the broad base is
        # declared first and the specific subclasses after, giving them priority.

        # Any upstream failure (connection/invalid response): GitHub broke, not
        # the client's token — surface as a gateway error.
        rescue_from ::Github::Error do
          render json: { error: "GitHub request failed" }, status: :bad_gateway
        end

        rescue_from ::Github::NotFoundError do
          render json: { error: "repository not found" }, status: :not_found
        end

        # A dead/missing GitHub token is distinct from a missing TicketForge
        # session: tell the user to re-authenticate with GitHub.
        rescue_from ::Github::UnauthorizedError do
          render json: { error: "GitHub token invalid, please sign in again" }, status: :unauthorized
        end

        REPO_FIELDS = %w[name full_name description language default_branch private].freeze

        # GET /api/v1/github/repos
        def index
          repos = ::Github::Client.new(current_user).repos
          render json: { repos: repos.map { |repo| repo.slice(*REPO_FIELDS) } }
        end

        # GET /api/v1/github/repos/:owner/:repo/context
        def context
          render json: ::Github::RepoContext.build(current_user, params[:owner], params[:repo])
        end
      end
    end
  end
end
