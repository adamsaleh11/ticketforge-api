require "rails_helper"

RSpec.describe "GET /api/v1/me", type: :request do
  context "with a valid token" do
    it "returns 200" do
      get "/api/v1/me", headers: auth_headers(valid_supabase_jwt)

      expect(response).to have_http_status(:ok)
    end

    it "returns the user's profile fields" do
      get "/api/v1/me", headers: auth_headers(valid_supabase_jwt)

      attributes = response.parsed_body.dig("data", "attributes")
      expect(attributes).to include(
        "supabase_user_id" => "supabase-user-123",
        "email" => "octocat@example.com",
        "ollama_endpoint" => "http://localhost:11434"
      )
    end

    it "never exposes the github access token" do
      get "/api/v1/me", headers: auth_headers(valid_supabase_jwt)

      expect(response.body).not_to include("github_access_token")
      expect(response.body).not_to include("gho_app_metadata_token")
    end

    it "creates exactly one user on the first request" do
      expect {
        get "/api/v1/me", headers: auth_headers(valid_supabase_jwt)
      }.to change(User, :count).by(1)

      expect(User.last.supabase_user_id).to eq("supabase-user-123")
    end

    it "reuses the user on a second request with the same subject" do
      get "/api/v1/me", headers: auth_headers(valid_supabase_jwt)

      expect {
        get "/api/v1/me", headers: auth_headers(valid_supabase_jwt)
      }.not_to change(User, :count)
    end

    it "returns the synced profile and reflects updated name on a later token" do
      get "/api/v1/me", headers: auth_headers(valid_supabase_jwt)

      get "/api/v1/me", headers: auth_headers(
        valid_supabase_jwt(user_metadata: { "full_name" => "Renamed", "user_name" => "octocat" })
      )

      attributes = response.parsed_body.dig("data", "attributes")
      expect(attributes).to include("name" => "Renamed", "github_username" => "octocat")
    end
  end
end
