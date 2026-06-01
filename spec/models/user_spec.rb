require "rails_helper"

RSpec.describe User, type: :model do
  describe "ollama_endpoint validation" do
    %w[http://localhost:11434 https://ollama.example.com http://ollama.internal:9999].each do |good|
      it "accepts #{good.inspect}" do
        expect(build(:user, ollama_endpoint: good)).to be_valid
      end
    end

    ["not-a-url", "ftp://ollama", "http://", "  "].each do |bad|
      it "rejects #{bad.inspect}" do
        user = build(:user, ollama_endpoint: bad)
        expect(user).not_to be_valid
        expect(user.errors[:ollama_endpoint]).to include("must be a valid http or https URL")
      end
    end
  end

  describe ".from_supabase_payload" do
    def payload(overrides = {})
      {
        "sub" => "sub-1",
        "email" => "user@example.com",
        "user_metadata" => {
          "full_name" => "Ada Lovelace",
          "user_name" => "ada"
        },
        "app_metadata" => {
          "provider_token" => "gho_from_app_metadata"
        }
      }.merge(overrides)
    end

    it "creates a user and syncs profile fields" do
      user = described_class.from_supabase_payload(payload)

      expect(user).to be_persisted
      expect(user.supabase_user_id).to eq("sub-1")
      expect(user.email).to eq("user@example.com")
      expect(user.name).to eq("Ada Lovelace")
      expect(user.github_username).to eq("ada")
    end

    it "reuses the existing user for the same sub" do
      first = described_class.from_supabase_payload(payload)

      expect {
        described_class.from_supabase_payload(payload)
      }.not_to change(described_class, :count)

      expect(described_class.from_supabase_payload(payload).id).to eq(first.id)
    end

    it "updates changed profile fields on a later token" do
      described_class.from_supabase_payload(payload)

      updated = described_class.from_supabase_payload(
        payload("email" => "new@example.com",
                "user_metadata" => { "full_name" => "Ada B.", "user_name" => "adab" })
      )

      expect(updated.email).to eq("new@example.com")
      expect(updated.name).to eq("Ada B.")
      expect(updated.github_username).to eq("adab")
    end

    it "prefers app_metadata.provider_token over user_metadata" do
      user = described_class.from_supabase_payload(
        payload("user_metadata" => { "provider_token" => "gho_from_user_metadata" })
      )

      expect(user.github_access_token).to eq("gho_from_app_metadata")
    end

    it "falls back to user_metadata.provider_token when app_metadata lacks it" do
      user = described_class.from_supabase_payload(
        payload("app_metadata" => {},
                "user_metadata" => { "provider_token" => "gho_from_user_metadata" })
      )

      expect(user.github_access_token).to eq("gho_from_user_metadata")
    end

    it "preserves a stored token when a later token omits provider_token" do
      described_class.from_supabase_payload(payload)

      refreshed = described_class.from_supabase_payload(
        payload("app_metadata" => {}, "user_metadata" => { "user_name" => "ada" })
      )

      expect(refreshed.github_access_token).to eq("gho_from_app_metadata")
    end

    it "stores the github access token encrypted at rest" do
      user = described_class.from_supabase_payload(payload)

      ciphertext = described_class.connection.select_value(
        "SELECT github_access_token FROM users WHERE id = #{user.id}"
      )
      expect(ciphertext).not_to include("gho_from_app_metadata")
      expect(user.reload.github_access_token).to eq("gho_from_app_metadata")
    end
  end
end
