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

      # DELETE /api/v1/me
      #
      # Destroys the User and everything it owns (projects -> phases -> tickets)
      # via ActiveRecord `dependent: :destroy`. `destroy!` runs the dependent
      # callbacks (the DB foreign keys have no ON DELETE CASCADE) and wraps the
      # whole cascade in a transaction, so a mid-cascade failure rolls back
      # rather than leaving a half-deleted account.
      #
      # CAVEAT: this does NOT delete the Supabase auth user — that needs the
      # Supabase admin API (service-role key) and is out of scope for MVP.
      # Because the user's Supabase JWT stays valid, the next authenticated
      # request will recreate an empty User row (see
      # Authenticatable#resolve_current_user). The frontend must sign the user
      # out immediately after a 2xx; full cleanup of the orphan Supabase auth
      # user is the frontend's job via supabase.auth.admin.deleteUser.
      def destroy
        current_user.destroy!
        head :no_content
      end

      private

      def user_params
        params.require(:user).permit(:github_access_token)
      end
    end
  end
end
