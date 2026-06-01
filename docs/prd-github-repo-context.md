# PRD: GitHub Read-Only Repo & Context Endpoints

## Problem Statement

TicketForge turns a project description into phased engineering tickets. A user is far better served when those tickets are grounded in the **actual codebase** they intend to build on, rather than generated from a prose description alone. The most valuable case is "I want to add a feature to an existing repo" — there, the LLM needs real context (the file layout, the README, the language mix) *before* it writes the plan, or the tickets will be generic and ungrounded.

The pieces to make this possible already exist on the backend but are unconnected. A user signs in with GitHub via Supabase OAuth (`public_repo read:user` scopes), and the resulting GitHub OAuth token is synced onto `users.github_access_token` (encrypted) by `User.from_supabase_payload`. But **there is no API surface that uses that token.** The frontend cannot list a user's repos for the "link a repo" picker, and the ticket-generation pipeline has no way to pull a repo's structure into the LLM prompt.

This matters now because repo-linking is the differentiator between generic ticket generation and codebase-aware planning, and the frontend's repo picker plus the future plan-generation step are both blocked on it.

## Solution

Add two authenticated, read-only endpoints under a new `github` namespace, both acting on behalf of the signed-in user using their stored GitHub token:

- **`GET /api/v1/github/repos`** — lists the user's GitHub repositories (most-recently-updated first), reduced to the fields the repo picker needs: `name`, `full_name`, `description`, `language`, `default_branch`, `private`.

- **`GET /api/v1/github/repos/:owner/:repo/context`** — returns a structured, LLM-ready snapshot of a single repo: a filtered file tree, the decoded README, the language breakdown, and a `truncated` flag. This is the context object that a later prompt-building step feeds to the LLM so it can write a plan grounded in the real codebase.

From the user's perspective: they open the new-project flow, see their repos listed, pick one, and the system pulls that repo's shape so the generated tickets reference real files and structure instead of guessing. The context call is cached for 10 minutes per repo, so re-opening the same repo is instant and doesn't burn GitHub rate limit.

Because the GitHub token can expire or be revoked independently of the Supabase session, both endpoints detect a dead token and return a distinct, actionable `401` telling the user to sign in again — separate from the ordinary "you have no valid session" `401`.

## User Stories

1. As a user linking a repo to a project, I want to see a list of my GitHub repositories, so that I can pick the codebase I'm building on without typing its name.
2. As a user, I want my repos sorted most-recently-updated first, so that the project I'm actively working on is near the top.
3. As a user with many repos, I want up to 100 of my most recent repos returned, so that the common case is covered in a single request.
4. As a user, I want each listed repo reduced to just name, full name, description, language, default branch, and private flag, so that the picker is fast and the response isn't bloated with raw GitHub fields.
5. As a user, I want my private repos included in the list (I granted the scope), so that I can plan against private codebases too.
6. As a user adding a feature to an existing repo, I want the system to fetch that repo's file structure, README, and languages, so that the generated plan is grounded in my actual codebase instead of guesses.
7. As a user, I want the file tree filtered to source-relevant files — excluding `node_modules`, `.git`, `dist`, `build`, `vendor`, lockfiles, images, fonts, and anything over 100KB — so that the context fed to the LLM is signal-dense and affordable.
8. As a user, I want only file (blob) paths in the tree, not directory entries, so that the context is a clean list of the files that exist.
9. As a user with a very large repo, I want the tree capped to a reasonable number of entries and flagged as truncated when it's incomplete, so that a huge monorepo doesn't blow the LLM context window and I'm told the picture is partial.
10. As a user whose repo has a README, I want it decoded from base64 and included, so that the LLM understands the project's purpose.
11. As a user whose repo has no README, I want the context to come back with a null README rather than an error, so that planning still works for undocumented repos.
12. As a user, I want the language breakdown included as-is, so that the plan reflects the repo's actual tech mix.
13. As a user re-opening the same repo within 10 minutes, I want the context served from cache, so that it's instant and doesn't consume my GitHub rate limit.
14. As any user requesting the same public-shaped repo context, I want the cache shared per repo (not per user), so that the cache isn't needlessly duplicated.
15. As a user whose GitHub token has expired or been revoked, I want a clear `401` with the message "GitHub token invalid, please sign in again", so that I know to re-authenticate rather than seeing a generic failure.
16. As a user whose Supabase session never carried a GitHub token, I want the same actionable `401` before any GitHub call is made, so that a missing token fails fast and clearly.
17. As a user requesting a repo that doesn't exist or that I can't access, I want a `404`, so that I'm not misled into thinking the request itself was malformed.
18. As a user hitting a transient GitHub outage or unexpected GitHub error, I want a `502` indicating the upstream failed, so that I can distinguish "GitHub is down" from "my token is bad".
19. As an unauthenticated caller, I want both endpoints to reject me with `401`, so that no GitHub data is ever fetched without a valid TicketForge session.
20. As a developer consuming `/context`, I want it to return structured data (tree, readme, languages, truncated) rather than a pre-formatted prompt string, so that prompt assembly stays a separate concern and the frontend can also render the structured data.

