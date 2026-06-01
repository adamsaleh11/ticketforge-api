require "rails_helper"

# The rejection matrix: every auth failure must return an identical, minimal 401
# so an attacker cannot learn *why* a token was refused.
RSpec.describe "GET /api/v1/me authentication", type: :request do
  let(:canonical_401) { { "error" => "unauthorized" } }

  shared_examples "an unauthorized request" do
    it "responds 401 with the canonical body" do
      get "/api/v1/me", headers: headers

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq(canonical_401)
    end

    it "does not create a user" do
      expect {
        get "/api/v1/me", headers: headers
      }.not_to change(User, :count)
    end
  end

  context "with no Authorization header" do
    let(:headers) { {} }
    it_behaves_like "an unauthorized request"
  end

  context "with a malformed Authorization header" do
    let(:headers) { { "Authorization" => "Token abc.def.ghi" } }
    it_behaves_like "an unauthorized request"
  end

  context "with an expired token" do
    let(:headers) { auth_headers(valid_supabase_jwt(exp: 1.hour.ago.to_i)) }
    it_behaves_like "an unauthorized request"
  end

  context "with a wrong audience" do
    let(:headers) { auth_headers(valid_supabase_jwt(aud: "anon")) }
    it_behaves_like "an unauthorized request"
  end

  context "with a token signed by an untrusted key" do
    let(:headers) do
      rogue_key = OpenSSL::PKey::EC.generate("prime256v1")
      auth_headers(valid_supabase_jwt(key: rogue_key))
    end
    it_behaves_like "an unauthorized request"
  end

  context "with an unsigned token (alg: none)" do
    let(:headers) do
      token = JWT.encode(
        { "sub" => "x", "aud" => "authenticated", "exp" => 1.hour.from_now.to_i },
        nil,
        "none"
      )
      auth_headers(token)
    end
    it_behaves_like "an unauthorized request"
  end
end
