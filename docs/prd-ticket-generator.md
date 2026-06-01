# PRD: TicketGenerator — Phased Engineering Tickets

> Feature owner: TicketForge API (Rails) · Phase 5
> Source endpoint: `POST /api/v1/projects/:id/generate`

## Problem Statement

A TicketForge user has created a project (name, description, optional linked GitHub
repo, chosen LLM provider/model) but the project is inert — `status: "draft"` with
zero tickets. The whole point of the product is to turn a project idea into a
**phased implementation plan of copy-paste-ready engineering tickets** the user can
hand to Claude Code or Codex. Today there is no way to produce that plan.

Two things make this hard and are the heart of this work:

1. **Accuracy across a wide complexity range.** Users will describe everything from a
   one-line idea ("a to-do app") to a richly-specified multi-service system with an
   explicit tech stack. The generated plan must be *useful and correct in both cases*:
   never collapse a complex brief into three vague phases, never bloat a trivial idea
   into busywork, always respect a stated tech stack, and sensibly default the stack
   when none is given.
2. **Grounding in a real repository.** When the user links a GitHub repo, the plan must
   be written *against their actual codebase* — real file paths, the real languages,
   the real README — not a generic guess. This means the repo must be **scanned first**
   and its context injected into the prompt before the LLM is asked for a plan.

This must run on the Render free tier: no background workers, no Redis. Generation is
therefore synchronous within a single request.

## Solution

From the user's perspective:

- On a project they own, the user triggers generation. The request runs synchronously
  and, when it succeeds, returns the **complete phased plan in one payload**: 5–8
  phases, each containing 2–5 tickets, every ticket tagged with a repo type
  (`frontend` / `backend` / `fullstack` / `devops`) and carrying a title plus a
  detailed, paste-ready body (explicit requirements, file paths, libraries, acceptance
  criteria).
- The project's `status` moves `draft/ready → generating → ready` on success, or
  `→ failed` on any error. Re-triggering while a generation is already in flight is
  rejected, not duplicated.
- **If the project has a linked GitHub repo, that repo is scanned first.** The plan is
  grounded in the repo's actual file tree, language breakdown, and README. If the scan
  cannot be completed (dead token, repo gone, GitHub down), generation still succeeds
  but produces a *generic* plan, and the response signals that repo context was
  skipped so the UI can tell the user.
- **The plan tracks the user's brief faithfully.** A stated tech stack is honored. No
  stated stack falls back to the documented default (Next.js frontend + Node/Supabase
  backend). Simple briefs yield lean, correct plans; complex briefs yield proportionally
  richer ones — always within the 5–8 phase / 2–5 ticket envelope.
- **Regeneration is safe.** Running generation again replaces the old plan only if the
  new generation succeeds; a failed regeneration leaves the previous plan intact.

## User Stories

1. As a user, I want to generate a phased plan from my project's description, so that I
   get actionable engineering tickets I can paste into an AI coding agent.
2. As a user with a one-line idea, I want the generator to produce a coherent,
   reasonably-scoped plan, so that I'm not blocked by having to over-specify upfront.
3. As a user with a detailed, multi-service brief, I want the plan to reflect that
   complexity across distinct phases, so that nothing important is flattened away.
4. As a user who stated an explicit tech stack in my description, I want the plan to use
   *that* stack, so that the tickets match the technologies I've chosen.
5. As a user who gave no tech stack, I want a sensible default stack applied, so that the
   tickets are still concrete and implementable.
6. As a user who linked a GitHub repo, I want the plan grounded in my actual codebase
   (real file paths, languages, README), so that the tickets fit my existing project
   rather than a generic template.
7. As a user with a large monorepo, I want the repo scan to stay within the LLM's
   context budget, so that generation still works and isn't dominated by irrelevant files.
8. As a user whose GitHub token is dead or repo is unavailable, I want generation to
   still produce a (generic) plan and tell me the repo wasn't used, so that I'm not hard-
   blocked and I understand why the plan ignores my code.
9. As a user, I want each ticket to be detailed enough to implement without follow-up
   questions, so that I can hand it straight to Claude Code / Codex.
10. As a user, I want each ticket labeled with its repo type, so that the frontend can
    show the correct repo badge and I know where the work lives.
11. As a user, I want to see my project move to a "generating" then "ready" state, so
    that the dashboard reflects reality.
