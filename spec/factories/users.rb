FactoryBot.define do
  factory :user do
    sequence(:supabase_user_id) { |n| "supabase-user-#{n}" }
    sequence(:email) { |n| "user#{n}@example.com" }
    name { "Test User" }
    github_username { "testuser" }
    github_access_token { "gho_test_token" }
  end
end
