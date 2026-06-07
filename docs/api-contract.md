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
GET /api/frames/device/{deviceId}/stream
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
GET  /local/frame-state
GET  /dashboard
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
POST /local/frame/display
POST /local/frame/like
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
- input
- mode
- network
- pairing
- storage
- release
- pendingCommands
- commandAudit
- framePlayback
- broadcast
- health

`GET /local/diagnostics` returns the same object plus local systemd service states when available.

`GET /local/health` returns a compact, redacted summary derived from diagnostics. It is intended for admin fleet scans, support scripts, and hardware acceptance checks that do not need the full telemetry payload. Add `?services=1` to include local systemd checks before deriving the health summary.

`GET /local/readiness` returns a redacted, phase-level rollout snapshot derived from diagnostics. It includes setup/local UI, runtime storage writability, system clock/NTP sync, touchscreen/input, network, pairing, settings sync, appliance timers, content/feed, local playback, cache, command executor, and release phases. Add `?services=0` to skip local systemd service/timer checks when running outside an installed Pi environment.

`GET /local/rollout/acceptance` returns a redacted fleet rollout gate derived from health, readiness, Admin capabilities, and unified event export. It accepts `profile=setup|staged|production`, `strictContent=1`, `services=0`, and `eventLimit=10`. The default `staged` profile requires no health errors, local UI diagnostics, touchscreen input, network, pairing with stored device key, settings sync, remote-admin readiness, empty command queue, non-failed release state, and the event export contract. Content/playback/cache are warnings for staged devices unless `strictContent=1`; production requires strict content and cache readiness and treats health warnings as blockers. `scripts/rollout-acceptance-check.sh` exits non-zero when required checks fail so Pi validation and future Admin > Frames rollout controls can consume the same contract. `scripts/rollout-issue-report.sh` combines this acceptance payload with `/local/support-bundle` into a redacted GitHub-style Markdown issue note for physical hardware blockers and support handoffs.

`GET /local/support-bundle` returns a redacted one-shot support object for hardware validation, admin adapters, and handoff reports. It aggregates diagnostics, compact health, readiness, runtime storage writability, system clock/NTP summary, touchscreen/input summary, systemd timer summary, active feed counts/items, local frame state, offline-cache inventory, recent command audit entries, local admin capability policy, recent display delivery events, recent release history events, and the unified device event export. Add `?services=0` to skip systemd service/timer checks, `?auditLimit=50` to tune recent command audit entries, `?deliveryLimit=50` to tune recent delivery events, `?releaseLimit=50` to tune recent release history entries, and `?eventLimit=50` to tune the unified device event export. The bundle intentionally reuses existing redacted endpoint shapes instead of exposing raw command payloads, local cache paths, release artifact URLs, checksums, or stored device API keys.

`scripts/support-bundle-check.sh` validates this support-bundle contract for physical Pi handoffs and Admin/Profile adapters. It checks the schema marker, redaction flag, generated timestamp, device identity, health/readiness summaries, runtime storage booleans, input summary, playback state, command policy matrix, event export shape, and absence of stored device-key fields, raw command payloads, release checksums, and artifact URLs.

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

Current issue codes include `device_unpaired`, `device_key_missing`, `network_offline`, `offline_fallback`, `storage_critical`, `storage_high`, `storage_low`, `storage_unknown`, `runtime_storage_unavailable`, `memory_low`, `temperature_critical`, `temperature_high`, `clock_unsynchronized`, `clock_unknown`, `clock_ntp_disabled`, `input_unknown`, `input_missing`, `touchscreen_missing`, `release_error`, `release_in_progress`, `settings_conflict`, `commands_pending`, `cache_failures`, `cache_empty`, `frame_no_playable_items`, `frame_queue_empty`, `service_failed`, `timer_failed`, and `timer_disabled`.

Runtime storage diagnostics verify that `DATA_DIR`, `CACHE_DIR`, and `LOG_DIR` exist or can be created, are directories, are readable/writable, and accept a short write probe by the local UI process. Health emits `runtime_storage_unavailable` when any required path is blocked, readiness includes a `storage` phase, and `scripts/runtime-storage-check.sh` is the acceptance gate for catching bad ownership, bad mounts, and missing runtime directories before pairing, cache, heartbeat, or support-bundle debugging begins.

Clock diagnostics use `timedatectl show` by default and report `status`, `systemTime`, `epochSeconds`, `timezone`, `ntpEnabled`, `ntpSynchronized`, `systemClockSynchronized`, and `localRtc`. Set `AUTOPOIESIS_TIMEDATECTL_BIN` for tests. The physical Pi milestone uses `AUTOPOIESIS_REQUIRE_CLOCK_SYNC=1 scripts/clock-check.sh` so staged hardware fails verification when system time is not synchronized.

Input diagnostics read Linux input metadata from `/proc/bus/input/devices` by default and report `status`, `touchscreenPresent`, `pointerPresent`, `keyboardPresent`, `totalDevices`, and a bounded device list. Set `AUTOPOIESIS_INPUT_DEVICES_PATH` for tests. The physical Pi milestone uses `AUTOPOIESIS_REQUIRE_TOUCHSCREEN=1 scripts/touchscreen-check.sh` so staged hardware fails verification when no touchscreen-class input is visible.

