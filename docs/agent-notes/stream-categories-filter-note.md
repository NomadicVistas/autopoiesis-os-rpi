# streamCategories Filter — Agent Note

**Date:** 2026-06-09
**Workstream:** Broadcast / Feed
**Author:** Pulse (cron)

## What Changed

Wired `streamCategories` user preference through from `aos_frame_user_preferences` to the `getStreamContent()` method in `hosted-api/db.js`, so the personalized stream only returns content types the user wants to see.

## Files Changed

- `hosted-api/db.js` — `getStreamContent()` accepts `streamCategories` parameter, filters by `_broadcastTypeToCategory()` mapping, emergency/critical bypass
- `hosted-api/server.js` — `handleStream()` extracts `streamCategories` from owner preferences, passes to `getStreamContent()`
- `scripts/stream-categories-filter-check.sh` — new 11-step 25-check validation gate

## Category Mapping

| Broadcast type | Category |
|---|---|
| artwork, image, video, audio, generative | artwork |
| curatorial, exhibition | curatorial |
| blog_post, blog | blog |
| news, announcement | news |
| broadcast_message, broadcast, system_notice | broadcast |

## Key Decisions

1. **Emergency bypass**: Emergency (500) and critical (400) priority items always pass through the category filter. These are admin-level broadcasts that shouldn't be hidden by user preferences.

2. **Null = all**: When `streamCategories` is null/undefined/empty, no filtering is applied. This is the safe default for unpaired devices and users without explicit preferences.

3. **Variable scope**: `streamCategories` is declared at function scope in `handleStream()` (before the `if (record.ownerUserId)` block) so it's always defined when passed to `getStreamContent()`.

## Open Items

- No HTTP endpoint for device pairing — the check script calls `db.claimPairingCode()` directly. A `/frames/pairing/claim` endpoint should be added.
- The admin broadcasts list endpoint returns `{items: [...]}` not `{broadcasts: [...]}` — inconsistent naming.
- Device-side feed sync doesn't pass `streamCategories` as a query parameter yet.
