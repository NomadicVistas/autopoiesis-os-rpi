# User Pair Endpoint Note

## 2026-06-09 — POST /frames/me/pair

### What was built

User-facing device pairing endpoint that closes the pairing loop: device registers → gets pairing code → user enters code on Profile > Frames → device paired.

### Handler: `handleMePairDevice(db, userId, body)`

Accepts `{ pairingCode }` from the request body. Validates format, checks entitlements (subscription status + device limit), and calls `db.claimPairingCode()`.

### Entitlement gating

- Degraded subscription (expired/cancelled/past_due) → 403 `subscription_degraded`
- Device limit reached (trial=1, basic=3, premium=10, enterprise=unlimited) → 403 `device_limit_reached`
- Expired pairing code → 410 `code_expired`
- Invalid/not-found code → 404 `code_not_found`
- Already-claimed code → 404 (handled by DB layer)

### Response shape (success)

```json
{
  "ok": true,
  "kind": "autopoiesis_frames_me_pair",
  "generatedAt": "...",
  "device": {
    "deviceId": "...",
    "deviceName": "...",
    "deviceType": "...",
    "softwareVersion": "...",
    "updateChannel": "stable",
    "paired": true,
    "pairedAt": "...",
    "ownerUserId": "..."
  },
  "entitlements": {
    "maxDevices": 3,
    "devicesRemaining": 2,
    "currentDeviceCount": 1
  }
}
```

### Also fixed: handleRegister now passes deviceName/deviceType

The `handleRegister` function was previously discarding `deviceName` and `deviceType` from the registration body. Now these are passed through to `registerDevice()`, so devices register with the names and types provided by the Pi agent.

### Validation

- `scripts/user-pair-endpoint-check.sh`: 15 steps, 212 checks, all passing
- No regressions in: CORS preflight (45/45), admin auth (38/38), security smoke (41/41), user profile me (99/99), admin fleet devices (63/63), admin command audit (75/75)

### Why this matters

The `claimPairingCode()` method in db.js existed but was never wired to any API endpoint. There was no way for a user to pair their device from the Profile > Frames page — only admin endpoints or direct DB calls could pair devices. This is the critical missing link in the pairing flow: Pi boots → registers → shows pairing code on screen → user opens Profile > Frames on their phone → enters code → device paired. Unblocks: Profile > Frames frontend pairing UI, physical Pi testing cycle, end-to-end pairing verification.

### Next steps

- Wire POST /frames/me/pair into the Profile > Frames frontend UI (pairing code input).
- Add pairing code display to the Pi local UI (show on-screen during setup).
- Test the full register → display code → enter code → paired cycle on physical Pi.
- Consider pairing code regeneration (user can request a new code if the old one expires).