When service checks are enabled, diagnostics also include `timers` entries for `autopoiesis-heartbeat.timer`, `autopoiesis-command-executor.timer`, `autopoiesis-cache.timer`, `autopoiesis-updater.timer`, and `autopoiesis-watchdog.timer`. Each timer reports redacted `active` and `enabled` strings from systemd. Health emits `timer_failed` for failed timers and `timer_disabled` for disabled or masked timers; readiness includes a `timers` phase so rollout/support tooling can tell whether the appliance maintenance loops are actually scheduled.

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

Pairing lifecycle validation:

- POST /api/frames/device/register
- POST /api/frames/user/devices/pair
- GET /api/frames/device/{deviceId}/pairing-status
- Optional adapter endpoint: GET /api/admin/frames/pairing-contract-bundle

`scripts/pairing-contract-check.sh` validates a saved or live read-only bundle containing `deviceRegistration`, `userPairing`, and `pairingStatus` sections. The bundle is a staging/CI contract fixture; it should report evidence from a controlled pairing flow without causing a new live claim.

The registration section should mirror `POST /api/frames/device/register`: device id/name/version metadata, an unpaired device row, a raw pairing code only for the registering device, `expiresAt`, and the per-device API credential the Pi stores for later authenticated calls. The default checker requires the device credential because the current Pi pairing path only persists it during registration.

The user-pairing section should mirror `POST /api/frames/user/devices/pair`: authenticated owner id, paired device id, claimed timestamp, optional applied settings/preferences, and no stored device API key or pairing-code hash. The pairing status section should mirror `GET /api/frames/device/{deviceId}/pairing-status` after claim: `paired: true`, the same owner/device relationship, optional safe pairing metadata, and optional settings handoff.

Pairing codes should be short uppercase alphanumeric text with optional hyphen separators, should expire after registration, and should normally stay within a one-hour maximum TTL. Pairing storage should prefer durable `aos_frame_pairing_codes.pairing_code_hash`; plaintext pairing codes belong only in the device-facing registration/status contract while active.

Device-route authentication validation:

- Optional adapter endpoint: GET /api/admin/frames/device-auth-contract-bundle
- Required route coverage by default: pairing status, settings read, settings write, heartbeat, stream, command polling, command acknowledgement, and release manifest.
- For every covered route, staging evidence should include a successful attempt with the correct per-device credential, a rejected attempt with no credential, a rejected attempt with an invalid credential, and a rejected cross-device attempt where another device credential is used against the route device id.
- Accepted attempts should return 2xx and, when a response names a device id, it must match the route device id. Missing and wrong credentials should return 401 or 403. Cross-device attempts should return 401, 403, or 404.
- The bundle must not expose stored device API keys, API-key field names, pairing-code hashes, private/admin tokens, secrets, passwords, raw bearer tokens, or local appliance paths.

`scripts/device-auth-contract-check.sh` validates this read-only bundle. It is intentionally separate from the pairing lifecycle gate: pairing proves a credential is issued and bound to an owner/device; device auth proves every device-only endpoint actually enforces that credential and cannot be used across devices.

Hosted settings conflict validation:

- Optional adapter endpoint: GET /api/admin/frames/settings-contract-bundle
- The bundle should include `settingsRead`, `newerWrite`, `staleWrite`, `finalRead`, and `heartbeat` sections derived from controlled staging/CI evidence, not from destructive production mutations.
- `settingsRead.response.settings.updatedAt` establishes the starting row. `newerWrite.request.settings.updatedAt` must be newer, and `newerWrite.response.settings.updatedAt` must preserve or advance the submitted timestamp.
- `staleWrite.request.settings.updatedAt` must be older than the accepted row. Its response should reject the write with a 4xx status or return an explicit conflict/not-applied marker, and any returned authoritative settings must still be at least as current as the accepted row.
- `finalRead.response.settings.updatedAt` and `heartbeat.response.settings.updatedAt` must be at least as current as the accepted newer write.
- The bundle must not expose device API keys, pairing codes or hashes, private/admin tokens, secrets, passwords, raw bearer tokens, or local appliance paths.

`scripts/settings-contract-check.sh` validates this read-only bundle. It closes the gap between device-side newest-`updatedAt` behavior and durable hosted `aos_` settings rows before heartbeat, Profile > Frames, or Admin > Frames evidence is trusted.

Profile account ownership validation:

- Optional adapter endpoint: GET /api/admin/frames/profile-ownership-contract-bundle
- Required successful owner checks by default: Profile-owned device list, Profile-owned device read, and Profile-owned settings write.
- Required rejection checks by default: cross-owner device read, cross-owner settings write, cross-owner owner-command enqueue, and anonymous Profile access.
- Required admin boundary check by default: admin/support fleet read succeeds through Admin > Frames and returns devices from at least two owners, proving fleet visibility is explicit and separate from ordinary Profile ownership.
- Profile list/read/write responses must only return devices owned by the authenticated actor. Cross-owner attempts should return 401, 403, or 404 and must not include device rows.
- The bundle must not expose stored device API keys, raw pairing codes, pairing-code hashes, private/admin tokens, secrets, passwords, raw bearer tokens, or local appliance paths.

