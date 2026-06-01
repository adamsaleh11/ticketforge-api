module Api
  module V1
    module Settings
      # User-level Ollama configuration. Both actions operate solely on
      # current_user; there is no record lookup by id.
      class OllamaController < ApplicationController
        # PATCH /api/v1/settings/ollama
        def update
          if current_user.update(ollama_params)
            render json: UserSerializer.new(current_user).serializable_hash
          else
            render_validation_errors(current_user)
          end
        end

        # POST /api/v1/settings/ollama/test
        #
        # A connectivity *report* against the user's saved endpoint. Always 200:
        # an unreachable Ollama is a successful report of a problem, not a failed
        # request, so the frontend gets a deterministic connected/not-connected
        # body to render.
        def test
          models = LLM::OllamaClient.new(endpoint: current_user.ollama_endpoint).list_models
          render json: { connected: true, models: models }
        rescue LLM::Error => e
          render json: { connected: false, error: e.message }
        end

        private

        def ollama_params
          params.require(:user).permit(:ollama_endpoint)
        end
      end
    end
  end
end
