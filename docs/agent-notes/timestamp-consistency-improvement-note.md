# Timestamp Consistency Improvement

## Summary
Fixed timestamp canonicalization inconsistencies in several API response functions to ensure consistent ISO 8601 UTC timestamp format across all endpoints.

## Changes Made

### 1. Fixed _mapCommandRow function
- Applied `canonicalTimestamp` to all timestamp fields:
  - `deliveredAt`
  - `acknowledgedAt`
  - `completedAt`
  - `lastAckAt`
  - `createdAt`
  - `updatedAt`
- This affects `getCommand` and `getPendingCommands` API endpoints

### 2. Fixed getLatestHeartbeat function
- Applied `canonicalTimestamp` to `createdAt` field

### 3. Fixed getReleaseRollouts function
- Applied `canonicalTimestamp` to all timestamp fields:
  - `queuedAt`
  - `startedAt`
  - `completedAt`
  - `failedAt`
  - `rolledBackAt`
  - `acknowledgedAt`
  - `lastSeenAt`
  - `createdAt`
  - `updatedAt`

### 4. Fixed _deliveryStatusTimestamp function (2026-06-23 10:15 AM)
- Applied `canonicalTimestamp` to all returned timestamp values
- Ensures consistent ISO 8601 UTC format for delivery status computations
- Affects broadcast delivery tracking and status determination logic

## Why This Matters
- Ensures consistent timestamp format across all API responses
- Eliminates need for clients to handle multiple timestamp formats
- Improves reliability of time-based filtering and sorting operations
- Aligns with existing patterns in other API endpoints like `getBroadcastDeliveries` and `getDeviceEvents`
- Supports the API/DATABASE/SYNC workstream goals of reliable device synchronization
- Prevents potential inconsistencies when comparing or storing timestamp values

## Verification
- All syntax checks pass: `node --check hosted-api/db.js`, `node --check hosted-api/server.js`, `node --check local-ui/server.js`
- All script checks pass: `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh`
- No functional changes, only improved timestamp consistency in API responses and internal processing

## Related Notes
- api-db-sync-conflict-resolution-enhancement.md
- heartbeat-work-summary-note.md