`scripts/profile-ownership-contract-check.sh` validates this read-only bundle. It is intentionally separate from device-route authentication: device auth proves Pi credentials cannot cross device boundaries, while profile ownership proves account/session routes cannot cross user boundaries.

Profile/Admin bundle validation:

- GET /api/frames/user/devices
- GET /api/frames/user/preferences
- GET /api/frames/user/active-artists
- GET /api/frames/user/liked-artworks
- GET /api/frames/user/cache-preferences
- Optional adapter endpoint: GET /api/admin/frames/cache-contract-bundle
- GET /api/admin/frames/users
- GET /api/admin/frames/subscribers
- GET /api/admin/frames/subscriptions
- GET /api/admin/frames/devices
- GET /api/admin/frames/remote-actions
- Optional adapter endpoint: GET /api/admin/frames/online-admin-bundle
- Optional adapter endpoint: GET /api/admin/frames/broadcast-contract-bundle
- Optional adapter endpoint: GET /api/admin/frames/release-rollout-contract-bundle
- Optional adapter endpoint: GET /api/admin/frames/command-ack-contract-bundle

`scripts/online-admin-contract-check.sh` validates a saved or live bundle assembled from the online Profile > Frames and Admin > Frames surfaces. The bundle is intentionally a contract fixture, not a required production endpoint; the optional adapter endpoint can assemble the same shape for staging and CI.

The bundle root should include `ok`, `kind: "autopoiesis_frames_online_admin_bundle"`, `schemaVersion: 1`, `generatedAt`, `profileFrames`, and `adminFrames`.

`profileFrames` should include `userId`, `devices`, `pairing` metadata when available, authoritative user/device `preferences`, `activeArtists`, `likedArtworks`, and explicit cache preferences. The cache preference object must state whether caching is enabled, whether liked/recent/selected-artist works are cacheable, and the cache size limit. If the same cache fields are mirrored under `preferences`, the values must match the explicit cache preference object. `activeArtists` ids must be unique and must agree with any `preferences.activeArtists` selections. Paged `likedArtworks.items` rows must carry stable, unique artwork ids just like the flat liked-artwork array form, and page totals cannot be smaller than returned rows. Device rows should expose owner-safe fields such as device name, pairing/online/remote state, software version, current mode/artwork, heartbeat timestamp, health/release summaries, device settings, subscription summary, cache summary, and `actionAvailability`.

`adminFrames` should include the authenticated `actor`, paged `users`, `subscribers`, `subscriptions`, paged fleet `devices`, and `remoteActions`. Remote action policies must include accepted actor roles, authorization window, high/critical audit-id requirements, and command policy rows for `sync_settings`, `clear_cache`, `restart_display`, `enable_device`, `disable_device`, `restart_device`, `update_device`, `show_broadcast`, and `factory_reset_request`. Medium/high/critical actions must require authorization; high/critical actions must require an audit id; critical actions must require local confirmation.

Admin user/subscriber/subscription pages must be internally consistent. Subscriber rows must reference a listed user, entitled subscription rows (`active`, `trialing`, `past_due`, or `comped`) must have a matching subscriber row, subscriber `subscriptionId` values must point at a listed subscription, fleet device `ownerUserId` values must point at a listed user, and device subscription summaries with ids must reference a listed subscription.

`remoteActions` must also include `roleActionMatrix` (or `roleMatrix`/`permissions`) with one row per accepted actor role and one explicit allow/deny decision per command type. Allowed medium/high/critical decisions must expose the matching `requiresAuthorization`, `requiresAuditId`, and `requiresLocalConfirmation` flags needed by Admin > Frames controls. Denied decisions must include a short reason/disabledReason so the UI can render disabled remote-action controls without guessing backend policy. The matrix must include at least one denied action and at least one denied critical action before destructive fleet controls are considered staging-ready.

Each Profile/Admin device row must also include `actionAvailability` (or `availableActions`/`remoteActionAvailability`) with one explicit allow/deny decision for every supported command. Allowed target decisions for risky commands must mirror the global authorization, audit-id, and local-confirmation flags; denied target decisions must include a short reason/disabledReason and may include a stable reason code such as `offline`, `remote_disabled`, `device_disabled`, `subscription_inactive`, `role_denied`, `not_paired`, `pending_command`, or `local_confirmation_required`. This is the target-specific layer: the role matrix says what an actor can do in principle, while `actionAvailability` says whether this exact frame can receive that action right now.

The contract check rejects sensitive or local-only fields including stored device API keys, pairing-code hashes, private access/refresh tokens, secrets, passwords, and absolute appliance paths.

Hosted broadcast lifecycle contract:

`scripts/broadcast-contract-check.sh` validates read-only staging/CI evidence for Admin > Frames broadcast readiness. The bundle root may use `kind: "autopoiesis_frames_broadcast_contract"` and `schemaVersion: 1`, and should include:

