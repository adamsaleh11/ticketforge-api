# Turns a project brief into a phased plan of engineering tickets via the LLM,
# then persists the result. Returns a Result so the controller maps outcomes
# without rescuing across the service boundary. Status transitions happen
# outside the persistence transaction so a failed write is never rolled back
# with the phases.
class TicketGenerator
  # Raised when the LLM returns JSON that breaks the structural contract
  # (phase/ticket counts or repo enum). Maps to :invalid_generation.
  class InvalidStructure < StandardError; end

  # One retry for content-level failures: a model that returns non-JSON or a
  # structurally wrong plan often succeeds on a second ask. Connection failures
  # are not retried here (LLM::Client already retries sockets once).
  MAX_ATTEMPTS = 2

  # Socket timeout for the generation call. Raised above the client's 60s
  # default (but kept under the 120s request budget) so a valid-but-slow model
  # response is not killed mid-flight.
  LLM_TIMEOUT = 110

  Result = Struct.new(:success, :error_kind, :repo_context_used, keyword_init: true) do
    def success?
      success
    end
  end

  def initialize(project)
    @project = project
    @repo_context_used = false
  end

  def call
    return Result.new(success: false, error_kind: :already_generating) if @project.generating?

    @project.update!(status: "generating")
    @repo_context = fetch_repo_context # scanned before the LLM call
    plan = fetch_valid_plan
    persist!(plan)
    @project.update!(
      status: "ready",
      ticket_count: @project.tickets.count,
      last_generated_at: Time.current
    )
    Result.new(success: true, repo_context_used: @repo_context_used)
  rescue LLM::ConnectionError
    failed!(:generation_failed)
  rescue LLM::InvalidResponseError, InvalidStructure
    failed!(:invalid_generation)
  end

  private

  # Scans the linked GitHub repo so the plan can be grounded in the real
  # codebase. The scan is an enhancement, not a hard dependency: any
  # Github::Error degrades to a generic (contextless) plan.
  def fetch_repo_context
    return nil if @project.github_repo_full_name.blank?

    owner, repo = @project.github_repo_full_name.split("/", 2)
    context = Github::RepoContext.build(@project.user, owner, repo)
    @repo_context_used = true
    context
  rescue Github::Error
    @repo_context_used = false
    nil
  end

  # Asks the LLM for a plan and validates its structure, retrying once on
  # content-level failures. Raises the final failure if retries are exhausted.
  def fetch_valid_plan
    attempts = 0
    begin
      attempts += 1
      plan = request_plan
      Validator.new(plan).validate!
      plan
    rescue LLM::InvalidResponseError, InvalidStructure
      retry if attempts < MAX_ATTEMPTS
      raise
    end
  end

  def request_plan
    client.chat(
      system: Prompts.system,
      user: Prompts.user(@project, repo_context: @repo_context),
      json_mode: true
    )
  end

  def client
    LLM::Client.for(
      provider: @project.llm_provider,
      model: @project.llm_model,
      endpoint: @project.user.ollama_endpoint,
      timeout: LLM_TIMEOUT
    )
  end

  def persist!(plan)
    Project.transaction do
      @project.phases.destroy_all

      Array(plan["phases"]).each_with_index do |phase_attrs, p_index|
        phase = @project.phases.create!(
          number: p_index + 1,
          position: p_index,
          title: phase_attrs["title"],
          description: phase_attrs["description"]
        )

        Array(phase_attrs["tickets"]).each_with_index do |ticket_attrs, t_index|
          phase.tickets.create!(
            position: t_index,
            repo: ticket_attrs["repo"],
            title: ticket_attrs["title"],
            body: ticket_attrs["body"]
          )
        end
      end
    end
  end

  def failed!(kind)
    @project.update!(status: "failed")
    Result.new(success: false, error_kind: kind, repo_context_used: @repo_context_used)
  end
end
