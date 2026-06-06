# Issue: Implement Durable Frames Stream Endpoint

Program: Autopoiesis OS + Frames Platform

Workstream: LEAD / INTEGRATION

Status: ready for backend implementation

## Summary

The Raspberry Pi appliance now prefers `GET /api/frames/device/{deviceId}/stream` and falls back to legacy `/feed`. Device-side gates validate stream playback, local preference filtering, cache eligibility, targeting redaction, likes, and delivery evidence. The hosted app should now make `/stream` the durable `aos_` source of truth instead of relying on scaffold feed responses.

## Scope

Implement `GET /api/frames/device/{deviceId}/stream` from durable online rows:

- `aos_frame_devices`
- `aos_frame_device_settings`
- `aos_frame_user_preferences`
- `aos_subscriptions` or canonical subscription mirror
- `aos_content_feed_items`
- `aos_broadcasts`
- `aos_broadcast_deliveries` where needed for suppression/reporting
- existing artwork/blog/exhibition source tables mapped into `aos_content_feed_items` or joined into the response

The endpoint should return only items eligible for the requesting device, owner, subscription status/tier, region, and active schedule window. Device-side targeting remains a last-mile guard, not the primary filter.

## Response Contract

Return JSON:

```json
{
  "ok": true,
  "schemaVersion": 1,
  "generatedAt": "2026-06-06T15:15:00.000Z",
  "stream": {
    "profile": "living-stream",
    "source": "aos",
    "cursor": null
  },
  "settings": {
    "displayMode": "living-stream",
    "streamProfile": "living-stream",
    "activeArtists": [],
    "streamCategories": ["artwork", "broadcast", "curatorial", "blog", "news"],
    "allowImages": true,
    "allowVideos": true,
    "allowSoundWorks": true,
    "allowGenerativeWorks": true,
    "autoplay": true,
    "videoAutoplay": true,
    "soundAutoplay": false,
    "soundEnabled": false,
    "volume": 50,
    "imageDuration": 60,
    "showArtworkInfoOnTap": true,
    "updatedAt": "2026-06-06T15:15:00.000Z"
  },
  "items": []
}
```

Each item should include:

- `id`
- `type`
- `title`
- `artist`
- `artistId`
- `body` or `description`
- `mediaUrl`
- `thumbnailUrl`
- `durationSeconds` when known
- `cacheAllowed`
- `priority`
- `createdAt`
- `startsAt`
- `expiresAt`
- `url`, `infoUrl`, `blogUrl`, `exhibitionUrl`, or `dashboardUrl` where relevant

Do not return stored device API keys, pairing-code hashes, private admin tokens, local filesystem paths, release artifact checksums, or raw command payloads.

## Acceptance Checks

Before handing to physical Pi validation:

1. Save a representative response and run:

   ```bash
   AUTOPOIESIS_REQUIRE_STREAM_ITEMS=1 scripts/stream-contract-check.sh /path/to/stream-response.json
   ```

2. Or check a live endpoint:

   ```bash
   AUTOPOIESIS_STREAM_CONTRACT_TOKEN="$TOKEN" scripts/stream-contract-check.sh "https://autopoiesis.art/api/frames/device/$DEVICE_ID/stream"
   ```

3. Then run the existing device gates against a paired device or mock API:

   ```bash
   scripts/stream-playback-check.sh
   scripts/feed-targeting-check.sh
   AUTOPOIESIS_REQUIRE_FRAME_ITEMS=1 scripts/frame-state-check.sh
   ```

## Open Questions

- Which canonical account/session check owns Profile > Frames and device ownership for this endpoint?
- Which subscription source is authoritative for `subscriptionStatus` and `subscriptionTier`?
- Should first production streams include only artworks and broadcasts, or also blog/exhibition/system-news rows immediately?
- What cursor format should be used for pagination once the MVP stream exceeds a single device payload?

