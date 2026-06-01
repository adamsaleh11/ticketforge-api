# Plan: Supabase JWT Verification & Local User Model

> Source PRD: [docs/prd-supabase-auth-user-model.md](../docs/prd-supabase-auth-user-model.md)

## Architectural decisions

Durable decisions that apply across all phases:

- **Routes**: `GET /api/v1/me` inside the existing `namespace :api { namespace :v1 }`,
  mapped to `Api::V1::UsersController#show`.
- **Schema**: `users` table — `id` bigint PK; `supabase_user_id` string `null: false` +
  unique index; `email` string `null: false`; `name` string nullable; `github_username`
  string nullable; `github_access_token` **text** nullable (encrypted); `ollama_endpoint`
  string `null: false` default `"http://localhost:11434"`; timestamps.
- **Key models**: `User` with `encrypts :github_access_token` (non-deterministic). Holds
  find-or-create + claim-sync logic.
- **Auth**: Supabase-issued HS256 JWT sent as `Authorization: Bearer <token>`. Verified by
  `SupabaseAuth::Verifier` (algorithm pinned to HS256; verify exp; verify `aud:
  "authenticated"`; 30s leeway; secret from `ENV["SUPABASE_JWT_SECRET"]`). Failures raise
  `SupabaseAuth::InvalidTokenError`. `Authenticatable` concern on `ApplicationController`
  provides `before_action :authenticate_user!`, memoized `current_user`, and a canonical
  `401 { "error": "unauthorized" }`. `HealthController` does not inherit the concern.
- **Claim mapping**: `supabase_user_id` ← `sub`; `email` ← top-level `email` then
  `user_metadata["email"]`; `name` ← `user_metadata["full_name"]` || `["name"]`;
  `github_username` ← `user_metadata["user_name"]` || `["preferred_username"]`;
  `github_access_token` ← `app_metadata["provider_token"]` preferred, fallback
  `user_metadata["provider_token"]`.
- **External services**: Supabase (token issuer; we only verify). No outbound calls in this
  slice. WebMock disallows real HTTP in specs.
- **Configuration**: Active Record encryption from `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`,
  `_DETERMINISTIC_KEY`, `_KEY_DERIVATION_SALT` (env in dev/prod; fixed dummy values in
  `config/environments/test.rb`). Test env also fixes `SUPABASE_JWT_SECRET =
  "test-jwt-secret"`. `.env.example` documents the three new keys.
- **Serialization**: `jsonapi-serializer` `UserSerializer` exposing `supabase_user_id`,
  `email`, `name`, `github_username`, `ollama_endpoint`, `created_at`, `updated_at`.
  **Never** `github_access_token`.

---

## Phase 1: Tracer bullet — valid token resolves to a user at `/api/v1/me`

**User stories**: 1, 2, 3, 7 (encrypted storage), 15, 16, 17, 18

### What to build

The complete happy path end-to-end. Configure Active Record encryption (env vars wired in
`config/application.rb`; fixed dummy values + `SUPABASE_JWT_SECRET` in the test env). Add the
`users` migration and `User` model with `encrypts :github_access_token`. Build a baseline
`SupabaseAuth::Verifier` that validates signature, expiry, and `aud: "authenticated"` and
returns the decoded payload. Add the `Authenticatable` concern to `ApplicationController`
with `current_user` (find-or-create by `sub`) and `authenticate_user!`. Expose
`GET /api/v1/me` via `Api::V1::UsersController#show` serialized with `UserSerializer`. Add
the `spec/support/auth_helpers.rb` JWT helper and a `User` factory.

### Acceptance criteria

- [ ] `bin/rails db:migrate` creates the `users` table matching the schema decision.
- [ ] `User.encrypts :github_access_token` round-trips (boots without encryption errors in
      test).
- [ ] A request to `GET /api/v1/me` with a valid Bearer token returns `200`.
- [ ] The 200 body contains `supabase_user_id`, `email`, `name`, `github_username`,
      `ollama_endpoint`, timestamps — and does **not** contain `github_access_token`.
- [ ] The first authenticated request creates exactly one `User` keyed by `sub`.
- [ ] `/health` still returns `{ "status": "ok" }` unauthenticated.
- [ ] The full spec suite passes with no local `.env` (test-env values only).

---

## Phase 2: Rejection matrix & hardening

**User stories**: 8, 9, 10, 11, 12, 13, 14

### What to build

Make `current_user` rescue all verifier failures and have `authenticate_user!` render the
single canonical `401 { "error": "unauthorized" }` for every failure mode. Pin the verifier
algorithm to HS256 so algorithm-confusion attempts are refused. Ensure no bad token produces
a 500.

### Acceptance criteria

- [ ] Missing `Authorization` header → `401 { "error": "unauthorized" }`.
- [ ] Malformed header (not `Bearer <token>`) → identical 401.
- [ ] Expired token → identical 401.
- [ ] Token with `aud` ≠ `authenticated` → identical 401.
- [ ] Token signed with the wrong secret → identical 401.
- [ ] Token with `alg: none` or an asymmetric alg → refused with identical 401 (no signature
      bypass).
- [ ] Every failure returns a byte-identical body and `401` status (no oracle).
- [ ] No auth failure surfaces as a 500.

---

## Phase 3: Profile sync & token preservation

**User stories**: 4, 5, 6 (+ claim-mapping decisions)

### What to build

On each authenticated request, sync `email` / `name` / `github_username` from the token and
update only when changed. Read `github_access_token` from `app_metadata.provider_token` with
fallback to `user_metadata.provider_token`. Apply the nil-guard so an absent `provider_token`
never wipes a stored token. Reuse the existing `User` on repeat requests (no duplicates) and
handle the concurrent-create race via `RecordNotUnique` retry.

### Acceptance criteria

- [ ] A second request with the same `sub` reuses the record (User count stays 1).
- [ ] Changed `email` / `name` / `github_username` in a later token updates the stored
      record; an unchanged token triggers no write.
- [ ] `app_metadata.provider_token` takes precedence over `user_metadata.provider_token`.
- [ ] A token omitting `provider_token` preserves the previously stored token (nil-guard).
- [ ] `github_access_token` persists encrypted (stored ciphertext ≠ plaintext) and decrypts
      correctly (model spec).
- [ ] Concurrent first requests for the same `sub` do not raise and yield one record.
