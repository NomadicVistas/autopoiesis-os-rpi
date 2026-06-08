# Pulse Agent Note — 2026-06-08 15:31 CEST

## Hosted API → Local UI End-to-End Bridge Check

### What was done
Created `scripts/hosted-api-local-ui-bridge-check.sh` — the key integration milestone proving the entire AOS stack works end-to-end with a real database backend.

### Why this matters
Previously, the hosted API server was validated in isolation (hosted-api-server-check.sh) and the mock API was validated with the local UI (hosted-mock-bridge-check.sh), but nobody had proven that the real database-backed hosted API could serve the real local UI through the full device lifecycle. This bridge check closes that gap.

### Key findings
- The hosted API's settings endpoint returns `ok: true` with empty settings for new devices (matching mock API behavior).
- The hosted API's heartbeat returns commands wrapped in `{ items: [...] }` which the local UI's `normalizeCommandsPayload` correctly unwraps.
- Command delivery through heartbeat → processCommands → audit log works correctly.
- Settings push from local UI to hosted API persists and reads back correctly (verified `brightness=75` round-trip).
- Both servers agree on device state after the full lifecycle (device ID, owner, paired status, settings).

### Database schema note
The `aos_frame_devices` table does not have a `status` column — use `last_heartbeat_at` to verify heartbeat persistence.

### Next steps
1. Add bridge check to `scripts/verify-all.sh`
2. Populate hosted API stream endpoint with real content
3. Run bridge check against PostgreSQL staging
4. Wire into physical Pi testing
