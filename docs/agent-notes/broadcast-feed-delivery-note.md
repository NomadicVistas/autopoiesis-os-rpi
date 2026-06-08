# Broadcast Feed Delivery Lifecycle

Date: 2026-06-08

## What was built

Source attribution and delivery deduplication for the personalized content stream.

## Key changes

### hosted-api/db.js — getStreamContent()

- All items now carry `source: "admin"` (they come from `aos_broadcasts`, admin-created content)
- Added `displayedSet` — queries `aos_broadcast_deliveries` for the requesting device
- Items with status `displayed`/`completed`/`acknowledged` are excluded from future stream responses
- Emergency (rank 500) and critical (rank 400) priority items bypass dedup — always shown

### local-ui/server.js — normalizeFeedItem()

- New `effectiveSource = raw.source || source` — respects the item's own source field
- Used for type fallback and output: items from the stream with `source: "admin"` keep that attribution
- Fixes the delivery tracking pipeline: `broadcastDeliveriesPayload()` picks up `source === "admin"`

## Delivery lifecycle (now end-to-end)

1. Admin creates content via CRUD → `aos_broadcasts`
2. `getStreamContent()` returns items with `source: "admin"`, excluding already-displayed items
3. Device normalizes items preserving source
4. Device tracks display events (`broadcast_shown`, `broadcast_dismissed`)
5. `broadcastDeliveriesPayload()` picks up items with `source === "admin"`
6. Heartbeat sends delivery status to hosted API
7. `ingestHeartbeat()` persists to `aos_broadcast_deliveries`
8. Next stream call excludes already-displayed items

## Check script

`scripts/broadcast-feed-delivery-lifecycle-check.sh` — 10 steps, 32 checks

## Open questions

- Should dedup be configurable per content type? (e.g., artworks never dedup, broadcasts always dedup)
- Should there be a "re-show" interval for non-emergency content? (e.g., show again after 24h)
- How to handle cache-informed dedup: prefer showing fresh content over cached items?
