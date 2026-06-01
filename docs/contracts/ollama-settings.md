# Implementation Handoff Contract

## 1. Summary

- **What was implemented:** Two authenticated, user-scoped endpoints for configuring a user's self-hosted Ollama server: `PATCH /api/v1/settings/ollama` (save the endpoint URL) and `POST /api/v1/settings/ollama/test` (report connectivity + list installed models). A URI-based http/https validation was added to the `User` model, and a `#list_models` connectivity method was added to `LLM::OllamaClient`.
- **Why:** The `users.ollama_endpoint` column and `LLM::OllamaClient` chat path already existed, but there was no API surface to set or verify the endpoint. This unblocks the frontend's Ollama setup wizard (save endpoint, then test connection + show available models before generating a project).
- **In scope:** Persisting the endpoint with validation; a read-only connectivity/models report against the saved endpoint; request + unit specs.
- **Out of scope:** Testing an unsaved/candidate endpoint; per-project endpoint overrides; rich model metadata (sizes/dates); pulling/installing models; configurable timeout; any frontend work. (See §10.)
- **Owner:** `ticketforge-api` (Rails 7.1 API-only backend). Module: `Api::V1::Settings`.

## 2. Files Added or Changed

| File | Status | Purpose |
|---|---|---|
| `config/routes.rb` | updated | Adds the `api/v1/settings` namespace with `patch "ollama"` and `post "ollama/test"`. |
| `app/controllers/api/v1/settings/ollama_controller.rb` | created | `Settings::OllamaController` with `update` (PATCH) and `test` (POST) actions. |
| `app/controllers/application_controller.rb` | updated | `render_validation_errors` promoted here (was private to `ProjectsController`) so all controllers share the JSON:API error shape. |
| `app/controllers/api/v1/projects_controller.rb` | updated | Removed the now-shared `render_validation_errors` (behavior unchanged; inherited from `ApplicationController`). |
| `app/models/user.rb` | updated | Adds `validate :ollama_endpoint_is_http_url` — a private URI-based validation requiring a `URI::HTTP`/`HTTPS` with a present host. |
| `app/services/llm/ollama_client.rb` | updated | `initialize` now defaults `model:` to `nil`; adds `TAGS_TIMEOUT = 5`, public `#list_models`, and private `get_tags`/`parse_tags_body`. |
| `spec/requests/api/v1/settings/ollama_spec.rb` | created | Request spec for PATCH (happy path, https, invalid-URL matrix, field preservation, 401). |
| `spec/requests/api/v1/settings/ollama_test_spec.rb` | created | Request spec for POST test (connected, timeout/refused/non-2xx, custom endpoint, 401). |
| `spec/models/user_spec.rb` | updated | Adds `ollama_endpoint validation` describe block. |
| `spec/services/llm/ollama_client_spec.rb` | updated | Adds `#list_models` describe block. |
| `docs/prd-ollama-settings.md` | created | Source PRD. |
| `plans/ollama-settings.md` | created | Phased implementation plan. |

Not source files: `log/development.log`, `log/test.log` (test-run noise; not part of the change).

## 3. Public Interface Contract

### 3.1 `PATCH /api/v1/settings/ollama`

- **Type:** HTTP JSON endpoint. **Route name:** `api_v1_settings_ollama`. **Owner:** `Api::V1::Settings::OllamaController#update`.
- **Purpose:** Update the authenticated user's `ollama_endpoint`.
- **Auth:** Required. `Authorization: Bearer <Supabase JWT>` (see §7).
- **Inputs (JSON body):**
  - `user` (object, **required**)
    - `user.ollama_endpoint` (string, **required**) — the only permitted attribute.
- **Validation rules:** `ollama_endpoint` must parse as a `URI::HTTP` or `URI::HTTPS` **and** have a present host. Rejected: `not-a-url`, `ftp://...`, `http://` (no host), blank/whitespace, unparseable strings.
- **Defaults:** none on input. The column default (`http://localhost:11434`) applies only at user-creation time, not here.
- **Outputs / status codes:**
  - `200 OK` — JSON:API-serialized user (via `UserSerializer`). Attributes: `supabase_user_id`, `email`, `name`, `github_username`, `ollama_endpoint`, `created_at`, `updated_at`. `github_access_token` is never included.
  - `422 Unprocessable Entity` — JSON:API `errors` array (see §3.3); stored value unchanged.
  - `401 Unauthorized` — body `{ "error": "unauthorized" }`.
- **Example input:**
  ```json
  { "user": { "ollama_endpoint": "http://ollama.internal:11434" } }
  ```
