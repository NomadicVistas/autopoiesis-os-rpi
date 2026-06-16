# Pulse Agent Notes

## 2026-06-16 08:09 PM Europe/Berlin - LEAD / INTEGRATION — Added index on aos_frame_devices(owner_user_id, last_heartbeat_at) for faster device lookup by owner
- Added index on owner_user_id and last_heartbeat_at (descending) in aos_frame_devices table via migration 20260616180900_add_index_on_devices_owner_user_id_last_heartbeat_at.sql
- Speeds up queries for retrieving a user's devices ordered by last heartbeat (profile dashboard).
- Improves admin device listing when filtering by owner.
- Benefits multiple workstreams: profile, API, admin, sync.
- Reduces query latency for owner-centric device lookups.
- Verification: bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed; node --check local-ui/server.js passed; node --check hosted-api/server.js passed.
- Verified index creation via schema query.

## 2026-06-16 04:45 PM Europe/Berlin - LEAD / RPI APPLIANCE — Cleaned up heartbeat script
- Removed test comments from scripts/heartbeat.sh
- Improved script clarity and maintainability by removing debugging artifacts.
- Verification: bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed; node --check local-ui/server.js passed; node --check hosted-api/server.js passed.

## 2026-06-16 11:10 AM Europe/Berlin - LEAD / INTEGRATION — Enhanced effective preferences endpoint with subscription and entitlements

Extended GET /frames/device/:id/effective-preferences to include subscription and entitlements for the device owner.
- Added logic to fetch owner subscription, compute device count and entitlements using existing computeEntitlements function.
- Returned subscription and entitlements in the response alongside existing effective preferences, device settings, and owner preferences.
- Reduces round trips for devices needing both effective preferences and subscription/entitlement data during startup or reconfiguration.
- Integrates profile (subscription) data directly into the effective preferences endpoint, simplifying device-side logic.
- Supports multiple workstreams (profile, API, pairing, sync) by providing a more complete device context in a single call.
- Lays foundation for future features like dynamic feature gating based on entitlements.
- Verification: bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed; node --check hosted-api/server.js passed; node --check local-ui/server.js passed.
- Manual verification of the updated endpoint returns correct subscription and entitlements for paired devices with owners, and null for unpaired devices.

## 2026-06-15 04:59 AM Europe/Berlin - API / DATABASE / SYNC — Enhanced settings conflict diagnostics

Enhanced pushSettings conflict response to include incomingSettings metadata in hosted-api/db.js
- When a settings conflict occurs (stale write), the response now includes both the current settings and the incoming settings that caused the conflict
- This improves debugging capabilities for sync issues by showing exactly what the client tried to write
- Preserves existing conflict resolution logic and API contract
- Verification: node --check hosted-api/server.js passed; bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed.

## 2026-06-08 19:15 - Admin token authentication for all hosted API admin endpoints

Added `authenticateAdmin(req)` to `hosted-api/server.js` — validates admin requests via `Authorization: Bearer <token>` or `x-admin-token: <token>` against `AUTOPOIESIS_FRAMES_ADMIN_TOKEN` environment variable.

Three auth states: (1) no token configured → 503, (2) missing → 401, (3) wrong → 403.

Applied to all 11 admin routes: bundle, device snapshot, broadcast deliveries (list + detail), broadcast CRUD (create, list, stats, get, update, publish, unpublish, archive).

Device-facing endpoints use `authenticateDevice()` (x-frame-device-key) — completely separate and unaffected.

Updated 4 existing check scripts: hosted-api-admin-bundle-check, admin-content-management-check, hosted-api-server-check, heartbeat-persistence-check. All now start the server with `AUTOPOIESIS_FRAMES_ADMIN_TOKEN` and include `x-admin-token` in admin endpoint calls.

Created `scripts/admin-auth-check.sh` — 7-step 38-check validation gate covering all auth states.

All regression checks passed: 121+131+74+33+94+38 checks, security-smoke, syntax checks.

**Design decisions:**
- Two header formats supported: `x-admin-token` (simple) and `Authorization: Bearer` (standard).