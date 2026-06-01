# PRD — TicketForge API: Initial Application Scaffold

**Status:** Approved for planning
**Date:** 2026-05-31
**Owner:** shilpatel821@gmail.com

## Problem Statement

There is no backend application yet. The repository contains only agent instructions
(`CLAUDE.md`/`agents.md`), a `.gitignore`, and Claude skills — no Rails app, no Gemfile,
no boot path. The local machine has only system Ruby 2.6.10, no Ruby version manager, and
no Rails installed, so nothing can run.

Before any TicketForge feature work (LLM ticket generation, GitHub repo context, JWT auth
flows) can begin, the team needs a correctly generated, bootable Rails 7 API-only skeleton
that already embeds the project's hard rules: API-only JSON, `/api/v1` namespacing,
Postgres-over-SSL for Supabase, Devise + JWT auth wiring, CORS for the separate Next.js
frontend, and a deployable configuration for Render's free tier. Without this foundation,
every downstream task is blocked.

## Solution

Produce a real `rails new --api` skeleton (not hand-authored) on Ruby 3.3.x / Rails 7.1.x,
configured so that:

- It boots locally against local Postgres for development and test, and connects to Supabase
  over SSL in production via `DATABASE_URL`.
- Authentication infrastructure (Devise + devise-jwt with a JTIMatcher revocation strategy)
  is installed and configured JSON-only, including a `User` model and migration — but the
  actual auth endpoints are deferred.
- CORS allows the local frontend and the eventual Vercel domain, and exposes the
  `Authorization` header so the frontend can read issued JWTs.
- A dependency baseline (the requested gems plus an RSpec/WebMock/FactoryBot test harness)
  is in place, with `dotenv-rails` loading env locally only.
- A `GET /health` endpoint returns `{ "status": "ok" }` with no auth, outside the API
  namespace, as a deploy smoke test.
- Render deploy config (`Procfile` with `web` + `release` migration phase), an
  `.env.example`, and a README with local setup instructions exist.
- Rails Active Record encryption keys are initialized so future `encrypts` attributes
  (e.g. GitHub tokens) work with no rework.

The result is a green-on-boot scaffold that satisfies `CLAUDE.md`'s conventions and is
immediately extensible by follow-up feature tasks.

## User Stories

1. As a backend developer, I want a generated Rails 7.1 API-only application on Ruby 3.3,
   so that I have a conventional, bootable foundation to build on.
2. As a backend developer, I want a pinned `.ruby-version` and resolved `Gemfile.lock`,
   so that every contributor and the Render deploy use the same toolchain.
3. As a backend developer, I want local Postgres used for development and test,
   so that running specs never touches the production Supabase database.
4. As an operator, I want production to connect to Supabase over SSL via `DATABASE_URL`
   with `sslmode=require`, so that production data is encrypted in transit.
5. As a frontend developer, I want CORS to allow `http://localhost:3000` and the Vercel
   domain from `FRONTEND_URL`, so that the Next.js app can call the API in dev and prod.
6. As a frontend developer, I want the `Authorization` response header exposed via CORS,
   so that I can read the JWT that devise-jwt issues on login.
7. As a backend developer, I want Devise + devise-jwt installed with a `User` model
   (`email`, `encrypted_password`, `jti`) and a JTIMatcher revocation strategy,
   so that JWT auth can be implemented in a follow-up without re-scaffolding.
8. As a backend developer, I want Devise configured JSON-only (no navigational/flash
   behavior), so that the API never attempts to render HTML.
9. As a monitoring system, I want `GET /health` to return `{ "status": "ok" }` with HTTP
   200 and no auth, so that I can verify the service is up.
10. As a backend developer, I want an `/api/v1` namespace scaffolded (empty),
    so that future versioned endpoints have a defined home per `CLAUDE.md`.
11. As a backend developer, I want an RSpec + WebMock + FactoryBot test harness plus a
    passing `/health` request spec, so that the "specs required" hard rule is satisfied
    from the first commit.
12. As an operator, I want a `Procfile` with a `web` process and a `release` phase running
    `db:migrate`, so that Render boots the server and runs migrations on deploy.
13. As a new contributor, I want an `.env.example` listing every required env var,
    so that I can configure my environment without reading source.
14. As a new contributor, I want a README with step-by-step local setup,
    so that I can get the app running and run the test suite quickly.
15. As a backend developer, I want Active Record encryption keys initialized in credentials,
    so that future `encrypts :github_token` works without additional setup.
16. As a security-conscious developer, I want `.env` and `config/master.key` gitignored,
    so that secrets are never committed.
17. As a backend developer, I want the requested HTTP/LLM gems (`httparty`, `faraday`,
    `ruby-openai`) installed, so that the LLM and GitHub service work can start immediately
    in follow-up tasks.

## Implementation Decisions

