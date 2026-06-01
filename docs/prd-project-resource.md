# PRD: Project Resource

## Problem Statement

TicketForge users sign in with GitHub and want to describe a software project, optionally link a GitHub repo, choose an LLM provider, and eventually generate phased engineering tickets. Today the API can authenticate a user (`GET /api/v1/me`) but has nowhere to store the projects those users create. Without a `Project` resource there is no persistent object for the frontend dashboard to list, create, edit, or delete, and no anchor for the future ticket-generation pipeline to attach phases and tickets to.

This affects every authenticated user: the core product loop (describe a project → generate tickets) cannot begin until projects can be created and owned. It matters now because the frontend dashboard and the project detail page are blocked on this contract.

## Solution

Introduce a `Project` resource owned by the authenticated user, exposed as a standard CRUD API under `/api/v1/projects`. Every project belongs to exactly one user and is only ever reachable by its owner. Users can list their projects (newest first), create a project, view a single project, update its editable fields, and delete it.

Each project carries the metadata needed to later drive ticket generation: a name, an optional description, an optional linked GitHub repo (`owner/repo`), an LLM provider (`groq` or `ollama`), a chosen model, and a lifecycle status (`draft`, `generating`, `ready`, `failed`). Status is system-managed — clients never set it directly; it defaults to `draft` and will be advanced later by the ticket-generation service.

Responses use the same JSON:API envelope the existing `/me` endpoint uses. The serializer exposes two forward-looking computed fields — `ticket_count` and `last_generated_at` — that are stubbed now (always `0` and `null`) and will light up when the Phase/Ticket models ship, with no change to the API contract.

## User Stories

1. As an authenticated user, I want to create a project with a name, description, linked repo, provider, and model, so that I have a place to generate tickets from.
2. As an authenticated user, I want to list my projects newest-first, so that my dashboard shows my most recent work at the top.
3. As an authenticated user, I want to view a single project by id, so that I can see its details on a project page.
4. As an authenticated user, I want the project detail response to include `ticket_count` and `last_generated_at`, so that the UI can show generation state without a separate request (even though both are stubbed until ticket generation ships).
5. As an authenticated user, I want to update a project's editable fields (name, description, linked repo, provider, model), so that I can correct or refine it before generating.
6. As an authenticated user, I want to delete a project, so that I can remove work I no longer need.
7. As an authenticated user, I want my projects to be private to me, so that no other user can list, read, update, or delete them.
8. As an authenticated user, when I request a project that doesn't exist or belongs to someone else, I want a `404 not_found`, so that the API never reveals whether another user's resource exists.
9. As an unauthenticated caller, when I hit any project endpoint without a valid token, I want a `401 unauthorized`, so that project data is never exposed without authentication.
10. As an authenticated user, when I submit invalid data (e.g. blank name, malformed repo, bad provider), I want a `422` with field-level errors, so that the frontend can show inline validation messages.
11. As a user whose account is deleted, I want my projects deleted with me, so that no orphaned project data remains.
12. As a frontend developer, I want validation errors keyed to specific fields (JSON:API pointers), so that I can map each error to its form input without re-deriving the field.
13. As a future ticket-generation service, I want to own the `status` transitions (`draft → generating → ready/failed`), so that lifecycle state is never corrupted by client input.

## Implementation Decisions

### Modules

- **`Project` model** — new ActiveRecord model. `belongs_to :user`. String-backed Rails enums for `llm_provider` (`groq`, `ollama`) and `status` (`draft`, `generating`, `ready`, `failed`). Validations: `name` presence + max length 255; `description` optional; `github_repo_full_name` optional but, when present, must match an `owner/repo` format; `llm_provider`, `llm_model`, and `status` presence (enum enforces inclusion). `status` defaults to `draft`.
- **`User` model (modified)** — add `has_many :projects, dependent: :destroy`.
- **`Api::V1::ProjectsController`** — `index`, `show`, `create`, `update`, `destroy`. All access scoped through `current_user.projects` so cross-user access raises `RecordNotFound`. `user_id` is never mass-assignable; projects are built via the `current_user.projects` association. `status` is never permitted through strong params (lifecycle-driven, set internally by the future ticket-generation service — documented with a comment in the params method).
- **`ProjectSerializer`** — `JSONAPI::Serializer`, matching `UserSerializer`. Real attributes: `name`, `description`, `github_repo_full_name`, `llm_provider`, `llm_model`, `status`, `created_at`, `updated_at`. Computed attributes `ticket_count` (stub `0`) and `last_generated_at` (stub `nil`), each marked with a `# TODO(Phase 5):` upgrade note.
- **`ApplicationController` (modified)** — add `rescue_from ActiveRecord::RecordNotFound` returning `{ error: "not_found" }` at `404`.

