# Database Schema

Program tag: autopoiesis_os_frames

Namespace: aos

Recommended table prefix: aos_

The online Autopoiesis app is the source of truth. Devices keep local config and queue offline changes, but server state wins after conflict resolution.

## Core Models

### User

Existing account model. Frames tables should reference the canonical user id.

### UserProfile

Existing or extended user profile model. Stores display name and account-level preferences.

### Subscription

Fields:

- id
- userId
- plan
- status
- currentPeriodStart
- currentPeriodEnd
- cancelAt
- provider
- providerSubscriptionId
- createdAt
- updatedAt

### FrameDevice

Fields:

- id
- deviceId
- ownerUserId
- deviceName
- deviceType
- softwareVersion
- updateChannel
- paired
- remoteEnabled
- subscriptionStatus
- lastHeartbeatAt
- currentMode
- currentArtworkId
- networkOnline
- networkType
- storageStatus
- createdAt
- updatedAt

### FramePairingCode

Fields:

- id
- deviceId
- pairingCodeHash
- expiresAt
- claimedByUserId
- claimedAt
- status
- createdAt

### FrameDeviceSettings

Device-specific overrides.

- deviceId
- displayMode
- soundEnabled
- volume
- brightness
- autoplay
- nightMode
- nightModeStart
- nightModeEnd
- cacheEnabled
- cacheSizeLimitMb
- updatedAt

### FrameUserPreferences

User-level defaults synced to all frames unless overridden.

- userId
- activeArtists
- enabledContentTypes
- displayMode
- soundEnabled
- volume
- soundAutoplay
- videoAutoplay
- imageDuration
- nightMode
- nightModeStart
- nightModeEnd
- cacheLikedArtworks
- cacheRecentArtworks
- offlineFallbackMode
- updatedAt

Profile/Admin contract notes:

- `scripts/pairing-contract-check.sh` expects registration evidence to come from durable `aos_frame_devices` and `aos_frame_pairing_codes` rows, user claim evidence to bind the device to the authenticated canonical user, and post-claim status evidence to return the same owner/device relationship to the keyed device.
- Pairing-code plaintext should be limited to active device-facing registration/status responses. Durable storage should prefer `pairingCodeHash`; Profile/Admin/user claim payloads must not expose device API keys or pairing-code hashes.
- `scripts/device-auth-contract-check.sh` expects the hosted API to authenticate device-only routes against a stored hash or otherwise non-exposed representation of the per-device credential, then bind that credential to the route `deviceId`. Missing, invalid, and cross-device credentials must be rejected for pairing status, settings, heartbeat, stream, command polling/acknowledgement, and release routes before physical Pi acceptance.
- `scripts/settings-contract-check.sh` expects durable `aos_frame_device_settings` and `aos_frame_user_preferences` writes to use newest-`updatedAt` conflict handling. Staging evidence should show an accepted newer settings write, a rejected or explicitly conflicted stale write, a final read preserving the newer row, and heartbeat settings at least as current as the accepted write.
- `scripts/profile-ownership-contract-check.sh` expects Profile > Frames account/session routes to derive device access from canonical user ownership on `aos_frame_devices.owner_user_id` or the equivalent account mapping. Staging evidence should prove owned list/read/settings-write success, cross-owner read/settings-write/command rejection, anonymous profile rejection, and separate Admin fleet access across multiple owners before owner-facing actions are enabled.
- `scripts/cache-contract-check.sh` expects the hosted cache/offline bundle to join explicit cache preferences from `aos_frame_user_preferences`/`aos_frame_device_settings`, cache-eligible stream rows from durable content/broadcast sources, and ingested device cache summaries from heartbeat/support data. The bundle must expose HTTP(S) candidate URLs and compact counts only, never local cache paths or stored device credentials.
- `scripts/online-admin-contract-check.sh` expects the hosted Profile > Frames surface to derive owned devices from `aos_frame_devices`, user preferences from `aos_frame_user_preferences`, liked artworks from the canonical artwork-like table or an `aos_` mirror, active artists from canonical artist rows plus preference selections, explicit cache preferences from user/device settings, and per-device action availability from the same authorization/device-state evaluator used by Admin > Frames.
- The Admin > Frames portion should derive users, subscribers, subscriptions, fleet devices, global remote action policies, and target-specific action availability from durable `aos_` rows plus the canonical account/subscription models.
- `scripts/release-rollout-contract-check.sh` expects hosted release rollout evidence to join `aos_software_releases`, per-device `aos_release_rollouts`, `aos_device_commands`/`aos_admin_command_audits`, and heartbeat-ingested `release_history` rows from `aos_device_events`. It should prove update commands and release-history projections point at known release/rollout rows before broad Admin > Frames updates are enabled.
- `scripts/command-poll-contract-check.sh` expects hosted command polling evidence to join durable `aos_device_commands`, `aos_admin_command_audits`, and device eligibility state from `aos_frame_devices`. It should prove queued rows are returned exactly once to the owning device, ineligible rows are withheld, denied devices receive no commands, and risky command authorization metadata is present before command acknowledgement behavior is trusted.
- `scripts/command-ack-contract-check.sh` expects hosted command acknowledgement evidence to join `aos_device_commands`, `aos_admin_command_audits`, and heartbeat-ingested `command_audit` rows from `aos_device_events`. It should prove acknowledgement and final completion/error transitions update durable rows, mirror admin audit status, and treat duplicate final acknowledgements as idempotent before broad remote commands are enabled.
- The contract intentionally rejects stored device API keys, pairing-code hashes, private tokens, secrets, passwords, and local Pi filesystem paths.

