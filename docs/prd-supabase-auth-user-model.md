# PRD — TicketForge API: Supabase JWT Verification & Local User Model

**Status:** Approved for planning
**Date:** 2026-05-31
**Owner:** shilpatel821@gmail.com

## Problem Statement

The Rails API skeleton boots and serves an unauthenticated `/health` endpoint, but it has
**no authentication and no user persistence**. The earlier scaffold left placeholders —
routes comment that "authentication is handled by verifying Supabase-issued JWTs in
middleware (added in a follow-up ticket)" — and the Devise/`User` artifacts from the
initial scaffold were since removed (see deleted `app/models/user.rb`,
`config/initializers/devise.rb`, and the `devise_create_users` migration in the working
tree). The database has zero application tables (`schema.rb` is at version 0).

As a result, the frontend (`ticketforge-web`) can sign a user in with GitHub via Supabase
and obtain a session JWT, but there is nowhere to send it: the backend cannot verify the
token, cannot identify the caller, and has no record to attach future projects/tickets to.
Every downstream feature (projects, GitHub repo context, LLM ticket generation, per-user
Ollama settings) is blocked on having an authenticated `current_user`.

Compounding this, the scaffold PRD assumed Active Record encryption keys would be
initialized "so future `encrypts` attributes work with no rework," but the current
credentials contain only `secret_key_base` — there is **no `active_record_encryption`
configuration**. Since the GitHub access token must be stored encrypted, this gap must be
closed as part of this work or the model will raise on first use.

## Solution

Introduce token-based authentication backed by a local `User` table, so that any request
carrying a valid Supabase access token is transparently resolved to a persisted user, and
unauthenticated requests are rejected with a clean 401.

From the caller's perspective:

- The frontend attaches the Supabase session token as `Authorization: Bearer <token>` on
  every API call (already its convention).
- The backend verifies that token's signature, expiry, and audience against the shared
  Supabase JWT secret. A valid token transparently finds-or-creates a `User` keyed by the
  Supabase user id, syncing profile fields (email, name, GitHub username) and the GitHub
  access token from the token's claims on each request.
- A new `GET /api/v1/me` endpoint returns the authenticated user's profile as JSON,
  giving the frontend a way to bootstrap session state and confirm the token round-trips.
- Any request with a missing, malformed, expired, wrong-audience, or wrongly-signed token
  receives `401 { "error": "unauthorized" }` with no detail that distinguishes the failure
  mode.
- The GitHub access token is persisted **encrypted at rest** and is **never** returned in
  any API response.

Active Record encryption is configured (via environment variables in dev/prod, fixed dummy
values in test) so `encrypts` works without rework, closing the gap the scaffold left open.

## User Stories

1. As the frontend, I want to send a Supabase session token as a Bearer header and have the
   backend accept it, so that authenticated API calls succeed without a separate login step.
2. As the frontend, I want `GET /api/v1/me` to return the current user's profile, so that I
   can hydrate session UI and verify the token is valid end-to-end.
3. As a first-time user, I want my `User` record created automatically on my first
   authenticated request, so that I never hit a "user not found" error after signing in.
4. As a returning user, I want my existing `User` record reused on subsequent requests, so
   that no duplicate accounts are created for the same Supabase identity.
5. As a returning user who updated my GitHub profile, I want my email / name / GitHub
   username refreshed from the token on each request, so that my stored profile stays
   current without a manual sync.
6. As a user whose Supabase session was refreshed without a fresh `provider_token`, I want
   my previously-stored GitHub access token preserved (not wiped), so that GitHub-backed
   features keep working across token refreshes.
7. As a security-conscious user, I want my GitHub access token stored encrypted and never
   echoed back by the API, so that a database leak or response inspection does not expose it.
8. As any caller, I want a request with no `Authorization` header rejected with 401, so that
   unauthenticated access is impossible.
9. As any caller, I want a malformed `Authorization` header (not `Bearer <token>`) rejected
   with 401, so that header parsing bugs cannot bypass auth.
10. As any caller, I want an expired token rejected with 401, so that stale sessions cannot
    be replayed.
11. As any caller, I want a token whose audience is not `authenticated` rejected with 401,
    so that tokens minted for other purposes cannot be reused against this API.
12. As any caller, I want a token signed with the wrong secret rejected with 401, so that
    forged tokens are refused.
13. As an attacker, I want algorithm-confusion attacks (e.g. `alg: none`, RS/HS swap)
    refused, so that the verifier cannot be tricked into skipping signature checks.
