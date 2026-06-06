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
