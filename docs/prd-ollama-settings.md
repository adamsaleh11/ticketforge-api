# PRD: User-Level Ollama Configuration Endpoints

## Problem Statement

TicketForge lets a user pick an LLM backend per project, and one of the two backends — **Ollama** — is a self-hosted server the user runs themselves. It has no fixed address: it might be `http://localhost:11434` (the default), a LAN host, or a custom port. The `users.ollama_endpoint` column already exists (NOT NULL, defaulting to `http://localhost:11434`), and the `LLM::OllamaClient` already reads an endpoint when talking to `/api/chat`. But there is **no API surface for a user to set or verify that endpoint**.

This blocks the frontend's Ollama setup wizard. A user who runs Ollama somewhere other than the default has no way to persist their endpoint, and — more importantly — no way to find out *before generating a project* whether the backend is even reachable or which models are installed on it. Today the only way they'd discover a bad endpoint is a failed ticket generation deep in the product loop, with a generic error. This matters now because the frontend's provider/model picker and `OllamaSetupWizard` need both a "save my endpoint" action and a "test connection + list my models" action to function.

## Solution

Add two authenticated endpoints under a new `settings` namespace, both scoped to the current user:

- **`PATCH /api/v1/settings/ollama`** — updates the signed-in user's `ollama_endpoint`. The endpoint must be a valid `http`/`https` URL; an invalid value is rejected with a field-level validation error the frontend can map back to its form input. On success it returns the updated user.

- **`POST /api/v1/settings/ollama/test`** — a pure connectivity *report* against the user's currently-saved endpoint. It pings `{endpoint}/api/tags` (Ollama's installed-models listing) with a short 5-second timeout and returns `{ connected: true, models: [...] }` when the server answers, or `{ connected: false, error: "..." }` when it can't be reached or answers badly. It always responds `200 OK` — a failure to reach Ollama is a successful *report of a problem*, not a failed API request.

From the user's perspective: they open the Ollama setup wizard, type their endpoint, save it (PATCH), then click "Test connection" (POST test) and immediately see either a green check with their list of installed models, or a clear error explaining why the connection failed — all before committing to a project.

## User Stories

1. As a self-hosted Ollama user, I want to save a custom Ollama endpoint to my account, so that project generation uses my server instead of the default localhost.
2. As a user who runs Ollama on the default port, I want the system to already have a sensible default endpoint, so that I never have to configure anything for the common case.
3. As a user, I want a malformed endpoint (not an http/https URL) to be rejected with a clear, field-level error, so that I can fix my input instead of silently saving a broken value.
4. As a user, I want a successfully saved endpoint to come back in the response, so that the UI can confirm the new value without a second request.
5. As a user, I want to test whether my saved Ollama endpoint is reachable, so that I can verify my setup before generating tickets.
6. As a user with a reachable Ollama, I want the test to return the list of models installed on my server, so that I can confirm the model I want to use is actually available.
7. As a user whose Ollama is down, misconfigured, or unreachable, I want the test to tell me it failed and why, so that I can troubleshoot rather than guess.
8. As a user, I want the test to give up quickly (within ~5 seconds) if Ollama doesn't respond, so that a hung or wrong endpoint doesn't make the UI hang.
9. As a user, I want the test endpoint to always answer with a clear connected/not-connected result rather than an HTTP error, so that the UI can render a deterministic success-or-failure state.
10. As an unauthenticated caller, I want both endpoints to reject me with 401, so that user settings are never exposed or modified without a valid session.
11. As a user, I want my saved endpoint to never wipe my GitHub token or other profile fields, so that updating one setting has no side effects on the rest of my account.
12. As the maintainer, I want the connectivity check to reuse the existing Ollama client abstraction, so that there is one place that knows how to talk to an Ollama server.

## Implementation Decisions

### Routing & controller

