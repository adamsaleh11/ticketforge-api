require "rails_helper"

RSpec.describe "PATCH /api/v1/me", type: :request do
  let(:params) { { user: { github_access_token: "gho_synced_from_frontend" } } }

  it "stores the GitHub token synced from the frontend session" do
    patch "/api/v1/me", params: params, headers: auth_headers(valid_supabase_jwt)

    expect(response).to have_http_status(:ok)
    expect(User.find_by(supabase_user_id: "supabase-user-123").github_access_token)
      .to eq("gho_synced_from_frontend")
  end

  it "never echoes the token back in the response" do
    patch "/api/v1/me", params: params, headers: auth_headers(valid_supabase_jwt)

    expect(response.body).not_to include("github_access_token")
    expect(response.body).not_to include("gho_synced_from_frontend")
  end

  it "keeps the synced token on a later request whose JWT carries no provider_token" do
    patch "/api/v1/me", params: params, headers: auth_headers(valid_supabase_jwt)

    # A refreshed session JWT without provider_token must not wipe the token.
    get "/api/v1/me", headers: auth_headers(valid_supabase_jwt("app_metadata" => {}))

    expect(User.find_by(supabase_user_id: "supabase-user-123").github_access_token)
      .to eq("gho_synced_from_frontend")
  end

  it "rejects an unauthenticated request with 401" do
    patch "/api/v1/me", params: params

    expect(response).to have_http_status(:unauthorized)
  end
end