## Implementation Decisions

### Services

- **`Github::Client.new(user)`** — a thin authenticated wrapper over the GitHub REST API at `https://api.github.com`, built with **HTTParty** to match the existing `LLM::Client`/`LLM::OllamaClient` convention (Faraday is in the Gemfile but unused; introducing a second HTTP idiom in a small codebase is not worth it — this is a deliberate deviation from the original "wraps Faraday" wording).
  - Sets `Authorization: Bearer {user.github_access_token}`, `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`.
  - Fails fast: if `user.github_access_token` is blank, raises `Github::UnauthorizedError` before any network call.
  - Maps responses to a `Github::`-namespaced error taxonomy that mirrors `LLM::`: `Github::Error` (base) with `Github::ConnectionError` (socket/transport failures, with a single retry mirroring `LLM::Client`), `Github::InvalidResponseError` (non-2xx other than 401/404, unparseable body), `Github::NotFoundError` (404), and `Github::UnauthorizedError` (401 from GitHub or missing token).
  - Public methods cover: list repos, fetch repo metadata (for `default_branch`), fetch recursive git tree, fetch README, fetch languages.

- **`Github::RepoContext.build(user, owner, repo)`** — the orchestrator that returns the structured context object `{ tree:, readme:, languages:, truncated: }`.
  - First fetches repo metadata (`GET /repos/{owner}/{repo}`) to obtain `default_branch` — required because the `/context` endpoint does not receive a branch from the client.
  - Fetches the recursive git tree for that branch, applies the filtering rules, caps the result, and sets `truncated` if GitHub flagged truncation **or** the cap was applied.
  - Fetches and base64-decodes the README; a 404 here yields `readme: nil` (not an error). Other non-2xx still propagate.
  - Fetches languages and passes them through unchanged.
  - Wraps the whole build in `Rails.cache.fetch` with a **per-repo** key (`github:repo_context:{owner}/{repo}`) and `expires_in: 10.minutes`. Errors propagate and are never cached.

### Tree filtering rules

- Keep only entries of type `blob` (drop directory/`tree` entries); output is an array of path strings.
- Exclude an entry if any path segment is one of: `node_modules`, `.git`, `dist`, `build`, `vendor`.
- Exclude lockfiles (`*.lock`).
- Exclude image/font extensions: `.png .jpg .jpeg .gif .svg .ico .webp .woff .woff2 .ttf .eot .otf`.
- Exclude blobs whose `size` exceeds 100KB (100,000 bytes).
- Cap the filtered list to a fixed maximum number of entries (e.g. ~1000); applying the cap sets `truncated: true`.
- Exclusion lists and the cap live as named constants.

### GitHub API calls used

- `GET /user/repos?sort=updated&per_page=100`
- `GET /repos/{owner}/{repo}` (for `default_branch`)
- `GET /repos/{owner}/{repo}/git/trees/{default_branch}?recursive=1`
- `GET /repos/{owner}/{repo}/readme`
- `GET /repos/{owner}/{repo}/languages`

### Controller & routing

- New `Api::V1::Github::ReposController` with `index` (list repos) and `context` actions.
- Explicit routes inside the existing `api/v1` namespace (not `resources`, because `:owner/:repo/context` is a two-segment path that maps awkwardly onto `resources`):
  - `GET /api/v1/github/repos` → `repos#index`
  - `GET /api/v1/github/repos/:owner/:repo/context` → `repos#context`
- `index` maps GitHub's repo objects down to the six specified fields and returns `{ repos: [...] }` (a plain hash, no serializer — these are not ActiveRecord models).
- `context` returns the `RepoContext` hash directly: `{ tree:, readme:, languages:, truncated: }`.