- `broadcasts` or `adminBroadcasts`: durable broadcast rows with stable ids, type, status, priority, scheduling/expiry fields, and explicit `targeting`, `audience`, or visibility data.
- `commands`, `commandQueue`, or `queuedCommands`: queued remote command rows. At least one `show_broadcast` command must reference a broadcast id, target a device id, and include approved authorization metadata with `action: "show_broadcast"`, accepted actor role, timestamp, and audit id.
- `deliveries`, `deliveryLogs`, or `broadcastDeliveries`: durable delivery rows keyed by broadcast/device, including `broadcast_shown`, `shown`, `delivered`, or equivalent display evidence before a broadcast rollout is considered complete.
- Optional `summary` counts for active/scheduled broadcasts, queued commands, delivery rows, shown rows, and failures.

The checker rejects unknown targeting keys, duplicate broadcast or command ids, command references to unknown broadcasts, delivery rows without device ids or event names, and sensitive/local-only data such as device API keys, pairing hashes, private/admin tokens, secrets, passwords, and absolute appliance paths. Use `AUTOPOIESIS_REQUIRE_BROADCAST_COMMANDS=0`, `AUTOPOIESIS_REQUIRE_BROADCAST_DELIVERY=0`, or `AUTOPOIESIS_REQUIRE_BROADCAST_TARGETING=0` only for narrow component tests; strict hosted readiness should keep the defaults.

Device settings conflict behavior:

- Settings payloads should include `updatedAt` as an ISO timestamp. The Pi also accepts legacy `updated_at` and normalizes it locally.
- Local setting changes are stamped before they are written or pushed to the Frames API.
- Remote settings from explicit sync, push responses, and heartbeat responses are applied only when their `updatedAt` is equal to or newer than the local settings timestamp.
- If the remote payload is stale, the Pi keeps local preferences, records `settingsSync.status = local_newer`, and exposes a `settings_conflict` diagnostics health warning.
- Untimestamped remote payloads are still applied for legacy API compatibility, but are recorded as `remote_applied_untimestamped`.
- Heartbeat diagnostics include a compact `settingsSync` object with status, source, conflict, reason, localUpdatedAt, remoteUpdatedAt, and checkedAt.
- `scripts/settings-sync-check.sh` is the acceptance gate for this contract. It runs an isolated local UI against a mock Frames API and verifies stale explicit sync rejection, newer remote apply, local push `updatedAt` propagation, stale heartbeat rejection, diagnostics conflict visibility, and the `settings_conflict` health issue.
- `scripts/settings-contract-check.sh` is the hosted acceptance gate for the same rule. It validates direct staging/CI evidence that durable `aos_` settings rows reject or explicitly conflict stale writes and keep heartbeat settings current.
- Backend `aos_` settings rows should mirror the same newest-`updatedAt` behavior and return authoritative `updatedAt` values from settings GET, settings POST, and heartbeat responses.

Content stream:

- GET /api/frames/device/{deviceId}/stream
- GET /api/frames/device/{deviceId}/feed
- GET /api/frames/device/{deviceId}/broadcasts
- POST /api/frames/artworks/{artworkId}/like
- DELETE /api/frames/artworks/{artworkId}/like

`GET /api/frames/device/{deviceId}/stream` is the preferred scalable Autopoiesis OS endpoint. The Pi calls it before falling back to legacy `/feed`. It should return one merged playback contract for artworks, broadcasts, curatorial notes, blogs, exhibitions, and system news.

Stream responses should include `schemaVersion`, `generatedAt`, `stream`, optional authoritative `settings`, and `items`. The `stream` object, or a root `polling`/`refresh` object, may include redacted cadence hints such as `pollAfterSeconds`, `minPollSeconds`, `maxPollSeconds`, `nextPollAt`, and `staleAfter` so devices and diagnostics can prove hosted feed freshness policy without exposing scheduler internals. Supported query parameters are `limit`, `after`, `artist`, `artists`, `categories`, and `profile`. The backend should treat saved device settings as authoritative defaults, then apply explicit query filters when present.

Use `scripts/stream-contract-check.sh` to validate a saved or live stream response before handing backend work to device validation. The check enforces schema version, generated timestamp, stream/settings shape, optional polling cadence shape, unique item ids, supported priorities, recognized mixed-content type/category mapping, active schedule windows relative to `generatedAt`, recognized targeting keys, per-item displayability/cache fields, and absence of local-only or sensitive values such as device API keys, pairing-code hashes, private tokens, or absolute appliance paths. Set `AUTOPOIESIS_REQUIRE_STREAM_POLLING=1` when a staging fixture must prove cadence metadata is present.

Stream `settings` should mirror the device preferences that can be managed on both website and device: `displayMode`, `streamProfile`, `activeArtists`, `streamCategories`, `allowImages`, `allowVideos`, `allowSoundWorks`, `allowGenerativeWorks`, `autoplay`, `videoAutoplay`, `soundAutoplay`, `soundEnabled`, `volume`, `imageDuration`, `showArtworkInfoOnTap`, and `updatedAt`.

