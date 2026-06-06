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
- Backend targeting remains authoritative, but the device defensively filters recognized targeting hints for specific devices, owners/users, subscriber status, subscription tier, region/country, test devices, and explicit exclusions before a feed item or broadcast enters local playback.
- `show_broadcast` commands are normalized through the same defensive targeting, expiry, priority, and schedule checks used by mixed-stream broadcasts.
- Immediate active broadcasts route `/launch` to the local `/broadcast` page. Scheduled broadcasts are stored but do not interrupt normal playback until their `startsAt` window opens.
- The local broadcast page records `broadcast_shown` only when `/broadcast` actually renders, then marks display complete through `POST /local/broadcast/dismiss` after its duration elapses and returns to `/launch`.
- The device keeps a bounded local `delivery-log.json` with metadata-only `broadcast_shown`, `broadcast_dismissed`, `broadcast_expired`, `broadcast_skipped`, and `feed_synced` events. `GET /local/delivery-log`, diagnostics, and the support bundle expose this safely for backend/admin delivery-log persistence.
- Broadcast priority is preserved for feed ordering and diagnostics.
- The local feed exposes a derived `displayQueue` for frame playback. It preserves priority bands, then round-robins broadcast, curatorial, artwork, blog, news, and general content categories inside each band so a personalized stream stays mixed without letting lower-priority items jump ahead.
- Public local feed output redacts targeting metadata after eligibility is evaluated.
- Cache eligibility is recorded as a manifest when `cacheAllowed` is not false and a media/thumbnail URL exists; actual media download/eviction belongs to the cache service.
- `scripts/broadcast-command-check.sh` validates command-delivered broadcasts end to end with a mock Frames API, including command acknowledgement status, wrong-target rejection, scheduled display delay, display-time `broadcast_shown`, dismissal, and expired-command rejection.
- `scripts/broadcast-contract-check.sh` validates the hosted side of the same lifecycle from a saved or live staging bundle: durable broadcast rows, queued `show_broadcast` commands with authorization/audit metadata, explicit targeting/audience, and durable delivery rows with display evidence.

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

## Hosted Contract Gate

Before broadcast controls are treated as staging-ready, generate a read-only `autopoiesis_frames_broadcast_contract` bundle from durable `aos_` rows or a controlled staging adapter and run:

```bash
./scripts/broadcast-contract-check.sh /path/to/broadcast-contract-bundle.json
```

The gate requires at least one broadcast with explicit targeting or audience, one queued `show_broadcast` command referencing that broadcast and carrying approved authorization metadata, and one delivery/display evidence row such as `broadcast_shown`. It rejects unknown targeting keys, unknown broadcast references, duplicate ids, and sensitive or local-only data. Component tests may relax command, delivery, or targeting requirements with `AUTOPOIESIS_REQUIRE_BROADCAST_COMMANDS=0`, `AUTOPOIESIS_REQUIRE_BROADCAST_DELIVERY=0`, or `AUTOPOIESIS_REQUIRE_BROADCAST_TARGETING=0`; strict hosted readiness should not.
