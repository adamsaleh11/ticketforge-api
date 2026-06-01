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
      # Current authenticated user's profile.
      get "me", to: "users#show"

      resources :projects, only: %i[index show create update destroy]
    end
  end
end
