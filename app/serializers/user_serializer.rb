class UserSerializer
  include JSONAPI::Serializer

  # Note: github_access_token is intentionally never exposed.
  attributes :supabase_user_id, :email, :name, :github_username,
             :ollama_endpoint, :created_at, :updated_at
end
