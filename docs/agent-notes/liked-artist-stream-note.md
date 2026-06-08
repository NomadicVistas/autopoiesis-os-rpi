# Liked-Artist Stream Weighting — Agent Note

**Date:** 2026-06-09
**Workstream:** LEAD / INTEGRATION
**Milestone:** MVP 0.2 Personal Stream — liked-artwork → artist preference → stream weighting

## What Was Built

1. **`getLikedArtistIds(userId)`** in `hosted-api/db.js`
   - Joins `aos_artwork_likes` with `aos_broadcasts` to resolve liked artwork IDs to artist IDs
   - Returns deduplicated artist IDs ordered by most-liked (highest like count first)
   - `try/catch` wrapper for bootstrap safety

2. **Liked-artist boosting in `handleStream()`** in `hosted-api/server.js`
   - Extracts artist IDs from owner's liked artworks
   - Merges with explicit `activeArtists` preferences (deduplication: explicit takes precedence)
   - Combined set passed to `getStreamContent()` for artist-boost sorting

3. **Validation gate**: `scripts/liked-artist-stream-weighting-check.sh` (33 checks, 11 steps)

## Architecture

```
User likes artwork on Frame
    ↓
POST /frames/artworks/:id/like → aos_artwork_likes
    ↓
GET /frames/device/:id/stream
    ↓
handleStream():
  1. Get explicit activeArtists from aos_frame_user_preferences
  2. Get likedArtistIds from aos_artwork_likes JOIN aos_broadcasts  ← NEW
  3. Merge (dedup) → combined artist set
  4. getStreamContent(activeArtists: combined set)
    ↓
Stream items from liked artists boosted above unknown artists
```

## Key Design Decisions

- **Like count ordering**: Artists with more likes are returned first, giving them stronger boost priority within the stream
- **Merge, don't replace**: Explicit preferences are preserved; liked artists only append
- **Graceful fallback**: No likes → no artists → no boost → standard priority ordering
- **Bootstrap safe**: `try/catch` handles fresh databases where tables don't exist yet

## Unblocks

- MVP 0.2 Personal Stream testing with real preferences
- Physical Pi end-to-end like → boost → display cycle
- Admin dashboard liked-artist analytics
- Content freshness weighting based on artist preference strength
