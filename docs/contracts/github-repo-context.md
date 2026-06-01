# Implementation Handoff Contract

## 1. Summary

- Implemented authenticated backend GitHub repository access for the signed-in TicketForge user.
- The frontend should call `GET /api/v1/github/repos` and populate the repo selector/dropdown from every object in `repos`.
- In scope: listing up to 100 user repositories, returning repo context for a selected repo, mapping GitHub errors to stable JSON API errors, and storing the synced GitHub token on `User#github_access_token`.
- Out of scope: frontend dropdown implementation, pagination beyond the first 100 GitHub repos, repository mutation, branch selection, and GitHub webhook handling.
- Owner: Rails backend repo `/Users/adamsaleh/Downloads/ticketforge-api`, under `app/controllers/api/v1/github/` and `app/services/github/`.

## 2. Files Added or Changed

- `/Users/adamsaleh/Downloads/ticketforge-api/app/controllers/api/v1/github/repos_controller.rb` - created; exposes `GET /api/v1/github/repos` and `GET /api/v1/github/repos/:owner/:repo/context`.
- `/Users/adamsaleh/Downloads/ticketforge-api/app/services/github/client.rb` - created; authenticated GitHub REST client using the stored user GitHub token.
- `/Users/adamsaleh/Downloads/ticketforge-api/app/services/github/repo_context.rb` - created; builds a filtered repository context payload.
- `/Users/adamsaleh/Downloads/ticketforge-api/app/services/github/error.rb` and subclasses - created; backend error taxonomy for GitHub failures.
- `/Users/adamsaleh/Downloads/ticketforge-api/app/controllers/api/v1/users_controller.rb` - updated; `PATCH /api/v1/me` stores `github_access_token` from the frontend Supabase session.
- `/Users/adamsaleh/Downloads/ticketforge-api/app/models/user.rb` - updated; `encrypts :github_access_token` and preserves the token when later Supabase JWTs omit `provider_token`.
- `/Users/adamsaleh/Downloads/ticketforge-api/config/routes.rb` - updated; registers the GitHub and `PATCH /api/v1/me` routes.
- `/Users/adamsaleh/Downloads/ticketforge-api/spec/requests/api/v1/github/repos_spec.rb` - created; verifies repo list shape and error statuses.
- `/Users/adamsaleh/Downloads/ticketforge-api/spec/requests/api/v1/github/repo_context_spec.rb` - created; verifies repo context shape, filtering, and errors.
- `/Users/adamsaleh/Downloads/ticketforge-api/spec/requests/api/v1/me_update_spec.rb` - created; verifies GitHub token sync.
- `/Users/adamsaleh/Downloads/ticketforge-api/docs/contracts/github-repo-context.md` - created; this handoff contract.

## 3. Public Interface Contract

### `GET /api/v1/github/repos`

- Type: HTTP endpoint.
- Purpose: return repositories visible to the signed-in user's stored GitHub OAuth token.
- Owner: Rails backend `Api::V1::Github::ReposController#index`.
- Inputs: `Authorization: Bearer <supabase_access_token>`.
- Outputs: JSON object with required `repos` array.
- Required fields per `repos[]`: `name`, `full_name`, `description`, `language`, `default_branch`, `private`.
- Optional fields: none in the response contract; `description` and `language` may be `null`.
- Validation rules: request must have a valid Supabase Bearer token; the matching backend `User` must have `github_access_token`.
- Defaults: GitHub request uses `sort=updated` and `per_page=100`.
- Status codes: `200 OK`, `401 Unauthorized`, `502 Bad Gateway`.
- Error shapes: `{ "error": "unauthorized" }`, `{ "error": "GitHub token invalid, please sign in again" }`, `{ "error": "GitHub request failed" }`.
- Example input: `GET http://localhost:3001/api/v1/github/repos` with `Authorization: Bearer <supabase_access_token>`.
- Example output:

```json
{
  "repos": [
    {
      "name": "ticketforge-api",
      "full_name": "adamsaleh11/ticketforge-api",
      "description": "- backend for ticketforge",
      "language": "Ruby",
      "default_branch": "main",
      "private": false
    },
    {
      "name": "ticketforge-web",
      "full_name": "adamsaleh11/ticketforge-web",
      "description": "- frontend for ticketforge. Paste in a feature or product idea, get ai to create phases ticket plans for you to interact with claude code or codex",
      "language": "TypeScript",
      "default_branch": "main",
      "private": false
    }
  ]
}
```

### `GET /api/v1/github/repos/:owner/:repo/context`

