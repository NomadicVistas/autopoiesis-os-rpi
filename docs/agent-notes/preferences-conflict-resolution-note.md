# Preferences Conflict Resolution Note

## Date: 2026-06-09

## What Changed

`setUserPreferences()` in `hosted-api/db.js` now accepts an optional `incomingUpdatedAt` parameter and rejects stale writes when the stored `updated_at` is newer than the client's timestamp. The server handler `handleAdminUpdateUserPreferences()` extracts `updatedAt` from the body, strips it from the patch, and passes it through.

## Key Decisions

1. **Conflict response shape matches device settings**: `{ ok: false, conflict: true, reason: "stale_write", preferences: <current>, updatedAt: <current> }` — identical to `pushSettings()` pattern.

2. **Merge, not replace**: `setUserPreferences()` now reads existing `preferences_json` and merges incoming over it (`{ ...existing, ...incoming }`). Previously it did a full replace, which lost unrelated fields on partial updates.

3. **updatedAt is metadata, not a preference**: The VALID_KEYS set includes `"updatedAt"` so it passes validation, but the server strips it with `delete patch.updatedAt` before passing to the DB layer.

4. **No updatedAt = no conflict check**: When `incomingUpdatedAt` is null/undefined, the write always succeeds — clients that don't send `updatedAt` get last-write-wins behavior (backwards compatible).

5. **Equal timestamps are allowed**: `incoming < existing` uses strict less-than, so a write with the exact same timestamp as the current row is accepted (idempotent re-send).

## Integration Points

- User preferences cascade to devices via `ownerPreferences` in `GET /settings` and `POST /heartbeat` responses.
- The admin bundle (`GET /frames/admin/bundle`) includes user preferences with `updatedAt`.
- Profile > Frames UI should send `updatedAt` from the last read when updating preferences.
- This fulfills the `userPreferences` conflict evidence requirement in `backend-settings-contract-issue.md`.

## Test Coverage

- `scripts/preferences-conflict-resolution-check.sh`: 9 steps, 40 checks, all passing.
