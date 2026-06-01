# PRD: Ticket Fetching & Status Updates

## Problem Statement

Today a user can create a project and generate a phased ticket plan, but once
generation finishes there is no way to *re-read* that plan or to *act on it*.

- `GET /api/v1/projects/:id` returns only the project's scalar attributes
  (`name`, `status`, `ticket_count`, …). The phases and tickets produced by
  generation are **not** embedded. The only response that ever includes the
  nested board is the one-time `POST /generate` response — so if the user
  reloads the project page, refreshes, or comes back tomorrow, the frontend has
  no endpoint to rebuild the ticket board from.
- Tickets carry a `status` column (`pending` / `in_progress` / `done`) that was
  added "for future use," but there is no endpoint to mutate it. A user cannot
  mark a ticket in progress or done as they work through the plan.

This blocks the core post-generation loop of the product: open a project, see
your tickets, and check them off as you implement them in Claude Code / Codex.

## Solution

Two changes, both server-side, both consumed by the existing frontend project
detail / board view:

1. **`GET /api/v1/projects/:id` always embeds the full board.** The detail
   endpoint returns the project *and* its phases, each with their tickets
   nested, in the same JSON:API shape the `generate` response already uses. The
   frontend uses one endpoint to render the board on first load, on refresh, and
   on return visits — no dependence on holding onto the transient generate
   response.

2. **`PATCH /api/v1/tickets/:id` updates a ticket's status.** The user moves a
   ticket between `pending`, `in_progress`, and `done` (in any direction). The
   endpoint accepts only `status`; every other ticket field is immutable here.
   The ticket is scoped to the signed-in user's own projects, so one user can
   never touch another user's tickets.

## User Stories

1. As a signed-in user, I want `GET /api/v1/projects/:id` to return my project
   together with its phases and their tickets, so that the frontend can render
   the full ticket board on page load.
2. As a signed-in user, I want the phases and tickets in that response to be
   ordered (phases by position, tickets by position within each phase), so that
   the board renders in the intended sequence without client-side sorting.
3. As a signed-in user opening a freshly created project that has not generated
   yet, I want the detail response to come back cleanly with an empty phase
   list, so that the board shows an empty state instead of erroring.
4. As a signed-in user, I want the project detail endpoint to remain efficient
   (no per-phase or per-ticket query fan-out), so that loading a large board is
   a small, bounded number of queries.
5. As a signed-in user, I want a 404 when I request a project that isn't mine or
   doesn't exist, so that the API never reveals whether someone else's project
   exists.
6. As a signed-in user, I want `PATCH /api/v1/tickets/:id` to update a ticket's
   status, so that I can mark tickets in progress and done as I work.
7. As a signed-in user, I want to move a ticket's status in any direction
   (including `done` back to `in_progress`), so that I can reopen work I had
   marked complete.
8. As a signed-in user, I want the update response to return the updated ticket,
   so that the frontend can confirm the new state without a refetch.
9. As a signed-in user, I want a validation error (422) with a field pointer
   when I send an unknown or missing status, so that the frontend can surface a
   clear, field-level message.
10. As a signed-in user, I want any fields other than `status` in my update
    request to be ignored, so that the ticket's generated content (title, body,
    repo, position) cannot be accidentally or maliciously altered through this
    endpoint.
11. As a signed-in user, I want a 404 when I try to update a ticket that belongs
    to another user or does not exist, so that ticket ownership is never
    leaked or bypassed.
12. As an unauthenticated caller, I want both endpoints to reject me with a 401,
    so that ticket data and mutations require a valid session.

## Implementation Decisions

### Modules built / modified

- **`Api::V1::ProjectsController#show` (modified).** Embeds the nested board.
  Loads the project through the user-scoped association with the phase/ticket
  graph eager-loaded, and serializes it with the same nested include the
  `generate` action already passes.
  - Lookup is eager-loaded only for `show` (e.g. the show path loads
    `phases: :tickets`); the shared `find_project` helper used by
    update/destroy/generate is left lean so those actions don't pay for the
    graph.
  - Serialized with `ProjectSerializer.new(project, include: %i[phases phases.tickets])`,
    matching the existing `generate` response contract exactly.

- **`Api::V1::TicketsController#update` (new).** Updates ticket status only.
  - Scopes the ticket to the current user's projects via the phase→project
    join, so a non-owned or missing id raises `RecordNotFound` → 404. No
    `User#tickets` association is added; the scope lives in a private
    `find_ticket` helper mirroring the existing `find_project`.
  - Permits `status` only (`params.require(:ticket).permit(:status)`).
  - Validates the incoming status against the enum's known values *before*
    assignment, because a string-backed enum raises `ArgumentError` on an
    unknown value. An unknown or missing status returns 422 with a JSON:API
    error object pointing at `/data/attributes/status`, reusing the existing
    error-object shape.
  - On success returns the updated ticket via `TicketSerializer` with HTTP 200.