Stream items should expose `id`, `type`, `title`, `artist`, `artistId`, `description` or `body`, `mediaUrl`, `thumbnailUrl`, `durationSeconds` when known, `cacheAllowed`, `priority`, scheduling fields, and remote links such as `url`, `infoUrl`, `blogUrl`, and `exhibitionUrl`. The hosted stream should return active-window items only: future `startsAt` rows and expired `expiresAt` rows should be filtered before the device sees them. Video, audio, and generative works should be authored for direct autoplay, without activation buttons in the artwork payload.

Hosted cache/offline contract:

`scripts/cache-contract-check.sh` validates a saved or live cache contract bundle before cache-management UI, offline fallback rollout, or physical Pi cache validation is treated as staging-ready. The bundle root may use `kind: "autopoiesis_frames_cache_contract"` and `schemaVersion: 1`, and should include:

- `device` or root `deviceId`: owner-safe device identity.
- `cachePreferences`, `cachePolicy`, or `profileFrames.cachePreferences`: explicit `enabled`, `likedArtworks`, `recentArtworks`, `selectedArtists`, and `sizeLimitMb` values derived from durable user/device settings.
- `cacheItems`, `cacheCandidates`, `cacheManifest`, `manifestItems`, or `items`: unique cache candidates with HTTP(S) media/source or thumbnail URLs, category/status metadata, optional size/duration timestamps, and no local filesystem paths.
- `deviceCache`, `cacheSummary`, or `offlineCache`: hosted-ingested device cache/offline summary with cached/playable/failed counts and optional size/last-sync metadata.
- Optional `commands`: cache-relevant `clear_cache` or `sync_settings` command evidence.

The checker rejects duplicate item ids, candidates without media or thumbnail URLs, unsupported cache statuses/categories, missing explicit cache-policy booleans, missing device cache evidence when required, and sensitive/local-only fields including stored device credentials, pairing hashes, private/admin tokens, secrets, passwords, absolute appliance paths, and raw cache paths. Use `AUTOPOIESIS_REQUIRE_CACHE_ITEMS=0` or `AUTOPOIESIS_REQUIRE_CACHE_DEVICE_SUMMARY=0` only for narrow component tests; strict hosted readiness should keep the defaults.

Local feed behavior:

- POST /local/feed/sync fetches GET /api/frames/device/{deviceId}/stream first, falls back to GET /api/frames/device/{deviceId}/feed, and stores a normalized local feed.
- Heartbeat responses may also carry feed, items, artworks, or broadcasts; the local UI normalizes those into the same feed state.
- The local feed preserves redacted polling/freshness hints from hosted stream responses and returns them through `POST /local/feed/sync`, `GET /local/feed`, diagnostics, support bundles, and `feed_synced` delivery evidence.
- GET /local/feed returns active, display-eligible items only. Expired items, future scheduled items, preference-disabled media types, disabled stream categories, non-selected artists, and explicit non-matching targeting hints are filtered out.
- Backend targeting remains authoritative, but the Pi defensively honors recognized device, owner/user, subscriber status, subscription tier, region/country, test-device, and exclusion target shapes when a stream response includes them. Public local feed responses redact targeting metadata after eligibility is evaluated.
- GET /local/feed also returns `displayQueue`, a priority-preserving mixed-content queue. The device keeps emergency/critical/high/normal/low priority bands intact, then round-robins categories inside each band across broadcast, curatorial, artwork, blog, news, and general content items so personalized streams do not collapse into a single content class.
- GET /local/frame-state returns the browser-safe local playback contract derived from `displayQueue`, including media role, cached-vs-remote source, playable counts, cached playable counts, display category, display position, and a compact `playback` readiness summary. It never exposes absolute cache paths or stored device API keys.
- `/frame` renders that local playback queue for the kiosk and prefers cached media URLs when `cache-index.json` has a usable asset. `/launch?local=1` or `preferences.displayMode=local-feed` routes to `/frame` while the default `/launch` path can remain hosted-display first.
- The frame player is time-based. Static images use `preferences.imageDuration`; video/audio items use item `durationSeconds` when present and otherwise advance when media fires `ended` or when the safe fallback timer expires. Video, audio, and generative works render without artist-authored activation buttons or browser controls.
- Tapping `/frame` opens a local artwork overlay when `showArtworkInfoOnTap` is enabled. The overlay includes artwork metadata, like, settings, dashboard, and remote artwork/blog/exhibition links when supplied.
- `POST /local/frame/like` records a local `feed_item_liked` delivery event, updates local liked state, and best-effort forwards `POST /api/frames/artworks/{artworkId}/like` for paired devices.
- `/dashboard` is the local Autopoiesis OS gateway. It summarizes stream readiness, cache, network, settings sync, current mode/profile, selected artists, and links to the frame, settings, blogs, exhibitions, and gallery.
- `/frame` posts `POST /local/frame/display` when it renders a queue item. The endpoint only records ids that are still present in the current `/local/frame-state` playable queue, appends a metadata-only `feed_item_shown` delivery event for non-broadcast items or `broadcast_shown` for broadcast-category items, and updates local state with `currentFeedItemId`, `currentArtworkId` for artwork-category items, and `lastFrameItemShownAt`.
- Feed diagnostics include `displayQueueItems` and category counts, while diagnostics/readiness/health/support bundles include `framePlayback` so Admin > Frames and support tooling can distinguish synced feed data from a queue the kiosk can actually render.
- The local UI also writes a feed cache manifest for items with cacheAllowed !== false and a media or thumbnail URL. `scripts/cache-artworks.sh` downloads those eligible assets into the local runtime cache and writes `cache-index.json` with cached/failed asset status.
- GET /local/offline-cache returns the redacted playable cache inventory. It reports counts and browser-safe local asset URLs without exposing absolute filesystem paths.
- GET /local/cache/assets/{itemId}/media and GET /local/cache/assets/{itemId}/thumbnail serve cached files only when the indexed path resolves under the configured cache directory.
- The `/offline` fallback reads `cache-index.json` and rotates playable cached feed media when the live Frames display is unreachable. Cache eviction remains a separate follow-up task.
- Feed items are sorted by priority, then created time, then explicit order; the derived display queue applies category mixing after that stable eligibility sort.

