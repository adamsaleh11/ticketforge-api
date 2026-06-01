require "rails_helper"

RSpec.describe "PATCH /api/v1/settings/ollama", type: :request do
  it "updates the user's ollama_endpoint and returns the serialized user" do
    patch "/api/v1/settings/ollama",
          params: { user: { ollama_endpoint: "http://ollama.internal:11434" } },
          headers: auth_headers(valid_supabase_jwt)

    expect(response).to have_http_status(:ok)
    attributes = response.parsed_body.dig("data", "attributes")
    expect(attributes["ollama_endpoint"]).to eq("http://ollama.internal:11434")
    expect(User.find_by(supabase_user_id: "supabase-user-123").ollama_endpoint)
      .to eq("http://ollama.internal:11434")
  end

  it "accepts an https URL" do
    patch "/api/v1/settings/ollama",
          params: { user: { ollama_endpoint: "https://ollama.example.com" } },
          headers: auth_headers(valid_supabase_jwt)

    expect(response).to have_http_status(:ok)
  end

  %w[not-a-url ftp://ollama http://].each do |bad|
    it "rejects #{bad.inspect} with a JSON:API validation error and leaves the value unchanged" do
      patch "/api/v1/settings/ollama",
            params: { user: { ollama_endpoint: bad } },
            headers: auth_headers(valid_supabase_jwt)

      expect(response).to have_http_status(:unprocessable_entity)
      pointer = response.parsed_body.dig("errors", 0, "source", "pointer")
      expect(pointer).to eq("/data/attributes/ollama_endpoint")
      expect(User.find_by(supabase_user_id: "supabase-user-123").ollama_endpoint)
        .to eq("http://localhost:11434")
    end
  end

  it "leaves other profile fields intact" do
    get "/api/v1/me", headers: auth_headers(valid_supabase_jwt) # materialize the user
    user = User.find_by(supabase_user_id: "supabase-user-123")

    patch "/api/v1/settings/ollama",
          params: { user: { ollama_endpoint: "http://ollama.internal:11434" } },
          headers: auth_headers(valid_supabase_jwt)

    user.reload
    expect(user.github_access_token).to eq("gho_app_metadata_token")
    expect(user.github_username).to eq("octocat")
  end

  it "rejects an unauthenticated request with 401" do
    patch "/api/v1/settings/ollama",
          params: { user: { ollama_endpoint: "http://ollama.internal:11434" } }

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq("error" => "unauthorized")
  end
end