### Schema changes

New `projects` table (bigint PK, matching `users`):

- `user_id` — bigint, `null: false`, foreign key, indexed
- `name` — string, `null: false`
- `description` — text, nullable
- `github_repo_full_name` — string, nullable
- `llm_provider` — string, `null: false`
- `llm_model` — string, `null: false`
- `status` — string, `null: false`, default `"draft"`
- `created_at` / `updated_at` timestamps

Enums are string-backed (not integer) so DB rows stay human-readable. Inclusion is enforced at the model layer, not via DB CHECK constraints.

### API contract

Base path `/api/v1/projects`, all endpoints authenticated.

- `GET /projects` — `200`, current user's projects ordered `created_at DESC`.
- `POST /projects` — `201` on success; `422` on validation failure.
- `GET /projects/:id` — `200`; serialized project including stubbed `ticket_count`/`last_generated_at`.
- `PATCH /projects/:id` — `200` on success; `422` on validation failure.
- `DELETE /projects/:id` — `204` via `head :no_content`, no body.

Permitted params (create + update): `name`, `description`, `github_repo_full_name`, `llm_provider`, `llm_model`. Never `status`, never `user_id`.

Response shapes:

- Success: JSON:API envelope (`data` / `attributes`), same as `/me`.
- `401` → `{ "error": "unauthorized" }` (existing behavior, unchanged).
- `404` → `{ "error": "not_found" }` (new, via `rescue_from`).
- `422` → JSON:API error array: `{ "errors": [{ "source": { "pointer": "/data/attributes/name" }, "detail": "can't be blank" }] }`.

Singular error responses (`401`, `404`) keep the existing flat `{ "error": ... }` shape because they are not field-scoped. Only validation `422`s use the `errors` array.

## Testing Decisions

Good tests here assert external behavior and the API contract — status codes, response envelopes, ownership scoping, and error shapes — not model internals. Mirror the existing request-spec style in `spec/requests/api/v1/` and reuse the `auth_headers` / `valid_supabase_jwt` helpers from `spec/support/auth_helpers.rb`.

Coverage to call out:

- **Request specs (`ProjectsController`)**, per endpoint:
  - Happy path (correct status code + serialized payload; `index` returns newest-first).
  - Unauthenticated (no/invalid token → `401 { error: "unauthorized" }`).
  - Cross-user access (another user's project → `404 { error: "not_found" }`, indistinguishable from missing).
  - Validation failure (`422` with the JSON:API pointer error shape).
  - `index` returns only the current user's projects, not others'.
  - `destroy` returns `204` with an empty body.
  - Serializer exposes `ticket_count: 0` and `last_generated_at: null`.
- **`Project` model spec** — associations, enum definitions, and each validation (name presence/length, `owner/repo` format, provider/model/status presence).
- **`:project` factory** in `spec/factories/` with sensible defaults, building its own `user`.

Prior art: `spec/requests/api/v1/me_spec.rb` and `me_authentication_spec.rb` for request structure and auth helpers; `spec/models/user_spec.rb` for model-spec style.

## Out of Scope

- `Phase` and `Ticket` models, and the ticket-generation pipeline (Phase 5). This PRD only stubs `ticket_count`/`last_generated_at`.
- Any `status` transition logic or endpoints to trigger generation. Status remains `draft` for the lifetime of this work.
- Nested phases/tickets in the `show` response — the field surface is forward-compatible but inert.
- Pagination, filtering, sorting beyond newest-first on `index`.
- Authorization beyond ownership (no roles, teams, or shared projects — reserve `403` for a future read-but-not-write case).
- Validating `llm_model` against the chosen `llm_provider` (any non-blank string accepted for now).
- DB-level CHECK constraints for enums.

## Further Notes

- **Forward compatibility:** when Phase/Ticket models land, `ticket_count` and `last_generated_at` get swapped from stubs to real association queries (`project.tickets.count`, `project.tickets.maximum(:updated_at)`), and the `show` endpoint can begin including nested associations — all without an API contract change. The `# TODO(Phase 5):` markers flag both upgrade points.
- **404-over-403 decision:** cross-tenant access returns `404`, matching the GitHub/Stripe/Linear convention, to avoid leaking resource existence. This falls out naturally from scoping through `current_user.projects.find`, which raises `RecordNotFound` → the new `rescue_from`. No policy/authorization layer is introduced.
- **Error-shape consistency:** the API now speaks two error dialects intentionally — flat `{ error: ... }` for singular auth/not-found conditions, and the JSON:API `errors` array for field-level validation. Keep this split consistent across future endpoints.
- **Assumption:** PK stays bigint to match `users`, despite `uuid-ossp` being enabled in the Supabase-managed schema.