Local delivery log behavior:

- Feed syncs append a bounded metadata-only `feed_synced` event to `delivery-log.json`.
- Local frame playback appends bounded metadata-only `feed_item_shown` events for artwork, blog, news, curatorial, and other non-broadcast mixed-stream items.
- Broadcast display lifecycle appends `broadcast_shown` when `/broadcast` renders or when a broadcast-category item is displayed inside the mixed `/frame` queue, `broadcast_dismissed` after command-delivered display completion, one-time `broadcast_expired` events, and `broadcast_skipped` when a stored command-delivered broadcast is no longer target-eligible.
- GET /local/delivery-log returns recent events without raw payloads, local file paths, or stored device API keys.
- Heartbeat diagnostics and `/local/support-bundle` include a compact delivery summary so the backend/admin layer can mirror these events into durable `aos_` delivery rows.
- `scripts/broadcast-command-check.sh` validates command-delivered broadcast targeting, scheduling, launch routing, display-time delivery logging, dismissal, expiry rejection, and command acknowledgements against a mock Frames API.

Unified device event export:

- `GET /local/events/export?limit=25` returns one redacted, newest-first event stream built from the command audit trail, display delivery log, and release history.
- Optional `commandLimit`, `deliveryLimit`, and `releaseLimit` tune per-source bounds; optional `since=<iso timestamp>` filters events newer than that timestamp.
- Heartbeats include the same shape under `events`, bounded by `AUTOPOIESIS_HEARTBEAT_EVENT_LIMIT` (default 10 per source), so the backend can persist durable `aos_` command audit, broadcast delivery, and release rollout rows without scraping Pi log files.
- Heartbeats also include `eventIngestionCursor` when a previous backend acknowledgement exists. This tells the API what event pointer the device believes was last accepted and which replay window it used for the current heartbeat.
- A heartbeat response may include `eventsAck`, `eventAck`, `deviceEventsAck`, or `eventIngestionCursor` with `status`, `acceptedAt`, `acceptedThroughObservedAt`, `acceptedThroughEventKey`, optional `sourceCursors`, and optional `counts`. The Pi persists that redacted acknowledgement in `event-cursor.json`, reports it in diagnostics/support bundles, and uses `acceptedThroughObservedAt` minus a small overlap window as the next heartbeat's `since` cursor.
- `scripts/heartbeat-contract-check.sh` validates a saved heartbeat response or a bundle with `request` and `response` sections before backend staging is treated as sync-ready. It checks request diagnostics/event export shape, response event acknowledgements, optional authoritative settings, remote command authorization metadata, mixed-stream item hints, and redaction of device keys, pairing-code hashes, private tokens, secrets, and local appliance paths.
- `scripts/events-ingestion-check.sh` validates the device side of this contract against a mock Frames API: first heartbeat exports all local event sources, accepted acks persist a redacted cursor, the next heartbeat uses the replay overlap, stale acks are rejected, and diagnostics/support surfaces keep the retained cursor visible.
- The online Frames backend accepts heartbeat `events`, stores them idempotently in `aos_device_events` by `deviceId + eventKey`, returns `eventsAck`, and projects recognized event sources into existing `aos_admin_command_audits`, `aos_broadcast_deliveries`, and `aos_release_rollouts` rows.
- Every exported event includes a stable `source`, `eventKey`, and `observedAt` when available. Backend ingestion should treat `deviceId + eventKey` as idempotent.
- The global `cursor` includes latest and oldest exported event pointers plus `hasMore`; `sourceCursors` repeats the same shape per source with total/exported counts and per-source limits so ingestion can detect truncation in command audit, display delivery, or release history independently.
- Exported events intentionally omit raw command payloads, local cache paths, release artifact URLs, checksums, stdout/stderr, and stored device API keys.

Durable schema gate:

- `scripts/aos-schema-contract-check.sh` validates a saved schema JSON fixture or SQLite database file for the minimum durable `aos_` table contract used by the Frames API.
- The gate covers device identity, pairing, device settings, user preferences, heartbeats, command queueing, admin command audits, unified device events, artwork likes, broadcasts, releases, subscriptions, broadcast deliveries, and release rollouts.
- Backend migrations should pass this check before stream, admin bundle, heartbeat event ingestion, command acknowledgement, broadcast delivery, or rollout tests are trusted.
- SQLite database checks require the `sqlite3` CLI. CI may instead export JSON with `tables`, `columns`, `primaryKey`, and `unique` metadata.

