class ProjectSerializer
  include JSONAPI::Serializer

  attributes :name, :description, :github_repo_full_name, :llm_provider,
             :llm_model, :status, :created_at, :updated_at

  # TODO(Phase 5): replace with project.tickets.count once Ticket model ships.
  attribute :ticket_count do |_project|
    0
  end

  # TODO(Phase 5): replace with project.tickets.maximum(:updated_at) once Ticket model ships.
  attribute :last_generated_at do |_project|
    nil
  end
end
