require "rails_helper"

RSpec.describe "DELETE /api/v1/me", type: :request do
  context "with a valid token" do
    it "returns 204 No Content with an empty body" do
      delete "/api/v1/me", headers: auth_headers(valid_supabase_jwt)

      expect(response).to have_http_status(:no_content)
      expect(response.body).to be_empty
    end

    it "destroys the authenticated user's record" do
      create(:user, supabase_user_id: "supabase-user-123", email: "octocat@example.com")

      expect {
        delete "/api/v1/me", headers: auth_headers(valid_supabase_jwt)
      }.to change(User, :count).by(-1)

      expect(User.find_by(supabase_user_id: "supabase-user-123")).to be_nil
    end

    it "cascades to the user's projects, phases, and tickets" do
      user = create(:user, supabase_user_id: "supabase-user-123", email: "octocat@example.com")
      phase = create(:phase, project: create(:project, user: user))
      create(:ticket, phase: phase)

      delete "/api/v1/me", headers: auth_headers(valid_supabase_jwt)

      expect(Project.count).to eq(0)
      expect(Phase.count).to eq(0)
      expect(Ticket.count).to eq(0)
    end

    it "leaves another user's projects, phases, and tickets untouched" do
      other = create(:user)
      other_phase = create(:phase, project: create(:project, user: other))
      other_ticket = create(:ticket, phase: other_phase)

      delete "/api/v1/me", headers: auth_headers(valid_supabase_jwt)

      expect(User.exists?(other.id)).to be(true)
      expect(Project.exists?(other_phase.project_id)).to be(true)
      expect(Phase.exists?(other_phase.id)).to be(true)
      expect(Ticket.exists?(other_ticket.id)).to be(true)
    end

    it "lets a deleted user be recreated as an empty record on the next request" do
      user = create(:user, supabase_user_id: "supabase-user-123", email: "octocat@example.com")
      create(:project, user: user)

      delete "/api/v1/me", headers: auth_headers(valid_supabase_jwt)

      # The Supabase JWT is still valid, so the next authenticated request
      # recreates the User row (without its old data). Documented MVP behavior.
      get "/api/v1/me", headers: auth_headers(valid_supabase_jwt)

      expect(response).to have_http_status(:ok)
      expect(User.count).to eq(1)
      expect(Project.count).to eq(0)
    end
  end

  context "without a valid token" do
    it "responds 401 with the canonical body and destroys nothing" do
      create(:user, supabase_user_id: "supabase-user-123", email: "octocat@example.com")

      expect {
        delete "/api/v1/me"
      }.not_to change(User, :count)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq("error" => "unauthorized")
    end
  end
end
