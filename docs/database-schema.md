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
- `scripts/online-admin-contract-check.sh` expects the hosted Profile > Frames surface to derive owned devices from `aos_frame_devices`, user preferences from `aos_frame_user_preferences`, liked artworks from the canonical artwork-like table or an `aos_` mirror, active artists from canonical artist rows plus preference selections, and cache preferences from user/device settings.
- The Admin > Frames portion should derive users, subscribers, subscriptions, fleet devices, and remote action policies from durable `aos_` rows plus the canonical account/subscription models.
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

## Conflict Rule

- latest updatedAt timestamp wins for user-editable preferences.
- server remains final source of truth.
- offline local changes queue until connection returns.
- remote admin commands override local state where safety requires it.
