class Project < ApplicationRecord
  belongs_to :user

  # String-backed so DB rows stay human-readable. Inclusion is enforced here,
  # not via DB CHECK constraints.
  enum llm_provider: { groq: "groq", ollama: "ollama" }
  enum status: { draft: "draft", generating: "generating", ready: "ready", failed: "failed" }

  validates :name, presence: true, length: { maximum: 255 }
  validates :llm_model, presence: true
  # github_repo_full_name is optional, but when present must look like "owner/repo".
  validates :github_repo_full_name,
            format: { with: %r{\A[\w.-]+/[\w.-]+\z} },
            allow_nil: true
end
