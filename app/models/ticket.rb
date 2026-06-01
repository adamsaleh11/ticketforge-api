class Ticket < ApplicationRecord
  belongs_to :phase

  # String-backed enums, inclusion enforced here (no DB CHECK), matching Project.
  enum repo: { frontend: "frontend", backend: "backend", fullstack: "fullstack", devops: "devops" }
  enum status: { pending: "pending", in_progress: "in_progress", done: "done" }

  validates :title, :body, presence: true
  validates :position, presence: true
end
