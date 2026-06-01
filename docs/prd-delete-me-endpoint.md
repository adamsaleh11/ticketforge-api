# PRD: DELETE /api/v1/me — Account & Data Deletion

## Problem Statement

A signed-in TicketForge user has no way to delete their account and the data
they have created (projects, the phases generated for them, and the tickets
within those phases). Users who want to walk away — whether for privacy
reasons, to clean up test data, or because they're done with the product —
are stuck. Their projects, phases, and tickets persist in the backend
indefinitely with no self-service removal path.

This matters now because the app already lets users create the full
`project → phase → ticket` hierarchy, so there is real user-owned data
accumulating with no deletion story. A delete-my-account control is table
stakes for a product that stores user content, and it's the data-removal half
of any future GDPR/"right to be forgotten" posture.

## Solution

Add an authenticated `DELETE /api/v1/me` endpoint. When the signed-in user
calls it, the backend destroys their `User` record and everything that record
owns — all of their projects, every phase under those projects, and every
ticket under those phases — in a single transaction. On success the endpoint
returns `204 No Content`.

Deletion of the user's **Supabase auth account** is explicitly *not* performed
by this endpoint. That requires the Supabase admin API (service-role key) and
is owned by the frontend / out of scope for MVP. Because the user's Supabase
JWT remains valid after this call, the very next authenticated request would
recreate an empty `User` row (the auth layer find-or-creates users from the
JWT). The frontend is therefore expected to sign the user out immediately
after receiving a 2xx so no further authenticated requests fire. Orphaned
Supabase auth users are an accepted MVP limitation; full cleanup is the
frontend's responsibility via `supabase.auth.admin.deleteUser`.

From the user's perspective: they hit "delete my account," their content is
gone, and they are signed out.

## User Stories

1. As a signed-in user, I want to delete my account, so that my data no longer
   lives in TicketForge.
2. As a signed-in user, when I delete my account, I want all of my projects to
   be destroyed, so that none of my project content remains.
3. As a signed-in user, when I delete my account, I want all phases under my
   projects to be destroyed, so that no generated phase data remains.
4. As a signed-in user, when I delete my account, I want all tickets under my
   phases to be destroyed, so that no generated ticket content remains.
5. As a signed-in user, I want a successful deletion to return a clear,
   body-less success response, so that the frontend can react deterministically
   and sign me out.
6. As a user of the product, I want one user's deletion to never affect another
   user's projects, phases, or tickets, so that account deletion is safely
   scoped to me alone.
7. As an unauthenticated caller, I want `DELETE /api/v1/me` to be rejected with
   the same canonical 401 as every other protected endpoint, so that the API
   never leaks behavior to unauthenticated requests.
8. As a developer integrating the frontend, I want the endpoint's documented
   contract to state that the Supabase auth user is not deleted and that the
   client must sign out afterward, so that I implement the correct post-delete
   flow.
9. As a developer, I want the known "User row respawns on the next request"
   limitation captured as an executable test, so that it is understood as a
   documented constraint rather than mistaken for a bug.
10. As an operator, I want a mid-cascade failure to roll back entirely, so that
    deletion never leaves a half-destroyed account behind.

## Implementation Decisions

- **Endpoint / route:** Add `DELETE /api/v1/me` routed to
  `Api::V1::UsersController#destroy`, alongside the existing `GET` and `PATCH`
  `me` routes.
- **Controller behavior:** `destroy` calls `current_user.destroy!` and responds
  `head :no_content` (HTTP `204`). No request params, no strong-params change,
  no serializer involved.
- **Authentication:** Relies on the existing `Authenticatable` `before_action`
  (`authenticate_user!`). Unauthenticated requests receive the canonical
  `401 { "error": "unauthorized" }` for free; no controller-level auth logic is
  added.
