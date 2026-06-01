# Plan: Project Resource

> Source PRD: docs/prd-project-resource.md

## Architectural decisions

Durable decisions that apply across all phases:

- **Routes**: nested in existing `namespace :api { namespace :v1 }` — `resources :projects, only: %i[index show create update destroy]`. Base path `/api/v1/projects`.
- **Schema**: `projects` table, bigint PK (matches `users`). Columns: `user_id` (bigint, null: false, FK, indexed), `name` (string, null: false), `description` (text, null), `github_repo_full_name` (string, null), `llm_provider` (string, null: false), `llm_model` (string, null: false), `status` (string, null: false, default `"draft"`), timestamps. Enums string-backed; inclusion enforced at model layer, no DB CHECK constraints.
- **Key models**: `Project` (`belongs_to :user`, string-backed enums `llm_provider` ∈ {groq, ollama}, `status` ∈ {draft, generating, ready, failed}); `User` gains `has_many :projects, dependent: :destroy`.
- **Auth**: every action scoped through `current_user.projects` (never `Project.find`). Cross-user/missing → `RecordNotFound` → `404 { error: "not_found" }` via a `rescue_from` in `ApplicationController`. Unauthenticated → existing `401 { error: "unauthorized" }`. `user_id` and `status` never mass-assignable.
- **Serialization**: `ProjectSerializer` via `JSONAPI::Serializer`, JSON:API envelope matching `/me`. Real attributes + stubbed `ticket_count` (0) / `last_generated_at` (nil), marked `# TODO(Phase 5):`.
- **Error dialects**: flat `{ error: ... }` for singular 401/404; JSON:API `errors` array with `source.pointer` for validation `422`.

---

## Phase 1: Read path + foundation

**User stories**: 2, 3, 4, 7, 8, 9

### What to build

Stand up the full stack against read behavior: the `Project` model + migration, `User has_many :projects`, `ProjectSerializer` with stubbed computed fields, the `rescue_from ActiveRecord::RecordNotFound` 404 contract, and the read endpoints `GET /api/v1/projects` (current user's projects, newest first) and `GET /api/v1/projects/:id` — all scoped through `current_user.projects`.

### Acceptance criteria

- [ ] `GET /projects` returns `200` with the current user's projects ordered `created_at DESC`, in the JSON:API envelope.
- [ ] `GET /projects` excludes other users' projects.
- [ ] `GET /projects/:id` returns `200` with the serialized project including `ticket_count: 0` and `last_generated_at: null`.
- [ ] Requesting another user's project (or a missing id) returns `404 { "error": "not_found" }`.
- [ ] Any read endpoint without a valid token returns `401 { "error": "unauthorized" }`.
- [ ] `Project` model spec covers associations, enums, and validations.
- [ ] `:project` factory exists, building its own user.

---

## Phase 2: Write path

**User stories**: 1, 5, 6, 10, 11, 12, 13

### What to build

Layer mutations on the proven foundation: `POST /projects` (create), `PATCH /projects/:id` (update), `DELETE /projects/:id` (destroy). Strong params permit only editable fields (`status` and `user_id` never permitted; `status` guard documented in the params method). Validation failures return the JSON:API pointer error shape; destroy returns `204` with no body.

### Acceptance criteria

- [ ] `POST /projects` with valid params returns `201` and the project belongs to `current_user`.
- [ ] `PATCH /projects/:id` updates editable fields and returns `200`.
- [ ] `DELETE /projects/:id` returns `204` with an empty body and removes the project.
- [ ] Invalid create/update (blank name, malformed `owner/repo`, bad provider) returns `422` with `{ "errors": [{ "source": { "pointer": "/data/attributes/<field>" }, "detail": ... }] }`.
- [ ] `status` cannot be set via create or update params.
- [ ] Cross-user `PATCH`/`DELETE` returns `404`.
- [ ] Deleting a user destroys their projects (`dependent: :destroy`).
- [ ] Write endpoints without a valid token return `401`.