- **Routing (modified).** Add a top-level `resources :tickets, only: %i[update]`
  inside the `api/v1` namespace — a flat `/api/v1/tickets/:id`, not nested under
  projects.

### Behavioral decisions

- **Status transitions are unconstrained.** Any of `pending` / `in_progress` /
  `done` may be set from any current value. The `pending → in_progress → done`
  ordering describes the typical lifecycle, not an enforced state machine; a
  board UI needs free movement (including reopening completed work).
- **Updating a ticket does not touch the project.** The project's
  `ticket_count`, `last_generated_at`, and `status` are generation-lifecycle
  fields and are unaffected by a per-ticket status change. No project cache bump
  or `touch`.

### API contracts

- `GET /api/v1/projects/:id`
  - 200: JSON:API document. `data` is the project resource; `included` contains
    its `phase` and `ticket` resources. A project with no phases returns the
    project with an empty `phases` relationship and no `included` key.
  - 404: `{ "error": "not_found" }` for a missing or non-owned project.
  - 401 for an unauthenticated request.
- `PATCH /api/v1/tickets/:id`
  - Request body: `{ "ticket": { "status": "in_progress" } }`.
  - 200: JSON:API document with the updated `ticket` resource.
  - 422: `{ "errors": [{ "source": { "pointer": "/data/attributes/status" }, "detail": "..." }] }`
    for an unknown or missing status.
  - 404: `{ "error": "not_found" }` for a missing or non-owned ticket.
  - 401 for an unauthenticated request.

### Schema changes

None. `phases`, `tickets`, and the `tickets.status` enum already exist.

## Testing Decisions

Tests assert externally observable behavior (HTTP status, response body shape,
persisted state, query counts) through the request layer, not controller
internals. Prior art: `spec/requests/api/v1/projects_spec.rb` and
`spec/requests/api/v1/projects/generate_spec.rb`, which establish the
`current_user` resolution pattern, `auth_headers(valid_supabase_jwt)`, and the
N+1 query-counting subscriber. Factories `:phase` and `:ticket` already exist
and chain up to a project/user.

- **`GET /api/v1/projects/:id` (extend `projects_spec.rb`):**
  - Returns the project with its phases and tickets embedded, correctly ordered.
  - A project with no phases returns 200 with an empty board (no error).
  - No N+1: the number of phase/ticket queries is bounded (mirrors the existing
    index N+1 spec, but asserts a small bound rather than zero, since here the
    graph is intentionally loaded).
  - Existing 404 (non-owned / missing) and 401 behavior still holds.

- **`PATCH /api/v1/tickets/:id` (new `tickets_spec.rb`):**
  - 200 updating `pending → in_progress`; response body reflects the new status
    and the row is persisted.
  - 200 updating `done → in_progress` — proves transitions are not forward-only.
  - 422 with a `/data/attributes/status` pointer for an unknown status value.
  - 422 for a missing status.
  - Fields other than `status` (e.g. `title`, `repo`) sent in the request are
    ignored — the generated content is unchanged.
  - 404 for another user's ticket, asserting the row was not mutated.
  - 404 for a missing ticket id.
  - 401 without a valid token.

## Out of Scope

- Editing ticket content (title, body, repo) or reordering tickets/phases.
- Forward-only status transition enforcement / a status state machine.
- Bulk status updates or updating multiple tickets in one request.
- Phase-level mutations (status, reordering, editing).
- Recomputing or exposing project-level progress (e.g. "% done") derived from
  ticket statuses — the frontend can derive this from the embedded board.
- A param-gated / sparse include option on `show`; the board is always embedded.
- Pagination of phases/tickets within a project.

## Further Notes

- This work was explicitly deferred in the original ticket-generator PRD
  (`docs/prd-ticket-generator.md`: "the `status` column exists for future use;
  no endpoints to mutate it here"). This PRD lifts that deferral for `status`
  only.
- The `show` response shape is deliberately identical to the existing `generate`
  response (same serializer, same `include:`), so the frontend can share one
  deserializer/board-rendering path for both.
- Assumption: the frontend derives any progress/summary UI client-side from the
  embedded ticket statuses; no new aggregate fields are added server-side.
- Open question for planning, not blocking: whether `find_ticket`'s phase→project
  join should later be promoted to a reusable `User#tickets` association if more
  ticket-scoped endpoints appear. For a single endpoint it stays inline.