**Toolchain & generation**
- Install `rbenv` via Homebrew; install Ruby 3.3.x; `gem install rails` (7.1.x).
- Generate with `rails new ticketforge-api --api --database=postgresql -T` (`-T` skips
  Minitest; RSpec is used instead). Pin `.ruby-version`; commit `Gemfile.lock`.

**Database**
- `config/database.yml`: development and test use local Postgres
  (`ticketforge_api_development` / `ticketforge_api_test`). Production uses
  `url: ENV["DATABASE_URL"]`.
- SSL is enforced by the `?sslmode=require` query string carried in Supabase's
  `DATABASE_URL`, not hardcoded in `database.yml`.

**Auth (infrastructure only; endpoints deferred)**
- Gems `devise` + `devise-jwt`.
- `User` model with Devise modules: `database_authenticatable`, `registerable`,
  `validatable`, `jwt_authenticatable`. Excluded: `recoverable`, `confirmable`,
  `trackable`, `rememberable`.
- Schema: `users` table with `email`, `encrypted_password`, `jti`; unique indexes on
  `email` and `jti`. Reversible migration.
- Revocation strategy: `Devise::JWT::RevocationStrategies::JTIMatcher` on `User`.
- devise-jwt config: dispatch on `POST /login`, revoke on `DELETE /logout`; secret from
  `ENV["DEVISE_JWT_SECRET_KEY"]`.
- Devise configured API/JSON-only: `config.navigational_formats = []`.

**HTTP / external clients**
- Add `jsonapi-serializer`, `httparty`, `faraday`, `ruby-openai` (no configuration of the
  LLM factory in this task — gem availability only).

**CORS**
- `rack-cors` initializer at `config/initializers/cors.rb`.
- Origins: `http://localhost:3000` and `ENV["FRONTEND_URL"]` (compacted so a missing var
  does not break boot).
- `expose: ["Authorization"]`; methods get/post/put/patch/delete/options/head;
  `credentials: false`.

**Endpoints & routing**
- `GET /health` → `HealthController < ActionController::API`, no auth, renders
  `{ status: "ok" }` (HTTP 200), static (no DB ping).
- Routes: `/health` at top level; empty `namespace :api { namespace :v1 }` block present.

**Config & secrets**
- `dotenv-rails` in `:development, :test` groups only.
- `.env.example` with: `DATABASE_URL`, `DEVISE_JWT_SECRET_KEY`, `GROQ_API_KEY`,
  `FRONTEND_URL`, `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` (inline comments).
- `bin/rails db:encryption:init`; store the three keys in Rails credentials.
- `.gitignore` covers `.env` and `config/master.key`.

**Deploy**
- `Procfile`: `web: bundle exec rails server -p $PORT` and
  `release: bundle exec rails db:migrate`.

**Version control**
- Do not commit unless the user requests it. If requested, create a branch
  (e.g. `scaffold/initial-app`) off `main` first.

## Testing Decisions

- Good tests here assert externally observable behavior and boot health, not Rails
  internals. The scaffold's job is to *boot and serve*, so coverage targets that.
- Required: a `/health` request spec asserting HTTP 200 and body `{ "status": "ok" }`.
- Test harness: `rspec-rails`, `factory_bot_rails`, `webmock` in the `:test` group;
  WebMock configured to disable real external HTTP (no network in tests).
- A `User` factory is created so future auth specs have prior art, but auth-endpoint
  specs are deferred with the auth endpoints themselves.
- No prior art exists in-repo (greenfield); these specs establish the patterns.

## Out of Scope

- Auth endpoints: signup, login, logout, me controllers and their specs.
- LLM integration: `LLM::Client.for` factory, Groq/Ollama implementations, prompt/
  `TicketGenerator` orchestration, `LLM::InvalidResponseError` handling.
- GitHub integration: `RepoContext` builder, tree caching, file filtering.
- Domain models beyond `User` (e.g. `Project`, tickets) and their serializers.
- Applying `encrypts` to any concrete attribute (keys are initialized, not yet used).
- Production provisioning of the actual Supabase instance and Render service.
- Rate limiting, observability, background jobs (explicitly disallowed by `CLAUDE.md`).

## Further Notes

- **Assumption:** Render's build image supports Ruby 3.3.x. If it pins lower, fall back
  to Ruby 3.2.x — `.ruby-version` is the single point of change.
- **Assumption:** the Supabase `DATABASE_URL` (pooler form) already includes
  `?sslmode=require`; documented in `.env.example` so it is not forgotten.
- **Dependency:** local Postgres 16 is already installed and was confirmed available.
- **JTIMatcher tradeoff:** logout rotates the user's single `jti`, invalidating all that
  user's active tokens at once. Acceptable for MVP; revisit a Denylist strategy if
  per-device logout is ever required.
- **Open question:** if the user prefers a web-only `Procfile`, drop the `release`
  migration phase and run migrations manually.
- **Follow-up:** the very next planned task should be the auth endpoints (Out of Scope
  item #1), since most API surface depends on `current_user`.