Durable migration gate:

- `scripts/aos-migration-contract-check.sh` validates a migration directory or saved migration manifest before the hosted app applies Frames database changes.
- The gate requires deterministic sortable migration ids, SQL transaction boundaries unless a manifest marks a migration non-transactional, `aos_` table/index namespacing for DDL/DML, and coverage for the same MVP durable tables checked by the schema gate.
- Migrations that reference persistent `pairing_code` without `pairing_code_hash` are rejected; plaintext pairing codes belong only in active device-facing registration/status responses.
- DROP, TRUNCATE, unconditional DELETE, and broad UPDATE statements fail by default. Reviewed repair/rollback migrations may opt in with `AUTOPOIESIS_ALLOW_DESTRUCTIVE_MIGRATIONS=1`, but should still be paired with backup/rollback notes in the backend release plan.
- Run the migration gate before `scripts/aos-schema-contract-check.sh`, then run the schema gate against the migrated staging database or exported final schema.

Hosted integration suite:

- `scripts/hosted-contract-suite-check.sh` runs the hosted migration, schema, pairing, device-auth, settings, profile-ownership, heartbeat, command-poll, command-ack, command-state, stream, cache/offline, online-admin, broadcast, release, and release-rollout gates in dependency order.
- Use `--strict` for staging or CI jobs that must provide every source before physical Pi acceptance.
- Use `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE=migrations,schema,pairing,device-auth,settings,profile-ownership,heartbeat,command-poll,command-ack,command-state,stream,cache,online-admin,broadcast,release,release-rollout` when a partial job should require only selected gates while still running any other provided sources.
- CI/staging may pass saved fixtures or live URLs through the existing `AUTOPOIESIS_*_SOURCE` variables, or provide one `AUTOPOIESIS_HOSTED_CONTRACT_MANIFEST` JSON file with a `sources` object keyed by gate name. Manifest-relative file paths are resolved from the manifest directory, and individual `AUTOPOIESIS_*_SOURCE` variables override manifest entries for targeted reruns.
- A manifest may self-declare required gates with `require`, `required`, `requireGates`, `requiredGates`, or `required_gates`, either as a comma-separated string, array, or object whose truthy keys are required. Set `strict` or `requireAll` to `true` in the manifest to require every hosted gate without also passing `--strict`.
- Set `AUTOPOIESIS_HOSTED_CONTRACT_REPORT=/path/to/hosted-contract-report.json` when CI or staging needs a machine-readable readiness artifact. The report is written on pass and fail, includes `status`, `exitCode`, required gates, summary counts, failed gate/reason when available, and per-gate source-presence booleans, and deliberately omits raw source paths, URLs, tokens, and local appliance paths.

Release manifest validation:

- `GET /api/frames/device/{deviceId}/release` should return either `{ release: null }` when current or a `release` object that passes `scripts/release-manifest-check.sh`.
- Required release fields: `version`. Artifact-based releases also require `artifact_url` or `artifactUrl` and a SHA-256 `checksum`/`sha256`.
- Recommended release fields for rollout: `channel` or `updateChannel`, `tagName` or `tag`, `publishedAt`, `rolloutPercent`, `changelogUrl` or `releaseNotesUrl`, and `rollbackNotes`.
- Channels accepted by the device gate are `stable`, `beta`, `dev`, `canary`, `nightly`, `staged`, and `test`. Release apply automatically uses device-local `device.json.updateChannel` as the expected channel when `AUTOPOIESIS_RELEASE_CHANNEL` is not set, and requires a matching manifest channel before mutating app code. Set `AUTOPOIESIS_RELEASE_CHANNEL` only to override the local device channel for an explicit test or service environment.
- Artifact URLs must use HTTPS by default and must not point at localhost. Local testing may opt in with `AUTOPOIESIS_RELEASE_ALLOW_INSECURE_URLS=1`.
- Release manifests must not expose device API keys, pairing-code hashes, private/admin tokens, secrets, passwords, local appliance paths, artifact checksums in public local support endpoints, or raw updater stdout/stderr.
- `scripts/update-from-release.sh` runs the manifest check before it writes rollback metadata, downloads artifacts, or fast-forwards git. Rollback metadata records previous version/revision plus release channel, tag, and id. Strict production gates can still set `AUTOPOIESIS_RELEASE_REQUIRE_TAG=1`, `AUTOPOIESIS_RELEASE_REQUIRE_ARTIFACT=1`, and `AUTOPOIESIS_RELEASE_REQUIRE_ROLLBACK_NOTES=1`.

Hosted release rollout contract:

