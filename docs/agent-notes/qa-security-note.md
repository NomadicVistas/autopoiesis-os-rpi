# QA / Security Agent Note

## 2026-06-08 — Hosted API Security Smoke + Admin PATCH Fix

### What was done
- Created `scripts/hosted-api-security-smoke.sh` — 41-check security regression gate for the hosted API.
- Fixed `handleAdminUpdateDevice()` in `hosted-api/server.js` to strip `deviceApiKey` from response.
- Added `*.pem`, `*.key`, `secrets/` to `.gitignore`.

### Key observations
- `GET /frames/device/:id/settings` is intentionally unauthenticated (device reads on boot before auth).
- `_mapDevice()` includes `deviceApiKey` — any new endpoint using mapped device records must explicitly strip it.
- The security smoke catches secret leaks by scanning all hosted API response bodies for device keys and admin tokens.

### Security architecture notes
- Device auth: `x-frame-device-key` header → `authenticateDevice()` → validates against `aos_frame_devices.device_api_key`.
- Admin auth: `Authorization: Bearer <token>` or `x-admin-token: <token>` → `authenticateAdmin()` → validates against `AUTOPOIESIS_FRAMES_ADMIN_TOKEN` env var.
- Cross-auth rejection: admin token does NOT work as device key, device key does NOT work as admin token.
- Health endpoint remains open (no auth).
- Registration is the ONLY endpoint that returns `deviceApiKey` in its response.

### Outstanding items
- Add hosted-api-security-smoke.sh to `scripts/verify-all.sh` Phase 3b.
- Consider `safeDeviceForResponse()` helper to reduce key leak surface.
- Consider CORS and rate-limiting security checks.
- Consider post-pair auth for `GET /settings`.
