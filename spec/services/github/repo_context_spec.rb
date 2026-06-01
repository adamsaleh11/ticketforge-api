require "rails_helper"

RSpec.describe Github::RepoContext do
  let(:user) { build(:user, github_access_token: "gho_token") }
  let(:repo_url) { "https://api.github.com/repos/octocat/hello-world" }
  let(:tree_url) { "https://api.github.com/repos/octocat/hello-world/git/trees/main?recursive=1" }
  let(:readme_url) { "https://api.github.com/repos/octocat/hello-world/readme" }
  let(:languages_url) { "https://api.github.com/repos/octocat/hello-world/languages" }

  before do
    stub_request(:get, repo_url).to_return(
      status: 200, body: { "default_branch" => "main" }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
    stub_request(:get, readme_url).to_return(status: 404, body: "{}")
    stub_request(:get, languages_url).to_return(
      status: 200, body: {}.to_json, headers: { "Content-Type" => "application/json" }
    )
  end

  def stub_tree(entries, truncated: false)
    stub_request(:get, tree_url).to_return(
      status: 200, body: { "tree" => entries, "truncated" => truncated }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end

  it "caps the tree and flags truncated when more files pass the filter than the cap" do
    over_cap = (described_class::MAX_TREE_ENTRIES + 50).times.map do |i|
      { "path" => "file_#{i}.rb", "type" => "blob", "size" => 10 }
    end
    stub_tree(over_cap)

    result = described_class.build(user, "octocat", "hello-world")

    expect(result[:tree].size).to eq(described_class::MAX_TREE_ENTRIES)
    expect(result[:truncated]).to be(true)
  end
end
