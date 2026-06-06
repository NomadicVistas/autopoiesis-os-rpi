# Broadcast System

Pulse needs a broadcast system for sending messages or media to all or selected Frames devices.

## Broadcast Types

- text_message
- image_message
- video_message
- audio_message
- curatorial_announcement
- system_notice
- emergency_notice
- event_invitation
- artist_drop
- maintenance_notice

## Targeting

- all devices
- all active subscribers
- specific user
- specific device
- subscription tier
- artist followers
- region
- test devices
- development devices

## Behavior

- immediate display
- scheduled display
- priority level
- expiry time
- repeat count
- dismissible or non-dismissible
- cache allowed
- sound allowed

## Device Fetch

Phase 1 uses polling. Device receives broadcasts through heartbeat response or a dedicated broadcasts endpoint.

Device-side MVP behavior:

- The RPi local UI normalizes feed items and broadcasts into one local feed state.
- Expired broadcasts are rejected before display.
- Scheduled broadcasts are ignored locally until their start time.
- Active `show_broadcast` commands set `currentMode: broadcast` and route `/launch` to the local `/broadcast` page before returning to the normal Frames URL.
- The local broadcast page marks the broadcast display complete through `POST /local/broadcast/dismiss` after its duration elapses, then returns to `/launch`.
- The device keeps a bounded local `delivery-log.json` with metadata-only `broadcast_shown`, `broadcast_dismissed`, `broadcast_expired`, and `feed_synced` events. `GET /local/delivery-log`, diagnostics, and the support bundle expose this safely for backend/admin delivery-log persistence.
- Broadcast priority is preserved for feed ordering and diagnostics.
- Cache eligibility is recorded as a manifest when `cacheAllowed` is not false and a media/thumbnail URL exists; actual media download/eviction belongs to the cache service.

Suggested endpoint:

GET /api/frames/device/{deviceId}/broadcasts

Suggested response shape:

{
  "broadcasts": [
    {
      "id": "broadcast_001",
      "type": "curatorial_announcement",
      "title": "New Kinema Stream",
      "body": "A new living work has entered the Frames stream.",
      "mediaUrl": null,
      "priority": "normal",
      "duration": 20,
      "expiresAt": "2026-07-01T00:00:00Z"
    }
  ]
}

## Admin Requirements

- Create draft broadcast.
- Preview target count.
- Send test broadcast to development device.
- Schedule or send immediately.
- View delivery logs.
- Cancel future broadcast.
- Expire active broadcast.
