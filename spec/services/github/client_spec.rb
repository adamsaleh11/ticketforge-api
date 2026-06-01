require "rails_helper"

RSpec.describe Github::Client do
  let(:user) { build(:user, github_access_token: "gho_token") }
  let(:client) { described_class.new(user) }
  let(:repos_url) { "https://api.github.com/user/repos?sort=updated&per_page=100" }

  it "returns the parsed body on success" do
    stub_request(:get, repos_url).to_return(
      status: 200, body: [{ "name" => "r" }].to_json,
      headers: { "Content-Type" => "application/json" }
    )

    expect(client.repos).to eq([{ "name" => "r" }])
  end

  it "raises UnauthorizedError on 401" do
    stub_request(:get, repos_url).to_return(status: 401, body: "{}")

    expect { client.repos }.to raise_error(Github::UnauthorizedError)
  end

  it "raises NotFoundError on 404" do
    stub_request(:get, repos_url).to_return(status: 404, body: "{}")

    expect { client.repos }.to raise_error(Github::NotFoundError)
  end

  it "raises NotFoundError on 403 (inaccessible private resource)" do
    stub_request(:get, repos_url).to_return(status: 403, body: "{}")

    expect { client.repos }.to raise_error(Github::NotFoundError)
  end

  it "raises InvalidResponseError on an unexpected non-2xx status" do
    stub_request(:get, repos_url).to_return(status: 500, body: "boom")

    expect { client.repos }.to raise_error(Github::InvalidResponseError)
  end

  it "retries once then raises ConnectionError on a persistent socket failure" do
    stub_request(:get, repos_url).to_raise(Errno::ECONNREFUSED)

    expect { client.repos }.to raise_error(Github::ConnectionError)
    expect(WebMock).to have_requested(:get, repos_url).twice
  end

  it "raises UnauthorizedError before any request when the token is blank" do
    blank = described_class.new(build(:user, github_access_token: nil))

    expect { blank.repos }.to raise_error(Github::UnauthorizedError)
    expect(WebMock).not_to have_requested(:get, repos_url)
  end
end