### ContentFeedItem

- id
- type
- title
- artistId
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

Query notes:

- `GET /api/frames/device/{deviceId}/stream` should derive its `items` array from durable content rows plus active broadcasts and any mapped artwork/blog/exhibition source rows.
- Device, owner, subscription, tier, region, country, test-device, explicit exclusion, `startsAt`, and `expiresAt` targeting should be applied in the backend before returning the stream response.
- `scripts/stream-contract-check.sh` is the backend response gate for the stream shape before physical Pi validation.
- `scripts/cache-contract-check.sh` is the hosted cache/offline gate for proving those stream rows can become a cache manifest and that heartbeat-ingested cache summaries are available for Profile/Admin rollout decisions.

### Broadcast

- id
- title
- body
- type
- mediaUrl
- targetType
- targetValue
- priority
- duration
- startsAt
- expiresAt
- repeatCount
- dismissible
- cacheAllowed
- soundAllowed
- createdBy
- createdAt

### BroadcastDelivery

- id
- broadcastId
- deviceId
- userId
- status
- deliveredAt
- displayedAt
- dismissedAt
- error
- createdAt

### Heartbeat

- id
- deviceId
- softwareVersion
- currentMode
- currentArtworkId
- networkOnline
- networkType
- diskFreeMb
- temperatureC
- diagnostics
- createdAt

### DeviceCommand

- id
- deviceId
- commandType
- payload
- status
- createdAt
- acknowledgedAt
- completedAt
- lastAckStatus
- lastAckAt
- error

### DeviceLog

- id
- deviceId
- severity
- source
- message
- metadata
- createdAt

### DeviceEvent

Durable online mirror of the redacted Pi event export.

- deviceId
- eventKey
- source
- eventType
- status
- observedAt
- eventJson
- ingestedAt
- updatedAt

Constraint:

- unique(deviceId, eventKey)

Projection:

- `command_audit` events update matching DeviceCommand and AdminCommandAudit rows when `commandId` is present.
- `display_delivery` broadcast lifecycle events update or create BroadcastDelivery rows.
- `release_history` events update or create ReleaseRollout rows when `releaseId` and target version are present.

Schema contract gate:

- `scripts/aos-schema-contract-check.sh` validates the durable `aos_` table contract from either a SQLite database file or a saved schema JSON fixture.
- The gate currently requires the MVP tables for devices, pairing, device settings, user preferences, heartbeats, commands, admin command audits, device events, artwork likes, broadcasts, releases, subscriptions, broadcast deliveries, and release rollouts.
- Required primary/unique keys are checked for device ids, settings rows, user preference rows, command ids, event idempotency, artwork likes, broadcasts, releases, subscriptions, delivery rows, and rollout rows.
- `aos_frame_pairing_codes.pairing_code_hash` is preferred for production hardening; the gate allows the current MVP `pairing_code` column with a warning so backend migration can happen deliberately.
- Run this gate before relying on hosted `/stream`, online admin bundles, heartbeat event ingestion, command acknowledgement, broadcast delivery, or release rollout tests.

Migration contract gate:

- `scripts/aos-migration-contract-check.sh` validates the migration plan before it mutates staging or production data.
- Directory mode scans sorted `.sql` files recursively; manifest mode accepts `migrations` plus optional `finalSchema.tables` metadata from a backend migration tool.
- The gate requires sortable migration ids, `aos_` table/index namespacing, transaction boundaries for SQL migrations, required MVP table coverage, hashed pairing-code storage, and no accidental destructive DDL/DML.
- Run it before the schema contract gate. Then run `scripts/aos-schema-contract-check.sh` against the migrated database/export so the migration plan and final database shape are both proven.

### SoftwareRelease

- id
- version
- channel
- gitRef
- changelog
- rollbackRef
- minimumVersion
- status
- createdAt

### ReleaseRollout

- id
- releaseId
- deviceId
- currentVersion
- targetVersion
- status
- commandId
- queuedAt
- startedAt
- completedAt
- failedAt
- rolledBackAt
- failureReason
- lastSeenAt

## Conflict Rule

- latest updatedAt timestamp wins for user-editable preferences.
- server remains final source of truth.
- offline local changes queue until connection returns.
- remote admin commands override local state where safety requires it.
- hosted settings GET, POST, and heartbeat responses should all return authoritative updatedAt values after conflict resolution.
