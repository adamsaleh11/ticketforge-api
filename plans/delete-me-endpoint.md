# Plan: DELETE /api/v1/me — Account & Data Deletion

> Source PRD: [docs/prd-delete-me-endpoint.md](../docs/prd-delete-me-endpoint.md)

## Architectural decisions

Durable decisions that apply across all phases:

- **Routes**: Add `DELETE /api/v1/me` → `Api::V1::UsersController#destroy`,
  alongside the existing `GET`/`PATCH` `me` routes.
- **Schema**: No changes. No new columns, no migration, no soft-delete/tombstone.
- **Key models**: No new models. Reuses the existing
  `User → projects → phases → tickets` hierarchy and its `dependent: :destroy`
  associations.
- **Auth**: Reuses the existing `Authenticatable` `before_action`
  (`authenticate_user!`). Unauthenticated requests get the canonical
  `401 { "error": "unauthorized" }` with no controller-level auth code added.
- **Cascade mechanism**: Deletion goes through ActiveRecord `destroy!` so
  `dependent: :destroy` callbacks run (DB foreign keys have no
  `ON DELETE CASCADE`). The bang variant surfaces a halted destroy as a 500
  rather than a silent success, and wraps the cascade in a transaction.
- **Supabase boundary**: This endpoint does NOT delete the Supabase auth user.
  The JWT stays valid, so the next authenticated request recreates an empty
  `User` row — accepted for MVP and documented in the controller comments. The
  frontend owns sign-out and any `supabase.auth.admin.deleteUser` cleanup.
- **Response**: `204 No Content`, empty body.

---

## Phase 1: DELETE /api/v1/me — account & data deletion

**User stories**: 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 (all)

### What to build

A complete authenticated delete-account endpoint. The signed-in user calls
`DELETE /api/v1/me`; the backend destroys their `User` and, via
`dependent: :destroy`, all of their projects, phases, and tickets in a single
transaction, then returns `204 No Content`. Unauthenticated callers are rejected
with the canonical 401. The Supabase auth user is intentionally left intact; the
controller documents this caveat and the resulting "empty User row respawns on
the next request" behavior.

This is one end-to-end slice: route + controller action + request spec.

### Acceptance criteria

- [ ] `DELETE /api/v1/me` is routed to `UsersController#destroy`.
- [ ] A valid token returns `204 No Content` with an empty body.
- [ ] The authenticated user's `User` record is destroyed (`User.count` -1).
- [ ] With a seeded project + phase + ticket, all three are destroyed (counts
      drop to zero) — proving the cascade is wired end-to-end.
- [ ] A second user's project/phase/ticket are untouched by the first user's
      deletion (scoping/isolation).
- [ ] An unauthenticated request returns `{ "error": "unauthorized" }` with 401
      and does not change `User.count`.
- [ ] After a successful delete, a follow-up `GET /api/v1/me` with the same JWT
      returns `200` and `User.count` is back to `1` (documented re-creation
      caveat, asserted as behavior).
- [ ] The controller action documents: Supabase auth user is not deleted, the
      JWT-driven re-creation behavior, and the frontend's responsibility to sign
      out / optionally call the Supabase admin API.
- [ ] Deletion uses `destroy!` (transactional, callback-driven), not
      `delete`/`delete_all`.
- [ ] New request spec follows existing `me_*_spec.rb` conventions
      (`auth_headers`, `valid_supabase_jwt`, factories) and the full suite is
      green.

### Prior art

- `spec/requests/api/v1/me_spec.rb`
- `spec/requests/api/v1/me_update_spec.rb`
- `spec/requests/api/v1/me_authentication_spec.rb`
