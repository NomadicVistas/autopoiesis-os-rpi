# Hosted Contract Suite CI Gate

## Summary

Wire `scripts/hosted-contract-suite-check.sh` into the hosted Frames staging or CI path so backend readiness is proven once before physical Raspberry Pi validation.

## Context

The repo now has individual gates for migration plans, final `aos_` schema shape, pairing lifecycle evidence, device-route authentication evidence, settings conflict evidence, heartbeat/event-ingestion evidence, stream responses, cache/offline evidence, Profile/Admin Frames bundles, broadcast lifecycle evidence, and release manifests. Running them one-by-one is easy to forget and makes backend handoff ambiguous.

The suite runner gives the hosted app one ordered contract pass:

1. `scripts/aos-migration-contract-check.sh`
2. `scripts/aos-schema-contract-check.sh`
3. `scripts/pairing-contract-check.sh`
4. `scripts/device-auth-contract-check.sh`
5. `scripts/settings-contract-check.sh`
6. `scripts/heartbeat-contract-check.sh`
7. `scripts/stream-contract-check.sh`
8. `scripts/cache-contract-check.sh`
9. `scripts/online-admin-contract-check.sh`
10. `scripts/broadcast-contract-check.sh`
11. `scripts/release-manifest-check.sh`

## Acceptance

- CI exports saved contract fixtures or staging URLs through the `AUTOPOIESIS_*_SOURCE` variables documented in the script usage.
- Staging runs `scripts/hosted-contract-suite-check.sh --strict` before physical Pi acceptance.
- Partial backend jobs use `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE` to require the gate(s) they own while still running any other provided sources.
- Cache/offline staging exports `AUTOPOIESIS_CACHE_CONTRACT_SOURCE` with explicit cache policy, cache candidates, and ingested device cache summary evidence.
- Broadcast staging exports `AUTOPOIESIS_BROADCAST_CONTRACT_SOURCE` with durable broadcast rows, queued `show_broadcast` command evidence, approved authorization/audit metadata, and delivery/display rows.
- The suite passes before Milestone 2 physical validation is treated as backend-ready.

## Open Questions

- Which hosted CI job will own generating the pairing and online-admin contract bundles from real auth/session data?
- Should the device-auth bundle be generated from route-level integration tests, a staging-only admin adapter, or both?
- Should the heartbeat bundle be generated from the same staged device used for pairing acceptance, or from a durable fixture seeded directly into `aos_device_events` and command queue rows?
- Should cache summaries be generated only from heartbeat ingestion, or can support-bundle uploads backfill cache/offline status for support workflows?
- Should the broadcast bundle come from a staging-only admin adapter, broadcast route integration tests, or a deterministic seeded `aos_broadcasts`/`aos_broadcast_deliveries` fixture?
- Should release manifest validation run against the GitHub release adapter, the Frames API release endpoint, or both before the first production tag?
