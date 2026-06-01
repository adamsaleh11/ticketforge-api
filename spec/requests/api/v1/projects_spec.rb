require "rails_helper"

RSpec.describe "Api::V1::Projects", type: :request do
  # Resolve the persisted User the default valid_supabase_jwt maps to, so specs
  # can attach projects to "the current user".
  let(:current_user) do
    get "/api/v1/me", headers: auth_headers(valid_supabase_jwt)
    User.find_by!(supabase_user_id: "supabase-user-123")
  end

  describe "GET /api/v1/projects" do
    it "returns the current user's projects newest first" do
      older = create(:project, user: current_user, name: "Older", created_at: 2.days.ago)
      newer = create(:project, user: current_user, name: "Newer", created_at: 1.hour.ago)

      get "/api/v1/projects", headers: auth_headers(valid_supabase_jwt)

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["data"].map { |r| r["id"] }
      expect(ids).to eq([newer.id.to_s, older.id.to_s])
    end

    it "excludes other users' projects" do
      create(:project, user: current_user, name: "Mine")
      create(:project, user: create(:user), name: "Theirs")

      get "/api/v1/projects", headers: auth_headers(valid_supabase_jwt)

      names = response.parsed_body["data"].map { |r| r.dig("attributes", "name") }
      expect(names).to contain_exactly("Mine")
    end

    it "returns 401 without a valid token" do
      get "/api/v1/projects"

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq("error" => "unauthorized")
    end
  end

  describe "GET /api/v1/projects/:id" do
    it "returns the serialized project with stubbed ticket fields" do
      project = create(:project, user: current_user)

      get "/api/v1/projects/#{project.id}", headers: auth_headers(valid_supabase_jwt)

      expect(response).to have_http_status(:ok)
      attributes = response.parsed_body.dig("data", "attributes")
      expect(attributes).to include(
        "name" => project.name,
        "llm_provider" => "groq",
        "status" => "draft",
        "ticket_count" => 0,
        "last_generated_at" => nil
      )
    end

    it "returns 404 for another user's project" do
      other = create(:project, user: create(:user))

      get "/api/v1/projects/#{other.id}", headers: auth_headers(valid_supabase_jwt)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("error" => "not_found")
    end

    it "returns 404 for a missing project" do
      get "/api/v1/projects/0", headers: auth_headers(valid_supabase_jwt)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("error" => "not_found")
    end
  end

  describe "POST /api/v1/projects" do
    let(:valid_params) do
      {
        project: {
          name: "New Project",
          description: "Generate some tickets",
          github_repo_full_name: "shilpatel/myrepo",
          llm_provider: "ollama",
          llm_model: "llama3"
        }
      }
    end

    it "creates a project owned by the current user" do
      expect {
        post "/api/v1/projects", params: valid_params, headers: auth_headers(valid_supabase_jwt)
      }.to change(current_user.projects, :count).by(1)

      expect(response).to have_http_status(:created)
      attributes = response.parsed_body.dig("data", "attributes")
      expect(attributes).to include("name" => "New Project", "llm_provider" => "ollama", "status" => "draft")
    end

    it "ignores a client-supplied status" do
      post "/api/v1/projects",
           params: valid_params.deep_merge(project: { status: "ready" }),
           headers: auth_headers(valid_supabase_jwt)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("data", "attributes", "status")).to eq("draft")
    end

    it "returns 422 with a field pointer for a blank name" do
      post "/api/v1/projects",
           params: valid_params.deep_merge(project: { name: "" }),
           headers: auth_headers(valid_supabase_jwt)

      expect(response).to have_http_status(:unprocessable_entity)
      pointers = response.parsed_body["errors"].map { |e| e.dig("source", "pointer") }
      expect(pointers).to include("/data/attributes/name")
    end

    it "returns 422 for a malformed github_repo_full_name" do
      post "/api/v1/projects",
           params: valid_params.deep_merge(project: { github_repo_full_name: "nope" }),
           headers: auth_headers(valid_supabase_jwt)

      expect(response).to have_http_status(:unprocessable_entity)
      pointers = response.parsed_body["errors"].map { |e| e.dig("source", "pointer") }
      expect(pointers).to include("/data/attributes/github_repo_full_name")
    end

    it "returns 401 without a valid token" do
      post "/api/v1/projects", params: valid_params

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "PATCH /api/v1/projects/:id" do
    it "updates editable fields" do
      project = create(:project, user: current_user, name: "Before")

      patch "/api/v1/projects/#{project.id}",
            params: { project: { name: "After" } },
            headers: auth_headers(valid_supabase_jwt)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "attributes", "name")).to eq("After")
      expect(project.reload.name).to eq("After")
    end

    it "returns 422 for invalid params" do
      project = create(:project, user: current_user)

      patch "/api/v1/projects/#{project.id}",
            params: { project: { name: "" } },
            headers: auth_headers(valid_supabase_jwt)

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 404 for another user's project" do
      other = create(:project, user: create(:user))

      patch "/api/v1/projects/#{other.id}",
            params: { project: { name: "Hijack" } },
            headers: auth_headers(valid_supabase_jwt)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/v1/projects/:id" do
    it "deletes the project with an empty 204 response" do
      project = create(:project, user: current_user)

      expect {
        delete "/api/v1/projects/#{project.id}", headers: auth_headers(valid_supabase_jwt)
      }.to change(current_user.projects, :count).by(-1)

      expect(response).to have_http_status(:no_content)
      expect(response.body).to be_empty
    end

    it "returns 404 for another user's project" do
      other = create(:project, user: create(:user))

      delete "/api/v1/projects/#{other.id}", headers: auth_headers(valid_supabase_jwt)

      expect(response).to have_http_status(:not_found)
      expect(Project.exists?(other.id)).to be(true)
    end
  end
end
