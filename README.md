# TicketForge API

Rails 7 API-only backend for TicketForge. Generates phased engineering tickets from a
project description using LLMs (Groq or Ollama), with read-only GitHub integration for repo
context and JWT auth. JSON only — the Next.js frontend lives in a separate repo
(`ticketforge-web`).

## Stack

- Ruby 3.3 / Rails 7.1 (API-only)
- PostgreSQL via Supabase over SSL in all environments (`DATABASE_URL`)
- Devise + devise-jwt for authentication
- RSpec + WebMock + FactoryBot for tests
- Deployed on Render (free tier)

## Prerequisites

- Ruby 3.3.x (a `.ruby-version` is committed; [rbenv](https://github.com/rbenv/rbenv) recommended)
- A Supabase project — grab its connection string from
  **Project Settings → Database → Connection string → URI** (use the pooler URI; it
  already includes `?sslmode=require`)
- Bundler (`gem install bundler`)

## Local setup

```bash
# 1. Install dependencies
bundle install

# 2. Configure environment
cp .env.example .env
# Set DATABASE_URL to your Supabase connection string (must end with ?sslmode=require).

# 3. Generate a JWT signing secret and paste it into .env as DEVISE_JWT_SECRET_KEY
bin/rails secret

# 4. Apply the schema to Supabase. Do NOT run db:create (Supabase manages the
#    database) — migrate only.
bin/rails db:migrate

# 5. Boot the server
bin/rails server
```

The app boots on http://localhost:3000.

> **Heads up — shared database:** development and test both point at the same Supabase
> database. The RSpec suite uses transactional fixtures so it rolls back its data, but
> **never** run `db:test:prepare`, `db:reset`, or `db:test:purge` against it — they drop
> every table. Apply schema changes with `bin/rails db:migrate` only.

> **Credentials:** `config/master.key` decrypts `config/credentials.yml.enc` (which holds the
> Active Record encryption keys). It is gitignored. In production, set `RAILS_MASTER_KEY`
> as an environment variable instead.

## Health check

```bash
curl http://localhost:3000/health
# => {"status":"ok"}
```

## Running tests

```bash
bundle exec rspec
```

WebMock blocks all real outbound HTTP in the test suite — external services (Groq, Ollama,
GitHub) must always be stubbed.

## API conventions

- All versioned endpoints live under `/api/v1`. `/health` is the only unauthenticated,
  unversioned route.
- Responses are JSON only; there is no HTML/flash behavior.
- See [`CLAUDE.md`](CLAUDE.md) for the full set of project rules and integration guidelines.

## Deployment (Render)

The `Procfile` defines:

- `web` — boots the Rails server on `$PORT`
- `release` — runs `db:migrate` on each deploy

Set these environment variables in the Render dashboard: `DATABASE_URL` (Supabase, with
`?sslmode=require`), `DEVISE_JWT_SECRET_KEY`, `GROQ_API_KEY`, `FRONTEND_URL`,
`GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, and `RAILS_MASTER_KEY`.
