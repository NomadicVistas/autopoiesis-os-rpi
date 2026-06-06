# Backend Broadcast Contract Gate

## Summary

Generate a read-only hosted broadcast lifecycle bundle and run `scripts/broadcast-contract-check.sh` before Admin > Frames broadcasts are treated as staging-ready.

## Context

The Pi now has local acceptance coverage for command-delivered broadcasts, but the hosted side still needs one durable proof that admin broadcast rows, queued `show_broadcast` commands, authorization/audit metadata, and delivery rows agree with each other.

The gate is intentionally fixture-friendly. It can read a saved JSON bundle from CI or a staging-only admin endpoint such as:

```text
GET /api/admin/frames/broadcast-contract-bundle
```

## Required Evidence

- Durable broadcast rows from the `aos_` namespace with stable ids, type, status, priority, schedule/expiry fields, and explicit targeting or audience.
- Queued command rows containing at least one `show_broadcast` command that references a known broadcast id and target device id.
- Approved command authorization metadata with `action: "show_broadcast"`, accepted actor role, authorized timestamp, and audit id.
- Durable delivery rows keyed by broadcast/device with display evidence such as `broadcast_shown`, `shown`, `delivered`, or `completed`.
- No raw device keys, pairing-code hashes, private/admin tokens, secrets, passwords, command payload secrets, or local appliance paths.

## Acceptance

```bash
AUTOPOIESIS_BROADCAST_CONTRACT_SOURCE=/path/to/broadcast-contract-bundle.json \
AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE=broadcast \
./scripts/hosted-contract-suite-check.sh
```

Use `./scripts/hosted-contract-suite-check.sh --strict` only when the full migration/schema/pairing/auth/heartbeat/stream/online-admin/broadcast/release source set is available.

Component-level route tests may run:

```bash
./scripts/broadcast-contract-check.sh /path/to/broadcast-contract-bundle.json
```

## Open Questions

- Should the bundle be generated from route-level integration tests, a staging-only admin adapter, or a seeded durable fixture?
- What is the canonical delivery state for scheduled broadcasts that have not reached their `startsAt` window yet?
- Should global broadcasts use `targeting: { allDevices: true }`, `audience: "all"`, or a normalized backend audience object?
