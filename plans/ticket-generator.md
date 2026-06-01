# Plan: TicketGenerator — Phased Engineering Tickets

> Source PRD: docs/prd-ticket-generator.md

## Architectural decisions

Durable decisions that apply across all phases:

- **Routes**: `POST /api/v1/projects/:id/generate`, nested as a `member` action under the
  existing `resources :projects` in `namespace :api { namespace :v1 }`. Every lookup
  scoped through `current_user.projects` — cross-user/missing → `404 { error: "not_found" }`
  (existing `rescue_from`); unauthenticated → existing `401`.
- **Schema**:
  - `phases`: `project_id` (bigint, null: false, FK, indexed), `number` (integer,
    null: false — 1-based human label), `title` (string, null: false), `description`
    (text, null), `position` (integer, null: false — 0-based sort key), timestamps.
    Index `[project_id, position]`.
  - `tickets`: `phase_id` (bigint, null: false, FK, indexed), `repo` (string, null: false),
    `title` (string, null: false), `body` (text, null: false), `position` (integer,
    null: false — 0-based sort), `status` (string, null: false, default `"pending"`),
    timestamps. Index `[phase_id, position]`.
  - Enums string-backed; inclusion enforced at the model layer, no DB CHECK constraints
    (matches `Project`).
- **Key models**:
  - `Phase` — `belongs_to :project`; `has_many :tickets, -> { order(:position) },
    dependent: :destroy`; ordered by `position`.
  - `Ticket` — `belongs_to :phase`; `enum repo: {frontend, backend, fullstack, devops}`,
    `enum status: {pending, in_progress, done}` (default `pending`).
  - `Project` — `has_many :phases, -> { order(:position) }, dependent: :destroy`;
    `has_many :tickets, through: :phases`.
- **Service boundary**: `TicketGenerator.new(project).call` returns a result object
  (success flag + error kind), keeping the controller free of cross-boundary rescues and
  leaving the service job-ready for a future async swap. Status transitions
  (`generating`/`ready`/`failed`) happen **outside** the persistence transaction so a
  `failed` write is never rolled back with the phases.
- **External services**:
  - LLM via existing `LLM::Client.for(provider: project.llm_provider,
    model: project.llm_model, endpoint: project.user.ollama_endpoint)
    .chat(system:, user:, json_mode: true)`. Endpoint ignored by Groq, used by Ollama.
  - GitHub via existing `Github::RepoContext.build(user, owner, repo)` (cached; returns
    `{ tree:, readme:, languages:, truncated: }`). `Github::Error` is rescued — generation
    degrades to a generic plan rather than failing.
- **Prompts**: dedicated prompts module exposing `system` (fixed, product-provided verbatim)
  and `user(project, repo_context:)`. System prompt enforces 5–8 phases, 2–5 tickets,
  mandatory repo tagging, paste-ready bodies, stated-stack-else-default, strict JSON.
- **Error contract**: success → `200` (serialized project with real `ticket_count` /
  `last_generated_at` + nested phases/tickets + repo-context-used flag); LLM unreachable /
  bad HTTP → `502 { error: "generation_failed" }`; malformed JSON / failed structure
  validation → `502 { error: "invalid_generation" }`; in-flight → `409 { error:
  "already_generating" }`. All failures persist `status: "failed"`.
- **Serialization**: new `PhaseSerializer` / `TicketSerializer` (JSONAPI::Serializer);
  `ProjectSerializer` Phase-5 stub fields wired to real data.
- **Timeouts**: request budget 120s (`rack-timeout` / Puma worker timeout); LLM client's
  60s socket timeout made overridable and raised (~110s) for the generate path.

---

## Phase 1: Core generation tracer bullet (brief → plan)

**User stories**: 1, 2, 3, 4, 5, 9, 10, 11, 16, 17

### What to build

The thin, complete happy path from a project brief to a persisted, serialized plan.
Stand up the `Phase` and `Ticket` models + migrations + associations and the
`:phase` / `:ticket` factories. Add the `POST /api/v1/projects/:id/generate` route and
controller action scoped through `current_user.projects`. Implement `TicketGenerator`
covering the success flow: set `status: "generating"`, build the fixed system prompt and a
user prompt from the project's name + description (no repo context yet), call the LLM in
JSON mode, parse the result, validate the structure (5–8 phases, each with 2–5 tickets,
every ticket with a valid `repo` enum), persist phases + tickets in a transaction with
correct `number`/`position`, then set `status: "ready"`. Return `200` with the serialized
project (real `ticket_count` / `last_generated_at`) and its nested phases + tickets via the
new `PhaseSerializer` / `TicketSerializer`. Honor a stated tech stack vs. default purely
through the fixed system prompt.

