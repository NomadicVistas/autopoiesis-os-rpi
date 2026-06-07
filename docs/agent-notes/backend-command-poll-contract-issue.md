# Backend Handoff: Hosted Command Polling Contract

## Summary

Add staging/CI evidence for the hosted command polling path that devices consume from heartbeat responses or GET /api/frames/device/{deviceId}/commands.

The new acceptance gate:

    AUTOPOIESIS_COMMAND_POLL_CONTRACT_SOURCE=/path/to/command-poll-contract-bundle.json ./scripts/command-poll-contract-check.sh

The hosted contract suite also accepts command-poll in AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE and strict mode now includes it before command acknowledgement.

## Bundle Shape

Preferred root:

    {
      "kind": "autopoiesis_frames_command_poll_contract",
      "schemaVersion": 1,
      "generatedAt": "2026-06-07T03:15:00.000Z",
      "deviceId": "rpi-example",
      "commands": [],
      "authorizedPoll": {
        "status": 200,
        "commands": []
      },
      "excludedCommands": [],
      "deniedPolls": []
    }

commands should be durable aos_device_commands rows or sanitized projections. authorizedPoll.commands should be the exact redacted command rows returned to the target device. excludedCommands should include at least one not-yet-due/scheduled command and one expired, cancelled, or terminal command that was not returned. deniedPolls should prove disabled, unauthorized, or otherwise blocked polling returns no commands.

## Acceptance Rules

- Every returned command must exist in durable command rows.
- Returned commands must belong to the polling device.
- Every queued/pending/ready/retry durable row for that device must be returned exactly once.
- Commands for other devices, terminal statuses, expired commands, cancelled commands, and future notBefore rows must not be returned.
- Risky commands must include approved authorization metadata; high/critical commands must include an audit id.
- factory_reset_request must carry localConfirmationRequired: true.
- The bundle must not expose device API keys, pairing codes/hashes, private/admin tokens, secrets, release artifact URLs, checksums, stdout/stderr, or local Pi paths.

## Durable Sources

Generate the bundle from:

- aos_device_commands
- aos_admin_command_audits
- device eligibility state from aos_frame_devices
- optional subscriber/subscription state if command availability depends on plan status
- the same serializer used by heartbeat command responses and GET /commands

## Open Questions

- Should command polling mark rows as sent immediately, or only after the device posts the initial acknowledged transition?
- Should disabled/unpaired devices receive 403, 409, or 423 when command polling is blocked?
- Should scheduled commands use notBefore, scheduledFor, or a normalized availability window in the API response?