- New nested namespace under `api/v1`: `settings`, with a dedicated `Api::V1::Settings::OllamaController` exposing two actions:
  - `update` → `PATCH /api/v1/settings/ollama`
  - `test`   → `POST  /api/v1/settings/ollama/test`
- The controller inherits the existing `ApplicationController` authentication (the `Authenticatable` concern already enforces a valid Bearer token and exposes `current_user`). Both actions operate exclusively on `current_user`; there is no record lookup by id and nothing is user-scopable to another account.

### `update` action (PATCH)

- Strong params follow the existing wrapper convention: `params.require(:user).permit(:ollama_endpoint)`.
- On success: `200 OK` with the user serialized via the existing `UserSerializer` (which already exposes `ollama_endpoint` and never exposes the GitHub token), consistent with `/api/v1/me` and the projects endpoints.
- On validation failure: `422 Unprocessable Entity` using the **same JSON:API `errors` array shape** that `ProjectsController` already produces (a `source.pointer` of `/data/attributes/ollama_endpoint` plus a human-readable `detail`). The existing `render_validation_errors` helper, currently private to `ProjectsController`, is promoted to `ApplicationController` so both controllers share one implementation.

### URL validation (on the `User` model)

- Validation lives on the `User` model, not in the controller, so the invariant ("a stored endpoint is always a valid http/https URL") holds for every write path, not just this one.
- Rule: the value must parse as a `URI::HTTP` or `URI::HTTPS` with a present host. A bare scheme (`http://`), a non-http scheme (`ftp://...`), or an unparseable string is invalid. Implemented as a custom validation using Ruby's `URI` parser rather than a loose regex, so the check matches what the HTTP client will actually attempt to connect to.
- Because the column is NOT NULL with a valid default and `User.from_supabase_payload` never assigns `ollama_endpoint`, adding this validation does not affect the existing find-or-create-on-login flow.

### `test` action (POST)

- Tests the **currently-saved** `current_user.ollama_endpoint`. It takes **no request body / no candidate endpoint** — the frontend flow is "PATCH to save, then POST to test." (Testing an unsaved value is explicitly out of scope; see below.)
- The connectivity check is performed by a **new method on `LLM::OllamaClient`** (e.g. a models-listing / tags call), not inline HTTP in the controller. This keeps the controller thin and keeps all knowledge of Ollama's wire protocol in the existing client.
  - It issues a `GET` to `{endpoint}/api/tags`.
  - It uses a **5-second timeout**, local to this method. The chat path's existing `TIMEOUT = 60` is untouched.
  - On a non-2xx, unparseable body, or transport failure it raises the existing `LLM::InvalidResponseError` / `LLM::ConnectionError` from the `LLM::Error` tree — the same uniform failure model the rest of the LLM service uses.
- The controller catches `LLM::Error` and shapes the report:
  - Success → `200 OK` with `{ connected: true, models: [...] }`.
  - Any `LLM::Error` → `200 OK` with `{ connected: false, error: "<human-readable message>" }`.

### Response payloads

- **Models shape:** an array of model **name strings**. Ollama's `/api/tags` returns `{ "models": [{ "name": "llama3:latest", ... }, ...] }`; the client maps this to `["llama3:latest", ...]` — exactly what a model-picker UI needs. Returning the richer objects (sizes, modified dates) is a deliberate later extension.
- **Test response is plain JSON**, not JSON:API — it's a status report, not a resource. The PATCH response, by contrast, is the JSON:API-serialized user.

## Testing Decisions

Good tests here assert the externally observable behavior and contracts: the HTTP status, the persisted change, the validation-error shape, and the connected/not-connected report — not the internal wiring. WebMock is already configured (`spec/support/webmock.rb`; localhost allowed but explicit stubs take priority, so `localhost:11434` is stubbable), and request specs already have `auth_headers(valid_supabase_jwt)` helpers. Stub `{endpoint}/api/tags`; never hit the network.

Coverage to call out:

