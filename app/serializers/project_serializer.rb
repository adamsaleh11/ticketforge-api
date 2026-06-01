class ProjectSerializer
  include JSONAPI::Serializer

  # ticket_count / last_generated_at are denormalized columns maintained by
  # TicketGenerator, so listing projects never runs per-project COUNT/MAX.
  attributes :name, :description, :github_repo_full_name, :llm_provider,
             :llm_model, :status, :ticket_count, :last_generated_at,
             :created_at, :updated_at

  # lazy_load_data: linkage (and the phase id pluck) is only emitted when the
  # caller passes include: %i[phases ...] — i.e. the generate response — never
  # on the index/show hot paths.
  has_many :phases, serializer: PhaseSerializer, lazy_load_data: true
end