12. As a user, I want a clear, distinct error when the LLM is unreachable vs. when it
    returns an unusable plan, so that I know whether to retry or change my model.
13. As a user on local Ollama, I want generation to wait long enough for my (slower)
    model to respond, so that a valid-but-slow response isn't killed prematurely.
14. As a user, I want re-running generation to be safe — replacing the plan only on
    success — so that a failed retry never wipes out my existing tickets.
15. As a user, I want a second simultaneous generate click to be rejected rather than
    running twice, so that I don't pay for or trigger duplicate work.
16. As a user, I want generation scoped to my own projects, so that I can't generate
    against (or even discover) another user's project.
17. As a user, I want my dashboard to show an accurate ticket count and last-generated
    timestamp after generating, so that project list state is trustworthy.
18. As a user, I want a failed generation to leave the project in a `failed` state with a
    clear path to regenerate, so that I'm never stuck.

## Implementation Decisions

### Data model

- New `Phase` model: belongs to `Project`; fields `number` (1-based human label),
  `title`, `description`, `position` (0-based sort key). Ordered by `position`.
- New `Ticket` model: belongs to `Phase`; fields `repo` (enum:
  `frontend`/`backend`/`fullstack`/`devops`), `title`, `body`, `position` (0-based sort),
  `status` (enum: `pending`/`in_progress`/`done`, default `pending`). Ordered by `position`.
- `Project has_many :phases` (ordered, `dependent: :destroy`) and
  `has_many :tickets, through: :phases`. `Phase has_many :tickets` (ordered,
  `dependent: :destroy`).
- All enums are **string-backed**, inclusion enforced at the model layer (no Postgres
  enums, no DB CHECK constraints) — matching the existing `Project` convention.
- Foreign keys and supporting indexes on `phases(project_id, position)` and
  `tickets(phase_id, position)`.

### Generation service

- `TicketGenerator.new(project).call` orchestrates the whole flow and returns a **result
  object** (success flag + error kind), so the controller maps outcomes without rescuing
  across the service boundary.
- Status lifecycle is managed **outside** the persistence transaction so a `failed`
  write is never rolled back with the phases:
  1. Set `status: "generating"` (standalone, committed).
  2. Build prompts, scan repo (if linked), call LLM, parse, validate — no DB writes.
  3. In a single transaction: destroy existing phases, then create new phases + tickets.
  4. Set `status: "ready"` after commit. Any failure in 2–3 → `status: "failed"`.
- **Repo scanning happens first**, before the LLM call, when `github_repo_full_name` is
  present: split into `owner/repo`, call the existing `Github::RepoContext.build(user,
  owner, repo)` (which is cached and returns file tree, README, languages, truncated
  flag). A `Github::Error` is rescued — generation continues without context and records
  that context was skipped.
- **Context is truncated to budget** before injection: file tree to ~3000 tokens, README
  to ~1000 tokens, using a chars≈tokens×4 heuristic, cutting on whole lines and marking
  truncation. Languages breakdown is included.
- LLM is invoked via the existing factory:
  `LLM::Client.for(provider: project.llm_provider, model: project.llm_model,
  endpoint: project.user.ollama_endpoint).chat(system:, user:, json_mode: true)`.
  The endpoint is ignored by the Groq client and consumed by the Ollama client.

### Prompts

- A dedicated prompts module exposes `system` and `user(project, repo_context:)`.
- The **system prompt is fixed** (provided verbatim by product): senior-eng-lead persona,
  5–8 phases, 2–5 tickets each, mandatory repo tagging, paste-ready ticket bodies,
  honor a stated tech stack else default to Next.js frontend + Node/Supabase backend,
  strict JSON schema, no prose/markdown fences.