- **`PATCH /api/v1/settings/ollama` (request spec)**
  - A valid http (and https) URL updates `ollama_endpoint` and returns `200` with the new value in the serialized user; assert the change is persisted.
  - An invalid URL (e.g. `not-a-url`, `ftp://x`, `http://`) returns `422` with a JSON:API error pointing at `ollama_endpoint`, and does **not** change the stored value.
  - No / invalid token returns `401` (mirrors `me_authentication_spec`).
  - Updating the endpoint does not clear other profile fields (e.g. the GitHub token / username remain intact).
- **`POST /api/v1/settings/ollama/test` (request spec)**
  - Stubbed `/api/tags` 200 with a models list → `200` and `{ connected: true, models: [...] }` with the expected names; assert the request hit `{current_user.ollama_endpoint}/api/tags`.
  - Stubbed timeout and stubbed connection-refused → `200` and `{ connected: false, error: ... }`.
  - Stubbed non-2xx (e.g. 500) → `200` and `{ connected: false, ... }`.
  - No / invalid token returns `401`.
- **`LLM::OllamaClient` models-listing method (unit spec, alongside the existing `spec/services/llm/ollama_client_spec.rb`)**
  - Happy path → returns the mapped array of model names; asserts the GET URL and the 5s timeout behavior.
  - Non-2xx / unparseable body → `InvalidResponseError`.
  - Transport failure → `ConnectionError`.
- **`User` model validation (unit spec, in the existing `spec/models/user_spec.rb`)**
  - Valid http/https endpoints are accepted; bare-scheme, non-http-scheme, and unparseable values are rejected with the expected message.

Prior art: `spec/requests/api/v1/projects_spec.rb` for the validation-error assertions and authenticated request patterns, `spec/requests/api/v1/me_authentication_spec.rb` for the 401 cases, and `spec/services/llm/ollama_client_spec.rb` for WebMock-stubbed Ollama client specs.

## Out of Scope

- **Testing an unsaved/candidate endpoint.** `test` only checks the persisted `ollama_endpoint`; there is no "try this value before saving" parameter in this iteration.
- **Per-project endpoint overrides.** This is a single user-level endpoint; projects do not carry their own endpoint.
- **Returning rich model metadata** (size, parameter count, modified date, digest) from the test endpoint — names only for now.
- **Pulling / installing models, or any write operation against Ollama.** The test is read-only (`/api/tags`).
- **Validating that a *reachable* endpoint is actually Ollama** beyond what `/api/tags` returning a parseable models list implies.
- **Authentation/headers for Ollama** — the local server is unauthenticated, matching the existing `OllamaClient`.
- **Frontend work** (the setup wizard UI) — that lives in the web repo.
- **Configurable timeout.** The 5-second test timeout is fixed.

## Further Notes

- **Why the test always returns 200:** the endpoint's job is to *report* connectivity, and a UI needs a deterministic success-or-failure body to render either the model list or an error banner. Returning a 502/504 on an unreachable Ollama would conflate "your Ollama is down" with "TicketForge's API failed," and would force the frontend to parse error states out of two different channels (HTTP status vs. body).
- **Why the connectivity check lives on `OllamaClient`:** the client is already the single owner of "how to talk to an Ollama server" (URL composition, the default endpoint constant, HTTParty transport, the `LLM::Error` failure model). Adding a `/api/tags` method there keeps that knowledge in one place and lets the test action reuse the same error taxonomy instead of inventing its own.
- **Why validation is on the model:** the column already exists and other code paths (and future ones) write to it; a model-level invariant guarantees a stored endpoint is always something the HTTP client can actually attempt, regardless of entry point.
- **Assumption:** the existing `ollama_endpoint` default (`http://localhost:11434`) remains the value for users who never configure anything, so `test` is meaningful even before a user has ever called PATCH.
- **Forward compatibility:** if the UI later wants richer model data or a "test before save" flow, both extend additively — the test response can grow from string array to objects, and `test` can learn an optional candidate-endpoint param — without changing the PATCH contract or the 401/422 behavior.
