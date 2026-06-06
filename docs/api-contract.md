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
GET  /local/support-bundle
GET  /local/diagnostics
GET  /local/feed
GET  /local/offline-cache
GET  /local/commands/audit
GET  /local/admin/capabilities
GET  /local/delivery-log
GET  /local/release/history
GET  /local/events/export
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
- events

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
- commandAudit
- broadcast
- health

`GET /local/diagnostics` returns the same object plus local systemd service states when available.

`GET /local/health` returns a compact, redacted summary derived from diagnostics. It is intended for admin fleet scans, support scripts, and hardware acceptance checks that do not need the full telemetry payload. Add `?services=1` to include local systemd checks before deriving the health summary.

`GET /local/readiness` returns a redacted, phase-level rollout snapshot derived from diagnostics. It includes setup/local UI, network, pairing, settings sync, content/feed, cache, command executor, and release phases. Add `?services=0` to skip local systemd service checks when running outside an installed Pi environment.

`GET /local/support-bundle` returns a redacted one-shot support object for hardware validation, admin adapters, and handoff reports. It aggregates diagnostics, compact health, readiness, active feed counts/items, offline-cache inventory, recent command audit entries, local admin capability policy, recent display delivery events, recent release history events, and the unified device event export. Add `?services=0` to skip systemd service checks, `?auditLimit=50` to tune recent command audit entries, `?deliveryLimit=50` to tune recent delivery events, `?releaseLimit=50` to tune recent release history entries, and `?eventLimit=50` to tune the unified event export. The bundle intentionally reuses existing redacted endpoint shapes instead of exposing raw command payloads, local cache paths, release artifact URLs, checksums, or stored device API keys.

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

Display delivery diagnostics add a compact `displayDelivery` summary with total entries, the last event type/item/timestamp, and recent feed/broadcast event counts.

Release rollout diagnostics add a compact `releaseHistory` summary with total entries, last event type/status/version/timestamp, and recent failure count.

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
- GET /local/feed also returns `displayQueue`, a priority-preserving mixed-content queue. The device keeps emergency/critical/high/normal/low priority bands intact, then round-robins categories inside each band across broadcast, curatorial, artwork, blog, news, and general content items so personalized streams do not collapse into a single content class.
- Feed diagnostics include `displayQueueItems` and category counts so Admin > Frames and support bundles can see whether a device has a usable mixed stream.
- The local UI also writes a feed cache manifest for items with cacheAllowed !== false and a media or thumbnail URL. `scripts/cache-artworks.sh` downloads those eligible assets into the local runtime cache and writes `cache-index.json` with cached/failed asset status.
- GET /local/offline-cache returns the redacted playable cache inventory. It reports counts and browser-safe local asset URLs without exposing absolute filesystem paths.
- GET /local/cache/assets/{itemId}/media and GET /local/cache/assets/{itemId}/thumbnail serve cached files only when the indexed path resolves under the configured cache directory.
- The `/offline` fallback reads `cache-index.json` and rotates playable cached feed media when the live Frames display is unreachable. Cache eviction remains a separate follow-up task.
- Feed items are sorted by priority, then created time, then explicit order; the derived display queue applies category mixing after that stable eligibility sort.

Local delivery log behavior:

- Feed syncs append a bounded metadata-only `feed_synced` event to `delivery-log.json`.
- Broadcast display lifecycle appends `broadcast_shown`, `broadcast_dismissed`, and one-time `broadcast_expired` events.
- GET /local/delivery-log returns recent events without raw payloads, local file paths, or stored device API keys.
- Heartbeat diagnostics and `/local/support-bundle` include a compact delivery summary so the backend/admin layer can mirror these events into durable `aos_` delivery rows.

Unified device event export:

- `GET /local/events/export?limit=25` returns one redacted, newest-first event stream built from the command audit trail, display delivery log, and release history.
- Optional `commandLimit`, `deliveryLimit`, and `releaseLimit` tune per-source bounds; optional `since=<iso timestamp>` filters events newer than that timestamp.
- Heartbeats include the same shape under `events`, bounded by `AUTOPOIESIS_HEARTBEAT_EVENT_LIMIT` (default 10 per source), so the backend can persist durable `aos_` command audit, broadcast delivery, and release rollout rows without scraping Pi log files.
- Heartbeats also include `eventIngestionCursor` when a previous backend acknowledgement exists. This tells the API what event pointer the device believes was last accepted and which replay window it used for the current heartbeat.
- A heartbeat response may include `eventsAck`, `eventAck`, `deviceEventsAck`, or `eventIngestionCursor` with `status`, `acceptedAt`, `acceptedThroughObservedAt`, `acceptedThroughEventKey`, optional `sourceCursors`, and optional `counts`. The Pi persists that redacted acknowledgement in `event-cursor.json`, reports it in diagnostics/support bundles, and uses `acceptedThroughObservedAt` minus a small overlap window as the next heartbeat's `since` cursor.
- The online Frames backend accepts heartbeat `events`, stores them idempotently in `aos_device_events` by `deviceId + eventKey`, returns `eventsAck`, and projects recognized event sources into existing `aos_admin_command_audits`, `aos_broadcast_deliveries`, and `aos_release_rollouts` rows.
- Every exported event includes a stable `source`, `eventKey`, and `observedAt` when available. Backend ingestion should treat `deviceId + eventKey` as idempotent.
- The global `cursor` includes latest and oldest exported event pointers plus `hasMore`; `sourceCursors` repeats the same shape per source with total/exported counts and per-source limits so ingestion can detect truncation in command audit, display delivery, or release history independently.
- Exported events intentionally omit raw command payloads, local cache paths, release artifact URLs, checksums, stdout/stderr, and stored device API keys.