- The **user prompt** carries the project name + description (the user's brief) and, when
  present, a clearly-delimited repository-context section (truncated tree, languages,
  truncated README), plus a restatement of the strict-JSON requirement.

### Accuracy & robustness

- Generation uses **JSON mode** end to end; the response is parsed as JSON.
- **Structure validation** enforces the contract that drives accuracy: top-level `phases`
  is an array of 5–8; each phase has a string title/description and 2–5 tickets; each
  ticket has a string title/body and a `repo` within the enum. First violation fails the
  generation as an "invalid generation."
- **One automatic retry** on malformed JSON or failed structure validation before
  declaring failure — a single re-ask materially improves reliability, especially for
  weaker/local models, without unbounded cost or latency.

### API contract

- `POST /api/v1/projects/:id/generate`, scoped through `current_user.projects`
  (cross-user/missing → 404, matching existing project routes). Nested as a `member`
  route under the existing `resources :projects`.
- Success → `200` with the serialized project (with **real** `ticket_count` and
  `last_generated_at`, replacing the current Phase-5 stubs) plus its nested phases and
  tickets, and a flag indicating whether repo context was used.
- LLM unreachable / bad upstream HTTP → `502 { error: "generation_failed" }`.
- Malformed JSON / failed structure validation (after the retry) →
  `502 { error: "invalid_generation" }` — the upstream model's fault, not the client's,
  so not a 422.
- Already generating → `409 { error: "already_generating" }`; the LLM is never called.
- All failure cases persist `status: "failed"`.
- New `PhaseSerializer` and `TicketSerializer` (JSONAPI::Serializer); `ProjectSerializer`
  computed fields wired to real data.

### Timeouts

- Request budget is 120s (app-level via `rack-timeout`/Puma worker timeout).
- The existing LLM client's 60s socket timeout is **raised for the generate path**
  (overridable timeout, ~110s) so a valid-but-slow Groq/Ollama response is not killed
  before the request budget is reached. This is the one change touching existing
  (`LLM::Client`) code.

## Testing Decisions

Good tests here exercise **external behavior and contracts** with the LLM (and GitHub)
boundaries stubbed via WebMock — mirroring the existing request-spec and
`Github::RepoContext` spec style. No assertions on private service internals.

Request specs for `POST /generate`:
- **Happy path:** stubbed valid LLM JSON → `200`, 5–8 phases with tickets created,
  correct `number`/`position`, `status: "ready"`.
- **Malformed JSON:** non-JSON content (after retry also bad) → `502 invalid_generation`,
  `status: "failed"`, no phases persisted.
- **Structure validation failure:** valid JSON but too few phases / a bad repo enum →
  `502 invalid_generation`, `status: "failed"`.
- **Retry success:** first stubbed response malformed, second valid → `200` (proves the
  single retry).
- **LLM connection error:** stubbed connection refusal → `502 generation_failed`,
  `status: "failed"`.
- **Already generating:** project pre-set to `generating` → `409`, LLM never invoked.
- **Regeneration:** existing phases + valid response → old phases replaced; failed
  regeneration leaves existing phases intact.
- **Repo grounding:** project with linked repo + stubbed GitHub → repo context is
  fetched before the LLM call and injected into the user prompt.
- **Repo degradation:** linked repo but GitHub stubbed to fail → generation still
  succeeds (`200`) with the "context skipped" flag set.
- **No tech stack vs. stated stack:** assert the user prompt reflects the brief (stack
  honored when present); system prompt handles the default.
- **Auth scoping:** cross-user → `404`; unauthenticated → `401`.

Unit/model specs:
- `Phase` / `Ticket`: associations, string-backed enums, `dependent: :destroy`,
  presence validations.
- Prompt builder: user prompt includes brief; includes repo section only when context
  present; truncation respects budget and marks truncation.
- Structure validator: accepts in-bounds plans, rejects each out-of-bounds case.
- New factories `:phase` and `:ticket`.

## Out of Scope

- Asynchronous generation (background jobs, Redis, polling/streaming, real progress
  reporting). The service is built job-ready so this is a cheap later swap, but it is not
  part of this work.
- Editing, reordering, or per-ticket status transitions via the API (the `status` column
  exists for future use; no endpoints to mutate it here).
- Per-phase or per-ticket regeneration; only whole-project regeneration is supported.
- Frontend implementation (loading copy, error UI, badges). This PRD defines the contract
  the frontend will consume.
- Caching or reuse of prior LLM generations; RLS (auth remains in Rails).

## Further Notes

- **Synchronous is a deliberate free-tier constraint**, not a preference. The 120s
  blocking wait with no real progress feedback is the known UX cost; the first upgrade
  once a paid worker + Redis are available is moving `TicketGenerator` behind a job.
- **Ollama users** will feel slowness and malformed-output risk most; the retry and the
  raised timeout are the mitigations within this scope.
- **Silent repo degradation** is intentional (don't hard-block on GitHub), but the
  response flag is what keeps it from being invisible to the user — the frontend should
  surface it.
- Open question for the frontend phase (not blocking this PRD): exact copy/affordance for
  the "generated without repo context" signal and the two distinct 502 error states.
