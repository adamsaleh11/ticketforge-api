# Plan: GitHub Read-Only Repo & Context Endpoints

> Source PRD: docs/prd-github-repo-context.md

## Architectural decisions

Durable decisions that apply across all phases:

- **Routes** (explicit, inside the existing `api/v1` namespace, under a new `github` namespace):
  - `GET /api/v1/github/repos` → `Api::V1::Github::ReposController#index`
  - `GET /api/v1/github/repos/:owner/:repo/context` → `Api::V1::Github::ReposController#context`
- **Schema**: none. Uses the existing encrypted `users.github_access_token`.
- **Key services**:
  - `Github::Client.new(user)` — authenticated HTTParty wrapper over `https://api.github.com`.
  - `Github::RepoContext.build(user, owner, repo)` → `{ tree:, readme:, languages:, truncated: }`.
- **Error taxonomy** (mirrors `LLM::`): `Github::Error` base; `Github::ConnectionError`, `Github::InvalidResponseError`, `Github::NotFoundError`, `Github::UnauthorizedError`.
- **HTTP client**: HTTParty (matches `LLM::Client`), single retry on connection errors. Deliberate deviation from the PRD's original "Faraday" wording.
- **Auth**: existing `Authenticatable` concern; `current_user` carries the token. `rescue_from` for `Github::` errors scoped to the Github controller, not `ApplicationController`.
- **External service**: GitHub REST API, `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`.
- **Caching**: only `RepoContext`, key `github:repo_context:{owner}/{repo}`, `expires_in: 10.minutes`, per-repo (not per-user).

---

## Phase 1: `Github::Client` + repos list endpoint

**User stories**: 1–5, 15, 16, 19

### What to build

The authenticated `Github::Client` with its error taxonomy and single-retry idiom, plus blank-token fast-fail. Wire `GET /api/v1/github/repos` through `Api::V1::Github::ReposController#index`, mapping GitHub repo objects down to the six fields and returning `{ repos: [...] }`. Scoped `rescue_from` maps `Github::UnauthorizedError` → 401 with the re-auth message and `Github::Error` → 502.

### Acceptance criteria

- [ ] `GET /api/v1/github/repos` returns `{ repos: [...] }` with exactly `name, full_name, description, language, default_branch, private`, sorted as GitHub returns (`sort=updated&per_page=100`).
- [ ] Private repos are included.
- [ ] A 401 from GitHub → `401 { error: "GitHub token invalid, please sign in again" }`.
- [ ] A user with a blank `github_access_token` → same 401, with no HTTP call made.
- [ ] An unauthenticated request (no/invalid JWT) → `401 { error: "unauthorized" }`.
- [ ] `Github::Client` maps 401→`UnauthorizedError`, 404→`NotFoundError`, other non-2xx→`InvalidResponseError`, socket failure→`ConnectionError` (after one retry).

---

## Phase 2: `Github::RepoContext` + context endpoint (uncached)

**User stories**: 6–12, 17, 18, 20

### What to build

`Github::RepoContext.build` orchestrates: repo-metadata call for `default_branch`, recursive tree fetch + filtering, base64 README decode, languages passthrough, returning structured data. `#context` action returns `{ tree:, readme:, languages:, truncated: }`. Repo 404 → 404; GitHub 5xx → 502.

### Acceptance criteria

- [ ] `GET /api/v1/github/repos/:owner/:repo/context` returns `{ tree:, readme:, languages:, truncated: }`.
- [ ] Tree contains only blob paths; excludes `node_modules`/`.git`/`dist`/`build`/`vendor` segments, `*.lock`, image/font extensions, and blobs > 100KB.
- [ ] Tree is capped to a fixed maximum; GitHub-reported truncation OR an applied cap sets `truncated: true`.
- [ ] README is base64-decoded; a repo with no README → `readme: nil` (not an error).
- [ ] Languages are passed through unchanged.
- [ ] Repo not found/inaccessible → `404 { error: "repository not found" }`.
- [ ] Transient GitHub 5xx → `502 { error: "GitHub request failed" }`.
- [ ] 401 / blank token → the re-auth 401 message.

---

## Phase 3: 10-minute per-repo caching

**User stories**: 13, 14

### What to build

Wrap `RepoContext.build` in `Rails.cache.fetch` with the per-repo key and `expires_in: 10.minutes`. Errors propagate and are never cached.

### Acceptance criteria

- [ ] A second `/context` request for the same repo within the window serves from cache; GitHub is called only once.
- [ ] The cache key is per-repo (`github:repo_context:{owner}/{repo}`), shared across users.
- [ ] A build that raises is not cached; a subsequent request retries the upstream.
