# TicketForge API — Agent Instructions

## What this repo is
Rails 7 API-only backend for TicketForge. Generates phased engineering tickets from a project description using LLMs (Groq or Ollama). Read-only GitHub integration for repo context. JWT auth.

Frontend lives in a separate repo: `ticketforge-web` (Next.js). This repo never serves HTML — JSON only.

## Stack
- Ruby 3.2+, Rails 7.1+ (API-only)
- PostgreSQL via Supabase (connection over SSL)
- Devise + devise-jwt for auth
- HTTParty / Faraday for external HTTP (Groq, Ollama, GitHub)
- RSpec for tests, WebMock for HTTP stubbing
- Deployed on Render free tier

## Project structure conventions

```
app/
  controllers/
    api/v1/         # All JSON endpoints versioned under /api/v1
    auth/           # Devise overrides (signup, login, logout, me)
  models/           # ActiveRecord, thin
  serializers/      # jsonapi-serializer, one per model
  services/
    llm/            # LLMClient factory + Groq/Ollama implementations
    github/         # RepoContext builder
    ticket_generator/  # Orchestration + prompts
```

## Hard rules
1. **No business logic in controllers.** Controllers parse params, call a service or model method, render JSON. That's it.
2. **All endpoints under `/api/v1`** except `/health`, `/signup`, `/login`, `/logout`.
3. **Always scope queries by `current_user`.** Use `current_user.projects.find(params[:id])`, never `Project.find`. This is the authorization layer — don't break it.
4. **Strong params always.** No `params.permit!`.
5. **Encrypted attributes** for any third-party token (GitHub token, future API keys). Use Rails' `encrypts :field` macro.
6. **Migrations are reversible.** Use `change` with reversible blocks or explicit `up`/`down`.
7. **Specs required** for every new endpoint. Happy path + unauthorized + validation failure. Minimum.
8. **No N+1 queries.** Use `includes` when serializing collections. Add Bullet gem in development if helpful.

## LLM integration rules
- Never call Groq or Ollama directly from a controller. Always go through `LLM::Client.for(...)`.
- LLM responses must be validated before persisting. If JSON parsing fails or schema doesn't match, raise `LLM::InvalidResponseError` and surface a clean error to the user.
- 60s timeout, 1 retry on connection errors only. Never retry on 4xx.
- `TicketGenerator` runs synchronously (Render free tier has no background workers). Expect 30–60s requests. Set controller timeout accordingly.

## GitHub integration rules
- Read-only. Scopes: `public_repo`, `read:user`. Never request write scopes even if asked.
- Cache repo trees in `Rails.cache` for 10 minutes per repo to stay under GitHub rate limits.
- Filter file trees: exclude `node_modules`, `.git`, `dist`, `build`, `vendor`, `*.lock`, images, fonts, anything over 100KB.

## Testing
- Run: `bundle exec rspec`
- Stub all external HTTP with WebMock. Never hit Groq / Ollama / GitHub in tests.
- Factory Bot for fixtures.

## Env vars (see `.env.example`)
`DATABASE_URL`, `DEVISE_JWT_SECRET_KEY`, `GROQ_API_KEY`, `FRONTEND_URL`, `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `RAILS_MASTER_KEY`

## What NOT to do
- Don't add Redis. Use `Rails.cache` (memory store in dev, Render disk in prod) or `solid_cache` if needed later.
- Don't add Sidekiq or any background job framework. Synchronous only for now.
- Don't introduce GraphQL. REST only.
- Don't add new gems without asking — the dependency list is intentionally small.
- Don't change the auth strategy. Devise + JWT stays.

## When stuck
Ask before guessing. Especially around: auth flows, serializer shape changes, migration design on existing tables.
