# Plan: TicketForge API — Initial Application Scaffold

> Source PRD: [docs/prd-scaffold.md](../docs/prd-scaffold.md)

## Architectural decisions

Durable decisions that apply across all phases:

- **Toolchain**: rbenv-managed Ruby 3.3.x (pinned in `.ruby-version`), Rails 7.1.x,
  API-only. Fallback to Ruby 3.2.x only if Render's image forces it.
- **Routes**: `GET /health` at top level (no auth). Empty `namespace :api { namespace :v1 }`
  reserved for all future endpoints.
- **Schema**: `users` table — `email`, `encrypted_password`, `jti`; unique indexes on
  `email` and `jti`. All migrations reversible.
- **Key models**: `User` (only model in scope).
- **Auth**: Devise + devise-jwt, JSON-only (`navigational_formats = []`). Modules:
  `database_authenticatable`, `registerable`, `validatable`, `jwt_authenticatable`.
  Revocation via `JTIMatcher`; dispatch on `POST /login`, revoke on `DELETE /logout`;
  secret from `ENV["DEVISE_JWT_SECRET_KEY"]`. Auth *endpoints* are deferred (next plan).
- **Database**: local Postgres for development/test; production via `ENV["DATABASE_URL"]`
  with SSL enforced by the URL's `?sslmode=require` query string (not hardcoded).
- **External services**: gems installed but unconfigured this scaffold — `httparty`,
  `faraday`, `ruby-openai` (Groq-compatible), `jsonapi-serializer`.
- **Secrets**: `dotenv-rails` in dev/test only; AR encryption keys initialized in
  credentials; `.env` and `config/master.key` gitignored.
- **Deploy**: Render via `Procfile` — `web` process + `release: db:migrate`.
- **Testing**: RSpec + WebMock (real HTTP disabled) + FactoryBot.
- **Version control**: no commits unless requested; if requested, branch
  `scaffold/initial-app` off `main` first.

---

## Phase 1: Bootable API skeleton + `/health` + test harness

**User stories**: 1, 2, 3, 9, 10, 11

### What to build

The tracer bullet: a real `rails new ticketforge-api --api --database=postgresql -T`
skeleton on Ruby 3.3 / Rails 7.1. Pin `.ruby-version`, commit `Gemfile.lock`. Configure
`database.yml` so development and test use local Postgres
(`ticketforge_api_development` / `ticketforge_api_test`). Add the RSpec + WebMock +
FactoryBot test harness with real external HTTP disabled. Implement `GET /health`
returning `{ "status": "ok" }` (HTTP 200, no auth) via a dedicated API controller, and
scaffold the empty `/api/v1` namespace. Write the `/health` request spec first (red),
then make it green.

### Acceptance criteria

- [ ] `rbenv`/Ruby 3.3.x installed; `.ruby-version` pinned; `Gemfile.lock` committed.
- [ ] `bin/rails db:create db:migrate` succeeds against local Postgres for dev and test.
- [ ] `bin/rails server` boots with no errors.
- [ ] `curl localhost:3000/health` returns `{"status":"ok"}` with HTTP 200 and no auth.
- [ ] Routes include an (empty) `namespace :api { namespace :v1 }` block.
- [ ] `bundle exec rspec` runs green, including a `/health` request spec asserting status
      and body.
- [ ] WebMock is configured to raise on any real outbound HTTP in tests.

---

## Phase 2: Auth infrastructure (Devise + devise-jwt + User)

**User stories**: 7, 8

### What to build

Install `devise` and `devise-jwt`. Generate the `User` model and a reversible migration
for the `users` table (`email`, `encrypted_password`, `jti`; unique indexes on `email`
and `jti`). Configure Devise modules (`database_authenticatable`, `registerable`,
`validatable`, `jwt_authenticatable`) with the `JTIMatcher` revocation strategy, JSON-only
behavior (`navigational_formats = []`), and devise-jwt dispatch/revoke on
`POST /login` / `DELETE /logout` using `ENV["DEVISE_JWT_SECRET_KEY"]`. Add a `User`
factory. Auth endpoints themselves remain deferred.

### Acceptance criteria

- [ ] `users` migration runs and rolls back cleanly (reversible).
- [ ] `User.create!(email:, password:)` succeeds in the console; `jti` is populated.
- [ ] Uniqueness enforced on `email` and `jti` at the DB and model layers.
- [ ] devise-jwt configured for JTIMatcher with dispatch/revoke routes and env secret.
- [ ] Devise is JSON-only (no navigational/flash rendering).
- [ ] A FactoryBot `User` factory builds and persists a valid user.
- [ ] `bundle exec rspec` stays green (model/factory specs as appropriate).

---

## Phase 3: Frontend & deploy readiness

**User stories**: 4, 5, 6, 12, 13, 14, 15, 16, 17

### What to build

Add and configure `rack-cors`: origins `http://localhost:3000` and `ENV["FRONTEND_URL"]`
(compacted), `expose: ["Authorization"]`, standard methods, `credentials: false`.
Configure the production `database.yml` block for `ENV["DATABASE_URL"]` (SSL via URL).
Add the remaining gems (`httparty`, `faraday`, `ruby-openai`, `jsonapi-serializer`) and
`dotenv-rails` in dev/test. Initialize AR encryption keys into credentials. Write
`.env.example` (six documented vars), ensure `.gitignore` covers `.env` and
`config/master.key`, add the `Procfile` (`web` + `release: db:migrate`), and a README with
local setup + test instructions.

### Acceptance criteria

- [ ] CORS preflight from `http://localhost:3000` succeeds and `Authorization` is exposed.
- [ ] Production `database.yml` reads `ENV["DATABASE_URL"]`; SSL documented via URL.
- [ ] `.env.example` lists `DATABASE_URL`, `DEVISE_JWT_SECRET_KEY`, `GROQ_API_KEY`,
      `FRONTEND_URL`, `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` with comments.
- [ ] AR encryption keys present in credentials (future `encrypts` works without rework).
- [ ] `.gitignore` excludes `.env` and `config/master.key`.
- [ ] `Procfile` contains the `web` and `release` lines.
- [ ] README documents prerequisites, install, env setup, db setup, run, and `rspec`.
- [ ] `bundle exec rspec` remains green.
