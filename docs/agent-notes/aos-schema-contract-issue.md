# Backend Issue: Durable AOS Schema Contract Gate

## Summary

Add `scripts/aos-schema-contract-check.sh` to backend migration/staging verification so the Frames API cannot drift away from the durable `aos_` database contract before device, admin, feed, broadcast, and rollout tests run.

## Why This Matters

The current workstream now has response gates for stream playback, Profile/Admin bundles, command acknowledgement retries, event ingestion cursors, delivery evidence, and rollout acceptance. Those gates still assume the same durable tables and keys exist underneath. A schema-level gate catches missing columns and idempotency keys before a Pi or UI test fails indirectly.

## Required Tables

- `aos_frame_devices`
- `aos_frame_pairing_codes`
- `aos_frame_device_settings`
- `aos_frame_user_preferences`
- `aos_heartbeats`
- `aos_device_commands`
- `aos_admin_command_audits`
- `aos_device_events`
- `aos_artwork_likes`
- `aos_broadcasts`
- `aos_releases`
- `aos_subscriptions`
- `aos_broadcast_deliveries`
- `aos_release_rollouts`

## Acceptance

- Run `scripts/aos-schema-contract-check.sh` against a staging SQLite database file or exported schema JSON.
- The gate passes before running hosted stream, online admin bundle, heartbeat ingestion, command acknowledgement, broadcast delivery, or rollout checks.
- The backend keeps `deviceId + eventKey`, `broadcastId + deviceId`, and `releaseId + deviceId` idempotency keys intact.
- If the backend still stores plaintext `pairing_code`, treat the gate warning as a production-hardening follow-up and migrate to `pairing_code_hash` before broader rollout.

## Open Questions

- Should `aos_frame_pairing_codes` move to hash-only before the next public pairing test, or after the current Pi claim path is stabilized?
- Should canonical account/subscription tables remain mirrored into `aos_subscriptions`, or should the schema gate accept a view once the account model is final?
