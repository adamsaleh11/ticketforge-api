require "rails_helper"

RSpec.describe "Api::V1::Projects generate", type: :request do
  let(:current_user) do
    get "/api/v1/me", headers: auth_headers(valid_supabase_jwt)
    User.find_by!(supabase_user_id: "supabase-user-123")
  end

  let(:groq_url) { "https://api.groq.com/openai/v1/chat/completions" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("GROQ_API_KEY").and_return("test-groq-key")
  end

  # Build a structurally valid plan: `phases` of `tickets`. Defaults satisfy the
  # 5-8 phases / 2-5 tickets contract.
  def plan(phases: 5, tickets_per_phase: 2)
    {
      "phases" => Array.new(phases) do |p|
        {
          "title" => "Phase #{p + 1}",
          "description" => "Description #{p + 1}",
          "tickets" => Array.new(tickets_per_phase) do |t|
            {
              "repo" => %w[frontend backend fullstack devops][t % 4],
              "title" => "Ticket #{p + 1}.#{t + 1}",
              "body" => "Do the work for #{p + 1}.#{t + 1}"
            }
          end
        }
      end
    }
  end

  def stub_groq_plan(plan_hash = plan)
    stub_request(:post, groq_url).to_return(
      status: 200,
      body: { "choices" => [{ "message" => { "content" => plan_hash.to_json } }] }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end

  def generate(project)
    post "/api/v1/projects/#{project.id}/generate", headers: auth_headers(valid_supabase_jwt)
  end

  describe "POST /api/v1/projects/:id/generate" do
    it "generates and persists a phased plan and returns 200" do
      stub_groq_plan
      project = create(:project, user: current_user, github_repo_full_name: nil)

      generate(project)

      expect(response).to have_http_status(:ok)
      expect(project.reload.status).to eq("ready")
      expect(project.phases.count).to eq(5)
      expect(project.tickets.count).to eq(10)
    end

    it "assigns 1-based number, 0-based position, and valid repo/status to records" do
      stub_groq_plan
      project = create(:project, user: current_user, github_repo_full_name: nil)

      generate(project)

      phases = project.reload.phases
      expect(phases.map(&:number)).to eq([1, 2, 3, 4, 5])
      expect(phases.map(&:position)).to eq([0, 1, 2, 3, 4])

      first_phase = phases.first
      expect(first_phase.tickets.map(&:position)).to eq([0, 1])
      expect(first_phase.tickets.map(&:repo)).to all(be_in(%w[frontend backend fullstack devops]))
      expect(first_phase.tickets.map(&:status)).to all(eq("pending"))
    end

    it "returns the project with its nested phases and tickets" do
      stub_groq_plan
      project = create(:project, user: current_user, github_repo_full_name: nil)

      generate(project)

      types = response.parsed_body["included"].map { |r| r["type"] }
      expect(types).to include("phase", "ticket")
      attributes = response.parsed_body.dig("data", "attributes")
      expect(attributes).to include("status" => "ready", "ticket_count" => 10)
      expect(attributes["last_generated_at"]).to be_present
    end

    it "grounds the plan in the linked repo and flags repo_context_used in meta" do
      stub_request(:get, "https://api.github.com/repos/octocat/hello-world")
        .to_return(status: 200, body: { "default_branch" => "main" }.to_json,
                   headers: { "Content-Type" => "application/json" })
      stub_request(:get, "https://api.github.com/repos/octocat/hello-world/git/trees/main?recursive=1")
        .to_return(status: 200,
                   body: { "tree" => [{ "path" => "app/grounded.rb", "type" => "blob", "size" => 5 }],
                           "truncated" => false }.to_json,
                   headers: { "Content-Type" => "application/json" })
      stub_request(:get, "https://api.github.com/repos/octocat/hello-world/readme")
        .to_return(status: 200, body: { "content" => Base64.encode64("# Readme") }.to_json,
                   headers: { "Content-Type" => "application/json" })
      stub_request(:get, "https://api.github.com/repos/octocat/hello-world/languages")
        .to_return(status: 200, body: { "Ruby" => 1 }.to_json,
                   headers: { "Content-Type" => "application/json" })
      stub_groq_plan
      project = create(:project, user: current_user, github_repo_full_name: "octocat/hello-world")

      generate(project)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("meta", "repo_context_used")).to be(true)
      expect(WebMock).to have_requested(:post, groq_url)
        .with { |req| req.body.include?("app/grounded.rb") }
    end

    it "still succeeds with repo_context_used false when the repo scan fails" do
      stub_request(:get, "https://api.github.com/repos/octocat/hello-world")
        .to_return(status: 404, body: "{}")
      stub_groq_plan
      project = create(:project, user: current_user, github_repo_full_name: "octocat/hello-world")

      generate(project)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("meta", "repo_context_used")).to be(false)
    end

    it "returns 404 for another user's project without calling the LLM" do
      other = create(:project, user: create(:user))

      post "/api/v1/projects/#{other.id}/generate", headers: auth_headers(valid_supabase_jwt)

      expect(response).to have_http_status(:not_found)
      expect(WebMock).not_to have_requested(:post, groq_url)
    end

    it "returns 401 without a valid token" do
      project = create(:project, user: current_user)

      post "/api/v1/projects/#{project.id}/generate"

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 502 generation_failed when the LLM is unreachable" do
      stub_request(:post, groq_url).to_raise(Errno::ECONNREFUSED)
      project = create(:project, user: current_user, github_repo_full_name: nil)

      generate(project)

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body).to eq("error" => "generation_failed")
      expect(project.reload.status).to eq("failed")
    end

    it "returns 502 invalid_generation when the model returns malformed JSON" do
      stub_request(:post, groq_url).to_return(
        status: 200,
        body: { "choices" => [{ "message" => { "content" => "not json" } }] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
      project = create(:project, user: current_user, github_repo_full_name: nil)

      generate(project)

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body).to eq("error" => "invalid_generation")
    end

    it "returns 502 invalid_generation when the plan breaks the structure contract" do
      stub_groq_plan(plan(phases: 3))
      project = create(:project, user: current_user, github_repo_full_name: nil)

      generate(project)

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body).to eq("error" => "invalid_generation")
    end

    it "returns 409 when a generation is already in flight" do
      project = create(:project, user: current_user, status: "generating")

      generate(project)

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to eq("error" => "already_generating")
      expect(WebMock).not_to have_requested(:post, groq_url)
    end
  end
end
