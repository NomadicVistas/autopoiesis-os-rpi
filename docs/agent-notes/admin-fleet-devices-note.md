# Admin Fleet Device Listing Endpoint

**Date:** 2026-06-09
**Workstream:** ONLINE ADMIN
**Milestone:** Fleet-wide device listing with filters, pagination, per-device enrichment

## What Changed

Added `GET /frames/admin/devices` — a focused, paginated, filterable device listing endpoint for the admin dashboard.

### db.js — extended listDevices + new helper

- `listDevices(opts)` now supports: `disabled`, `deviceType`, `updateChannel`, `search` (fuzzy), `paired` (explicit boolean)
- `getPendingCommandCount(deviceId)` — efficient count-only query for pending commands

### server.js — new handler + route

- `handleAdminListDevices(db, queryParams)` — fleet-wide listing with per-device enrichment
- `GET /frames/admin/devices` — admin-only, filtered, paginated
- Per-device returns: online status, pendingCommandCount, subscription, entitlements, actionAvailability

### Validation

- `scripts/admin-fleet-devices-check.sh` — 14 steps, 63 checks, all green
- No regressions in existing test suites

## Design Decisions

- `online` filter is post-SQL (computed from lastHeartbeatAt, not a stored column)
- `search` uses SQL LIKE across device_id, device_name, owner_user_id
- `getPendingCommandCount` is a separate method (not loading full command objects)
- `limit` capped at 500, defaults to 50
- `total` in response reflects the SQL-level total (pre-online-filter), online filter adjusts items but not total when online filter is active

## Gaps / Next Steps

- No sort parameter yet
- No fleet stats endpoint (total/online/disabled counts)
- No bulk device operations
- deviceType and updateChannel filters depend on data being stored at registration (currently registration doesn't persist these)