- **Cascade mechanism:** Destruction relies on ActiveRecord
  `dependent: :destroy` already declared across the chain
  (`User → projects`, `Project → phases`, `Phase → tickets`). Use `destroy!`
  (not `delete`/`delete_all`) so the dependent callbacks run — the database
  foreign keys do **not** declare `ON DELETE CASCADE`, so the cascade must go
  through ActiveRecord.
- **Transactionality:** `destroy!` wraps the entire cascade in a transaction;
  a failure anywhere rolls the whole deletion back. No partial deletion.
- **Error surfacing:** `destroy!` (bang) is chosen over `destroy` so that a
  future halting callback surfaces as a 500 rather than a silent `204` that
  didn't actually delete.
- **Supabase auth user:** Not deleted by this endpoint. This is documented in
  the controller action's comments, including the re-creation caveat and the
  expectation that the frontend signs the user out and (optionally) calls the
  Supabase admin API.
- **No schema changes.** No new columns, no migration, no soft-delete/tombstone
  column. The "next request recreates an empty User row" behavior is accepted
  as-is for MVP.

## Testing Decisions

A new request spec (e.g. `spec/requests/api/v1/me_delete_spec.rb`) following the
existing `me_*_spec.rb` conventions — `auth_headers`, `valid_supabase_jwt`, and
the existing factories. Tests target external behavior and contract, not
internals. Required coverage:

1. **Success status:** a valid token returns `204 No Content`.
2. **User destroyed:** `DELETE /api/v1/me` changes `User.count` by `-1`.
3. **Full cascade:** with a seeded project + phase + ticket for the user,
   `Project`, `Phase`, and `Ticket` counts all drop to zero — this is the test
   that proves `dependent: :destroy` is wired end-to-end.
4. **Scoping / isolation:** a second user's project/phase/ticket are untouched
   when the first user deletes their account.
5. **Unauthenticated rejection:** a request with no Authorization header returns
   the canonical `{ "error": "unauthorized" }` 401 and does not change
   `User.count` (mirror the shared-example pattern in
   `me_authentication_spec.rb`).
6. **Documented re-creation caveat:** after a successful DELETE, a follow-up
   `GET /api/v1/me` with the same JWT returns `200` and `User.count` is back to
   `1` — encoding the known limitation as executable documentation.

Prior art: `spec/requests/api/v1/me_spec.rb`,
`spec/requests/api/v1/me_update_spec.rb`, and
`spec/requests/api/v1/me_authentication_spec.rb`.

## Out of Scope

- Deleting the Supabase auth user / revoking the Supabase session server-side.
- Calling the Supabase admin API from Rails (no service-role key handling).
- Soft delete, tombstoning, or blocking re-creation of a deleted
  `supabase_user_id` on subsequent authenticated requests.
- Any frontend work (the delete-account UI, post-delete sign-out, optional
  `supabase.auth.admin.deleteUser` call). This PRD is backend-only.
- Audit logging, deletion confirmation emails, grace periods, or undo.
- Data export / "download my data" prior to deletion.
- Rate limiting or extra confirmation challenges on the endpoint.

## Further Notes

- **Re-creation behavior is intentional for MVP.** Because the Supabase JWT
  outlives the deletion and `Authenticatable#resolve_current_user`
  find-or-creates from the JWT, the next authenticated request rebuilds an empty
  `User`. The data (projects/phases/tickets) is the GDPR-meaningful part and is
  genuinely gone; the respawning empty row is harmless. This is accepted, not a
  defect.
- **Frontend contract dependency:** The frontend must sign the user out
  immediately on a 2xx so no follow-up authenticated request resurrects the
  user row. This should be communicated alongside the endpoint contract.
- **Follow-up (future, not now):** if durable account deletion is later
  required, the likely path is either (a) a `deleted_at`/blocked tombstone that
  `resolve_current_user` refuses to resurrect, or (b) server-side Supabase admin
  deletion. Both were considered and deferred during design.
- **Performance:** the cascade issues per-record destroys through ActiveRecord
  callbacks; acceptable at MVP data volumes for a single user's content.
