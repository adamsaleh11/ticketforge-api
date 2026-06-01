require "rails_helper"

RSpec.describe "POST /api/v1/settings/ollama/test", type: :request do
  let(:endpoint) { "http://localhost:11434" } # the factory/default user's saved endpoint
  let(:tags_url) { "#{endpoint}/api/tags" }

  def tags_response(*names)
    { "models" => names.map { |n| { "name" => n, "model" => n } } }
  end

  it "reports connected with the installed model names when Ollama responds" do
    stub_request(:get, tags_url).to_return(
      status: 200,
      body: tags_response("llama3:latest", "qwen2:7b").to_json,
      headers: { "Content-Type" => "application/json" }
    )

    post "/api/v1/settings/ollama/test", headers: auth_headers(valid_supabase_jwt)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(
      "connected" => true,
      "models" => ["llama3:latest", "qwen2:7b"]
    )
    expect(WebMock).to have_requested(:get, tags_url)
  end

  it "reports not connected on a timeout" do
    stub_request(:get, tags_url).to_timeout

    post "/api/v1/settings/ollama/test", headers: auth_headers(valid_supabase_jwt)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["connected"]).to be(false)
    expect(response.parsed_body["error"]).to be_present
  end

  it "reports not connected when the connection is refused" do
    stub_request(:get, tags_url).to_raise(Errno::ECONNREFUSED)

    post "/api/v1/settings/ollama/test", headers: auth_headers(valid_supabase_jwt)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["connected"]).to be(false)
  end

  it "reports not connected on a non-2xx response" do
    stub_request(:get, tags_url).to_return(status: 500, body: "boom")

    post "/api/v1/settings/ollama/test", headers: auth_headers(valid_supabase_jwt)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["connected"]).to be(false)
  end

  it "tests the user's saved custom endpoint" do
    custom = "http://ollama.internal:9999"
    User.from_supabase_payload("sub" => "supabase-user-123", "email" => "octocat@example.com")
        .update!(ollama_endpoint: custom)
    stub_request(:get, "#{custom}/api/tags").to_return(
      status: 200, body: tags_response("llama3").to_json,
      headers: { "Content-Type" => "application/json" }
    )

    post "/api/v1/settings/ollama/test", headers: auth_headers(valid_supabase_jwt)

    expect(WebMock).to have_requested(:get, "#{custom}/api/tags")
    expect(response.parsed_body["models"]).to eq(["llama3"])
  end

  it "rejects an unauthenticated request with 401" do
    post "/api/v1/settings/ollama/test"

    expect(response).to have_http_status(:unauthorized)
  end
end