14. As an attacker probing the API, I want all auth failures to return an identical 401
    body, so that I cannot learn *why* a token was rejected.
15. As an operator, I want Active Record encryption keys supplied via environment variables
    in dev/prod, so that secrets live alongside the existing env-var configuration and not
    baked into source or coupled to `master.key`.
16. As a developer running the test suite, I want auth and encryption to work with fixed
    test-environment values, so that specs are deterministic and require no local `.env`.
17. As a developer writing future endpoints, I want `current_user` available in any
    controller inheriting from `ApplicationController`, so that I can build authenticated
    features without re-implementing token handling.
18. As an operator, I want the `/health` endpoint to remain unauthenticated, so that uptime
    monitoring and deploy smoke tests keep working.

## Implementation Decisions

### Modules to build or modify

- **`SupabaseAuth::Verifier` (new service).** Single entry point `Verifier.call(token)` that
  decodes and validates a Supabase JWT and returns the decoded payload as a plain hash, or
  raises `SupabaseAuth::InvalidTokenError`. Hides all `jwt` gem mechanics behind a stable
  interface.
  - Decode options: algorithm **pinned** to `HS256` (passed explicitly to prevent
    algorithm-confusion / `alg: none`), `verify_expiration: true`, `verify_aud: true`,
    `aud: "authenticated"`, `leeway: 30` seconds for clock skew.
  - Secret read from `ENV["SUPABASE_JWT_SECRET"]`.
  - Blank token raises `InvalidTokenError`. All `JWT::DecodeError` subclasses (expired,
    signature, audience, malformed) are caught and re-raised as `InvalidTokenError`.
- **`SupabaseAuth::InvalidTokenError` (new error class).** Namespaced error the verifier
  raises and the controller concern rescues.
- **`Authenticatable` (new controller concern).** `extend ActiveSupport::Concern`; on
  inclusion adds `before_action :authenticate_user!`. Provides:
  - `current_user` — extracts the Bearer token, verifies it via `SupabaseAuth::Verifier`,
    finds-or-creates the `User`, and returns it. Memoized per request including a legitimate
    nil result (guarded so a nil is not recomputed on every call). Rescues
    `InvalidTokenError` internally and returns nil.
  - `authenticate_user!` — renders 401 when `current_user` is nil.
  - A private `render_unauthorized` helper producing the single canonical 401 body.
- **`ApplicationController`.** Includes `Authenticatable`, making every controller that
  inherits from it authenticated by default. `HealthController` and the CORS preflight path
  do **not** inherit the concern and remain unauthenticated.
- **`User` (new model).** `encrypts :github_access_token` (non-deterministic, the default).
  Holds the find-or-create + field-sync logic (or delegates it to a class method used by the
  concern).
- **`Api::V1::UsersController` (new controller).** `#show` action mapped to `/api/v1/me`,
  returns the serialized current user with status 200.
- **`UserSerializer` (new, `jsonapi-serializer`).** Exposes `supabase_user_id`, `email`,
  `name`, `github_username`, `ollama_endpoint`, `created_at`, `updated_at`. **Excludes**
  `github_access_token` entirely.
- **Configuration.** Active Record encryption wired in `config/application.rb` from
  `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`,
  `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`. Fixed dummy encryption values **and**
  `SUPABASE_JWT_SECRET = "test-jwt-secret"` set in `config/environments/test.rb`.
  `.env.example` documents the three new keys.

### Schema changes

New `users` table:

- `id` — bigint primary key (Rails default).
- `supabase_user_id` — string, `null: false`, unique index.
- `email` — string, `null: false`.
- `name` — string, nullable.
- `github_username` — string, nullable.
- `github_access_token` — **text** (encrypted ciphertext exceeds plaintext length;
  `text` avoids truncation), nullable.
- `ollama_endpoint` — string, `null: false`, default `"http://localhost:11434"`.
- `created_at` / `updated_at` timestamps.

### API contract

- `GET /api/v1/me`
  - Auth: `Authorization: Bearer <supabase-jwt>` required.
  - 200: serialized user (fields listed above; no token).
  - 401: `{ "error": "unauthorized" }` for any auth failure.
- Route added inside the existing `namespace :api { namespace :v1 }`:
  `get "me", to: "users#show"`.

### Claim mapping (token → User)

- Find by `supabase_user_id` = JWT `sub`.
- `email` ← top-level `email` claim, fallback `user_metadata["email"]`.
- `name` ← `user_metadata["full_name"]` || `user_metadata["name"]`.
- `github_username` ← `user_metadata["user_name"]` || `user_metadata["preferred_username"]`.
- `github_access_token` ← `app_metadata["provider_token"]` **preferred**, fallback
  `user_metadata["provider_token"]`.

