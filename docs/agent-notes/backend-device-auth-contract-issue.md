# Backend Device Auth Contract Gate

## Summary

Add staging/CI evidence for device-route authentication and validate it with `scripts/device-auth-contract-check.sh` before physical Raspberry Pi acceptance.

## Context

Pairing now proves that a device receives a durable credential and becomes bound to an owner. The remaining backend risk is route drift: heartbeat, stream, settings, commands, and releases could accidentally accept missing credentials, invalid credentials, or credentials from another frame.

## Acceptance

- Generate a saved bundle or staging-only adapter at `GET /api/admin/frames/device-auth-contract-bundle`.
- Cover these route kinds by default: `pairing-status`, `settings-read`, `settings-write`, `heartbeat`, `stream`, `commands`, `command-ack`, and `release`.
- For every route, include attempts for:
  - `authorized`: correct device credential succeeds with 2xx.
  - `missingCredential`: no device credential fails with 401 or 403.
  - `wrongCredential`: invalid credential fails with 401 or 403.
  - `mismatchedDevice`: another device's valid credential against this route device id fails with 401, 403, or 404.
- When an authorized response includes a device id, it must match the route device id.
- Do not expose raw device API keys, API-key field names, pairing-code hashes, private/admin tokens, bearer tokens, secrets, passwords, or local Pi paths in the bundle.

## Suggested Bundle Shape

```json
{
  "kind": "autopoiesis_frames_device_auth_contract",
  "schemaVersion": 1,
  "generatedAt": "2026-06-06T21:15:00.000Z",
  "routes": [
    {
      "kind": "heartbeat",
      "method": "POST",
      "path": "/api/frames/device/frame-alpha/heartbeat",
      "deviceId": "frame-alpha",
      "attempts": {
        "authorized": { "status": 200, "body": { "ok": true, "deviceId": "frame-alpha" } },
        "missingCredential": { "status": 401, "body": { "ok": false, "error": "missing_device_credential" } },
        "wrongCredential": { "status": 403, "body": { "ok": false, "error": "invalid_device_credential" } },
        "mismatchedDevice": { "status": 403, "body": { "ok": false, "error": "device_credential_mismatch" } }
      }
    }
  ]
}
```

## Verification

```bash
scripts/device-auth-contract-check.sh /path/to/device-auth-contract-bundle.json

AUTOPOIESIS_DEVICE_AUTH_CONTRACT_SOURCE=/path/to/device-auth-contract-bundle.json \
AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE=device-auth \
scripts/hosted-contract-suite-check.sh
```

## Open Questions

- Should production device credentials be presented as bearer tokens, an `x-device-key` header, or both during a transition period?
- Should pairing status remain device-keyed after pairing, or split into a public setup-safe status and a keyed owner/device status?
