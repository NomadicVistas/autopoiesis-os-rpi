# Backend Settings Contract Issue

## Summary

Add read-only staging/CI evidence for hosted Frames settings conflict handling and make it pass `scripts/settings-contract-check.sh`.

This is not a required production endpoint. It is an acceptance fixture or protected adapter so device sync, heartbeat, Profile > Frames, Admin > Frames, and durable `aos_` settings rows share the same newest-`updatedAt` behavior before physical Pi testing.

## Contract Source

Recommended optional adapter:

```text
GET /api/admin/frames/settings-contract-bundle
```

The bundle should include:

- `kind: "autopoiesis_frames_settings_contract"`
- `schemaVersion: 1`
- `generatedAt`
- `deviceId`
- `settingsRead`
- `newerWrite`
- `staleWrite`
- `finalRead`
- `heartbeat`
- optional `userPreferences` nested flow for account-level preference conflict evidence

## Required Evidence

- `settingsRead.response.settings.updatedAt` establishes the starting authoritative row.
- `newerWrite.request.settings.updatedAt` is newer than the starting row.
- `newerWrite.response.settings.updatedAt` preserves or advances the submitted timestamp.
- `staleWrite.request.settings.updatedAt` is older than the accepted row.
- `staleWrite.response` rejects the write with a 4xx status or returns an explicit conflict/not-applied marker.
- `finalRead.response.settings.updatedAt` still points to the accepted newer row.
- `heartbeat.response.settings.updatedAt` is at least as current as the accepted newer row.

When `AUTOPOIESIS_REQUIRE_SETTINGS_USER_PREFERENCES=1` is enabled, the bundle must also include:

- `userPreferences.userPreferencesRead.response.preferences.updatedAt` or `settings.updatedAt`
- `userPreferences.newerPreferenceWrite.request.preferences.updatedAt` newer than the starting row
- `userPreferences.newerPreferenceWrite.response.preferences.updatedAt` preserving or advancing the submitted timestamp
- `userPreferences.stalePreferenceWrite.response` rejecting or explicitly conflicting an older preference write
- `userPreferences.finalPreferencesRead.response.preferences.updatedAt` preserving the accepted newer preference row
- `userPreferences.heartbeat.response.settings.updatedAt` at least as current as the accepted user preference row, proving cascade freshness into effective device settings

The bundle must not expose device API keys, pairing codes or hashes, private/admin tokens, secrets, passwords, raw bearer tokens, or local appliance paths.

## Durable Rows

Use durable rows from:

- `aos_frame_devices`
- `aos_frame_device_settings`
- `aos_frame_user_preferences`
- heartbeat response assembly backed by the same resolved settings row

## Acceptance

```bash
scripts/settings-contract-check.sh /path/to/settings-contract-bundle.json
AUTOPOIESIS_REQUIRE_SETTINGS_USER_PREFERENCES=1 \
scripts/settings-contract-check.sh /path/to/settings-contract-bundle.json
AUTOPOIESIS_SETTINGS_CONTRACT_SOURCE=/path/to/settings-contract-bundle.json \
AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE=settings \
scripts/hosted-contract-suite-check.sh
```

For strict staging readiness, include the settings source alongside migration, schema, pairing, device-auth, heartbeat, stream, online-admin, broadcast, and release sources:

```bash
scripts/hosted-contract-suite-check.sh --strict
```

## Open Questions

- Should stale settings writes return `409 Conflict`, `200 ok=false`, or a successful response with explicit `applied: false` conflict metadata?
- Should user-level preference cascades and device-specific overrides use one shared timestamp namespace or separate `updatedAt` values with a deterministic merge order?
- Which Profile > Frames action should surface a stale-write conflict to the user, and which should silently refresh from the authoritative row?
