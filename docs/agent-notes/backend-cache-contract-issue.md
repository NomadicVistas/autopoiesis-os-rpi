# Backend Cache Contract Issue

## Summary

Generate a read-only hosted cache/offline contract bundle for `scripts/cache-contract-check.sh` before enabling Profile > Frames cache-management UI or treating physical Pi cache validation as staging-ready.

## Context

The Pi already builds a local cache manifest from stream items, downloads eligible media, exposes `/local/offline-cache`, and reports cache summaries through diagnostics/readiness/support bundles. Profile > Frames now requires explicit cache preferences, but the hosted side still needs one evidence bundle tying together:

- cache preferences from durable user/device settings
- cache-eligible stream rows from content/broadcast sources
- ingested device cache/offline summaries from heartbeat/support data
- optional `clear_cache` or `sync_settings` command evidence

## Contract Shape

The bundle may be assembled by a staging-only adapter such as:

`GET /api/admin/frames/cache-contract-bundle`

Root fields:

- `kind: "autopoiesis_frames_cache_contract"`
- `schemaVersion: 1`
- `generatedAt`
- `device` or root `deviceId`
- `cachePreferences` / `cachePolicy` / `profileFrames.cachePreferences`
- `cacheItems` / `cacheCandidates` / `cacheManifest` / `manifestItems` / `items`
- `deviceCache` / `cacheSummary` / `offlineCache`
- optional `commands`

## Acceptance

- Cache policy has explicit `enabled`, `likedArtworks`, `recentArtworks`, `selectedArtists`, and `sizeLimitMb` values.
- Cache candidates have unique stable ids and HTTP(S) `mediaUrl`, `sourceUrl`, or `thumbnailUrl` values.
- Candidate status/category values are from the supported contract vocabulary.
- Device cache evidence includes cached/playable/failed counts for returned candidates.
- Optional commands are limited to `clear_cache` or `sync_settings`.
- The bundle does not expose stored device API keys, pairing hashes, private/admin tokens, secrets, passwords, absolute appliance paths, or raw cache paths.

## Verification

Run:

```bash
scripts/cache-contract-check.sh /path/to/cache-contract-bundle.json
AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE=cache \
AUTOPOIESIS_CACHE_CONTRACT_SOURCE=/path/to/cache-contract-bundle.json \
scripts/hosted-contract-suite-check.sh
```

For strict staging readiness, include the cache source in the full hosted suite between stream and online-admin.

## Open Questions

- Should hosted cache summaries be driven only by heartbeat ingestion, or should support-bundle uploads also backfill cache state?
- Should cache candidates mirror stream item ids exactly, or use a stable derived cache key when one content row has multiple media roles?
- What is the canonical `clear_cache` command acknowledgement shown in Profile > Frames after a user clears one device's cache?
