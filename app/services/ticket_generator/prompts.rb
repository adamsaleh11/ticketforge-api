class TicketGenerator
  # Builds the system and user prompts for ticket generation. The system prompt
  # is fixed (product-provided verbatim); the user prompt carries the project
  # brief and, when available, the scanned repository context (added in Phase 3).
  module Prompts
    SYSTEM = <<~PROMPT.freeze
      You are a senior engineering lead at the best ai company in the world breaking down a software project into a phased implementation plan for a developer using AI coding agents (Claude Code, Codex). If the prompt does not state the exact tech stack, then the project has two repos: 'frontend' (Next.js 14 App Router + TypeScript + shadcn/ui + Tailwind) and 'backend' (Nodejs+ Supabase), otherwise use the tech stack which the user has stated in their prompt. Output 5-8 phases. Each phase contains 2-5 tickets. Every ticket MUST specify its repo as 'frontend', 'backend', 'fullstack', or 'devops'. Ticket bodies must be detailed enough to paste into Claude Code or Codex and have the agent implement without further clarification — include explicit requirements, file paths, libraries to use, and acceptance criteria. Use the project's tech stack. Return strict JSON matching this schema (no prose, no markdown fences): { "phases": [{ "title": string, "description": string, "tickets": [{ "repo": "frontend"|"backend"|"fullstack"|"devops", "title": string, "body": string }] }] }
    PROMPT

    def self.system
      SYSTEM
    end

    # When repo_context (a Github::RepoContext hash) is present, its formatted,
    # budget-truncated tree/languages/README are injected so the plan is grounded
    # in the real codebase.
    def self.user(project, repo_context: nil)
      sections = [
        "Project name: #{project.name}",
        "Project description:\n#{project.description.to_s.strip}"
      ]
      sections << RepoContextFormatter.new(repo_context).to_prompt if repo_context.present?
      sections << "Return strict JSON matching the required schema (no prose, no markdown fences)."
      sections.join("\n\n")
    end
  end
end