- Optional adapter endpoint: GET /api/admin/frames/release-rollout-contract-bundle
- `scripts/release-rollout-contract-check.sh` validates read-only staging/CI evidence that Admin > Frames update rollout state is backed by durable rows, not inferred from a manifest alone.
- The bundle root may use `kind: "autopoiesis_frames_release_rollout_contract"` and `schemaVersion: 1`, and should include `releases`, `rollouts`, `commands`, optional `adminAudits`, and `deviceEvents`.
- Release rows must include stable ids, semantic versions, recognized channels/statuses, and optional rollout percentage. Per-device rollout rows must reference known releases, name device ids, match the target release version, and expose terminal progress or failure evidence for strict readiness.
- Queued `update_device` command rows must reference known release/rollout evidence and include approved authorization metadata with `action: "update_device"`, accepted actor role, timestamp, and audit id.
- Device event rows must come from the `release_history` source, carry stable `eventKey` values for idempotent `deviceId + eventKey` ingestion, and reference known releases/rollouts when those ids are present.
- The checker rejects unknown release/rollout references, duplicate ids/event keys, missing update authorization, bundles without rollout progress, and sensitive/local-only fields including device credentials, tokens, artifact URLs, checksums, raw command payload hints, and appliance paths.

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
- Heartbeat `events` ingestion into broadcast delivery and release rollout rows should be proven with the broadcast and release-rollout contract gates before enabling broad Admin > Frames fleet actions.

Hosted command polling contract:

- Optional adapter endpoint: GET /api/admin/frames/command-poll-contract-bundle
- `scripts/command-poll-contract-check.sh` validates read-only staging/CI evidence for command polling through heartbeat command responses or GET /api/frames/device/{deviceId}/commands.
- The bundle root may use `kind: "autopoiesis_frames_command_poll_contract"` and `schemaVersion: 1`, and should include durable `commands`, an `authorizedPoll` response, `excludedCommands`, and `deniedPolls`.
- Every queued/pending/ready/retry durable command row for the polling device must be returned exactly once. Other-device rows, not-yet-due rows, expired/cancelled rows, and terminal rows must not be returned.
- Risky commands must include approved authorization metadata. High/critical commands must include an audit id, and `factory_reset_request` must also require local confirmation.
- Denied poll evidence should prove disabled, unpaired, unauthorized, owner-mismatched, or otherwise blocked devices receive no command rows.
- The checker rejects unknown returned commands, missing queued commands, duplicate command ids, unsupported command types, raw payload keys outside the safe command surface, stored credentials, pairing codes/hashes, tokens, release artifact details, checksums, stdout/stderr, and local appliance paths.

Hosted command acknowledgement contract:

- Optional adapter endpoint: GET /api/admin/frames/command-ack-contract-bundle
- `scripts/command-ack-contract-check.sh` validates read-only staging/CI evidence for `POST /api/frames/device/{deviceId}/commands/{commandId}/ack`.
- The bundle root may use `kind: "autopoiesis_frames_command_ack_contract"` and `schemaVersion: 1`, and should include durable `commands`, `acknowledgements`/`ackAttempts`, matching `adminAudits`, and heartbeat-ingested `deviceEvents` from the `command_audit` source.
- At least one acknowledgement must move a command to `acknowledged`, at least one final acknowledgement must move a command to `completed`, `error`, `failed`, or `denied`, and duplicate final acknowledgement evidence must be idempotent/no-change.
- Durable command rows must preserve `acknowledgedAt` and terminal timestamp evidence, admin audit rows must mirror terminal command status, and command audit events must reference known command/device rows with unique `deviceId + eventKey` idempotency.
- The checker rejects unknown command references, duplicate ids/event keys, non-terminal rows after final ack, raw command payload keys, stored credentials, tokens, release artifact details, checksums, stdout/stderr, and local appliance paths.

Hosted command state contract:

- Optional adapter endpoint: GET /api/admin/frames/command-state-contract-bundle
- `scripts/command-state-contract-check.sh` validates read-only staging/CI evidence that the durable command outbox moves through poll and ack transitions without re-delivering terminal commands.
- The bundle root may use `kind: "autopoiesis_frames_command_state_contract"` and `schemaVersion: 1`, and should include `beforePollCommands`, `postPollCommands`, `postAckCommands`, `adminAudits`, and `nextPoll`.
- At least one command must move from queued before poll, to delivered/sent after poll with delivered timestamp evidence, to terminal after acknowledgement with terminal timestamp evidence.
- Admin audit rows must mirror terminal command status, and a subsequent poll for the same device must not return terminal commands.
- The checker rejects unknown command references, duplicate command ids, unsupported command types, terminal re-delivery, stored credentials, tokens, release artifact details, checksums, stdout/stderr, raw command payloads, and local appliance paths.

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
- Command audit includes `ack_failed` when initial or final acknowledgement delivery fails, and `ack_retry_failed` when a retained final acknowledgement retry still cannot be delivered. These statuses count as command-audit errors in diagnostics.
- `scripts/command-ack-retry-check.sh` validates the device side of this contract against a mock Frames API: initial ack failures retain commands before execution, final ack failures are audited, final retries do not re-execute commands, and retry failures remain visible.

Release history:

- `POST /local/release/check` appends a metadata-only `release_checked` event to `release-log.json` with current version, update availability, release id, target version, channel, tag, and rollout id when supplied by the API.
- `POST /local/release/apply`, `POST /local/system/update-now`, and `update_device` commands append `release_apply_started`, `release_apply_completed`, `release_apply_failed`, or `release_skipped` events with the same release channel/tag context.
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
