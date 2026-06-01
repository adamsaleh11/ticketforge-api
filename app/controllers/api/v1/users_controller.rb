module Api
  module V1
    class UsersController < ApplicationController
      # GET /api/v1/me
      def show
        render json: UserSerializer.new(current_user).serializable_hash
      end

      # PATCH /api/v1/me
      #
      # Syncs the GitHub OAuth token from the frontend. Supabase returns
      # provider_token only in the client-side session (never in the JWT), so
      # the frontend posts it here after sign-in to be stored encrypted on the
      # user. from_supabase_payload only overwrites the token when the JWT
      # carries one, so this synced value survives later requests.
      def update
        if current_user.update(user_params)
          render json: UserSerializer.new(current_user).serializable_hash
        else
          render_validation_errors(current_user)
        end
      end

      private

      def user_params
        params.require(:user).permit(:github_access_token)
      end
    end
  end
end
