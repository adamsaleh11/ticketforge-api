FactoryBot.define do
  factory :project do
    user
    sequence(:name) { |n| "Project #{n}" }
    description { "A project that generates phased engineering tickets." }
    github_repo_full_name { "octocat/hello-world" }
    llm_provider { "groq" }
    llm_model { "llama-3.3-70b-versatile" }
    status { "draft" }
  end
end
