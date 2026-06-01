module Api
  module V1
    class UsersController < ApplicationController
      # GET /api/v1/me
      def show
        render json: UserSerializer.new(current_user).serializable_hash
      end
    end
  end
end
