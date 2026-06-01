require "rails_helper"

RSpec.describe "GET /api/v1/github/repos/:owner/:repo/context", type: :request do
  let(:owner) { "octocat" }
  let(:repo) { "hello-world" }
  let(:path) { "/api/v1/github/repos/#{owner}/#{repo}/context" }

  let(:repo_url) { "https://api.github.com/repos/#{owner}/#{repo}" }
  let(:tree_url) { "https://api.github.com/repos/#{owner}/#{repo}/git/trees/main?recursive=1" }
  let(:readme_url) { "https://api.github.com/repos/#{owner}/#{repo}/readme" }
  let(:languages_url) { "https://api.github.com/repos/#{owner}/#{repo}/languages" }

  def blob(path, size: 100)
    { "path" => path, "type" => "blob", "size" => size }
  end

  def stub_repo(default_branch: "main")
    stub_request(:get, repo_url).to_return(
      status: 200, body: { "default_branch" => default_branch }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end

  def stub_tree(entries, truncated: false)
    stub_request(:get, tree_url).to_return(
      status: 200, body: { "tree" => entries, "truncated" => truncated }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end

  def stub_readme(content)
    stub_request(:get, readme_url).to_return(
      status: 200,
      body: { "content" => Base64.encode64(content), "encoding" => "base64" }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end

  def stub_languages(langs)
    stub_request(:get, languages_url).to_return(
      status: 200, body: langs.to_json, headers: { "Content-Type" => "application/json" }
    )
  end

  it "returns the filtered tree, decoded readme, languages, and truncated flag" do
    stub_repo
    stub_tree(
      [
        { "path" => "app", "type" => "tree" },                 # dir dropped
        blob("app/models/user.rb"),                            # kept
        blob("README.md"),                                     # kept
        blob("node_modules/left-pad/index.js"),                # excluded dir
        blob("vendor/bundle/gem.rb"),                          # excluded dir
        blob("dist/bundle.js"),                                # excluded dir
        blob("yarn.lock"),                                     # excluded lockfile
        blob("public/logo.png"),                               # excluded image
        blob("fonts/icons.woff2"),                             # excluded font
        blob("data/huge.json", size: 200_000)                  # excluded oversize
      ]
    )
    stub_readme("# Hello World\nA sample project.")
    stub_languages("Ruby" => 12_345, "JavaScript" => 678)

    get path, headers: auth_headers(valid_supabase_jwt)

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["tree"]).to eq(["app/models/user.rb", "README.md"])
    expect(body["readme"]).to eq("# Hello World\nA sample project.")
    expect(body["languages"]).to eq("Ruby" => 12_345, "JavaScript" => 678)
    expect(body["truncated"]).to be(false)
  end

  it "returns a null readme when the repo has none" do
    stub_repo
    stub_tree([blob("main.rb")])
    stub_request(:get, readme_url).to_return(status: 404, body: '{"message":"Not Found"}')
    stub_languages("Ruby" => 1)

    get path, headers: auth_headers(valid_supabase_jwt)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["readme"]).to be_nil
  end

  it "flags truncated when GitHub truncates the tree" do
    stub_repo
    stub_tree([blob("main.rb")], truncated: true)
    stub_readme("# r")
    stub_languages("Ruby" => 1)

    get path, headers: auth_headers(valid_supabase_jwt)

    expect(response.parsed_body["truncated"]).to be(true)
  end

  it "returns 404 when the repo does not exist or is inaccessible" do
    stub_request(:get, repo_url).to_return(status: 404, body: '{"message":"Not Found"}')

    get path, headers: auth_headers(valid_supabase_jwt)

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to eq("error" => "repository not found")
  end

  it "returns 502 on a transient GitHub failure" do
    stub_request(:get, repo_url).to_return(status: 503, body: "down")

    get path, headers: auth_headers(valid_supabase_jwt)

    expect(response).to have_http_status(:bad_gateway)
    expect(response.parsed_body).to eq("error" => "GitHub request failed")
  end

  it "returns the re-auth 401 when the token is rejected" do
    stub_request(:get, repo_url).to_return(status: 401, body: '{"message":"Bad credentials"}')

    get path, headers: auth_headers(valid_supabase_jwt)

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq("error" => "GitHub token invalid, please sign in again")
  end
end
