# Backend Heartbeat Contract Gate

## Summary

Generate a staging/CI heartbeat fixture and run `scripts/heartbeat-contract-check.sh` before treating the hosted Frames backend as sync-ready for physical Pi validation.

## Context

`POST /api/frames/device/{deviceId}/heartbeat` is the cross-system join point for device health, settings sync, command queues, event ingestion, broadcast delivery evidence, and release rollout evidence. The device-side mock gate proves cursor behavior locally, but the hosted backend still needs a direct response contract check.

## Expected Fixture

Provide either:

- A saved heartbeat response object.
- A bundle with `request` and `response` sections.
- A live URL plus `AUTOPOIESIS_HEARTBEAT_CONTRACT_REQUEST=/path/to/request.json`.

The request should include safe diagnostics and a unified `events.events[]` export with stable `source`, `eventKey`, and `observedAt` fields. The response should include `eventsAck` or `deviceEventsAck` with accepted event pointers. Optional `settings`, `commands`, and `items` are validated when present.

## Acceptance

- The checker passes with at least one exported request event and one event acknowledgement.
- Medium/high/critical command rows include approved authorization metadata; high/critical commands include an audit id.
- The fixture does not expose device API keys, pairing-code hashes, private/admin tokens, secrets, passwords, or local appliance paths.
- `scripts/hosted-contract-suite-check.sh --strict` includes the heartbeat source and passes before physical Pi Milestone 2 validation.

## Open Questions

- Should the canonical CI fixture come from a full staged paired-device heartbeat, or from direct seed rows in `aos_frame_devices`, `aos_frame_commands`, and `aos_device_events`?
- Should hosted CI require a command in the heartbeat response with `AUTOPOIESIS_REQUIRE_HEARTBEAT_COMMANDS=1`, or keep command authorization covered by the online-admin and command-ack gates?