- Type: HTTP endpoint.
- Purpose: return LLM-ready context for a selected repo.
- Owner: Rails backend `Api::V1::Github::ReposController#context`.
- Inputs: `Authorization: Bearer <supabase_access_token>`, URL params `owner`, `repo`.
- Outputs: JSON object with `tree`, `readme`, `languages`, `truncated`.
- Required fields: `tree`, `readme`, `languages`, `truncated`.
- Optional fields: `readme` may be `null`.
- Validation rules: request must have a valid Supabase Bearer token and stored GitHub token.
- Defaults: uses the selected repo's GitHub `default_branch`.
- Status codes: `200 OK`, `401 Unauthorized`, `404 Not Found`, `502 Bad Gateway`.
- Error shapes: `{ "error": "unauthorized" }`, `{ "error": "GitHub token invalid, please sign in again" }`, `{ "error": "repository not found" }`, `{ "error": "GitHub request failed" }`.
- Example input: `GET /api/v1/github/repos/adamsaleh11/ticketforge-api/context`.
- Example output:

```json
{
  "tree": ["app/models/user.rb", "README.md"],
  "readme": "# TicketForge API",
  "languages": { "Ruby": 12345 },
  "truncated": false
}
```

### `PATCH /api/v1/me`

- Type: HTTP endpoint.
- Purpose: sync the GitHub OAuth provider token from the frontend Supabase session into encrypted backend storage.
- Owner: Rails backend `Api::V1::UsersController#update`.
- Inputs: `Authorization: Bearer <supabase_access_token>`, JSON body `{ "user": { "github_access_token": "<provider_token>" } }`.
- Outputs: serialized user profile; never includes `github_access_token`.
- Required fields: `user.github_access_token`.
- Optional fields: none for this route.
- Validation rules: valid Supabase Bearer token required.
- Defaults: NOT IMPLEMENTED.
- Status codes: `200 OK`, `401 Unauthorized`, `422 Unprocessable Entity`.
- Error shapes: `{ "error": "unauthorized" }` or JSON:API-style `{ "errors": [{ "source": { "pointer": "/data/attributes/<field>" }, "detail": "<message>" }] }`.
- Example input: `{ "user": { "github_access_token": "gho_xxx" } }`.
- Example output: user serializer output with no token field.

## 4. Data Contract

### `repos` response object

- Exact name: `repos`.
- Type: array of repository picker objects.
- Required: yes.
- Allowed values: zero or more repository objects returned from GitHub `/user/repos`.
- Backward compatibility notes: frontend must read `response.data.repos`, not a top-level array.

### Repository picker object

- `name`: string, required, repository name only.
- `full_name`: string, required, owner/name pair; use this as the dropdown option value.
- `description`: string or null, required key.
- `language`: string or null, required key.
- `default_branch`: string, required.
- `private`: boolean, required.
- Frontend display recommendation: label can be `full_name`; secondary text can use `description`, `language`, and `private`.

### Repo context object

- `tree`: array of strings, required; filtered file paths only.
- `readme`: string or null, required.
- `languages`: object, required; GitHub language names to byte counts.
- `truncated`: boolean, required.

### `User#github_access_token`

- Type: encrypted text column on `users.github_access_token`.
- Required: no; missing token causes GitHub endpoints to return `401` with `GitHub token invalid, please sign in again`.
- Migration notes: existing `users.github_access_token` column is reused.
- Backward compatibility notes: the token is never serialized back to clients.

## 5. Integration Contract

- Upstream dependency: Supabase Auth; every backend request requires `Authorization: Bearer <supabase_access_token>`.
- Upstream dependency: frontend Supabase client; after OAuth callback, frontend must call `PATCH /api/v1/me` with `session.provider_token` when present.
- Downstream dependency: GitHub REST API at `https://api.github.com`.
- GitHub repos call: `GET /user/repos?sort=updated&per_page=100`.
- GitHub context calls: `GET /repos/:owner/:repo`, `GET /repos/:owner/:repo/git/trees/:branch?recursive=1`, `GET /repos/:owner/:repo/readme`, `GET /repos/:owner/:repo/languages`.
- Auth assumptions: GitHub token came from Supabase GitHub OAuth with scopes `public_repo read:user`.
- Retry behavior: one retry for transport errors only.
- Timeout behavior: 30 seconds for GitHub open/read timeout.
- Fallback behavior: no fallback list; frontend must show an empty state only when `repos` is an empty array.
- Idempotency behavior: `PATCH /api/v1/me` can be repeated with the same token.
- Cache behavior: backend does not define a custom 304 body. If browser devtools shows `Status: 304 Not Modified` or `Source: Memory Cache` for `/api/v1/github/repos`, the frontend should render the cached successful JSON instead of showing "Repositories couldn't be loaded". If the frontend HTTP client treats `304` as an error, adjust that client path to accept cached success or bypass conditional cache for this endpoint.

## 6. Usage Instructions for Other Engineers

- Frontend should use the existing authenticated API client, not bare `fetch`.
- Call `GET /api/v1/github/repos` after the user is authenticated and after the callback token sync has had a chance to complete.
- Populate the repo dropdown from every element in `response.data.repos`.
- Use `repo.full_name` as the option value because the context route needs `owner` and `repo`; split on the first `/` when calling `/api/v1/github/repos/:owner/:repo/context`.
- Handle loading with a spinner or skeleton while the repos request is pending.
- Handle success with `repos.length > 0` by rendering all repos returned.
- Handle empty success with `repos.length === 0` by showing an empty-repos state, not an error.
- Handle `401` with `GitHub token invalid, please sign in again` by prompting re-authentication.
- Handle `502` with a retryable GitHub outage message.
- Do not show "Repositories couldn't be loaded" for a browser-cached `304 Not Modified` when cached repo JSON exists.
- Finalized: route names, response field names, and error strings.
- Provisional: pagination beyond 100 repos is NOT IMPLEMENTED.
- Mocked or stubbed: tests use WebMock for GitHub API calls.
- Must not be changed without coordination: `repos[]` field names, `full_name` owner/name format, and the two GitHub endpoint paths.