Commands:

- GET /api/frames/device/{deviceId}/commands
- POST /api/frames/device/{deviceId}/commands/{commandId}/ack

Remote command rows returned by heartbeat or `GET /commands` use:

```json
{
  "id": "cmd_123",
  "commandType": "disable_device",
  "payload": {
    "reason": "Support action requested by subscriber.",
    "authorization": {
      "approved": true,
      "action": "disable_device",
      "actorId": "admin-user-id",
      "actorRole": "admin",
      "authorizedAt": "2026-06-06T01:05:00.000Z",
      "auditId": "aud_123"
    }
  }
}
```

Device-side command policy:

- `sync_settings`: low risk, no remote authorization required.
- `clear_cache`, `restart_display`, `enable_device`, `show_broadcast`: medium risk, require approved authorization metadata.
- `restart_device`, `update_device`, `disable_device`: high risk, require approved authorization metadata plus an audit id.
- `factory_reset_request`: critical risk, requires approved authorization metadata plus an audit id, and still refuses execution until local device confirmation exists.

Authorization roles accepted by the Pi executor are `admin`, `owner`, `support`, `ops`, `maintainer`, and `super_admin`. Authorization timestamps expire after 24 hours by default. The device cannot prove server-side role truth; the online admin API must authenticate the actor, check role/ownership, create an audit row, and then queue the command with this metadata.

`GET /local/admin/capabilities` returns the device-side remote action capability contract for Admin > Frames, local support tools, and backend adapters. It is redacted and includes device pairing/key presence, accepted actor roles, authorization window seconds, supported command types, each command's risk, whether authorization/audit metadata is required, local confirmation requirements, runtime opt-in requirements such as `AUTOPOIESIS_ALLOW_REBOOT=1`, pending command count, and compact command-audit summary. The endpoint is descriptive only; online admin must still authenticate the actor, enforce role/ownership, persist an `aos_` audit row, and queue authorization metadata before the Pi will execute medium/high/critical commands.

Online admin backend behavior:

- The backend persists admin-originated remote actions in `aos_admin_command_audits` before queueing commands that require authorization.
- The queued command payload includes `payload.authorization` with `approved`, `action`, `actorId`, `actorRole`, `authorizedAt`, and `auditId` for medium/high/critical commands.
- `show_broadcast` and `update_device` commands created by admin broadcast/release endpoints use the same authorization/audit path as direct device commands.
- Device acknowledgement updates the matching backend audit row status so Admin > Frames can show queued/acknowledged/completed/error state from durable `aos_` data.
- Heartbeat `events` ingestion into broadcast delivery and release rollout rows remains a separate follow-up from command queue authorization.

Local command audit:

- `POST /local/commands/process` appends one metadata-only audit entry for each completed, denied, or failed command attempt.
- Entries are stored locally in `command-audit.json` and capped by `AUTOPOIESIS_COMMAND_AUDIT_LIMIT` (default 100).
- `GET /local/commands/audit?limit=25` returns newest entries first. The endpoint is intended for local support, admin adapters, and hardware validation.
- Audit entries include command id/type, risk, status, actor id/role when supplied, admin audit id, authorization timestamp, processing timestamps, and error text. They intentionally omit command payloads and stored device API keys.
- Heartbeat diagnostics and `GET /local/readiness` include a compact `commandAudit` summary with total entries, last command id/type/status, last observed timestamp, and recent error count.

Local command acknowledgement retry:

- The Pi only removes a command from local `commands.json` after the relevant remote acknowledgement has succeeded.
- If the initial `acknowledged` POST fails, the command is retained with local retry metadata and is not executed yet.
- If command execution finishes but the final `completed` or `error` acknowledgement fails, the command is retained with a final-ack retry state and is not executed again on the next processing pass.
- Final-ack retry state is local-only metadata. It is not part of the online command payload contract and should not be interpreted by the backend.
- Command audit may include `ack_failed` or `ack_retry_failed` statuses when API acknowledgement delivery fails.

Release history:

- `POST /local/release/check` appends a metadata-only `release_checked` event to `release-log.json` with current version, update availability, release id, target version, channel, and rollout id when supplied by the API.
- `POST /local/release/apply`, `POST /local/system/update-now`, and `update_device` commands append `release_apply_started`, `release_apply_completed`, `release_apply_failed`, or `release_skipped` events.
- `GET /local/release/history?limit=25` returns newest entries first. Entries intentionally omit artifact URLs, checksums, local file paths, stdout/stderr, command payloads, and stored device API keys.
- Heartbeat diagnostics, compact health, readiness, and `/local/support-bundle` include a compact release-history summary for admin rollout adapters.
- Backend `aos_` release rows should treat repeated device reports as idempotent and persist per-device rollout progress from these event names.

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
