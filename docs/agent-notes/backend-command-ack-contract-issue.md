# Backend Command Acknowledgement Contract Handoff

## Summary

Generate a read-only command acknowledgement contract bundle from hosted staging/CI and run `scripts/command-ack-contract-check.sh` before treating remote command execution as backend-ready.

## Context

The device already has a local retry gate for failed acknowledgements, and device-route auth already proves the ack endpoint rejects missing/wrong/cross-device credentials. The remaining backend risk is durable state drift: the ack route can accept a request but fail to update `aos_device_commands`, fail to mirror status into `aos_admin_command_audits`, create duplicate effects for repeated final acks, or lose the heartbeat-ingested `command_audit` event trail.

## Bundle Shape

Expose a staging-only adapter or CI fixture at:

```txt
GET /api/admin/frames/command-ack-contract-bundle
```

Recommended root:

```json
{
  "ok": true,
  "kind": "autopoiesis_frames_command_ack_contract",
  "schemaVersion": 1,
  "generatedAt": "2026-06-07T02:45:00.000Z",
  "commands": [],
  "acknowledgements": [],
  "adminAudits": [],
  "deviceEvents": []
}
```

The fixture should be derived from seeded staging rows or route-level integration tests for:

- `aos_device_commands`
- `aos_admin_command_audits`
- `aos_device_events` rows with `source: "command_audit"`
- `POST /api/frames/device/{deviceId}/commands/{commandId}/ack` attempts

## Acceptance

- At least one command reaches `acknowledged` and has `acknowledgedAt`.
- At least one command reaches terminal `completed`, `error`, `failed`, or `denied` with terminal timestamp evidence.
- Admin audit rows mirror terminal command status.
- `command_audit` device events reference known command/device rows and use unique `deviceId + eventKey` idempotency.
- A repeated final acknowledgement is accepted or harmlessly rejected as idempotent/no-change, without duplicate audit/event effects.
- The bundle omits raw command payloads, device credentials, tokens, pairing hashes, release artifact URLs/checksums, stdout/stderr, and local appliance paths.

## Verification

```bash
AUTOPOIESIS_COMMAND_ACK_CONTRACT_TOKEN="$TOKEN" \
  ./scripts/command-ack-contract-check.sh \
  "https://autopoiesis.art/api/admin/frames/command-ack-contract-bundle"

AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE=command-ack \
AUTOPOIESIS_COMMAND_ACK_CONTRACT_SOURCE=/path/to/command-ack-contract-bundle.json \
  ./scripts/hosted-contract-suite-check.sh
```

## Open Question

Should duplicate final ack attempts return `200/204` with explicit idempotent metadata or `409` with the unchanged terminal row? Either is acceptable for the checker if the evidence is explicitly harmless and no duplicate effects are created.
