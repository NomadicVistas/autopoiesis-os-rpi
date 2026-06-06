# API Contract

Base:

```txt
https://autopoiesis.art/api
```

The local prototype does not assume these endpoints exist yet.

## Register Device

```txt
POST /api/frames/device/register
```

## Pairing Status

```txt
GET /api/frames/device/{deviceId}/pairing-status
```

## Settings

```txt
GET /api/frames/device/{deviceId}/settings
POST /api/frames/device/{deviceId}/settings
```

## Heartbeat

```txt
POST /api/frames/device/{deviceId}/heartbeat
```

## Artwork Feed

```txt
GET /api/frames/device/{deviceId}/artwork-feed
```

## Local Internal API

```txt
GET  /local/status
GET  /local/health
GET  /local/readiness
GET  /local/diagnostics
GET  /local/feed
GET  /local/offline-cache
GET  /local/network/status
POST /local/lan/connect
GET  /local/wifi/scan
GET  /local/wifi/scan.json
POST /local/wifi/connect
POST /local/settings
POST /local/pairing/start
GET  /local/pairing/status
POST /local/pairing/check
POST /local/settings/sync
POST /local/heartbeat
POST /local/feed/sync
POST /local/broadcast/dismiss
POST /local/commands/process
POST /local/release/check
POST /local/release/apply
POST /local/system/restart
POST /local/system/factory-reset
POST /local/system/update-now
```

## Minimum Frames API

Device lifecycle:

- POST /api/frames/device/register
- GET /api/frames/device/{deviceId}/pairing-status
- POST /api/frames/device/{deviceId}/pair
- POST /api/frames/device/{deviceId}/heartbeat

Heartbeat request body includes:

- softwareVersion
- currentMode
- currentArtworkId
- networkOnline
- networkType
- storageStatus
- diagnostics

Diagnostics fields are intentionally compact and safe for admin/profile/support surfaces:

- collectedAt
- deviceId
- deviceName
- softwareVersion
- hostname
- platform
- arch
- kernel
- uptimeSeconds
- loadAverage
- memory
- temperatureC
- mode
- network
- pairing
- storage
- release
- pendingCommands
- broadcast
- health

`GET /local/diagnostics` returns the same object plus local systemd service states when available.

`GET /local/health` returns a compact, redacted summary derived from diagnostics. It is intended for admin fleet scans, support scripts, and hardware acceptance checks that do not need the full telemetry payload. Add `?services=1` to include local systemd checks before deriving the health summary.

`GET /local/readiness` returns a redacted, phase-level rollout snapshot derived from diagnostics. It includes setup/local UI, network, pairing, settings sync, content/feed, cache, command executor, and release phases. Add `?services=0` to skip local systemd service checks when running outside an installed Pi environment.

Example:

```json
{
  "ok": true,
  "status": "warning",
  "device": {
    "deviceId": "rpi-example",
    "deviceName": "Gallery frame",
    "softwareVersion": "0.1.0"
  },
  "mode": "offline",
  "network": {
    "online": false,
    "primary": null
  },
  "pairing": {
    "paired": true
  },
  "pendingCommands": 0,
  "collectedAt": "2026-06-06T00:15:00.000Z"
}
```

Diagnostics health summary:

```json
{
  "status": "ok|warning|error",
  "issues": [
    {
      "level": "warning|error",
      "code": "network_offline",
      "message": "Human-readable support summary."
    }
  ],
  "paired": true,
  "networkOnline": true,
  "deviceKeyPresent": true,
  "checkedAt": "2026-06-05T21:15:00.000Z"
}
```

Current issue codes include `device_unpaired`, `device_key_missing`, `network_offline`, `offline_fallback`, `storage_critical`, `storage_high`, `storage_low`, `storage_unknown`, `memory_low`, `temperature_critical`, `temperature_high`, `release_error`, `release_in_progress`, `settings_conflict`, `commands_pending`, `cache_failures`, `cache_empty`, and `service_failed`.

Cache-aware diagnostics add feed cache index fields: `cacheIndexGeneratedAt`, `cacheIndexedItems`, `cacheCachedItems`, `cacheFailedItems`, and `offlinePlayableItems`.

Settings sync:

- GET /api/frames/device/{deviceId}/settings
- POST /api/frames/device/{deviceId}/settings
- GET /api/frames/user/preferences
- POST /api/frames/user/preferences
- GET /api/frames/user/devices
- POST /api/frames/user/devices/pair

Device settings conflict behavior:

- Settings payloads should include `updatedAt` as an ISO timestamp. The Pi also accepts legacy `updated_at` and normalizes it locally.
- Local setting changes are stamped before they are written or pushed to the Frames API.
- Remote settings from explicit sync, push responses, and heartbeat responses are applied only when their `updatedAt` is equal to or newer than the local settings timestamp.
- If the remote payload is stale, the Pi keeps local preferences, records `settingsSync.status = local_newer`, and exposes a `settings_conflict` diagnostics health warning.
- Untimestamped remote payloads are still applied for legacy API compatibility, but are recorded as `remote_applied_untimestamped`.
- Heartbeat diagnostics include a compact `settingsSync` object with status, source, conflict, reason, localUpdatedAt, remoteUpdatedAt, and checkedAt.

