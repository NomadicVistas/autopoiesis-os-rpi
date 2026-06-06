# Backend Pairing Contract Issue

## Summary

Add a read-only staging/CI contract bundle for the Frames pairing lifecycle and make the backend pairing implementation satisfy `scripts/pairing-contract-check.sh`.

This is not a production endpoint requirement. It is a safe evidence adapter so the Pi, Profile > Frames, Admin > Frames, and durable `aos_` tables can be validated before physical device pairing is treated as rollout-ready.

## Proposed Adapter

```txt
GET /api/admin/frames/pairing-contract-bundle
```

The endpoint should be admin/staging gated and should return controlled evidence from a fixture or a recently completed test pairing flow. It should not claim a real user's device as a side effect.

## Required Bundle Shape

Root:

- `ok: true`
- `kind: "autopoiesis_frames_pairing_contract_bundle"`
- `schemaVersion: 1`
- `generatedAt`
- `deviceRegistration`
- `userPairing`
- `pairingStatus`

`deviceRegistration.response` should mirror `POST /api/frames/device/register`:

- Stable `deviceId`
- Device name/type/version metadata when available
- `paired: false`
- Active raw `pairingCode` only for the registering device
- `expiresAt` within the configured TTL
- Per-device API credential returned to the device at registration

`userPairing.response` should mirror `POST /api/frames/user/devices/pair`:

- Authenticated `ownerUserId`
- Same `deviceId`
- `paired: true`
- `claimedAt`
- Optional applied settings/preferences
- No stored device API key
- No `pairingCodeHash`

`pairingStatus.response` should mirror `GET /api/frames/device/{deviceId}/pairing-status` after claim:

- `paired: true`
- Same device/owner relationship
- Optional safe pairing status metadata
- Optional settings handoff
- No stored device API key or pairing-code hash

## Durable Storage Expectations

- `aos_frame_devices.device_id` remains the stable device identity.
- `aos_frame_pairing_codes` stores a hash, expiry, status, claimant, and claimed timestamp.
- Raw pairing codes are allowed only in active device-facing registration/status responses.
- User/Profile/Admin responses must never expose stored device API keys or pairing-code hashes.
- Claiming a code must be one-time and idempotent from the user's perspective: repeated requests for an already claimed code should not reassign ownership.

## Acceptance

Run:

```bash
scripts/pairing-contract-check.sh /path/to/pairing-contract-bundle.json
AUTOPOIESIS_PAIRING_CONTRACT_TOKEN="$TOKEN" scripts/pairing-contract-check.sh "https://autopoiesis.art/api/admin/frames/pairing-contract-bundle"
```

Then pair a physical Pi and run the existing local readiness, admin capabilities, settings sync, heartbeat, and rollout gates.

## Open Questions

- Should the backend rotate the device API credential after claim, or keep the registration credential as the durable device key?
- Should expired code cleanup be a scheduled job or happen opportunistically during registration/claim/status calls?
- Which account/session identity field is canonical for `ownerUserId` in hosted Profile > Frames?
