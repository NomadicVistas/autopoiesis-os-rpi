# Hosted API Stream Composition Engine

Date: 2026-06-08
Agent: Pulse

## What

The hosted API's stream endpoint now returns personalized content from `aos_broadcasts` instead of an empty `items: []` array.

## Components

### hosted-api/db.js
- `getStreamContent(context)` — queries `aos_broadcasts`, filters by targeting/scheduling/priority, boosts artist-matched items
- `getActiveBroadcastCount()` — monitoring helper
- `_broadcastTypeToCategory()` — type → category mapping
- `_priorityRank()` — priority → numeric rank

### hosted-api/server.js
- `handleStream()` rewritten to resolve owner context (tier, artists) and call `db.getStreamContent()`
- Subscription polling tier now correctly reads `sub.plan` (not `sub.subscription.plan`)

### Schema Extension
- `aos_broadcasts` gained 4 columns: `thumbnail_url`, `artist`, `artist_id`, `metadata_json`
- Updated both SQLite validation and PostgreSQL canonical migration

## Targeting Logic

The targeting filter in `getStreamContent()` supports:
- `target_type = 'all'` → passes through (default)
- `target_type = 'device'` / `'device_id'` → only specified devices
- `target_type = 'owner'` / `'user_id'` → only specified owners
- `target_type = 'tier'` / `'subscription_tier'` → only specified subscription tiers
- `target_type = 'exclude_device'` → exclude specified devices
- `target_type = 'exclude_owner'` / `'exclude_user'` → exclude specified owners
- Multiple values via comma-separated `target_value`

## Verification

- hosted-api-server-check: 74 checks (was 68), non-empty stream verified
- hosted-api-local-ui-bridge-check: 94 checks (was 86), 5 categories verified
- hosted-api-db-check: 45 checks, no regression
- All syntax checks pass

## Next

- Populate with real gallery content
- Admin content management UI
- Device feed pipeline testing with real data
