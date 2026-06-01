# TicketForge API

Rails 7 API-only backend for TicketForge. Generates phased engineering tickets from a
project description using LLMs (Groq), with read-only GitHub integration for repo context.
JSON only — the Next.js frontend lives in a separate repo (`ticketforge-web`).

Authentication is handled by **Supabase**: the frontend obtains a Supabase JWT, sends it in
the `Authorization` header, and the API verifies it in middleware (added in a follow-up
ticket). There is no Devise/session layer in this service.

## Stack

- Ruby 3.3 / Rails 7.1 (API-only)
- PostgreSQL via Supabase over SSL in development/production (`DATABASE_URL`); local
  Postgres for the test suite
- Supabase JWT auth (verified in middleware — next ticket)
- RSpec + WebMock + FactoryBot for tests
- Deployed on Render (free tier)

## Prerequisites

- Ruby 3.3.x (a `.ruby-version` is committed; [rbenv](https://github.com/rbenv/rbenv) recommended)
- A Supabase project — grab its **Session pooler** connection string from
  **Project Settings → Database → Connection string → URI → Session pooler**
  (host `*.pooler.supabase.com`, port `5432`; append `?sslmode=require`)
- PostgreSQL 14+ running locally for the test database
  (`brew install postgresql@16 && brew services start postgresql@16`)
- Bundler (`gem install bundler`)

## Local setup

```bash
# 1. Install dependencies
bundle install

# 2. Configure environment
cp .env.example .env
# Fill in DATABASE_URL (Supabase Session pooler, ending in ?sslmode=require),
# SUPABASE_URL, and SUPABASE_JWT_SECRET. See .env.example for each var.

# 3. Create the local test database (used only by the test suite)
RAILS_ENV=test bin/rails db:create

# 4. Boot the server (connects to Supabase via DATABASE_URL)
bin/rails server
```

The app boots on http://localhost:3000.

> **Database split:** development and production talk to Supabase via `DATABASE_URL`; the
> RSpec suite uses a **local** Postgres database (`ticketforge_api_test`) so tests are fast,
> isolated, and can never touch Supabase data. Supabase provisions its own database — do not
> run `db:create` against it.

## Health check

```bash
curl http://localhost:3000/health
# => {"status":"ok"}
```

## Running tests

```bash
bundle exec rspec
```

WebMock blocks all real outbound HTTP in the test suite — external services (Groq, GitHub)
must always be stubbed.

## API conventions

- All versioned endpoints live under `/api/v1`. `/health` is the only unauthenticated,
  unversioned route.
- Responses are JSON only.
- See [`CLAUDE.md`](CLAUDE.md) for the full set of project rules and integration guidelines.

## Deployment (Render)

The `Procfile` defines the `web` process (`bundle exec rails server -p $PORT`).

Set these environment variables in the Render dashboard: `DATABASE_URL` (Supabase Session
pooler, with `?sslmode=require`), `SUPABASE_URL`, `SUPABASE_JWT_SECRET`, `GROQ_API_KEY`,
`FRONTEND_URL`, and `RAILS_MASTER_KEY` (decrypts `config/credentials.yml.enc`).