### Error handling

- `rescue_from` declarations are **scoped to the Github controller**, not `ApplicationController`, to avoid colliding with the existing auth `401`/`404` semantics on the base controller.
  - `Github::UnauthorizedError` → `401 { error: "GitHub token invalid, please sign in again" }`.
  - `Github::NotFoundError` → `404 { error: "repository not found" }`.
  - `Github::Error` (connection/invalid-response) → `502 { error: "GitHub request failed" }`.
- Ordinary unauthenticated requests (no/invalid Supabase JWT) continue to be handled by the existing `Authenticatable` concern → `401 { error: "unauthorized" }`.

## Testing Decisions

- **Request specs with WebMock**, mirroring the existing `spec/requests/api/v1/settings/ollama_test_spec.rb` style: stub `https://api.github.com/...`, authenticate with `auth_headers(valid_supabase_jwt)`. WebMock is already configured globally (`allow_localhost: true`), so outbound GitHub calls must be stubbed. Cases to cover:
  - `index`: happy path asserting the response contains exactly the six mapped fields; `401` from GitHub → `401` with the exact re-auth message; user with a blank token → same `401` with no HTTP call made; unauthenticated → `401`.
  - `context`: happy path asserting the tree is filtered correctly (excluded dirs/extensions/lockfiles/oversize blobs removed, only blob paths present), README base64-decoded, languages passed through, `truncated` correct; README `404` → `readme: nil`; repo `404` → `404`; transient GitHub `5xx` → `502`; `401` → re-auth message; caching: a second `/context` request within the window serves from cache and asserts GitHub was called only once (`have_requested(...).once`).
- **Service specs** for the riskiest logic in isolation:
  - `Github::RepoContext` tree filtering and `truncated` behavior (the exclusion rules and the cap are the highest-risk logic).
  - `Github::Client` error mapping: `401` → `UnauthorizedError`, `404` → `NotFoundError`, other non-2xx → `InvalidResponseError`, socket failure → `ConnectionError` (after the single retry), blank token → `UnauthorizedError` before any request.
- **Cache behavior in tests:** the cache-hit spec requires `Rails.cache` to be a real store rather than the null store, so those examples use a `MemoryStore` (or stub `Rails.cache`) and clear it between examples.

## Out of Scope

- Writing to GitHub (creating issues/PRs, pushing commits) — these endpoints are strictly read-only.
- Building the LLM prompt string from the context, and the plan/ticket generation step that consumes it. `RepoContext` returns structured data only; prompt assembly is a separate future ticket.
- Refreshing or re-minting an expired GitHub token. When the token is dead, the user is told to sign in again; the re-auth flow itself lives in the Supabase/frontend layer.
- Pagination beyond the first 100 repos.
- Caching the repos *list* (only `RepoContext` is cached).
- Migrating the existing `LLM::` HTTP clients from HTTParty to Faraday.
- Webhooks, branch selection by the client, per-file content fetching beyond the README.

## Further Notes

- **Deviations from the original request, called out explicitly:** (1) HTTParty instead of Faraday, for consistency with the existing service layer; (2) an added `GET /repos/{owner}/{repo}` metadata call to obtain `default_branch`, since `/context` does not receive a branch; (3) a distinct `Github::UnauthorizedError` plus a non-401 → `502` path and a `404` path, where the original spec named only the 401 case.
- **Rate limit:** authenticated GitHub requests get 5,000/hour per token. The 10-minute per-repo context cache is the main guard. The repos list is intentionally uncached because it changes as the user creates repos and is a single cheap call.
- **Token source:** `users.github_access_token` is populated by `User.from_supabase_payload` from the Supabase JWT's `app_metadata.provider_token` (falling back to `user_metadata`). A refreshed Supabase session can omit `provider_token`, which is exactly why the blank-token fast-fail (story 16) exists.
- **Assumption:** the stored token carries the `public_repo read:user` scopes requested by the frontend; private-repo access depends on the user having granted them at OAuth time. If scopes are insufficient, GitHub returns 404/403 for private repos, which surfaces as our `404` — acceptable for this slice.
- **Open question for planning:** the exact tree-entry cap (~1000 suggested) and whether `truncated` should distinguish "GitHub truncated" from "we capped it" — currently merged into a single boolean for simplicity.