- **Example output (200):**
  ```json
  {
    "data": {
      "id": "1",
      "type": "user",
      "attributes": {
        "supabase_user_id": "supabase-user-123",
        "email": "octocat@example.com",
        "name": "The Octocat",
        "github_username": "octocat",
        "ollama_endpoint": "http://ollama.internal:11434",
        "created_at": "2026-06-01T12:00:00.000Z",
        "updated_at": "2026-06-01T12:00:01.000Z"
      }
    }
  }
  ```

### 3.2 `POST /api/v1/settings/ollama/test`

- **Type:** HTTP JSON endpoint. **Route name:** `api_v1_settings_ollama_test`. **Owner:** `Api::V1::Settings::OllamaController#test`.
- **Purpose:** Connectivity *report* against the user's currently-saved `ollama_endpoint`; lists installed models on success.
- **Auth:** Required (same as above).
- **Inputs:** **None.** No request body / no candidate endpoint param. Always tests `current_user.ollama_endpoint`.
- **Behavior:** Issues `GET {ollama_endpoint}/api/tags` with a 5-second timeout (see §5).
- **Outputs / status codes:**
  - `200 OK` (success): `{ "connected": true, "models": ["<name>", ...] }` — `models` is an array of model **name strings** (mapped from Ollama's `models[].name`).
  - `200 OK` (failure): `{ "connected": false, "error": "<human-readable message>" }`. Returned for any `LLM::Error` (timeout, connection refused, non-2xx, unparseable body). **Always 200**, never a 5xx, even when Ollama is unreachable.
  - `401 Unauthorized` — body `{ "error": "unauthorized" }`.
- **Example output (connected):**
  ```json
  { "connected": true, "models": ["llama3:latest", "qwen2:7b"] }
  ```
- **Example output (not connected):**
  ```json
  { "connected": false, "error": "LLM::OllamaClient could not reach the backend: Net::OpenTimeout ..." }
  ```

### 3.3 Shared JSON:API validation-error shape (`ApplicationController#render_validation_errors`)

- **Type:** Reusable private controller method (inherited). **Owner:** `ApplicationController`.
- **Output shape:** `{ "errors": [ { "source": { "pointer": "/data/attributes/<attr>" }, "detail": "<message>" }, ... ] }` with HTTP `422`.
- For a bad `ollama_endpoint` the pointer is `/data/attributes/ollama_endpoint` and detail is `must be a valid http or https URL`.

### 3.4 `LLM::OllamaClient#list_models`

- **Type:** Public Ruby instance method. **Owner:** `LLM::OllamaClient`.
- **Purpose:** Return installed model names from `{endpoint}/api/tags`.
- **Constructor:** `LLM::OllamaClient.new(model: nil, endpoint: nil)` — `endpoint` defaults to `http://localhost:11434` when `nil`/blank; `model` is optional and unused by this method.
- **Inputs:** none (uses the instance's `@endpoint`).
- **Output:** `Array<String>` of model names (`[]` when the server reports no models).
- **Errors:** `LLM::InvalidResponseError` (non-2xx, unparseable body); `LLM::ConnectionError` (transport failure: timeout, refused, reset, DNS/socket — the existing `LLM::Client::CONNECTION_ERRORS` set). Both descend from `LLM::Error`.

## 4. Data Contract

### 4.1 `users.ollama_endpoint` (existing column — no migration)

- **Type:** `string`, `NOT NULL`, default `http://localhost:11434`.
- **New constraint (app-level):** must be a valid http/https URL with a present host (model validation `ollama_endpoint_is_http_url`).
- **Required/optional:** required (NOT NULL, has default). Set via PATCH §3.1.
- **Allowed values:** any `http://`/`https://` URL with a host (host may be `localhost`, an IP, or a domain; port optional).
- **Migration notes:** none — column predates this work. **Backward compatibility:** the validation does not run against `User.from_supabase_payload` (which never assigns `ollama_endpoint`), so existing login/find-or-create flow is unaffected. Any pre-existing rows with the default value remain valid.

### 4.2 PATCH request payload (DTO)

```jsonc
{ "user": { "ollama_endpoint": "string (http/https URL, required)" } }
```
Strong params: `params.require(:user).permit(:ollama_endpoint)`. No other attributes are accepted.

### 4.3 Test response payloads (JSON shapes)

- Success: `{ "connected": true, "models": string[] }`
- Failure: `{ "connected": false, "error": string }`

These are **plain JSON**, not JSON:API (the test result is a status report, not a resource).

### 4.4 Ollama `/api/tags` consumed shape (external)

Reads `{ "models": [ { "name": "<string>", ... }, ... ] }`. Only `name` is consumed; other fields are ignored.

## 5. Integration Contract

- **Downstream dependency:** the user's self-hosted Ollama server at `current_user.ollama_endpoint`. Only `GET /api/tags` is called (read-only).
- **HTTP client:** `HTTParty` (already in the Gemfile), consistent with the chat path.
- **Timeout:** `LLM::OllamaClient::TAGS_TIMEOUT = 5` seconds for `#list_models`. The chat path's `LLM::Client::TIMEOUT = 60` is **untouched**.
- **Retry:** **None** for `#list_models` (unlike the chat path's single connection-error retry). A failure is reported immediately.
- **Fallback:** on any `LLM::Error`, the `test` action returns `{ connected: false, error: ... }` with HTTP 200 — no exception propagates to the client.
- **Auth assumption:** Ollama is unauthenticated (no auth header sent), matching the existing `OllamaClient`.
- **Idempotency:** both endpoints are idempotent (PATCH overwrites; test is read-only).
- **Upstream dependency:** `ApplicationController` + `Authenticatable` concern (Supabase JWT verification, `current_user`).
- **Events published/consumed:** none.

## 6. Usage Instructions for Other Engineers

- **Frontend flow to build against:** PATCH the endpoint to save → then POST `.../test` to verify. The test endpoint reads the **saved** value, so save first.
- **You can rely on:** the test endpoint always returning `200` with a boolean `connected`. Render the model list from `models` on `connected: true`; render `error` text on `connected: false`. Do **not** branch on HTTP status for the test result.
- **Inputs you must provide:** a valid Supabase Bearer token on both calls; a `user.ollama_endpoint` string on PATCH.
- **Outputs you'll receive:** PATCH → serialized user (read `data.attributes.ollama_endpoint`) or `422` errors array (map `errors[].source.pointer` back to the form field). Test → `{ connected, models }` or `{ connected, error }`.
- **States to handle (test endpoint):** loading (spinner during the up-to-5s wait); success-connected (show models); success-not-connected (show `error`); 401 (sign out / redirect per CLAUDE.md rule 6). The test endpoint has no separate "empty" — an empty `models: []` means reachable but no models installed.
- **Finalized:** route paths, response shapes, validation rule, 5s timeout, always-200 test contract.
- **Provisional / safe to extend later:** `models` may grow from string array to richer objects; `test` may gain an optional candidate-endpoint param. Neither is implemented now.
- **Mocked/stubbed:** nothing is mocked in production code. Specs stub Ollama via WebMock.
- **Do not change without coordination:** the always-200 contract of the test endpoint (frontend depends on it); the shared `ApplicationController#render_validation_errors` (also used by `ProjectsController`).

## 7. Security and Authorization Notes

- **Auth required** on both endpoints via the `Authenticatable` concern (Supabase ES256 JWT, verified against JWKS). Missing/invalid/expired/wrong-audience/untrusted-key/`alg:none` tokens → canonical `401 { "error": "unauthorized" }`.
- **Tenancy / data isolation:** both actions operate exclusively on `current_user`. There is **no record lookup by id and no params-driven user selection**, so one user cannot read or modify another's settings.
- **Mass-assignment:** strictly limited to `user.ollama_endpoint` via strong params; `github_access_token`, `supabase_user_id`, etc. cannot be set through these endpoints.
- **Sensitive fields:** `github_access_token` is `encrypts`-ed at rest and is never serialized by `UserSerializer` (verified by existing `/me` spec). The PATCH response cannot leak it.
- **SSRF consideration:** `POST .../test` issues a server-side GET to a user-controlled URL (`ollama_endpoint`). It is constrained to http/https with a host, but **no allowlist / private-IP blocking is applied** — a user can point it at internal hosts. Acceptable for this product (the endpoint is the user's own Ollama, and only `/api/tags` JSON-name extraction is returned), but note it as a follow-up if SSRF hardening is later required. (See §10.)
- **Logging:** no new logging of tokens or endpoints was added; standard Rails request logging applies.

## 8. Environment and Configuration

- **No new environment variables, secrets, or feature flags** were introduced.
- **Runtime constant:** `LLM::OllamaClient::TAGS_TIMEOUT = 5` (seconds) — hardcoded, not configurable.
- **Runtime constant (existing, referenced):** `LLM::OllamaClient::DEFAULT_ENDPOINT = "http://localhost:11434"` — used when a user's endpoint is blank/nil at client construction.
- Dev vs prod: identical behavior. No config keys added.

## 9. Testing and Verification

- **Tests added/updated:**
  - `spec/requests/api/v1/settings/ollama_spec.rb` (PATCH): valid http + https → 200 & persisted; `not-a-url` / `ftp://ollama` / `http://` → 422 + pointer + unchanged value; field preservation (github token/username intact); 401 unauthenticated.
  - `spec/requests/api/v1/settings/ollama_test_spec.rb` (POST test): connected + names; timeout / connection-refused / non-2xx → not connected; custom saved endpoint is hit; 401 unauthenticated.
  - `spec/models/user_spec.rb`: accepts 3 valid URLs, rejects `not-a-url` / `ftp://ollama` / `http://` / whitespace with the exact message.
  - `spec/services/llm/ollama_client_spec.rb`: `#list_models` returns names; honors custom endpoint; `InvalidResponseError` on non-2xx and unparseable body; `ConnectionError` on timeout.
- **How to run:** `eval "$(rbenv init - zsh)" && bundle exec rspec` (project uses rbenv Ruby 3.3.11; system Ruby is 2.6 and will fail). Full suite: **118 examples, 0 failures**.
- **Routes verified:** `bin/rails routes | grep ollama` shows `api_v1_settings_ollama` (PATCH) and `api_v1_settings_ollama_test` (POST).
- **Network in tests:** WebMock stubs all Ollama calls; no real network is hit.
- **Known coverage gaps:** no test asserts the literal 5s timeout *value* is passed to HTTParty (behavior is covered via `to_timeout`); no SSRF/private-IP test (not implemented — see §10).

## 10. Known Limitations and TODOs

- **No SSRF hardening:** `test` will GET any user-supplied http/https host (including internal/private IPs). Add an allowlist or private-range block if this becomes a concern.
- **Test uses saved endpoint only** — no "test before save" candidate param.
- **`models` returns names only** — no size/digest/modified-date metadata.
- **Timeout is fixed at 5s** — not configurable per request or via env.
- **No retry** on the connectivity check (intentional — fail fast).
- **`error` message is raw `LLM::Error#message`** (includes the Ruby exception class/text); fine for a setup wizard but not localized.
- **Reachability ≠ "is Ollama"**: a 200 with a parseable `{models: [...]}` is treated as connected; no deeper protocol verification.

## 11. Source of Truth Snapshot

- **Routes:** `PATCH /api/v1/settings/ollama` (`api_v1_settings_ollama`), `POST /api/v1/settings/ollama/test` (`api_v1_settings_ollama_test`).
- **Controller:** `Api::V1::Settings::OllamaController` (`#update`, `#test`).
- **Model validation:** `User#ollama_endpoint_is_http_url` (private), registered via `validate`.
- **Service interface:** `LLM::OllamaClient#list_models` → `Array<String>`; `LLM::OllamaClient.new(model: nil, endpoint: nil)`; `LLM::OllamaClient::TAGS_TIMEOUT = 5`.
- **Shared helper:** `ApplicationController#render_validation_errors(record)` (moved from `ProjectsController`).
- **Response shapes:** PATCH 200 → JSON:API user; PATCH 422 → `{ errors: [{ source:{pointer}, detail }] }`; test → `{ connected: bool, models?: string[], error?: string }` (always 200); 401 → `{ error: "unauthorized" }`.
- **Key files:** `app/controllers/api/v1/settings/ollama_controller.rb`, `app/models/user.rb`, `app/services/llm/ollama_client.rb`, `config/routes.rb`, `app/controllers/application_controller.rb`.
- **Breaking changes:** none external. Internal refactor only: `ProjectsController#render_validation_errors` removed (now inherited) — behavior identical, existing project specs green.

## 12. Copy-Paste Handoff for the Next Engineer

**Already done:** Two working, authenticated, user-scoped endpoints — `PATCH /api/v1/settings/ollama` (save endpoint, http/https validated) and `POST /api/v1/settings/ollama/test` (connectivity + model-name list against the saved endpoint). Full RSpec suite green (118 examples). No migration, no new env vars.

**Safe to depend on:** the route paths, the JSON:API user response on PATCH success, the `422` `errors[].source.pointer = /data/attributes/ollama_endpoint` on bad URLs, and the **always-200** test contract `{ connected, models | error }`. `LLM::OllamaClient#list_models` is reusable and uses the existing `LLM::ConnectionError`/`InvalidResponseError` taxonomy.

**Still to build:** the frontend Ollama setup wizard (this repo is backend only). Optionally, if requirements grow: SSRF hardening on the test GET, "test an unsaved endpoint" param, richer model metadata, configurable timeout.

**Traps / gotchas:** (1) Run specs with `eval "$(rbenv init - zsh)"` — system Ruby 2.6 won't work. (2) The test endpoint never returns 5xx for an unreachable Ollama — branch on the `connected` field, not HTTP status. (3) `render_validation_errors` now lives on `ApplicationController`; don't re-add it to subcontrollers. (4) Test reads the *saved* endpoint — PATCH before POST-test.

**Read first in this contract:** §3 (Public Interface) and §6 (Usage Instructions).