### Acceptance criteria

- [ ] `POST /projects/:id/generate` with a stubbed valid LLM JSON response returns `200`
      with the project plus nested phases and tickets in the JSON:API envelope.
- [ ] 5–8 `Phase` records and their 2–5 `Ticket` records are created with correct
      `number` (1-based) and `position` (0-based) ordering.
- [ ] Every created ticket has a `repo` within `{frontend, backend, fullstack, devops}`
      and a non-empty `title` and `body`; `status` defaults to `pending`.
- [ ] Project `status` ends as `ready`; `ProjectSerializer` reports the real
      `ticket_count` and a non-null `last_generated_at`.
- [ ] A response that violates the structure contract (too few/many phases or tickets,
      bad repo enum) does not persist a partial plan.
- [ ] The user prompt reflects the project brief; a one-line brief and a detailed brief
      both produce a valid in-bounds plan (stubbed responses).
- [ ] Cross-user generate → `404`; unauthenticated → `401`.
- [ ] Model specs cover associations, string-backed enums, `dependent: :destroy`, and
      presence validations; `:phase` / `:ticket` factories exist.

---

## Phase 2: Robustness, accuracy & lifecycle hardening

**User stories**: 12, 13, 14, 15, 18

### What to build

Harden the proven path. Map every failure mode to its contract status: LLM connection
errors → `502 generation_failed`; malformed JSON or failed structure validation →
`502 invalid_generation`; a project already `generating` → `409 already_generating`
without invoking the LLM. Persist `status: "failed"` outside the transaction on any
failure. Make regeneration safe: existing phases are destroyed only inside the successful
transaction, so a failed regeneration leaves the prior plan intact. Add a single automatic
retry on malformed JSON / failed structure validation before declaring failure. Do the
timeout work: make the LLM client's socket timeout overridable and raise it (~110s) for the
generate path, and configure the 120s request budget (`rack-timeout` / Puma).

### Acceptance criteria

- [ ] Stubbed LLM connection refusal → `502 { error: "generation_failed" }`, project
      `status: "failed"`, no phases persisted.
- [ ] Stubbed malformed JSON (and a malformed retry) → `502 { error: "invalid_generation" }`,
      `status: "failed"`.
- [ ] Stubbed structurally-invalid-but-valid-JSON response → `502 invalid_generation`,
      `status: "failed"`.
- [ ] First stubbed response malformed, second valid → `200` (single retry succeeds).
- [ ] Generating a project already in `generating` → `409`, LLM never called.
- [ ] Regenerating with existing phases + a valid response replaces the old plan; a failed
      regeneration leaves existing phases untouched and sets `status: "failed"`.
- [ ] The LLM call on the generate path uses a timeout above 60s; request budget is 120s.

---

## Phase 3: Repo grounding

**User stories**: 6, 7, 8

### What to build

Ground the plan in a linked repository. When `github_repo_full_name` is present, scan the
repo **before** the LLM call: split into `owner/repo`, call `Github::RepoContext.build`,
truncate the file tree to ~3000 tokens and the README to ~1000 tokens (chars≈tokens×4
heuristic, whole-line cuts, truncation marked), include the languages breakdown, and inject
this as a clearly-delimited repository-context section in the user prompt. Degrade
gracefully: rescue `Github::Error`, continue generation without context, and surface a
"repo context used / skipped" flag in the response.

### Acceptance criteria

- [ ] A project with a linked repo fetches `RepoContext` before the LLM call, and the user
      prompt includes the repo's file tree, languages, and README (stubbed GitHub).
- [ ] Tree and README injection respect the token budgets and mark truncation when cut;
      a large stubbed tree does not blow the prompt.
- [ ] When GitHub fails (stubbed `Github::Error`), generation still returns `200` with a
      valid plan and the response flags that repo context was skipped.
- [ ] A project with no linked repo omits the repository-context section entirely and the
      flag indicates context was not used.
- [ ] Request specs assert the scan-before-generate ordering and the degradation path.