## 7. Security and Authorization Notes

- All `/api/v1/github/*` routes require a valid Supabase Bearer token.
- The backend uses `current_user.github_access_token`; users cannot pass arbitrary GitHub tokens to GitHub endpoints.
- `github_access_token` is encrypted by Active Record encryption.
- `github_access_token` must never be serialized, logged, or displayed.
- Missing, expired, or revoked GitHub tokens return `401` with `GitHub token invalid, please sign in again`.
- Repo access is limited to what the stored GitHub token can see.
- GitHub `403` is treated like inaccessible/not found for repo context and returns `{ "error": "repository not found" }`.

## 8. Environment and Configuration

- `SUPABASE_URL`: required; used by Supabase JWT verification.
- `SUPABASE_JWT_SECRET`: legacy/reference only; not used by the ES256 JWKS verifier.
- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`: required outside test; encrypts `User#github_access_token`.
- `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`: required outside test; Active Record encryption config.
- `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`: required outside test; Active Record encryption config.
- Test environment: fixed dummy Active Record encryption keys are set in `/Users/adamsaleh/Downloads/ticketforge-api/config/environments/test.rb`.
- Development note: after changing `.env`, restart Rails so encryption keys are loaded.

## 9. Testing and Verification

- Added request tests: `/Users/adamsaleh/Downloads/ticketforge-api/spec/requests/api/v1/github/repos_spec.rb`.
- Added request tests: `/Users/adamsaleh/Downloads/ticketforge-api/spec/requests/api/v1/github/repo_context_spec.rb`.
- Added request tests: `/Users/adamsaleh/Downloads/ticketforge-api/spec/requests/api/v1/me_update_spec.rb`.
- Verified command previously run: `rbenv exec bundle exec rspec spec/requests/api/v1/me_update_spec.rb` returned `4 examples, 0 failures`.
- Manual payload verified from `http://localhost:3001/api/v1/github/repos`: JSON object containing `repos` with repositories including `adamsaleh11/ticketforge-api` and `adamsaleh11/ticketforge-web`.
- Local validation: restart Rails, sign in with GitHub, confirm `PATCH /api/v1/me` returns `200`, then confirm `GET /api/v1/github/repos` returns `200` or browser-cached `304` with cached repo JSON.
- Known gap: frontend dropdown rendering is not tested in this backend repo.

## 10. Known Limitations and TODOs

- Pagination beyond the first 100 repos is NOT IMPLEMENTED.
- Repo search/filtering is NOT IMPLEMENTED.
- Branch selection is NOT IMPLEMENTED; context uses GitHub `default_branch`.
- Context cache is keyed by `github:repo_context:<owner>/<repo>` for 10 minutes.
- `304 Not Modified` has no JSON body from the backend; frontend must not treat a cached 304 with usable cached body as a repo-load failure.
- Private repo access depends on the Supabase GitHub OAuth token scopes and GitHub permissions.

## 11. Source of Truth Snapshot

- Final route: `GET /api/v1/github/repos`.
- Final route: `GET /api/v1/github/repos/:owner/:repo/context`.
- Final route: `PATCH /api/v1/me`.
- Final controller: `Api::V1::Github::ReposController`.
- Final service: `Github::Client`.
- Final service: `Github::RepoContext`.
- Final repo DTO: `{ name, full_name, description, language, default_branch, private }`.
- Final repo list wrapper: `{ repos: [...] }`.
- Final context DTO: `{ tree, readme, languages, truncated }`.
- Final auth error: `{ "error": "unauthorized" }`.
- Final GitHub token error: `{ "error": "GitHub token invalid, please sign in again" }`.
- Final GitHub outage error: `{ "error": "GitHub request failed" }`.
- Breaking changes from previous version: new backend API surface for GitHub repo listing and repo context; frontend must consume `repos` wrapper instead of expecting a top-level array.

## 12. Copy-Paste Handoff for the Next Engineer

The backend GitHub repo API is already implemented. Use `GET /api/v1/github/repos` through the authenticated API client and render every item in `response.data.repos` as dropdown options; use `full_name` as the selected value.

It is safe to depend on the route names, response field names, and error strings in this contract. The frontend still needs to fix the repo picker so cached `304 Not Modified` / memory-cache responses do not become "Repositories couldn't be loaded" when cached repo JSON exists.

Read sections 3, 4, and 6 first. The main gotcha is that the backend response is `{ "repos": [...] }`, not an array, and browser devtools may show `304 Not Modified` for a usable cached repo response.
