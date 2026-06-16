# Index on aos_frame_devices(owner_user_id, paired)

Added index to speed up queries that filter by owner and paired status.

## Why
- The countDevicesByOwner function (used for entitlement computation) queries aos_frame_devices with WHERE owner_user_id = ? AND paired = 1.
- The listDevices function also filters by owner_user_id and paired status.
- Without an index, these queries perform a full table scan, which becomes slow as the number of devices grows.

## Impact
- Speeds up entitlement computation for subscriptions.
- Improves device listing in admin UI.
- Benefits profile, API, admin, and sync workstreams.
- Reduces latency for device-centric operations.

## Migration
- Migration: 20260616123000_add_index_on_devices_owner_user_id_paired.sql
- Creates index: idx_aos_devices_owner_user_id_paired

## Verification
- Index verified via schema query.
- No regressions in existing functionality.
