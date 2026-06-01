# Implementation Handoff Contract

## 1. Summary

- **What:** Two API behaviors for the post-generation ticket loop — (a) `GET /api/v1/projects/:id` now embeds the full board (phases with nested tickets); (b) a new `PATCH /api/v1/tickets/:id` that updates a ticket's `status` only.
- **Why:** After generation, the frontend had no endpoint to re-read the board (only the one-time `POST /generate` response carried it) and no way to mutate a ticket's `status`. This unblocks "open a project, see your tickets, check them off."
- **In scope:** Embedding phases+tickets on project detail; status-only ticket updates with unconstrained transitions; user-scoped authorization; request specs.
- **Out of scope:** Editing ticket content (title/body/repo) or position; reordering; phase mutations; bulk updates; forward-only status enforcement; project progress aggregates; pagination; param-gated/sparse includes.
- **Owner:** `ticketforge-api` (Rails 7 API-only), module `Api::V1`.

## 2. Files Added or Changed

| File | Change | Purpose |
|------|--------|---------|
| `app/controllers/api/v1/projects_controller.rb` | updated | `#show` eager-loads `phases: :tickets` and serializes with `include: %i[phases phases.tickets]`. `find_project` left lean (other actions don't load the graph). |
| `app/controllers/api/v1/tickets_controller.rb` | created | `#update` — status-only ticket update, user-scoped via phase→project join, 422 on invalid status. |
| `config/routes.rb` | updated | Added `resources :tickets, only: %i[update]` inside `namespace :api / :v1` (flat `/api/v1/tickets/:id`). |
| `spec/requests/api/v1/projects_spec.rb` | updated | Added `GET /:id` cases: nested ordered board, empty board, bounded queries (no N+1). |
| `spec/requests/api/v1/tickets_spec.rb` | created | 8 request specs for `PATCH /api/v1/tickets/:id`. |

Pre-existing (relied on, not changed by this work): `app/serializers/project_serializer.rb`, `phase_serializer.rb`, `ticket_serializer.rb`, `app/models/{project,phase,ticket}.rb`, `app/controllers/application_controller.rb`, `app/controllers/concerns/authenticatable.rb`.

## 3. Public Interface Contract

### Interface A — `GET /api/v1/projects/:id`

- **Type:** HTTP endpoint (existing route, behavior changed) · **Owner:** `Api::V1::ProjectsController#show`
- **Purpose:** Return one project with its phases and tickets embedded, for rendering the board.
- **Inputs:** Path param `:id`. Header `Authorization: Bearer <supabase-jwt>` (required).
- **Outputs:** JSON:API document. `data` = `project` resource; `included` = `phase` and `ticket` resources. Phases ordered by `position`; tickets ordered by `position` within each phase.
- **Status codes:**
  - `200` — success (board embedded; empty board if no phases).
  - `404` — `{ "error": "not_found" }` for a missing or non-owned project.
  - `401` — `{ "error": "unauthorized" }` for missing/invalid token.
- **Example output (abridged):**
  ```json
  {
    "data": {
      "id": "12", "type": "project",
      "attributes": { "name": "...", "status": "ready", "ticket_count": 10, "last_generated_at": "..." },
      "relationships": { "phases": { "data": [{ "id": "3", "type": "phase" }] } }
    },
    "included": [
      { "id": "3", "type": "phase", "attributes": { "number": 1, "title": "...", "description": "...", "position": 0 },
        "relationships": { "tickets": { "data": [{ "id": "7", "type": "ticket" }] } } },
      { "id": "7", "type": "ticket", "attributes": { "repo": "backend", "title": "...", "body": "...", "position": 0, "status": "pending" } }
    ]
  }
  ```
- **Empty board:** `data.relationships.phases.data == []` and `included == []`.

### Interface B — `PATCH /api/v1/tickets/:id`

- **Type:** HTTP endpoint (new) · **Owner:** `Api::V1::TicketsController#update`
- **Purpose:** Update a ticket's `status`. Transitions are **unconstrained** (any value → any value, including `done → in_progress`).
- **Inputs:**
  - Path param `:id`.
  - Header `Authorization: Bearer <supabase-jwt>` (required).
  - Body: `{ "ticket": { "status": "<pending|in_progress|done>" } }`.
  - **Required:** `ticket.status`. **Optional:** none. Any other key under `ticket` (e.g. `title`, `repo`, `body`, `position`) is **silently ignored** (strong-params permit `:status` only).
- **Validation:** `status` must be one of `pending`, `in_progress`, `done`. Validated against `Ticket.statuses.key?(...)` before assignment; `""`, missing, or unknown → 422.
- **Outputs:** JSON:API document with the updated `ticket` resource.
- **Status codes:**
  - `200` — updated. Body `data` is the ticket resource with new `status`.
  - `422` — `{ "errors": [{ "source": { "pointer": "/data/attributes/status" }, "detail": "is not a valid status" }] }` for unknown/missing status.
  - `404` — `{ "error": "not_found" }` for a missing or non-owned ticket.
  - `401` — `{ "error": "unauthorized" }` for missing/invalid token.
  - `400` — `ActionController::ParameterMissing` if the `ticket` key itself is absent (Rails default; not custom-handled).
- **Example input:** `{ "ticket": { "status": "in_progress" } }`
- **Example output:**
  ```json
  { "data": { "id": "7", "type": "ticket",
    "attributes": { "repo": "backend", "title": "...", "body": "...", "position": 0, "status": "in_progress" } } }
  ```

## 4. Data Contract

No schema changes were made by this work. The tables/enums below already existed and are the data this feature reads/writes.

### `tickets` table (written by Interface B, read by Interface A)

| Field | Type | Null | Default | Notes |
|-------|------|------|---------|-------|
| `id` | bigint | no | — | PK |
| `phase_id` | bigint | no | — | FK → `phases` |
| `repo` | string | no | — | enum: `frontend`, `backend`, `fullstack`, `devops` (immutable here) |
| `title` | string | no | — | immutable here |
| `body` | text | no | — | immutable here |
| `position` | integer | no | — | 0-based order within phase (immutable here) |
| `status` | string | no | `"pending"` | enum: `pending`, `in_progress`, `done` — **the only mutable field** |
| `created_at`/`updated_at` | datetime | no | — | |

- Index: `(phase_id, position)`, `(phase_id)`.
- `status` allowed values are enforced in `app/models/ticket.rb` via `enum status:` (no DB CHECK). The controller pre-validates against `Ticket.statuses` to avoid the `ArgumentError` a raw enum assignment would raise on an unknown value.

### `phases` table (read by Interface A)

| Field | Type | Null | Notes |
|-------|------|------|-------|
| `id` | bigint | no | PK |
| `project_id` | bigint | no | FK → `projects` |
| `number` | integer | no | 1-based |
| `title` | string | no | |
| `description` | text | yes | |
| `position` | integer | no | 0-based order within project |

### Serialized JSON:API attribute shapes

- `project` (`ProjectSerializer`): `name, description, github_repo_full_name, llm_provider, llm_model, status, ticket_count, last_generated_at, created_at, updated_at` + `phases` relationship (`lazy_load_data: true` — only emitted when `include:` is passed).
- `phase` (`PhaseSerializer`): `number, title, description, position` + `tickets` relationship.
- `ticket` (`TicketSerializer`): `repo, title, body, position, status`.

## 5. Integration Contract

- **Auth dependency (upstream):** Both endpoints run through `ApplicationController` → `Authenticatable`, which verifies a Supabase-issued JWT (ES256 / JWKS) and exposes `current_user`. No token → `401 { "error": "unauthorized" }`.
- **Authorization scoping:**
  - Interface A: `current_user.projects.includes(phases: :tickets).find(params[:id])`.
  - Interface B: `Ticket.joins(phase: :project).where(projects: { user_id: current_user.id }).find(params[:id])`.
  - Both raise `ActiveRecord::RecordNotFound` for missing/non-owned rows; `ApplicationController` rescues it to `404 { "error": "not_found" }` (existence never leaked).
- **No external services called.** No events published/consumed. No files read/written.
- **Side effects of Interface B:** Updates one `tickets` row only. Does **not** touch the parent project — `ticket_count`, `last_generated_at`, and project `status` are generation-lifecycle fields and are intentionally left unchanged (no `touch`, no cache bump).
- **Idempotency:** Interface B is idempotent — re-PATCHing the same status yields the same 200 result and state.
- **No retry/timeout logic** (synchronous DB writes only).

## 6. Usage Instructions for Other Engineers

**Frontend / consumers can rely on:**
- `GET /api/v1/projects/:id` is the single source for rendering the board on first load, refresh, and return visits. Shape is **identical** to the `POST /api/v1/projects/:id/generate` response (same serializer + same `include:`), so one deserializer/board renderer handles both.
- To mark a ticket: `PATCH /api/v1/tickets/:id` with `{ ticket: { status } }`. Attach the Supabase bearer token (axios interceptor already does this per the web app's `lib/api.ts`).

**Inputs you must provide:** valid bearer token; for PATCH, a `ticket.status` of `pending|in_progress|done`.

**States to handle:**
- GET: `200` board (possibly empty — `included: []`), `404`, `401`.
- PATCH: `200` updated ticket, `422` (read `errors[].source.pointer == "/data/attributes/status"` for field mapping), `404`, `401`.

**Finalized — safe to depend on:** route paths, status codes, error shapes, the status enum values, unconstrained-transition behavior, and "non-status fields ignored."

**Provisional / coordinate before changing:**
- The "always embed on show" decision (no sparse-include param). If you need a lean show, coordinate — don't quietly add a param the index relies on staying absent.
- The absence of a `User#tickets` association — the phase→project join lives inline in `TicketsController#find_ticket`. If more ticket-scoped endpoints appear, promote it to a shared scope rather than copy-pasting the join.

**Nothing is mocked or stubbed in production code.**

## 7. Security and Authorization Notes

- **Auth required:** Both endpoints require a valid Supabase JWT; unauthenticated → `401`.
- **Tenancy / data isolation:** Every lookup is scoped to `current_user`. A ticket or project belonging to another user returns `404` (not `403`) so the API never reveals whether the resource exists. Verified by request specs (`404 for another user's ticket without mutating it`, `404 for another user's project`).
- **Forbidden fields:** Interface B permits `:status` only. `repo`, `title`, `body`, `position`, `phase_id` cannot be mutated through this endpoint (strong params). Verified by the "ignores fields other than status" spec.
- **No new sensitive fields, no PII added, no logging changes.**

## 8. Environment and Configuration

No new environment variables, config keys, feature flags, or secrets were introduced by this work.

Pre-existing runtime assumptions (unchanged): Supabase JWT verification config used by `Authenticatable` (e.g. Supabase project URL / JWKS). These are not part of this feature's surface.

## 9. Testing and Verification

- **Tests added/updated:**
  - `spec/requests/api/v1/projects_spec.rb` — `GET /:id`: embeds ordered phases+tickets; 200 empty board; bounded phase/ticket queries (no N+1, ≤2 queries); existing 404/401 retained.
  - `spec/requests/api/v1/tickets_spec.rb` (new, 8 examples): `pending→in_progress`; `done→in_progress` (non-forward-only); 422 unknown status w/ pointer; 422 missing status; non-status fields ignored; 404 non-owned (no mutation); 404 missing; 401 no token.
- **How to run:**
  ```
  eval "$(rbenv init - zsh)"            # ruby 3.3.11 via rbenv
  bundle exec rspec spec/requests/api/v1/tickets_spec.rb spec/requests/api/v1/projects_spec.rb
  bundle exec rspec                     # full suite
  ```
- **Verification output:** full suite **210 examples, 0 failures**. Route registered: `PATCH/PUT /api/v1/tickets/:id → api/v1/tickets#update` (confirmed via `bin/rails routes`).
- **Known coverage gaps:** No explicit spec for an entirely-absent `ticket` param key (Rails returns 400 by default; not custom-handled). No spec asserting tickets across *different* phases are globally ordered in `included` (only within-phase ordering is asserted).

## 10. Known Limitations and TODOs

- `show` always embeds the board; there is no lightweight variant. Large boards load in a bounded (~3) query count but the full graph is always serialized.
- Status transitions are intentionally unconstrained — there is no audit trail or guard preventing `done → pending`. If product later wants a state machine, it's a model-level `validate` addition.
- `find_ticket`'s join is inline (no `User#tickets`); duplicate it carefully or promote it if reused.
- Deprecation warning: code uses `:unprocessable_entity` (Rack will rename to `:unprocessable_content`). Matched existing codebase style on purpose; a future repo-wide rename should include this file.
- No commit was made — changes are in the working tree only.

## 11. Source of Truth Snapshot

- **Routes:** `GET /api/v1/projects/:id` (behavior changed); `PATCH /api/v1/tickets/:id` (new, also accepts PUT).
- **Controllers:** `Api::V1::ProjectsController#show`; `Api::V1::TicketsController#update` (new).
- **Serializers (unchanged):** `ProjectSerializer`, `PhaseSerializer`, `TicketSerializer`.
- **Models (unchanged):** `Project`, `Phase`, `Ticket`.
- **Enum — ticket status:** `pending`, `in_progress`, `done` (default `pending`).
- **Permitted PATCH params:** `ticket: { status }` only.
- **Error shapes:** `{ "error": "not_found" }` (404), `{ "error": "unauthorized" }` (401), `{ "errors": [{ "source": { "pointer": "/data/attributes/status" }, "detail": ... }] }` (422).
- **Key files:** `app/controllers/api/v1/tickets_controller.rb`, `app/controllers/api/v1/projects_controller.rb`, `config/routes.rb`, `spec/requests/api/v1/tickets_spec.rb`, `spec/requests/api/v1/projects_spec.rb`.
- **Breaking changes:** `GET /api/v1/projects/:id` response now includes `relationships.phases` and an `included` array. Additive for clients that ignore unknown keys; clients must not assume `included` is absent.

## 12. Copy-Paste Handoff for the Next Engineer

**Already done:** `GET /api/v1/projects/:id` returns the full board (phases→tickets, ordered, eager-loaded, no N+1). `PATCH /api/v1/tickets/:id` updates `status` only, user-scoped, with 422/404/401 handling. 210 specs green.

**Safe to depend on:** route paths, status enum (`pending`/`in_progress`/`done`), unconstrained transitions, "non-status fields ignored," all error shapes, and the fact that the show payload matches the generate payload exactly.

**Remaining to build:** frontend board rendering + status controls; any progress/% aggregate (derive client-side from ticket statuses — not provided server-side); optional lean/sparse show variant if needed.

**Traps / gotchas:** (1) Other-user resources return **404, not 403** — don't treat 404 as "doesn't exist." (2) `included: []` on an empty board is expected, not an error. (3) PATCH ignores `title`/`repo`/`body`/`position` silently — don't expect a 422 for sending them. (4) Updating a ticket does **not** update the project's `ticket_count`/`status`. (5) No commit yet — working tree only.

**Read first in this contract:** §3 (Public Interface Contract) and §7 (Security/Authorization).
