# Backend Issue: Profile Ownership Contract Bundle

## Summary

Add a staging/CI fixture or adapter that proves Profile > Frames account/session ownership boundaries before owner-facing frame controls are enabled.

## Acceptance

- Generate a read-only bundle consumable by `scripts/profile-ownership-contract-check.sh`.
- Include successful Profile requests for an owner listing their frames, reading one owned frame, and writing settings for that owned frame.
- Include rejected attempts where a different authenticated user tries to read the owner frame, write its settings, and queue an owner command for it.
- Include rejected anonymous Profile access.
- Include a separate Admin > Frames fleet read by an admin/support actor that returns devices from at least two owners, proving fleet visibility is not leaking through Profile routes.
- Do not include stored device API keys, raw pairing codes, pairing-code hashes, private/admin tokens, secrets, passwords, raw bearer tokens, command payload secrets, or local appliance paths.

## Suggested Bundle Shape

```json
{
  "ok": true,
  "kind": "autopoiesis_frames_profile_ownership_contract",
  "schemaVersion": 1,
  "generatedAt": "2026-06-07T02:15:00.000Z",
  "checks": [
    {
      "kind": "owned-list",
      "actorUserId": "user_owner_a",
      "status": 200,
      "allowedDeviceIds": ["frame-a"],
      "forbiddenDeviceIds": ["frame-b"],
      "body": {
        "devices": [
          { "deviceId": "frame-a", "ownerUserId": "user_owner_a", "paired": true }
        ]
      }
    },
    {
      "kind": "cross-owner-read",
      "actorUserId": "user_owner_b",
      "targetDeviceId": "frame-a",
      "expectedOwnerUserId": "user_owner_a",
      "status": 403,
      "body": { "ok": false, "error": "forbidden" }
    }
  ]
}
```

The checker also requires `owned-read`, `owned-settings-write`, `cross-owner-settings-write`, `cross-owner-command`, `anonymous-profile`, and `admin-fleet-read` by default.

## Verification

```bash
AUTOPOIESIS_PROFILE_OWNERSHIP_CONTRACT_SOURCE=/path/to/profile-ownership-contract-bundle.json \
  scripts/hosted-contract-suite-check.sh

AUTOPOIESIS_PROFILE_OWNERSHIP_CONTRACT_SOURCE=/path/to/profile-ownership-contract-bundle.json \
  AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE=profile-ownership \
  scripts/hosted-contract-suite-check.sh
```

## Open Question

Decide whether cross-owner misses should normalize to `403` or `404`. Both are accepted by the contract; the UI and logs should use one canonical shape so support can distinguish unauthenticated, unauthorized, and missing-device cases cleanly.
