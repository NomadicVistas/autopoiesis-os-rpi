# Pulse Agent Notes

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

[1338 more lines in file. Use offset=21 to continue.]