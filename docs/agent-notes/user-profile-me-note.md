# User Profile /frames/me/* Note

**Date:** 2026-06-09
**Milestone:** PROFILE — user-facing API for Profile > Frames page

## What was built

User-facing API surface (`/frames/me/*`) that allows authenticated users to read their own profile data without admin credentials. This is the first user-facing endpoint layer in the hosted API.

## Auth design

- `authenticateUser(req, db)` validates `x-user-token` or `Authorization: Bearer <token>` against `AUTOPOIESIS_FRAMES_USER_TOKENS` env var (JSON map: `{\"token\": \"userId\"}`).
- Admin token pass-through: admin can access any user via `?userId=...`.
- Env var approach is an MVP placeholder — designed for swap to OAuth/session auth without touching handlers.

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | /frames/me | Profile summary (userId, devices, sub, prefs, likes) |
| GET | /frames/me/devices | User's paired devices with online status |
| GET | /frames/me/preferences | Read preferences with defaults |
| PATCH | /frames/me/preferences | Update with merge + conflict resolution |
| GET | /frames/me/liked-artworks | Paginated liked artwork IDs |
| GET | /frames/me/subscription | Subscription + computed entitlements |

## Decisions

- Entitlements use `deviceLimit`/`deviceSlotsRemaining` from `computeEntitlements()`, mapped to `maxDevices`/`devicesRemaining` in user-facing responses for clarity.
- Preference defaults served on GET when no stored preferences exist (same pattern as admin endpoint).
- Conflict resolution reuses the same `updatedAt`-based pattern as admin preferences and device settings.

## Open items

- Replace env var auth with proper user auth (OAuth, session-based).
- Add `POST /frames/me/pair` for user-initiated pairing flow.
- Add user token management endpoints (admin creates/revokes user tokens).
- Wire /frames/me/* into admin dashboard for user context switching.
