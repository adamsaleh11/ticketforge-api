# Plan: User-Level Ollama Configuration Endpoints

> Source PRD: [docs/prd-ollama-settings.md](../docs/prd-ollama-settings.md)

## Architectural decisions

Durable decisions that apply across all phases:

- **Routes**: new `settings` namespace under `api/v1`.
  - `PATCH /api/v1/settings/ollama` → `Api::V1::Settings::OllamaController#update`
  - `POST  /api/v1/settings/ollama/test` → `Api::V1::Settings::OllamaController#test`
- **Schema**: none. `users.ollama_endpoint` already exists (string, NOT NULL, default `http://localhost:11434`).
- **Key models**: `User` gains an http/https URL validation on `ollama_endpoint` (URI-based, requires `URI::HTTP`/`HTTPS` + present host).
- **Auth**: inherits `ApplicationController` + `Authenticatable`; both actions operate only on `current_user`. Missing/invalid token → 401.
- **External services**: Ollama, via a new read-only `/api/tags` method on `LLM::OllamaClient` (GET, 5s timeout, reuses the `LLM::Error` taxonomy). The chat path's `TIMEOUT = 60` is untouched.
- **Response shapes**: PATCH success → `UserSerializer` (JSON:API); PATCH failure → JSON:API `errors` array (shared `render_validation_errors`, promoted to `ApplicationController`). `test` → plain JSON `{ connected: bool, ... }`, always `200`.

---

## Phase 1: Save the Ollama endpoint (PATCH)

**User stories**: 1, 2, 3, 4, 10, 11

### What to build

A vertical slice that lets an authenticated user persist their Ollama endpoint. Add the `settings` route namespace and `Settings::OllamaController#update` (`params.require(:user).permit(:ollama_endpoint)`). Add a URI-based http/https validation to the `User` model so the invariant holds on every write path. Promote `ProjectsController`'s `render_validation_errors` to `ApplicationController` so the new controller reuses the JSON:API error shape. Success returns the serialized user (200); an invalid URL returns a JSON:API `422` pointing at `ollama_endpoint`; no/invalid token returns 401.

### Acceptance criteria

- [ ] `PATCH /api/v1/settings/ollama` with a valid http or https URL persists `ollama_endpoint` and returns `200` with the new value in the serialized user.
- [ ] An invalid value (`not-a-url`, `ftp://x`, `http://`) returns `422` with a JSON:API error whose pointer is `/data/attributes/ollama_endpoint`, and the stored value is unchanged.
- [ ] Missing or invalid Bearer token returns `401`.
- [ ] Updating the endpoint leaves other profile fields (GitHub token/username) intact.
- [ ] `User` model spec covers accepted http/https values and rejected bare-scheme / non-http / unparseable values.
- [ ] `render_validation_errors` lives on `ApplicationController`; `ProjectsController` still returns its existing error shape (specs green).

---

## Phase 2: Test the connection (POST test)

**User stories**: 5, 6, 7, 8, 9, 10, 12

### What to build

A vertical slice that reports connectivity against the user's saved endpoint. Add a read-only models-listing method to `LLM::OllamaClient` that issues `GET {endpoint}/api/tags` with a 5-second timeout, maps the response to an array of model name strings, and raises the existing `LLM::ConnectionError` / `LLM::InvalidResponseError` on failure. Add `Settings::OllamaController#test`, which takes no body, calls the client against `current_user.ollama_endpoint`, and always returns `200`: `{ connected: true, models: [...] }` on success, or `{ connected: false, error: "..." }` when any `LLM::Error` is raised.

### Acceptance criteria

- [ ] `POST /api/v1/settings/ollama/test` against a stubbed reachable `/api/tags` returns `200` and `{ connected: true, models: [...] }` with the installed model names, hitting `{current_user.ollama_endpoint}/api/tags`.
- [ ] A stubbed timeout and a stubbed connection-refused each return `200` and `{ connected: false, error: ... }`.
- [ ] A stubbed non-2xx (e.g. 500) returns `200` and `{ connected: false, ... }`.
- [ ] Missing or invalid Bearer token returns `401`.
- [ ] The connectivity check enforces a 5s timeout and does not alter the chat path's 60s timeout.
- [ ] `LLM::OllamaClient` unit spec covers: happy path → mapped name array; non-2xx / unparseable → `InvalidResponseError`; transport failure → `ConnectionError`.
