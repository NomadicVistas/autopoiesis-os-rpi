# Backend Command State Contract Handoff

## Summary

Generate a read-only command state contract bundle from hosted staging/CI and run `scripts/command-state-contract-check.sh` before treating remote command lifecycle state as backend-ready.

## Context

`command-poll` proves the device receives the right queued commands, and `command-ack` proves acknowledgement writes are durable. The remaining state-machine gap is the outbox transition between them: after polling, queued rows should be marked delivered/sent; after terminal acknowledgement, rows should become terminal, mirror Admin audit status, and disappear from the next device poll.

## Bundle Shape

Expose a staging-only adapter or CI fixture at:

```txt
GET /api/admin/frames/command-state-contract-bundle
```

Recommended root:

```json
{
  "ok": true,
  "kind": "autopoiesis_frames_command_state_contract",
  "schemaVersion": 1,
  "generatedAt": "2026-06-07T06:45:00.000Z",
  "deviceId": "frame-test-001",
  "beforePollCommands": [],
  "postPollCommands": [],
  "postAckCommands": [],
  "adminAudits": [],
  "nextPoll": {
    "statusCode": 200,
    "commands": []
  }
}
```

The fixture should be derived from seeded staging rows or route-level integration tests for:

- `aos_device_commands`
- `aos_admin_command_audits`
- the command polling serializer
- `POST /api/frames/device/{deviceId}/commands/{commandId}/ack`

## Acceptance

- At least one command is visible as queued before poll.
- The same command is visible as delivered/sent after poll with delivered timestamp evidence.
- The same command reaches terminal `completed`, `error`, `failed`, `denied`, `expired`, or `cancelled` after acknowledgement with terminal timestamp evidence.
- Post-poll and post-ack command rows expose durable `updatedAt`; row update timestamps must not move backwards relative to the queued row, delivered timestamp, terminal timestamp, or previous row update.
- Admin audit rows mirror terminal command status.
- A subsequent poll for the same device no longer returns terminal commands.
- The bundle omits raw command payloads, device credentials, tokens, pairing hashes, release artifact URLs/checksums, stdout/stderr, and local appliance paths.

## Verification

```bash
AUTOPOIESIS_COMMAND_STATE_CONTRACT_TOKEN="$TOKEN" \
  ./scripts/command-state-contract-check.sh \
  "https://autopoiesis.art/api/admin/frames/command-state-contract-bundle"

AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE=command-state \
AUTOPOIESIS_COMMAND_STATE_CONTRACT_SOURCE=/path/to/command-state-contract-bundle.json \
  ./scripts/hosted-contract-suite-check.sh
```

## Open Question

Should polling move a command from `queued` to `sent` immediately, or only after the device posts an initial `acknowledged` acknowledgement? The checker accepts `sent`, `delivered`, `acknowledged`, or `processing` as the post-poll state, but staging should choose one canonical transition before broad Admin/Profile command controls ship.