### Find-or-create / sync behavior

- `find_or_initialize_by(supabase_user_id:)`, assign synced attributes, `save!` only when
  the record is new or changed.
- **Nil-guard:** do not overwrite `github_access_token` (nor other GitHub fields) with nil
  when the claim is absent — only update when a value is present, preserving tokens across
  Supabase session refreshes that omit `provider_token`.
- **Race handling:** rescue `ActiveRecord::RecordNotUnique` on create (two concurrent first
  requests) and retry the find.

### Error / security decisions

- Algorithm pinned to HS256; no caller-supplied algorithm honored.
- All auth failures return an identical minimal 401 body — no oracle distinguishing missing
  vs. expired vs. malformed vs. bad-signature vs. wrong-audience.
- Bad tokens never surface as 500s; the concern rescues verifier errors and returns 401.

## Testing Decisions

- **Style:** test external behavior and contracts through real request specs hitting
  `GET /api/v1/me`, not internal method calls. Mirrors the existing
  `spec/requests/health_spec.rb` / `cors_spec.rb` request-spec prior art.
- **Shared helper:** `spec/support/auth_helpers.rb` exposing
  `valid_supabase_jwt(overrides = {})` that builds a payload (`sub`, `aud: "authenticated"`,
  `exp`, `email`, `user_metadata`, `app_metadata`) and signs with
  `ENV["SUPABASE_JWT_SECRET"]` (the test-env value). Included via
  `config.include AuthHelpers, type: :request`. The secret is sourced from one place only —
  never hardcoded in two locations.
- **`User` factory:** re-add `spec/factories/users.rb` (the prior one was deleted) for any
  model-level coverage.
- **Request-spec coverage (must be called out):**
  - Valid token → 200 with the expected body, and **assert `github_access_token` is absent**
    from the response.
  - Missing `Authorization` header → 401.
  - Malformed Bearer header → 401.
  - Expired token → 401.
  - Wrong audience → 401.
  - Wrong signature → 401.
  - First request **creates** a `User`; second request with the same `sub` **reuses** it
    (no duplicate; assert count).
  - `provider_token` present in `app_metadata` takes precedence over `user_metadata`.
  - A refreshed token omitting `provider_token` **preserves** the previously stored token
    (nil-guard).
- **Model-level coverage (called out):** the field-sync + nil-guard logic and that
  `github_access_token` round-trips through encryption (stored ciphertext ≠ plaintext,
  decrypts correctly).

## Out of Scope

- Projects, tickets, GitHub repo context, and LLM/Ollama/Groq integration endpoints — this
  PRD delivers only auth + the `/me` profile read.
- Any write endpoints for `User` (e.g. updating `ollama_endpoint`); only `GET /me` ships.
- Token refresh, sign-in, sign-out, and OAuth flows — those live entirely in the frontend
  via Supabase; the backend only verifies.
- Role/authorization tiers (admin vs. user); all authenticated users are equal here.
- Replacing the stray frontend `CLAUDE.md` in this repo with backend-specific instructions.
- Fixing the dev `DATABASE_URL` (IPv6 direct-host) note — pre-existing, not caused here.
- Rotating or revoking Supabase-side secrets.

## Further Notes

- **Blocking dependency:** Active Record encryption must be configured before `encrypts`
  works. This PRD includes that configuration; the three new env vars must be set in dev
  (`.env`) and prod (Render) for real use. Test env uses fixed dummy values, so the suite
  passes with no local `.env`.
- **Secret reuse:** `SUPABASE_JWT_SECRET` already exists in `.env` and `.env.example`; the
  verifier reuses it. The test value is fixed in `config/environments/test.rb`.
- **Assumption:** Supabase issues HS256-signed JWTs with `aud: "authenticated"` and the
  GitHub identity under `user_metadata` / `app_metadata`. If a given Supabase project is
  configured for asymmetric (RS256) signing, the verifier's pinned algorithm would need
  revisiting — flagged as a follow-up, not handled now.
- **Forward-looking:** `current_user` becomes the foundation every later authenticated
  endpoint builds on; keeping it in a concern on `ApplicationController` means future
  controllers are authenticated by default and must opt out explicitly (as `HealthController`
  does by not inheriting it).
- **Frontend contract:** on 401 the frontend signs out and redirects to `/login`; the stable
  minimal 401 body supports that without leaking failure detail.
