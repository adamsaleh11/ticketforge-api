require "rails_helper"

RSpec.describe TicketGenerator do
  let(:project) { create(:project, github_repo_full_name: nil) }
  let(:groq_url) { "https://api.groq.com/openai/v1/chat/completions" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("GROQ_API_KEY").and_return("test-groq-key")
  end

  def plan(phases: 5, tickets_per_phase: 2)
    {
      "phases" => Array.new(phases) do |p|
        {
          "title" => "Phase #{p + 1}",
          "description" => "Description #{p + 1}",
          "tickets" => Array.new(tickets_per_phase) do |t|
            { "repo" => "backend", "title" => "T#{p}.#{t}", "body" => "body" }
          end
        }
      end
    }
  end

  def chat_body(content)
    { "choices" => [{ "message" => { "content" => content } }] }.to_json
  end

  def stub_groq(plan_hash)
    stub_request(:post, groq_url).to_return(
      status: 200, body: chat_body(plan_hash.to_json),
      headers: { "Content-Type" => "application/json" }
    )
  end

  describe "success" do
    it "persists a valid plan and reports success" do
      stub_groq(plan(phases: 6, tickets_per_phase: 3))

      result = described_class.new(project).call

      expect(result).to be_success
      expect(project.phases.count).to eq(6)
      expect(project.reload.status).to eq("ready")
    end
  end

  describe "structurally invalid output" do
    it "fails with :invalid_generation, persists nothing, and marks the project failed" do
      stub_groq(plan(phases: 3))

      result = described_class.new(project).call

      expect(result).not_to be_success
      expect(result.error_kind).to eq(:invalid_generation)
      expect(project.phases.count).to eq(0)
      expect(project.reload.status).to eq("failed")
    end
  end

  describe "malformed JSON content" do
    it "fails with :invalid_generation" do
      stub_request(:post, groq_url).to_return(
        status: 200, body: chat_body("not json at all"),
        headers: { "Content-Type" => "application/json" }
      )

      result = described_class.new(project).call

      expect(result.error_kind).to eq(:invalid_generation)
      expect(project.reload.status).to eq("failed")
    end
  end

  describe "LLM unreachable" do
    it "fails with :generation_failed" do
      stub_request(:post, groq_url).to_raise(Errno::ECONNREFUSED)

      result = described_class.new(project).call

      expect(result.error_kind).to eq(:generation_failed)
      expect(project.reload.status).to eq("failed")
    end
  end

  describe "retry on unusable output" do
    it "retries once and succeeds when the second response is valid" do
      stub_request(:post, groq_url)
        .to_return(
          { status: 200, body: chat_body("not json"), headers: { "Content-Type" => "application/json" } },
          { status: 200, body: chat_body(plan.to_json), headers: { "Content-Type" => "application/json" } }
        )

      result = described_class.new(project).call

      expect(result).to be_success
      expect(project.phases.count).to eq(5)
      expect(WebMock).to have_requested(:post, groq_url).twice
    end

    it "gives up after one retry" do
      stub_request(:post, groq_url).to_return(
        status: 200, body: chat_body("still not json"),
        headers: { "Content-Type" => "application/json" }
      )

      result = described_class.new(project).call

      expect(result.error_kind).to eq(:invalid_generation)
      expect(WebMock).to have_requested(:post, groq_url).twice
    end
  end

  describe "already generating" do
    it "refuses to start and never calls the LLM" do
      project.update!(status: "generating")

      result = described_class.new(project).call

      expect(result.error_kind).to eq(:already_generating)
      expect(WebMock).not_to have_requested(:post, groq_url)
    end
  end

  describe "repo grounding" do
    let(:project) { create(:project, github_repo_full_name: "octocat/hello-world") }

    def stub_github(tree: [{ "path" => "app/server.rb", "type" => "blob", "size" => 10 }],
                    readme: "# Hello", languages: { "Ruby" => 100 })
      stub_request(:get, "https://api.github.com/repos/octocat/hello-world")
        .to_return(status: 200, body: { "default_branch" => "main" }.to_json,
                   headers: { "Content-Type" => "application/json" })
      stub_request(:get, "https://api.github.com/repos/octocat/hello-world/git/trees/main?recursive=1")
        .to_return(status: 200, body: { "tree" => tree, "truncated" => false }.to_json,
                   headers: { "Content-Type" => "application/json" })
      stub_request(:get, "https://api.github.com/repos/octocat/hello-world/readme")
        .to_return(status: 200, body: { "content" => Base64.encode64(readme) }.to_json,
                   headers: { "Content-Type" => "application/json" })
      stub_request(:get, "https://api.github.com/repos/octocat/hello-world/languages")
        .to_return(status: 200, body: languages.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "scans the repo and injects its context into the LLM prompt" do
      stub_github(tree: [{ "path" => "app/grounded_file.rb", "type" => "blob", "size" => 10 }])
      stub_groq(plan)

      result = described_class.new(project).call

      expect(result).to be_success
      expect(result.repo_context_used).to be(true)
      expect(WebMock).to have_requested(:post, groq_url)
        .with { |req| req.body.include?("app/grounded_file.rb") }
    end

    it "degrades to a generic plan when the repo scan fails" do
      stub_request(:get, "https://api.github.com/repos/octocat/hello-world")
        .to_return(status: 404, body: "{}")
      stub_groq(plan)

      result = described_class.new(project).call

      expect(result).to be_success
      expect(result.repo_context_used).to be(false)
      expect(project.phases.count).to eq(5)
    end

    it "reports repo_context_used false when no repo is linked" do
      project = create(:project, github_repo_full_name: nil)
      stub_groq(plan)

      result = described_class.new(project).call

      expect(result.repo_context_used).to be(false)
    end
  end

  describe "regeneration safety" do
    it "keeps the existing plan when a regeneration fails" do
      stub_groq(plan(phases: 5))
      described_class.new(project).call
      expect(project.phases.count).to eq(5)

      stub_request(:post, groq_url).to_raise(Errno::ECONNREFUSED)
      result = described_class.new(project).call

      expect(result.error_kind).to eq(:generation_failed)
      expect(project.reload.phases.count).to eq(5)
    end

    it "replaces the existing plan on a successful regeneration" do
      stub_groq(plan(phases: 5))
      described_class.new(project).call

      stub_groq(plan(phases: 7))
      described_class.new(project).call

      expect(project.reload.phases.count).to eq(7)
    end
  end
end
