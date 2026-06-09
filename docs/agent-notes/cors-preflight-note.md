# CORS Preflight Note

Date: 2026-06-09

## What

Added CORS preflight (OPTIONS) handling to the hosted API server.

## Why

The hosted API included `access-control-allow-origin: *` on all JSON responses via `sendJson()`, but had no OPTIONS handler. Browsers send a preflight OPTIONS request before cross-origin requests with custom headers (x-admin-token, x-frame-device-key, Authorization). Without an OPTIONS handler, the browser blocks the actual request.

This was a deployment blocker for:
- Admin dashboard at admin.autopoiesis.art → api.autopoiesis.art
- Profile > Frames settings page
- Any browser-based management interface

## Implementation

- `CORS_HEADERS` constant with standard CORS response headers
- `sendCorsPreflight()` returns 204 No Content with CORS headers
- OPTIONS handler at top of `handle()` before route matching
- No authentication required for preflight (by design — preflight must never fail due to credentials)
- `access-control-max-age: 86400` caches preflight for 24 hours

## Design decisions

- `access-control-allow-origin: *` (wildcard) — appropriate for a public API. Production may want to restrict to specific domains.
- `access-control-allow-headers` includes all custom headers used by the API: Content-Type, Authorization, x-admin-token, x-frame-device-key.
- OPTIONS handler runs before all route matching and authentication — preflight must always succeed regardless of the path or credentials.
- 204 No Content (not 200 OK) — preflight responses must not have a body per the CORS spec.

## Verification

- `scripts/cors-preflight-check.sh` — 7 steps, 45 checks, all passing
- `scripts/hosted-api-security-smoke.sh` — 41/41, no regression
- All syntax checks pass

## Next

- Consider restricting origin in production (replace * with specific domains)
- Add CORS to local-ui/server.js for browser-based local management
- Test with actual admin dashboard frontend
