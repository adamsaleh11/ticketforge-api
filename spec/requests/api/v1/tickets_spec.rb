require "rails_helper"

RSpec.describe "Api::V1::Tickets", type: :request do
  # Resolve the persisted User the default valid_supabase_jwt maps to, so specs
  # can attach tickets to "the current user".
  let(:current_user) do
    get "/api/v1/me", headers: auth_headers(valid_supabase_jwt)
    User.find_by!(supabase_user_id: "supabase-user-123")
  end

  # A ticket owned by the current user, reachable via project -> phase -> ticket.
  let(:ticket) do
    phase = create(:phase, project: create(:project, user: current_user))
    create(:ticket, phase: phase, status: "pending")
  end

  def patch_ticket(id, params)
    patch "/api/v1/tickets/#{id}", params: params, headers: auth_headers(valid_supabase_jwt)
  end

  describe "PATCH /api/v1/tickets/:id" do
    it "updates the status from pending to in_progress" do
      patch_ticket(ticket.id, ticket: { status: "in_progress" })

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "attributes", "status")).to eq("in_progress")
      expect(ticket.reload.status).to eq("in_progress")
    end

    it "allows moving a done ticket back to in_progress (transitions are not forward-only)" do
      ticket.update!(status: "done")

      patch_ticket(ticket.id, ticket: { status: "in_progress" })

      expect(response).to have_http_status(:ok)
      expect(ticket.reload.status).to eq("in_progress")
    end

    it "returns 422 with a field pointer for an unknown status value" do
      patch_ticket(ticket.id, ticket: { status: "banana" })

      expect(response).to have_http_status(:unprocessable_entity)
      pointers = response.parsed_body["errors"].map { |e| e.dig("source", "pointer") }
      expect(pointers).to include("/data/attributes/status")
      expect(ticket.reload.status).to eq("pending")
    end

    it "returns 422 when status is missing" do
      patch_ticket(ticket.id, ticket: { status: "" })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(ticket.reload.status).to eq("pending")
    end

    it "ignores fields other than status" do
      patch_ticket(ticket.id, ticket: { status: "done", title: "hacked", repo: "frontend" })

      expect(response).to have_http_status(:ok)
      ticket.reload
      expect(ticket.status).to eq("done")
      expect(ticket.title).to eq("Implement the thing")
      expect(ticket.repo).to eq("backend")
    end

    it "returns 404 for another user's ticket without mutating it" do
      other_phase = create(:phase, project: create(:project, user: create(:user)))
      other_ticket = create(:ticket, phase: other_phase, status: "pending")

      patch_ticket(other_ticket.id, ticket: { status: "done" })

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("error" => "not_found")
      expect(other_ticket.reload.status).to eq("pending")
    end

    it "returns 404 for a missing ticket" do
      patch_ticket(0, ticket: { status: "done" })

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("error" => "not_found")
    end

    it "returns 401 without a valid token" do
      patch "/api/v1/tickets/#{ticket.id}", params: { ticket: { status: "done" } }

      expect(response).to have_http_status(:unauthorized)
      expect(ticket.reload.status).to eq("pending")
    end
  end
end
