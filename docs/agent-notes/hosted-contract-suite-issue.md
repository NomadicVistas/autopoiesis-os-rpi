# Hosted Contract Suite CI Gate

## Summary

Wire `scripts/hosted-contract-suite-check.sh` into the hosted Frames staging or CI path so backend readiness is proven once before physical Raspberry Pi validation.

## Context

The repo now has individual gates for migration plans, final `aos_` schema shape, pairing lifecycle evidence, stream responses, Profile/Admin Frames bundles, and release manifests. Running them one-by-one is easy to forget and makes backend handoff ambiguous.

The suite runner gives the hosted app one ordered contract pass:

1. `scripts/aos-migration-contract-check.sh`
2. `scripts/aos-schema-contract-check.sh`
3. `scripts/pairing-contract-check.sh`
4. `scripts/stream-contract-check.sh`
5. `scripts/online-admin-contract-check.sh`
6. `scripts/release-manifest-check.sh`

## Acceptance

- CI exports saved contract fixtures or staging URLs through the `AUTOPOIESIS_*_SOURCE` variables documented in the script usage.
- Staging runs `scripts/hosted-contract-suite-check.sh --strict` before physical Pi acceptance.
- Partial backend jobs use `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE` to require the gate(s) they own while still running any other provided sources.
- The suite passes before Milestone 2 physical validation is treated as backend-ready.

## Open Questions

- Which hosted CI job will own generating the pairing and online-admin contract bundles from real auth/session data?
- Should release manifest validation run against the GitHub release adapter, the Frames API release endpoint, or both before the first production tag?
