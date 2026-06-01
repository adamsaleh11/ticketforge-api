require "rails_helper"

RSpec.describe "GET /api/v1/github/repos", type: :request do
  let(:repos_url) { "https://api.github.com/user/repos?sort=updated&per_page=100" }

  # The token the Verifier extracts from valid_supabase_jwt's app_metadata.
  let(:github_token) { "gho_app_metadata_token" }

  def github_repo(overrides = {})
    {
      "name" => "hello-world",
      "full_name" => "octocat/hello-world",
      "description" => "My first repo",
      "language" => "Ruby",
      "default_branch" => "main",
      "private" => false,
      "stargazers_count" => 42,
      "owner" => { "login" => "octocat" }
    }.merge(overrides)
  end

  it "lists the user's repos reduced to the six picker fields" do
    stub_request(:get, repos_url)
      .with(headers: { "Authorization" => "Bearer #{github_token}" })
      .to_return(
        status: 200,
        body: [github_repo, github_repo("name" => "second", "full_name" => "octocat/second", "private" => true)].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    get "/api/v1/github/repos", headers: auth_headers(valid_supabase_jwt)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["repos"]).to eq(
      [
        {
          "name" => "hello-world",
          "full_name" => "octocat/hello-world",
          "description" => "My first repo",
          "language" => "Ruby",
          "default_branch" => "main",
          "private" => false
        },
        {
          "name" => "second",
          "full_name" => "octocat/second",
          "description" => "My first repo",
          "language" => "Ruby",
          "default_branch" => "main",
          "private" => true
        }
      ]
    )
  end

  it "returns the actionable re-auth 401 when GitHub rejects the token" do
    stub_request(:get, repos_url).to_return(status: 401, body: '{"message":"Bad credentials"}')

    get "/api/v1/github/repos", headers: auth_headers(valid_supabase_jwt)

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq("error" => "GitHub token invalid, please sign in again")
  end

  it "returns the re-auth 401 without calling GitHub when the user has no token" do
    jwt = valid_supabase_jwt("app_metadata" => {}, "user_metadata" => { "user_name" => "octocat" })

    get "/api/v1/github/repos", headers: auth_headers(jwt)

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq("error" => "GitHub token invalid, please sign in again")
    expect(WebMock).not_to have_requested(:get, repos_url)
  end

  it "returns 502 when GitHub fails unexpectedly" do
    stub_request(:get, repos_url).to_return(status: 500, body: "boom")

    get "/api/v1/github/repos", headers: auth_headers(valid_supabase_jwt)

    expect(response).to have_http_status(:bad_gateway)
    expect(response.parsed_body).to eq("error" => "GitHub request failed")
  end

  it "rejects an unauthenticated request with 401 unauthorized" do
    get "/api/v1/github/repos"

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq("error" => "unauthorized")
  end
end
