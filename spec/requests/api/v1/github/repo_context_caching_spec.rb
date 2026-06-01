require "rails_helper"

RSpec.describe "GET /api/v1/github/repos/:owner/:repo/context caching", type: :request do
  let(:owner) { "octocat" }
  let(:repo) { "hello-world" }
  let(:path) { "/api/v1/github/repos/#{owner}/#{repo}/context" }
  let(:repo_url) { "https://api.github.com/repos/#{owner}/#{repo}" }
  let(:tree_url) { "https://api.github.com/repos/#{owner}/#{repo}/git/trees/main?recursive=1" }
  let(:readme_url) { "https://api.github.com/repos/#{owner}/#{repo}/readme" }
  let(:languages_url) { "https://api.github.com/repos/#{owner}/#{repo}/languages" }

  # The cache test needs a real store; the test env defaults to :null_store.
  around do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = original
  end

  def stub_happy_repo
    stub_request(:get, repo_url).to_return(
      status: 200, body: { "default_branch" => "main" }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
    stub_request(:get, tree_url).to_return(
      status: 200, body: { "tree" => [{ "path" => "a.rb", "type" => "blob", "size" => 1 }], "truncated" => false }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
    stub_request(:get, readme_url).to_return(status: 404, body: "{}")
    stub_request(:get, languages_url).to_return(
      status: 200, body: { "Ruby" => 1 }.to_json, headers: { "Content-Type" => "application/json" }
    )
  end

  it "serves the second request for the same repo from cache, hitting GitHub once" do
    stub_happy_repo

    2.times { get path, headers: auth_headers(valid_supabase_jwt) }

    expect(response).to have_http_status(:ok)
    expect(WebMock).to have_requested(:get, repo_url).once
    expect(WebMock).to have_requested(:get, tree_url).once
  end

  it "does not cache a failed build, retrying the upstream on the next request" do
    stub_request(:get, repo_url)
      .to_return(status: 503, body: "down").then
      .to_return(status: 200, body: { "default_branch" => "main" }.to_json,
                 headers: { "Content-Type" => "application/json" })
    stub_request(:get, tree_url).to_return(
      status: 200, body: { "tree" => [], "truncated" => false }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
    stub_request(:get, readme_url).to_return(status: 404, body: "{}")
    stub_request(:get, languages_url).to_return(
      status: 200, body: {}.to_json, headers: { "Content-Type" => "application/json" }
    )

    get path, headers: auth_headers(valid_supabase_jwt)
    expect(response).to have_http_status(:bad_gateway)

    get path, headers: auth_headers(valid_supabase_jwt)
    expect(response).to have_http_status(:ok)
  end
end
