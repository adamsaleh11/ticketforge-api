Rails.application.routes.draw do
  # Authentication is handled by verifying Supabase-issued JWTs via the
  # Authenticatable concern on ApplicationController.
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Application health check (unauthenticated) for uptime monitoring and deploy smoke tests.
  get "health" => "health#show"

  # All versioned JSON endpoints live here. Reserved for future controllers
  # (auth, projects, tickets, ...). See CLAUDE.md routing rules.
  namespace :api do
    namespace :v1 do
      # Current authenticated user's profile. PATCH syncs the GitHub OAuth token
      # the frontend reads from the Supabase session (provider_token), which is
      # never present in the JWT itself.
      get    "me", to: "users#show"
      patch  "me", to: "users#update"
      delete "me", to: "users#destroy"

      resources :projects, only: %i[index show create update destroy] do
        member do
          post :generate
        end
      end

      # Per-ticket status updates. Flat path (not nested under projects); the
      # ticket is scoped to the current user's projects in the controller.
      resources :tickets, only: %i[update]

      # User-level Ollama configuration: save the endpoint, then test connectivity.
      namespace :settings do
        patch "ollama",      to: "ollama#update"
        post  "ollama/test", to: "ollama#test"
      end

      # Read-only GitHub access on behalf of the signed-in user. Explicit routes
      # (not resources) because :owner/:repo/context is a two-segment path.
      namespace :github do
        get "repos",                       to: "repos#index"
        get "repos/:owner/:repo/context",  to: "repos#context"
      end
    end
  end
end