Content stream:

- GET /api/frames/device/{deviceId}/feed
- GET /api/frames/device/{deviceId}/broadcasts
- POST /api/frames/artworks/{artworkId}/like
- DELETE /api/frames/artworks/{artworkId}/like

Local feed behavior:

- POST /local/feed/sync fetches GET /api/frames/device/{deviceId}/feed and stores a normalized local feed.
- Heartbeat responses may also carry feed, items, artworks, or broadcasts; the local UI normalizes those into the same feed state.
- GET /local/feed returns active, display-eligible items only. Expired items, future scheduled items, and preference-disabled media types are filtered out.
- The local UI also writes a feed cache manifest for items with cacheAllowed !== false and a media or thumbnail URL. `scripts/cache-artworks.sh` downloads those eligible assets into the local runtime cache and writes `cache-index.json` with cached/failed asset status.
- GET /local/offline-cache returns the redacted playable cache inventory. It reports counts and browser-safe local asset URLs without exposing absolute filesystem paths.
- GET /local/cache/assets/{itemId}/media and GET /local/cache/assets/{itemId}/thumbnail serve cached files only when the indexed path resolves under the configured cache directory.
- The `/offline` fallback reads `cache-index.json` and rotates playable cached feed media when the live Frames display is unreachable. Cache eviction remains a separate follow-up task.
- Feed items are sorted by priority, then created time, then explicit order.

Commands:

- GET /api/frames/device/{deviceId}/commands
- POST /api/frames/device/{deviceId}/commands/{commandId}/ack

Remote command rows returned by heartbeat or `GET /commands` use:

```json
{
  "id": "cmd_123",
  "commandType": "disable_device",
  "payload": {},
  "authorization": {
    "approved": true,
    "action": "disable_device",
    "actorId": "admin-user-id",
    "actorRole": "admin",
    "authorizedAt": "2026-06-06T01:05:00.000Z",
    "auditId": "audit_123",
    "reason": "Support action requested by subscriber."
  }
}
```

Device-side command policy:

- `sync_settings`: low risk, no remote authorization required.
- `clear_cache`, `restart_display`, `enable_device`, `show_broadcast`: medium risk, require approved authorization metadata.
- `restart_device`, `update_device`, `disable_device`: high risk, require approved authorization metadata plus an audit id.
- `factory_reset_request`: critical risk, requires approved authorization metadata plus an audit id, and still refuses execution until local device confirmation exists.

Authorization roles accepted by the Pi executor are `admin`, `owner`, `support`, `ops`, `maintainer`, and `super_admin`. Authorization timestamps expire after 24 hours by default. The device cannot prove server-side role truth; the online admin API must authenticate the actor, check role/ownership, create an audit row, and then queue the command with this metadata.

## Admin API

Users and subscribers:

- GET /api/admin/frames/users
- GET /api/admin/frames/users/{userId}
- GET /api/admin/frames/subscribers
- GET /api/admin/frames/subscriptions

Devices:

- GET /api/admin/frames/devices
- GET /api/admin/frames/devices/{deviceId}
- POST /api/admin/frames/devices/{deviceId}/disable
- POST /api/admin/frames/devices/{deviceId}/enable
- POST /api/admin/frames/devices/{deviceId}/commands
- GET /api/admin/frames/devices/{deviceId}/logs
- GET /api/admin/frames/devices/{deviceId}/heartbeats

Broadcasts:

- GET /api/admin/frames/broadcasts
- POST /api/admin/frames/broadcasts
- GET /api/admin/frames/broadcasts/{broadcastId}
- POST /api/admin/frames/broadcasts/{broadcastId}/send-test
- POST /api/admin/frames/broadcasts/{broadcastId}/cancel
- GET /api/admin/frames/broadcasts/{broadcastId}/deliveries

Releases:

- GET /api/admin/frames/releases
- POST /api/admin/frames/releases
- POST /api/admin/frames/releases/{releaseId}/promote
- POST /api/admin/frames/releases/{releaseId}/rollback

## Content Feed Item

Fields:

- id
- type
- title
- artist
- body
- url
- mediaUrl
- thumbnailUrl
- duration
- soundRequired
- cacheAllowed
- priority
- visibility
- createdAt
- expiresAt
- startsAt
- dismissible
- source

Supported types:

- artwork_image
- artwork_video
- artwork_audio
- artwork_web
- artwork_generative
- news
- blog
- artist_update
- curatorial_note
- broadcast_message
- broadcast_media
- system_notice

## Command Types

- restart_display
- restart_device
- update_device
- clear_cache
- sync_settings
- disable_device
- enable_device
- show_broadcast
- factory_reset_request
