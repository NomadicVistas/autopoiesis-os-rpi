# Hosted Contract Suite CI Gate

## Summary

Wire `scripts/hosted-contract-suite-check.sh` into the hosted Frames staging or CI path so backend readiness is proven once before physical Raspberry Pi validation.

## Context

The repo now has individual gates for migration plans, final `aos_` schema shape, pairing lifecycle evidence, device-route authentication evidence, settings conflict evidence, profile ownership evidence, heartbeat/event-ingestion evidence, command polling evidence, command acknowledgement lifecycle evidence, command state transitions, stream responses, cache/offline evidence, Profile/Admin Frames bundles, broadcast lifecycle evidence, release manifests, and hosted release rollout evidence. Running them one-by-one is easy to forget and makes backend handoff ambiguous.

The suite runner gives the hosted app one ordered contract pass:

1. `scripts/aos-migration-contract-check.sh`
2. `scripts/aos-schema-contract-check.sh`
3. `scripts/pairing-contract-check.sh`
4. `scripts/device-auth-contract-check.sh`
5. `scripts/settings-contract-check.sh`
6. `scripts/profile-ownership-contract-check.sh`
7. `scripts/heartbeat-contract-check.sh`
8. `scripts/command-poll-contract-check.sh`
9. `scripts/command-ack-contract-check.sh`
10. `scripts/command-state-contract-check.sh`
11. `scripts/stream-contract-check.sh`
12. `scripts/cache-contract-check.sh`
13. `scripts/online-admin-contract-check.sh`
14. `scripts/broadcast-contract-check.sh`
15. `scripts/release-manifest-check.sh`
16. `scripts/release-rollout-contract-check.sh`

## Acceptance

- CI exports saved contract fixtures or staging URLs through the `AUTOPOIESIS_*_SOURCE` variables documented in the script usage, or through one `AUTOPOIESIS_HOSTED_CONTRACT_MANIFEST` JSON file with a `sources` object keyed by gate name.
- CI uses `scripts/hosted-contract-suite-check.sh --list-gates` as the authoritative gate catalog for manifest generation and rollout annotations instead of duplicating gate order or source env names in backend jobs.
- CI can start manifest generation with `scripts/hosted-contract-suite-check.sh --manifest-template`, which emits a disabled source entry for every catalog gate plus source env, checker, and label metadata.
- Manifest-relative paths resolve from the manifest directory, and per-gate `AUTOPOIESIS_*_SOURCE` variables override manifest entries for targeted reruns.
- Staging runs `scripts/hosted-contract-suite-check.sh --strict`, or emits a manifest with `strict: true` / `requireAll: true`, before physical Pi acceptance.
- Partial backend jobs use manifest `require`/`requiredGates` or `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE` to require the gate(s) they own while still running any other provided sources.
- CI runs `scripts/hosted-contract-suite-check.sh --plan` against the same manifest before the full suite when it needs a redacted rollout/source matrix without fetching live fixtures or executing individual checkers.
- Required-gate typos in `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE` or manifest requirements fail before any gate runs.
- CI sets `AUTOPOIESIS_HOSTED_CONTRACT_REPORT` to archive the redacted JSON readiness report, then uses `status`, `mode`, `requiredGates`, `summary`, `failedGate`, and per-gate statuses for deploy/rollout annotations instead of scraping terminal output.
- Profile ownership staging exports `AUTOPOIESIS_PROFILE_OWNERSHIP_CONTRACT_SOURCE` with owned Profile success, cross-owner denial, anonymous denial, and admin-boundary evidence from real account/session checks.
- Cache/offline staging exports `AUTOPOIESIS_CACHE_CONTRACT_SOURCE` with explicit cache policy, cache candidates, and ingested device cache summary evidence.
- Broadcast staging exports `AUTOPOIESIS_BROADCAST_CONTRACT_SOURCE` with durable broadcast rows, queued `show_broadcast` command evidence, approved authorization/audit metadata, and delivery/display rows.
- Release/update staging exports `AUTOPOIESIS_RELEASE_ROLLOUT_CONTRACT_SOURCE` with durable release rows, per-device rollout rows, queued `update_device` command evidence, approved authorization/audit metadata, and heartbeat-ingested `release_history` events.
- Command polling staging exports `AUTOPOIESIS_COMMAND_POLL_CONTRACT_SOURCE` or a manifest `command-poll` source with durable command rows, exact authorized poll output, denied poll evidence, authorization metadata, and redaction boundaries.
- Command acknowledgement staging exports `AUTOPOIESIS_COMMAND_ACK_CONTRACT_SOURCE` with durable command rows, ack attempts, mirrored admin audit rows, heartbeat-ingested `command_audit` events, and duplicate final-ack idempotency evidence.
- Command state staging exports `AUTOPOIESIS_COMMAND_STATE_CONTRACT_SOURCE` with queued before-poll rows, delivered/sent post-poll rows, terminal post-ack rows, mirrored admin audits, next-poll exclusion evidence, and redaction boundaries.
- The suite passes before Milestone 2 physical validation is treated as backend-ready.

## Open Questions

- Which hosted CI job will own generating the pairing and online-admin contract bundles from real auth/session data?
- Should the profile ownership bundle be generated from route-level integration tests, a staging-only admin adapter, or both?
- Should the device-auth bundle be generated from route-level integration tests, a staging-only admin adapter, or both?
- Should the heartbeat bundle be generated from the same staged device used for pairing acceptance, or from a durable fixture seeded directly into `aos_device_events` and command queue rows?
- Should the command acknowledgement bundle use route-level ack tests, seeded durable rows, or both to prove duplicate final ack idempotency?
- Should polling mark commands `sent` immediately, or should the first `acknowledged` acknowledgement be the canonical delivered transition?
- Should cache summaries be generated only from heartbeat ingestion, or can support-bundle uploads backfill cache/offline status for support workflows?
- Should the broadcast bundle come from a staging-only admin adapter, broadcast route integration tests, or a deterministic seeded `aos_broadcasts`/`aos_broadcast_deliveries` fixture?
- Should release manifest validation run against the GitHub release adapter, the Frames API release endpoint, or both before the first production tag?
- Should the release-rollout bundle be generated by a staging-only admin adapter, seeded update route tests, or the same release promotion job that creates `aos_release_rollouts` rows?
