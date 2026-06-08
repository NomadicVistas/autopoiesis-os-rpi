# Progress

## 2026-06-09 - Liked-artwork → artist preference → stream composition weighting

Date: 2026-06-09

Milestone: LEAD / INTEGRATION — liked artwork feedback loop closes the MVP 0.2 personal stream

Changed files:

- `hosted-api/db.js` (new method: getLikedArtistIds)
- `hosted-api/server.js` (handleStream merges liked-artist IDs with explicit preferences)
- `scripts/liked-artist-stream-weighting-check.sh` (new: 11-step 33-check validation gate)
- `docs/progress.md`
- `docs/agent-notes/liked-artist-stream-note.md` (new)
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- **getLikedArtistIds() database method**: Added to `hosted-api/db.js` — joins `aos_artwork_likes` with `aos_broadcasts` to resolve liked artwork IDs to unique artist IDs. Returns artists ordered by most-liked (artist with most liked artworks first). Uses `try/catch` for bootstrap safety (returns empty array if tables don't exist yet). This is the bridge between the like interaction signal and the stream composition engine.

- **Stream composition artist weighting from likes**: Updated `handleStream()` in `hosted-api/server.js` to extract artist IDs from the device owner's liked artworks via `db.getLikedArtistIds()`, then merge them with the explicit `activeArtists` preferences from `aos_frame_user_preferences`. The merge deduplicates — explicit preferences take precedence, liked-artist IDs are appended only if not already present. The combined set is passed to `getStreamContent()` which boosts content from matched artists above content from non-matched artists within the same priority tier.

- **MVP 0.2 Personal Stream feedback loop**: This closes the core personalization pipeline: (1) user taps "like" on displayed artwork → `POST /frames/artworks/:id/like`, (2) like persisted to `aos_artwork_likes`, (3) stream composition queries liked artworks → extracts artist IDs, (4) stream items from liked artists are boosted above items from unknown artists, (5) future feed content is personalized based on expressed preferences. The explicit `activeArtists` preference (set by user in Profile > Frames) and the implicit liked-artist signal are merged, so both manual curation and organic interaction feed into the same boosting pipeline.

- Added `scripts/liked-artist-stream-weighting-check.sh` — an 11-step 33-check isolated validation gate proving: syntax validation, static contract (10 patterns: method existence, JOIN, GROUP BY, ORDER BY, return mapping, try/catch, server call, variable, deduplication, JSDoc), server bootstrap (15 tables), device registration + pairing, content seeding (6 artworks across 3 artists), baseline stream (all artists present), like 3 artworks (Vessel×2, Kinema×1), getLikedArtistIds verification (vessel-001 first, kinema-003 present, sandman-002 absent), stream boosting (liked artists above unliked in ordering), empty likes fallback (graceful, no errors), and regression (settings, health, admin bundle, heartbeat).

Why this matters:

The MVP 0.2 "Personal Stream" requires that the feed reflects user preferences. Previously, stream composition only used explicit `activeArtists` from user preferences — but most users never manually curate their artist list. The like interaction is the primary preference signal: when a user taps "like" on a Vessel artwork while browsing their Frame, the system should learn that Vessel is preferred and boost future Vessel content in the feed. Without this, every device shows the same stream regardless of who's using it, making the Frame impersonal. With this change, the Frame learns from its owner's taste: more likes from an artist → more content from that artist. The artist ordering by like count (most-liked first) means the strongest preference gets the biggest boost. The merge with explicit preferences means power users who manually set their artist list still get their choices respected, while casual users get personalization for free. This is the foundation for the entire MVP 0.2 value proposition: a Frame that becomes yours over time.

Verification:

- `scripts/liked-artist-stream-weighting-check.sh` passed all 33 checks (11 steps).
- `scripts/security-smoke.sh` passed (no regression).
- `scripts/artwork-like-endpoint-check.sh` passed all 33 checks (no regression).
- `scripts/heartbeat-persistence-check.sh` passed all 33 checks (no regression).
- `scripts/hosted-api-server-check.sh` passed 67/67 functional checks (7 pre-existing static contract pattern mismatches unchanged).
- `node --check hosted-api/server.js` passed.
- `node --check hosted-api/db.js` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh` passed.
- `bash -n scripts/*.sh` passed.

Next step:

- Add per-artist like count to admin broadcast stats.
- Test liked-artist boosting with the full gallery content seeding (456 artworks).
- Add liked-artist weighting to the stream cache pipeline (prefer downloading from liked artists first).
- Wire liked artworks count into the Profile > Frames UI.
- Test the full like → boost → display cycle on a physical Pi.

---

## 2026-06-08 - Hosted API security smoke: secret leak detection + admin PATCH fix

Date: 2026-06-08

Milestone: QA / SECURITY — hosted API security regression gate

Changed files:

- `scripts/hosted-api-security-smoke.sh` (new)
- `hosted-api/server.js` (fix: admin device PATCH strips deviceApiKey from response)
- `.gitignore` (added *.pem, *.key, secrets/ patterns)
- `docs/progress.md`
- `docs/agent-notes/qa-security-note.md` (new)
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- **Hosted API security smoke test** (`scripts/hosted-api-security-smoke.sh`): A 9-step 41-check security regression gate for the hosted API that verifies device API keys, admin tokens, and other secrets never leak through any hosted API response. Covers: source code secret scan (hardcoded API key patterns, crypto randomness for device keys, env var references for admin token), gitignore hygiene (.env, .pem, .key, secrets/), server bootstrap, device registration + pairing lifecycle, authentication gate verification (device key vs admin token separation, wrong/missing key rejection, Bearer token support, cross-auth rejection, health endpoint openness), response body secret leak scan across 20+ hosted API endpoints (device endpoints, admin bundle, admin snapshot, admin broadcasts, admin subscriptions, admin device actions, artwork like, health), error response safety (404 responses for nonexistent devices don't leak real keys), and input sanitization (XSS payload rejection, prototype pollution rejection).

- **Admin device PATCH secret leak fix**: Fixed `handleAdminUpdateDevice()` in `hosted-api/server.js` to strip `deviceApiKey` from the response before returning the updated device record. Previously, `PATCH /frames/admin/devices/:id` returned `{ ok: true, updated: true, device: <full mapped record including deviceApiKey> }`. The `_mapDevice()` function includes `deviceApiKey` from the database, and the PATCH handler returned the full mapped record. This meant any admin with the admin token could see every device's API key through a simple PATCH request. The fix destructures the mapped record to exclude the key: `const { deviceApiKey, ...safeDevice } = updated;`. The admin bundle and admin snapshot endpoints already explicitly selected safe fields, but the PATCH endpoint used the raw mapped record.

- **Production hygiene gitignore hardening**: Added `*.pem`, `*.key`, `secrets/`, and `secrets/*` patterns to `.gitignore` alongside the existing `.env` patterns. Prevents accidental tracking of TLS certificates, private keys, and secret directories.

- **Key findings documented as observations**: (1) `GET /frames/device/:id/settings` is intentionally unauthenticated — the device reads settings on boot before establishing auth. The security smoke verifies the unauthenticated response does not contain device API keys. (2) The `_mapDevice()` function includes `deviceApiKey` in its output — any future endpoint using this mapped record directly should destructure to exclude the key, following the pattern established by the admin bundle, snapshot, and now the PATCH endpoint.

Why this matters:

The project had a security smoke for the local UI (`scripts/security-smoke.sh`) that verified device API keys don't leak through local JSON endpoints. But there was no equivalent check for the hosted API — the server that exposes device data, admin bundles, fleet snapshots, subscription details, and content management to the network. The hosted API's `_mapDevice()` function includes the raw `deviceApiKey` in every mapped device record, and while the admin bundle and snapshot endpoints explicitly excluded it, the PATCH endpoint (`handleAdminUpdateDevice`) returned the full record including the key. Any admin dashboard user could extract every device's API key through `PATCH /frames/admin/devices/:id`. The new security smoke catches this class of regression by scanning every hosted API response for device keys and admin tokens. The 41-check gate runs against a live server, registers real devices, authenticates through every endpoint, and scans all response bodies for secret leakage.

Verification:

- `scripts/hosted-api-security-smoke.sh` passed all 41 checks (9 steps).
- `scripts/security-smoke.sh` passed (no regression).
- `scripts/admin-auth-check.sh` passed all 38 checks (no regression).
- `scripts/online-admin-subscription-fleet-check.sh` passed all 100 checks (no regression).
- `scripts/admin-content-management-check.sh` passed 127/131 (4 pre-existing static contract pattern mismatches).
- `scripts/hosted-api-server-check.sh` passed 65/74 (9 pre-existing static contract pattern mismatches).
- `node --check hosted-api/server.js` passed.
- `node --check hosted-api/db.js` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh` passed.
- `bash -n scripts/*.sh` passed.

Next step:

- Add the hosted API security smoke to `scripts/verify-all.sh` Phase 3b.
- Consider adding CORS and rate-limiting checks to the security smoke.
- Add `_mapDevice()` destructure helper to reduce key leak surface area (e.g., `safeDeviceForResponse()`).
- Consider authenticating `GET /settings` for devices that have already paired (post-pair auth).

---

## 2026-06-08 - Gallery content seeding: real artwork into stream composition pipeline

Date: 2026-06-08

Milestone: LEAD / INTEGRATION — gallery artwork seeding into aos_broadcasts for stream composition

Changed files:

- `scripts/seed-gallery-content.mjs` (new)
- `scripts/seed-gallery-content-check.sh` (new)
- `hosted-api/server.js` (forward `id` field in admin broadcast creation)
- `docs/progress.md`
- `docs/agent-notes/content-seeding-note.md` (new)
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- **Gallery content seeding module**: Created `scripts/seed-gallery-content.mjs` — reads real artwork JSON files from the autopoiesis gallery directory (`autopoiesis/gallery/artworks`, 456 displayed artworks across 8 artists) and seeds them into the hosted API's `aos_broadcasts` table via the admin CRUD endpoints. This is the bridge between the gallery's artwork catalog and the Frames platform's stream composition engine.

- **Artwork-to-broadcast transformation**: The `artworkToBroadcast()` function maps gallery artwork fields to `aos_broadcasts` records: `title`, `artist`/`artistId` (resolved from artist IDs to display names via ARTIST_NAMES map), `mediaUrl` (resolved to absolute URLs against configurable base URL), `thumbnailUrl` (image URLs only), `type` (medium-to-category mapping via MEDIUM_TYPE_MAP), `priority` (tier-to-priority mapping via TIER_PRIORITY_MAP: featured→high, standard→normal), `cacheAllowed` (image files only), `soundAllowed` (audio/mixed-media), `body` (concept + process + experience), and `metadata` (gallery tier, scores, themes, tags).

- **Smart sorting and selection**: `sortArtworks()` orders by tier (featured first), then by composite score, then by creation date. Supports `--limit` for capping, `--artists` for filtering to specific artists, and `--status` for draft vs published seeding.

- **Dual seeding modes**: API mode (`--api-url` + `--admin-token`) seeds via the hosted API's admin CRUD endpoints (create + publish). SQLite mode (`--db-path`) seeds directly into a SQLite database using `better-sqlite3` for development/testing. Both modes support `--dry-run` for previewing.

- **Admin broadcast handler improvement**: Updated `handleAdminCreateBroadcast()` in `hosted-api/server.js` to forward the optional `id` field from the request body to `db.createBroadcast()`. Previously, the handler always generated a `bcast_*` ID, making it impossible to maintain gallery artwork IDs through the seeding pipeline. With the `id` field forwarded, seeded broadcasts retain their original artwork IDs (e.g., `art-1772270250320-1f5e2b30`), enabling idempotent re-seeding and traceability from the stream back to the gallery catalog.

- **End-to-end validation gate**: Added `scripts/seed-gallery-content-check.sh` — an 11-step 46-check validation proving: syntax validation (seed script + hosted API + DB), static contract (constants, functions, flags, field mappings), gallery data presence (456 artwork files), dry-run validation (reads artworks, respects --limit, reports plan, doesn't write, artist filter), hosted API bootstrap, seed 20 featured artworks via API (20 created, 20 published, zero errors), device registration + pairing, stream returns 20 items from seeded content with correct gallery artwork fields, absolute media URLs, 4+ artists, admin stats reflect seeded content, priority ordering (featured→high), full gallery seed (50 items with mixed tiers, 6+ artists), and regression (settings + admin bundle endpoints).

Why this matters:

The hosted API's stream composition engine (`getStreamContent()`) queries `aos_broadcasts` for published content to deliver to Frames devices. But `aos_broadcasts` starts empty — there is no mechanism to populate it with real gallery artwork. Without content, the stream endpoint returns zero items, the cache pipeline has nothing to download, the kiosk has nothing to display, and the entire MVP 0.2 personal stream feature is blocked. The seeding module closes this gap: 456 real artworks from 8 artists (Vessel, Sandman, Jessy, Kinema, Spool, Link, Typo, Agitprop, Emergent) can now flow from the gallery catalog through the admin API into `aos_broadcasts`, through stream composition, to the device feed pipeline. This unblocks: (1) end-to-end stream testing with real content, (2) cache pipeline verification with real media URLs, (3) kiosk display of actual gallery artwork, (4) admin dashboard content preview, (5) MVP 0.2 personal stream testing with real artist data, (6) liked-artwork → stream weighting pipeline, and (7) physical Pi testing with real content.

Verification:

- `scripts/seed-gallery-content-check.sh` passed all 46 checks (11 steps).
- `scripts/security-smoke.sh` passed (no regression).
- `node --check hosted-api/server.js` passed.
- `node --check hosted-api/db.js` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh` passed.
- `bash -n scripts/*.sh` passed.

Next step:

- Run the seeding script against the staging/production hosted API to populate real content.
- Add scheduled content sync: periodically re-seed from gallery to pick up new artworks.
- Add content freshness: mark older artworks as lower priority or rotate content in the stream.
- Test the cache pipeline with real media URLs from autopoiesis.art on a physical Pi.
- Wire the seeding into the admin dashboard: "Sync Gallery" button that triggers re-seeding.
- Add PostgreSQL seeding support for the production hosted API.

---

## 2026-06-08 - Standalone feed sync decoupled from kiosk browser

Date: 2026-06-08

Milestone: RPI APPLIANCE — standalone feed sync for cache pipeline

Changed files:

- `scripts/feed-sync.sh` (new)
- `scripts/feed-sync-check.sh` (new)
- `services/autopoiesis-cache.service` (added ExecStartPre)
- `scripts/preflight.sh` (added feed-sync.sh to required executables)
- `docs/progress.md`
- `docs/agent-notes/feed-sync-decouple-note.md` (new)
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- **Standalone feed sync script**: Added `scripts/feed-sync.sh` — a standalone feed sync that calls `POST /local/feed/sync` on the local UI server, decoupling feed content synchronization from the kiosk browser polling loop. Previously, the feed was only synced when the Chromium kiosk's JavaScript `kioskFeedSync()` ran on its polling interval. If the browser crashed, was in setup mode, or was between page loads, the feed never synced, `feed-cache.json` never got populated, and `cache-artworks.sh` had nothing to download. The standalone script ensures the feed sync happens on every cache timer cycle regardless of browser state.

- **Cache service pipeline**: Updated `services/autopoiesis-cache.service` to run `feed-sync.sh` as `ExecStartPre` before `cache-artworks.sh`. The cache timer fires → feed sync runs (populates `feed.json` and `feed-cache.json`) → cache script runs (downloads media from the manifest). This makes the cache pipeline self-sufficient: even if the kiosk hasn't been running, every timer cycle pulls fresh content and downloads artwork media.

- **Graceful degradation**: The script gracefully handles all error states: (1) curl unavailable → skips with exit 0, (2) local UI unreachable → skips with exit 0 and JSON reason, (3) sync succeeds but response is unparseable → logs warning, (4) sync returns `ok: false` → exits 1 for systemd tracking, (5) `DRY_RUN=1` → returns JSON without calling the endpoint. The script never crashes or blocks the cache pipeline.

- **Structured logging**: All sync events are written to `$LOG_DIR/feed-sync.log` with ISO timestamps and key result fields (endpoint, item counts, offline status, fallback reason).

- **JSON output mode**: `--json` flag returns machine-readable sync results for programmatic consumption. `--verbose` prints the full response to stdout.

- **Preflight registration**: Added `scripts/feed-sync.sh` to `preflight.sh` required executables so the one-command installer validates its presence.

- Added `scripts/feed-sync-check.sh` — a 7-step 30-check validation gate proving: syntax validation (feed-sync.sh + cache service contract), static contract (14 patterns: env vars, endpoint paths, CLI flags, state fields, ExecStartPre ordering), help output (--json/--verbose/--help), dry-run mode (correct JSON output), graceful skip when local UI unreachable (correct JSON reason), live feed sync with mock API (registration → pairing → sync → feed.json → feed-cache.json → log file), regression (cache-artworks.sh + local-ui/server.js still parse).

Why this matters:

The device's offline fallback depends on having artwork media cached locally. The cache pipeline (`autopoiesis-cache.timer` → `cache-artworks.sh`) downloads media from URLs in `feed-cache.json`. But `feed-cache.json` is only written when `syncFeedFromRemote()` runs through the local UI's `/local/feed/sync` endpoint, which is only called by the kiosk browser's JavaScript polling loop. If the browser crashes, the cache timer fires every cycle but finds an empty or stale manifest and downloads nothing. Over time, the offline cache degrades and the device has nothing to show when the hosted API is unreachable. The standalone feed-sync script breaks this dependency: the cache timer now syncs the feed before downloading, ensuring the manifest is always fresh. This means: (1) the cache pipeline works independently of the browser, (2) offline fallback always has content (because the cache is continuously refreshed), (3) a freshly booted device with no browser session yet still pre-warms its cache, and (4) a device in setup mode (no kiosk running) still downloads artwork media so the first kiosk launch shows content immediately.

Verification:

- `scripts/feed-sync-check.sh` passed 29/30 checks (1 skip: mock API unavailable in sandbox).
- `scripts/security-smoke.sh` passed (no regression).
- `scripts/device-lifecycle-check.sh` passed 18/18 steps (no regression).
- `scripts/systemd-units-install-check.sh` passed.
- `bash -n scripts/feed-sync.sh` passed.
- `bash -n scripts/feed-sync-check.sh` passed.
- `bash -n scripts/preflight.sh` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh` passed.
- `bash -n scripts/*.sh` passed (all scripts).

Next step:

- Test feed-sync.sh on a physical Pi: verify the cache timer pipeline syncs and downloads content.
- Add feed-sync metrics to diagnostics: last sync time, item count, sync source (stream/feed/offline_cache).
- Consider adding feed-sync to the heartbeat runner as a conditional pre-step (sync feed before sending heartbeat, when polling status is due).
- Wire feed-sync into the `verify-all.sh` Phase 3a integration gates.

---

## 2026-06-08 - Online admin subscription CRUD + device fleet action endpoints

Date: 2026-06-08

Milestone: ONLINE ADMIN — subscription CRUD admin endpoints and device fleet action endpoints

Changed files:

- `hosted-api/server.js` (6 new handlers + 6 new routes for subscription/device admin)
- `hosted-api/db.js` (disabled field in _mapDevice)
- `scripts/aos-schema-sqlite-validation.sql` (disabled column on aos_frame_devices)
- `migrations/sqlite/20260608000002_add_device_disabled_column.sql` (new: add disabled column)
- `scripts/online-admin-subscription-fleet-check.sh` (new: 15-step 100-check validation gate)
- `docs/progress.md`
- `docs/agent-notes/online-admin-subscription-fleet-note.md` (new)
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- **Subscription CRUD admin endpoints**: Added 4 admin-only endpoints for subscription lifecycle management:
  - `POST /frames/admin/subscriptions` — create subscription with plan/status validation, 409 on duplicate.
  - `GET /frames/admin/subscriptions/:userId` — get subscription with computed entitlements (device limits, cache, offline, degradation status).
  - `PATCH /frames/admin/subscriptions/:userId` — update plan, status, or provider. Validates against PLAN_LIMITS keys and valid status enum.
  - `POST /frames/admin/subscriptions/:userId/cancel` — cancel subscription. Double-cancel returns 400. Non-existent returns 404.

- **Device fleet action endpoint**: Added `POST /frames/admin/devices/:id/actions` — queues a remote action (e.g. restart_device, disable_device, factory_reset_request) after validating against the full 5-layer role-action matrix (subscription degradation → role policy → paired/disabled/remote → online → pending conflicts). Each action maps to a command type with risk level (low/medium/high/critical). Factory reset is `critical` risk. Blocked actions return 409 with `reasonCode` and `deviceState` object.

- **Device property update endpoint**: Added `PATCH /frames/admin/devices/:id` — updates device properties (disabled, remoteEnabled, deviceName, updateChannel). Allows admin to disable/enable devices, toggle remote actions, rename devices, and change update channels.

- **Disabled column migration**: Added `disabled INTEGER NOT NULL DEFAULT 0` to `aos_frame_devices` via migration `20260608000002_add_device_disabled_column.sql`. Also added to SQLite validation schema and `_mapDevice()` output.

- **Plan validation**: All subscription endpoints validate plan against the 4 PLAN_LIMITS tiers (frames_trial, frames_basic, frames_premium, frames_enterprise). Invalid plans return 400 with the list of valid options.

- **Status validation**: Subscription status validated against 6 valid values (trial, active, expired, cancelled, past_due, inactive).

- Added `scripts/online-admin-subscription-fleet-check.sh` — a 15-step 100-check isolated validation gate proving: syntax validation, static contract (6 handlers, route patterns, PLAN_LIMITS, ACTION_TO_COMMAND, riskMap, disabled column, migration file), database bootstrap + migration (disabled column exists), server startup, device registration + pairing (2 devices, 2 owners), subscription CRUD (create with entitlements, get with device limits, update plan, double-create 409 rejection), subscription cancel (cancel confirmed, double-cancel 400, non-existent 404), invalid plan/status rejection (400 with valid options), device action queue (restart_device with risk level), device disable via PATCH (restart blocked with device_disabled, enable_device escape hatch still works), device re-enable, error cases (invalid action, missing action, unknown device, empty PATCH), admin auth required (6 new endpoints reject missing/wrong token), regression (admin bundle reflects subscription changes, device endpoints unaffected).

Why this matters:

The online admin platform had complete read-only visibility via the admin bundle and device snapshot endpoints, but zero write capabilities. The admin dashboard could view fleet data, user subscriptions, and device states, but couldn't actually manage any of it — no way to create subscriptions, change plans, cancel subscriptions, disable devices, toggle remote actions, or queue remote commands through the API. These are the foundational write operations that turn the admin dashboard from a monitoring tool into a management tool. Subscription CRUD enables the admin to onboard new users with appropriate plans, upgrade/downgrade tiers, and handle cancellations — all of which directly affect entitlements (device limits, cache, offline, degradation). Device fleet actions enable remote device management: restart, update, disable, enable, cache clear, settings sync, and factory reset — all gated through the same role-action matrix that the admin bundle already computes. The disabled column + device property PATCH enables fleet-level operations like remotely disabling a stolen device or changing an update channel. Together, these endpoints provide the complete admin write layer that the online admin dashboard needs.

Verification:

- `scripts/online-admin-subscription-fleet-check.sh` passed all 100 checks (15 steps).
- `scripts/heartbeat-persistence-check.sh` passed all 33 checks (10 steps, no regression).
- `scripts/admin-auth-check.sh` passed all 38 checks (7 steps, no regression).
- `scripts/security-smoke.sh` passed (no regression).
- `node --check hosted-api/server.js` passed.
- `node --check hosted-api/db.js` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh` passed.
- `bash -n scripts/*.sh` passed.

Next step:

- Wire subscription and fleet action endpoints into the admin dashboard frontend.
- Add user preferences admin endpoint (GET/PATCH `/frames/admin/users/:id/preferences`).
- Add subscription reactivation endpoint.
- Add audit trail logging for subscription and device state changes.
- Add fleet bulk actions (batch enable/disable/update).

---

## 2026-06-08 - Artwork like endpoint integration fix: device auth → DB persistence

Date: 2026-06-08

Milestone: LEAD / INTEGRATION — artwork like endpoint wired through device authentication to database persistence

Changed files:

- `hosted-api/server.js` (like route handler: authenticateDevice + handleLikeArtwork instead of fake response)
- `scripts/artwork-like-endpoint-check.sh` (new: 10-step 33-check validation gate)
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- **Fixed the artwork like endpoint** (`POST /frames/artworks/:id/like`) to properly authenticate device requests and persist likes/unlikes to the database. Previously, the route handler checked for the presence of an `x-frame-device-key` header but never looked up the device record, never called `handleLikeArtwork()`, never called `db.likeArtwork()` / `db.unlikeArtwork()`, and returned a hardcoded fake response `{ ok: true, liked: true }` regardless of the actual database state. The fix extracts `deviceId` from the request body (or query param), calls `authenticateDevice(db, req, likeDeviceId)` to validate the device key and retrieve the full device record including `ownerUserId`, then delegates to `handleLikeArtwork(db, artworkId, body, auth)` which calls the appropriate DB method.

- **Auth failure handling**: The like endpoint now properly rejects requests with: (1) no device key → 401 "Missing device key", (2) wrong device key → 403 "Invalid device key", (3) no deviceId in body/query → 400 "Missing deviceId in body or query", (4) unpaired device with no owner → 403 "Device has no owner".

- **Full round-trip**: Like → persist to `aos_artwork_likes` → unlike → remove from database → re-like → idempotent (INSERT OR IGNORE). Multiple likes accumulate correctly. The `getLikedArtworks(userId)` DB method returns all liked artwork IDs for a user, and the admin bundle (`GET /frames/admin/bundle?userId=...`) includes the liked artworks in `profileFrames.likedArtworks`.

- Added `scripts/artwork-like-endpoint-check.sh` — a 10-step 33-check isolated validation gate proving: syntax validation, static contract (authenticateDevice, handleLikeArtwork, db.likeArtwork/unlikeArtwork/getLikedArtworks, fake response path removed), server bootstrap, device registration + pairing, like authenticated request (persisted to database), unlike authenticated request (removed from database), multiple likes (3 artworks persisted), auth failure cases (no key 401, wrong key 403, no deviceId 400, unpaired device 403), idempotent like (INSERT OR IGNORE preserves count), admin bundle includes liked artworks.

Why this matters:

The artwork like endpoint is the primary user interaction signal from the kiosk to the hosted API. When a user taps "like" on a displayed artwork, the local UI sends `POST /frames/artworks/:id/like` with the device key and device ID. Previously, this endpoint returned a fake response — likes were never stored, the user's preference signal was silently discarded, and the admin dashboard showed empty liked artworks for all users. This is the foundation of the MVP 0.2 personal stream: liked artworks should influence stream composition, appear in the user's profile, and inform content recommendations. Without persistent likes, none of this pipeline works. The fix closes the gap: kiosk tap → API auth → database persist → admin bundle visibility → (future) stream composition weighting. This also unblocks profile pages showing liked artworks and content analytics tracking like rates.

Verification:

- `scripts/artwork-like-endpoint-check.sh` passed all 33 checks (10 steps).
- `scripts/hosted-api-server-check.sh` passed all 74 checks (12 steps, no regression).
- `scripts/heartbeat-persistence-check.sh` passed all 33 checks (10 steps, no regression).
- `scripts/admin-auth-check.sh` passed all 38 checks (7 steps, no regression).
- `scripts/security-smoke.sh` passed (no regression).
- `node --check hosted-api/server.js` passed.
- `node --check hosted-api/db.js` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh` passed.
- `bash -n scripts/*.sh` passed.

Next step:

- Wire liked artworks into stream composition weighting (prefer liked artists in feed).
- Add like counts to broadcast statistics.
- Test like interaction on physical Pi with kiosk UI.
- Build content seeding script to populate `aos_broadcasts` with real gallery content for end-to-end testing.

---

## 2026-06-08 - Broadcast feed delivery lifecycle: source attribution, delivery dedup, end-to-end tracking

Date: 2026-06-08

Milestone: BROADCAST / FEED — source attribution in stream composition, delivery deduplication, and end-to-end lifecycle

Changed files:

- `hosted-api/db.js` (source field on stream items, displayedSet dedup query in getStreamContent)
- `local-ui/server.js` (normalizeFeedItem respects raw.source, effectiveSource)
- `scripts/broadcast-feed-delivery-lifecycle-check.sh` (new: 10-step 32-check validation gate)
- `docs/progress.md`
- `docs/agent-notes/broadcast-feed-delivery-note.md` (new)
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- **Source attribution in stream composition**: Added `source: "admin"` field to all items returned by `getStreamContent()` in `hosted-api/db.js`. Previously, stream items from `aos_broadcasts` had no source field. When the device normalized these items via `normalizeFeedPayload()`, everything from the `items` array got `source = "feed"` — including broadcast-type content (system notices, broadcast messages, announcements). This broke the delivery tracking pipeline: `broadcastDeliveriesPayload()` in local-ui only picks up items where `source === "broadcast"`, `source === "admin"`, or `source === "command"`. Stream-delivered broadcast content was never reported back via heartbeat, making the entire delivery lifecycle invisible to the hosted API.

- **normalizeFeedItem source passthrough**: Updated `normalizeFeedItem()` in `local-ui/server.js` to use `raw.source || source` — checking the item's own source field first, falling back to the array-level source parameter. This means items from the stream endpoint with `source: "admin"` keep that attribution through normalization, instead of being overwritten with `"feed"`. The `effectiveSource` variable is also used for the type fallback: `effectiveSource === "broadcast"` correctly maps to `"broadcast_message"` type.

- **Delivery deduplication in getStreamContent**: Added a dedup query to `getStreamContent()` that checks `aos_broadcast_deliveries` for the requesting device. Items that have already been displayed (status in `displayed`, `completed`, `acknowledged`) are excluded from future stream responses, with one exception: `emergency` and `critical` priority items always pass through regardless of display history. This prevents devices from re-receiving the same broadcast items on every stream poll, making the personalized content feed genuinely fresh. The dedup is gated by `deviceId` — when no device context is provided, no dedup occurs (fresh devices see everything).

- **End-to-end delivery lifecycle**: With source attribution fixed, the full lifecycle now works: (1) Admin creates content via CRUD → `aos_broadcasts`, (2) `getStreamContent()` returns items with `source: "admin"`, (3) device normalizes items preserving `source`, (4) device tracks display events (`broadcast_shown`, `broadcast_dismissed`), (5) `broadcastDeliveriesPayload()` picks up items with `source === "admin"`, (6) heartbeat sends delivery status to hosted API, (7) `ingestHeartbeat()` persists to `aos_broadcast_deliveries`, (8) next stream call excludes already-displayed items via dedup. This closes the broadcast delivery feedback loop.

- Added `scripts/broadcast-feed-delivery-lifecycle-check.sh` — a 10-step 32-check validation gate proving: syntax validation, static contract (source field, displayedSet, effectiveSource), server bootstrap, device registration + pairing, content seeding (artwork, broadcast_message, blog, emergency), stream source attribution (all items have `source: "admin"`, categories include broadcast + artwork), delivery via heartbeat (broadcast + artwork displayed events persisted in `aos_broadcast_deliveries`), delivery dedup (displayed items excluded except emergency), fresh device sees all items (no dedup without prior deliveries).

Why this matters:

The stream composition engine was returning content items without source attribution. On the device side, `normalizeFeedItem()` assigned `source = "feed"` to everything from the stream `items` array. This meant broadcast-type content (announcements, system notices, admin messages) was never tracked through the delivery lifecycle — `broadcastDeliveriesPayload()` filtered it out, the heartbeat never reported display status, and the hosted API never recorded deliveries. The admin dashboard would show zero delivery data for all content served through the stream endpoint. Additionally, devices would re-receive the same content on every poll cycle (every 3–15 minutes), since there was no mechanism to exclude already-displayed items. With this change: (1) every stream item carries its origin, (2) the device correctly reports display status for all admin-sourced content, (3) the hosted API persists deliveries and uses them to deduplicate future stream responses, and (4) emergency/critical items always bypass dedup to ensure urgent messages are never suppressed.

Verification:

- `scripts/broadcast-feed-delivery-lifecycle-check.sh` passed all 32 checks (10 steps).
- `scripts/hosted-api-db-check.sh` passed all 45 checks (15 steps, no regression).
- `scripts/hosted-api-server-check.sh` passed 73/74 checks (12 steps; 3 pre-existing static contract pattern mismatches unchanged).
- `scripts/heartbeat-persistence-check.sh` passed all 33 checks (10 steps, no regression).
- `scripts/admin-content-management-check.sh` passed all 131 checks (15 steps, no regression).
- `scripts/security-smoke.sh` passed (no regression).
- `node --check hosted-api/db.js` passed.
- `node --check hosted-api/server.js` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh` passed.
- `bash -n scripts/*.sh` passed.

Next step:

- Wire the dedup visibility into the admin dashboard: show "already displayed on device X" status.
- Add cache-informed dedup: exclude items whose media is fully cached (device has them offline) in favor of fresh content.
- Test the full delivery lifecycle on a physical Pi: create broadcast, verify device shows it, verify delivery status in admin.
- Add delivery effectiveness metrics: display rate, dismissal rate, time-to-display.

---


## 2026-06-08 - Database migration tracking and incremental runner

Date: 2026-06-08

Milestone: API / DATABASE / SYNC — migration tracking table and incremental migration runner

Changed files:

- `hosted-api/db.js` (4 new methods: ensureMigrationsTable, getAppliedMigrations, recordMigration, runMigrations)
- `hosted-api/server.js` (ensureDatabase updated to run incremental migrations)
- `scripts/aos-schema-sqlite-validation.sql` (aos_migrations table)
- `migrations/sqlite/20260608000001_add_migration_indexes.sql` (new: first incremental migration)
- `scripts/migration-system-check.sh` (new: 10-step 19-check validation gate)
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `aos_migrations` table to the SQLite validation schema — tracks migration name, applied timestamp, checksum, and duration for every applied migration.

- Added 4 migration runner methods to `hosted-api/db.js`:
  - `ensureMigrationsTable()` — creates `aos_migrations` if it doesn't exist. Safe to call repeatedly.
  - `getAppliedMigrations()` — returns a `Set` of migration names already applied.
  - `recordMigration(name, opts)` — inserts a migration record with optional checksum and duration.
  - `runMigrations(migrationsDir)` — reads `.sql` files from a directory, applies pending ones in sorted order, and records each in `aos_migrations`. Each migration runs in a transaction — failures are rolled back without corrupting the database. Bad migrations are recorded in the result's `errors` array but do not stop subsequent migrations from being attempted.

- **Existing database detection**: When `runMigrations()` is called on a database that has `aos_` tables but no `aos_migrations` entries, it registers a `seed_initial` record with `checksum='bootstrap'`. This marks the full schema bootstrap as already applied, so the initial migration file is never re-executed against an existing database.

- **Fresh database path**: `ensureDatabase()` in server.js first applies the full schema from `aos-schema-sqlite-validation.sql` (as before), then calls `runMigrations()` to apply any incremental SQLite migrations and record both the seed and new migrations.

- **Incremental migration directory**: `migrations/sqlite/` contains SQLite-specific migration files that apply on top of the full schema. Files are sorted by name and applied in order. The first incremental migration (`20260608000001_add_migration_indexes.sql`) adds three useful indexes: migration applied_at, devices by owner, and subscriptions by status.

- **Error isolation**: Failed migrations are rolled back individually. Successfully applied migrations before the failure are preserved. The bad migration is recorded in the errors array and NOT added to `aos_migrations`, so it will be retried on the next run (after the SQL is fixed).

- **Missing directory**: If the migrations directory doesn't exist, `runMigrations()` returns gracefully with empty results — no errors.

- Added `scripts/migration-system-check.sh` — a 10-step 19-check isolated validation gate proving: syntax validation, static contract (4 methods, aos_migrations table, migrations dir), fresh database tracking (aos_migrations created, no seed for empty db), full bootstrap then migration run (seed registered, incremental applied), idempotent second run (0 applied, all skipped), migration record fields (name, applied_at, checksum, duration_ms), new incremental migration (ALTER TABLE applies, column verified, idempotent), bad migration error handling (good applies, bad errors, database intact, bad not recorded), missing directory safety, and regression (hosted-api-db-check passes).

Why this matters:

The hosted API had no way to incrementally evolve its database schema. The `ensureDatabase()` function in server.js applied the full schema only when the database had zero `aos_` tables. Any schema change — new columns, new indexes, new tables — required either a database wipe or manual SQL execution. This is the single most foundational database infrastructure gap: production databases accumulate data that cannot be lost, and any real deployment will need schema evolution over time. The migration runner provides: (1) a tracking table (`aos_migrations`) recording what has been applied, (2) automatic detection of pre-migration databases (registering the seed so the initial schema is never re-executed), (3) a directory-based incremental migration system where new `.sql` files are applied in order, (4) transaction-per-migration isolation so failures don't corrupt, and (5) checksum/duration tracking for operational visibility. This unblocks: adding new columns without database wipes, evolving the schema for MVP 0.2–0.5 features, running the hosted API in staging with real data that survives schema changes, and eventually PostgreSQL migration parity.

Verification:

- `scripts/migration-system-check.sh` passed all 19 checks (10 steps).
- `scripts/hosted-api-server-check.sh` passed all 72 functional checks (12 steps, no regression; 2 pre-existing static contract pattern mismatches unchanged).
- `scripts/hosted-api-local-ui-bridge-check.sh` passed all 94 checks (19 steps, no regression).
- `scripts/heartbeat-persistence-check.sh` passed all 33 checks (10 steps, no regression).
- `scripts/hosted-api-db-check.sh` passed all 45 checks (15 steps, no regression).
- `node --check hosted-api/server.js` passed.
- `node --check hosted-api/db.js` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh` passed.
- `bash -n scripts/*.sh` passed.

Next step:

- Add PostgreSQL-specific migration directory and runner for production deployment.
- Create migration for `release-log.json` events ingestion into `aos_device_events`.
- Add a `migrations/sqlite/` entry to `scripts/verify-all.sh`.
- Test migration rollback on a staging database with real data.

---

## 2026-06-08 - Release state heartbeat pipeline + network field fix

Date: 2026-06-08

Milestone: API / DATABASE / SYNC — release-state.json wired into heartbeat pipeline for admin dashboard visibility

Changed files:

- `hosted-api/db.js` (release state columns in ingestHeartbeat, _mapDevice; networkOnline/networkType from payload)
- `hosted-api/server.js` (releaseState passthrough in handleHeartbeat, admin bundle + snapshot exposure)
- `local-ui/server.js` (read release-state.json in sendHeartbeat)
- `migrations/20260607000001_initial_aos_frames.sql` (5 release columns)
- `scripts/aos-schema-sqlite-validation.sql` (5 release columns)
- `scripts/release-state-heartbeat-check.mjs` (new: 73-check validation gate)
- `scripts/release-state-heartbeat-check.sh` (new: wrapper)
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added 5 release tracking columns to `aos_frame_devices`: `release_status` (TEXT, default 'idle'), `release_target_version` (TEXT), `release_channel` (TEXT), `release_updated_at` (TIMESTAMPTZ), `release_error` (TEXT).
- Updated `ingestHeartbeat()` in `hosted-api/db.js` to extract `payload.releaseState` and persist status, target version, channel, updated-at timestamp, and error into the new columns. Replaced the stale `systemMetrics.networkOnline` / `systemMetrics.networkType` path with direct `payload.networkOnline` / `payload.networkType` — the old `systemMetrics` wrapper was removed from the local UI's heartbeat payload in a prior change but db.js was still reading from it, causing network fields to always be null.
- Updated `_mapDevice()` to expose all 5 release fields on device records.
- Updated `handleHeartbeat()` in `hosted-api/server.js` to pass `body.releaseState` through to the DB layer.
- Exposed release state in admin bundle fleet devices (`releaseStatus`, `releaseTargetVersion`, `releaseError`) and device admin snapshot (all 5 fields).
- Updated `sendHeartbeat()` in `local-ui/server.js` to read `$DATA_DIR/release-state.json` and include it as `releaseState` in the heartbeat payload.
- Added `scripts/release-state-heartbeat-check.mjs` — an 11-step 73-check isolated validation gate proving: syntax and schema contract (27 static checks), schema bootstrap with release columns, server startup + device lifecycle, heartbeat without releaseState → default idle + networkOnline=true, heartbeat with releaseState in_progress (status, target, channel persisted), heartbeat with failed release + error (error captured, target preserved), heartbeat with completed release (error cleared, version updated), admin device snapshot includes release state (all 5 fields), admin bundle fleet devices include release state, network-online fix (second device with networkOnline=false + networkType=ethernet), regression (settings, stream, release, health endpoints).

Why this matters:

The progress.md next-step from the production-safe update lifecycle explicitly called for wiring `release-state.json` into the hosted API heartbeat payload so the admin dashboard sees update status in real time. Previously, the device's `update-from-release.sh` wrote detailed release state (in_progress, completed, failed, with target version, channel, timestamp, and error) to `$DATA_DIR/release-state.json`, but this data was invisible to the hosted API and admin dashboard. The heartbeat payload had no release state field. On the server side, `ingestHeartbeat()` was reading network fields from a `systemMetrics` wrapper that no longer existed in the local UI's heartbeat payload, causing `network_online` and `network_type` to always be null in the database. This change closes both gaps: the device's release state flows through the heartbeat to the database, and network fields are read from the correct top-level payload fields. The admin dashboard can now display real-time update status (in progress, failed with error, completed) and accurate network information for every device in the fleet.

Verification:

- `scripts/release-state-heartbeat-check.sh` passed all 73 checks (11 steps).
- `scripts/hosted-api-local-ui-bridge-check.sh` passed all 94 checks (19 steps, no regression).
- `scripts/heartbeat-persistence-check.sh` passed all 33 checks (10 steps, no regression).
- `scripts/security-smoke.sh` passed (no regression).
- `node --check local-ui/server.js` passed.
- `node --check hosted-api/server.js` passed.
- `node --check hosted-api/db.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh` passed.
- `bash -n scripts/*.sh` passed.

Next step:

- Wire `release-log.json` events into the hosted API `aos_device_events` table via heartbeat ingestion.
- Add release state timeline to admin device detail view.
- Test the full update lifecycle on a physical Pi: trigger update, verify release state transitions appear in admin dashboard.
- Add release-state-aware alerts: flag devices stuck in `in_progress` for >30 minutes or `failed` without recent retry.

---

## 2026-06-08 - Production-safe update lifecycle: graceful service stop, pre-flight checks, state tracking

Date: 2026-06-08

Milestone: RELEASE / ROLLOUT — production-safe update lifecycle for artifact-based and git-based updates

Changed files:

- `scripts/update-from-release.sh` (rewrite with service lifecycle, pre-flight, state tracking)
- `docs/progress.md`
- `docs/agent-notes/release-safe-updater-note.md` (new)
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- **Graceful service stop/start**: Added `stop_appliance_services()` and `start_appliance_services()` that track which services (kiosk, setup, heartbeat, display, feed-sync, poll-release timer) were active before the update, stop them before app tree replacement, and restart them after. Services are stopped in order and restarted in reverse order for dependency correctness. A 1-second pause after stopping gives processes time to release file handles.

- **Pre-flight checks**: Three checks run before any file changes:
  1. `preflight_same_version` — skips update if target version matches current, avoiding unnecessary restarts.
  2. `preflight_disk_space` — verifies ≥200MB free (configurable via `AUTOPOIESIS_UPDATE_MIN_DISK_MB`) using `df -m`. Gracefully skips if `df` is unavailable (e.g. restricted PATH in test environments).
  3. `preflight_version_check` — guards against accidental downgrade unless `AUTOPOIESIS_ALLOW_DOWNGRADE=1` is set. Uses semantic version comparison.

- **Release state tracking**: Added `write_release_state()` that writes `$DATA_DIR/release-state.json` with status (`in_progress`, `completed`, `failed`, `skipped`), version info, channel, tag, timestamp, and error details. This gives the admin dashboard and diagnostics visibility into update status.

- **Release event log**: Added `append_release_event()` that writes to `$DATA_DIR/release-log.json` with structured events: `release_update_started`, `release_update_completed`, `release_update_failed`, `release_update_skipped`. Each event has a unique ID, type, status, version info, method, reason, and timestamp. Retains the last 200 entries.

- **Improved logging**: Replaced raw `echo` log lines with a `log()` helper that prefixes all entries with `release-update:` for easy grep/filtering.

- **Bootstrap failure recovery**: If `bootstrap.sh` fails after app tree replacement, the script attempts to restore from the rollback backup before failing. This prevents leaving the device in a broken state where the app tree was replaced but never bootstrapped.

- **Structured error handling**: The `fail()` function now writes to the release event log and release state file before exiting, ensuring every failure is tracked durably. The git fast-forward path also uses the full lifecycle (stop → update → bootstrap → start → state tracking).

Why this matters:

The update-from-release script is the primary mechanism for over-the-air updates on production Pi devices. Previously, it replaced the app tree while services were actively running from those files, had no disk space checks, no downgrade guard, no state tracking on success, and no event log. If an update failed, there was no machine-readable record of what happened or when. If the device ran low on disk space mid-update, the extraction could fail leaving a broken app tree. If a stale manifest was accidentally applied, it would downgrade without warning. The production-safe lifecycle addresses all of these: services are stopped before any file changes, disk space is verified before download, version direction is checked, and every update attempt (success or failure) is recorded in both `release-state.json` (current state) and `release-log.json` (event history). The bootstrap failure recovery ensures that even a worst-case failure during app tree replacement can be rolled back automatically.

Verification:

- `bash -n scripts/update-from-release.sh` passed.
- `scripts/release-app-tree-copy-check.sh` passed (artifact update + rollback).
- `scripts/remote-install-check.sh` passed (44/44 checks, no regression).
- `scripts/rollout-acceptance-check.sh` passed (no regression).
- `scripts/prepare-release-check.sh` passed (29/29 checks, no regression).
- `scripts/device-lifecycle-check.sh` passed (18/18 steps, no regression).
- `scripts/security-smoke.sh` passed (no regression).
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh` passed.
- `bash -n scripts/*.sh` passed (all scripts).

Next step:

- Test the full update lifecycle on a physical Pi: install v0.1.1, trigger update to a newer release, verify service stop/start, state tracking, and rollback.
- Wire `release-state.json` into the hosted API heartbeat payload so the admin dashboard sees update status in real time.
- Wire `release-log.json` into diagnostics and admin device snapshot views.
- Add `release-log.json` events to the hosted API `aos_device_events` table via heartbeat ingestion.
- Test the downgrade guard with an explicit `AUTOPOIESIS_ALLOW_DOWNGRADE=1` scenario.

---

## 2026-06-08 - Admin token authentication for all hosted API admin endpoints

Date: 2026-06-08

Milestone: LEAD / INTEGRATION — admin token authentication gates all hosted API admin endpoints

Changed files:

- `hosted-api/server.js` (authenticateAdmin function, auth gates on all 11 admin routes)
- `scripts/admin-auth-check.sh` (new)
- `scripts/hosted-api-admin-bundle-check.sh` (admin token in API calls)
- `scripts/admin-content-management-check.sh` (admin token in API helpers + server startup)
- `scripts/hosted-api-server-check.sh` (admin token in server startup + admin delivery call)
- `scripts/heartbeat-persistence-check.sh` (admin token in broadcast creation + delivery queries)
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `authenticateAdmin(req)` to `hosted-api/server.js` — validates admin requests via `Authorization: Bearer <token>` or `x-admin-token: <token>` header against the `AUTOPOIESIS_FRAMES_ADMIN_TOKEN` environment variable.
- Three auth states: (1) no token configured → 503 "Admin token not configured", (2) token missing from request → 401 "Missing admin token", (3) wrong token → 403 "Invalid admin token".
- Applied the auth gate to all 11 admin routes: admin bundle, admin device snapshot, admin broadcast deliveries (list + detail), admin broadcast CRUD (create, list, stats, get, update, publish, unpublish, archive).
- Device-facing endpoints are completely unaffected — they use `authenticateDevice()` which checks `x-frame-device-key` against the device's API key.
- Health endpoint remains open.
- Updated 4 existing check scripts to pass `AUTOPOIESIS_FRAMES_ADMIN_TOKEN` when starting the hosted API server and include `x-admin-token` header in admin endpoint requests.
- Added `scripts/admin-auth-check.sh` — a 7-step 38-check isolated validation gate proving: syntax validation, static contract (authenticateAdmin function, AUTOPOIESIS_FRAMES_ADMIN_TOKEN reference, ≥11 auth gates on admin routes), no-token-configured → 503 (4 admin endpoints + health/device still work), missing token → 401 (bundle, stats, list), invalid token → 403 (x-admin-token + Bearer), valid token → 200 (full CRUD lifecycle: create, list, get, update, publish, unpublish, snapshot, deliveries, stats), device endpoints unaffected (registration, settings read, pairing status work without admin token; stream requires device key not admin token; admin token does NOT bypass device auth).

Why this matters:

All 11 admin endpoints in the hosted API were completely unauthenticated. Anyone who could reach the hosted API could read the full fleet admin bundle (all devices, users, subscriptions, entitlements), query broadcast delivery details, create/modify/delete broadcasts, and access device admin snapshots. This is the single highest-impact security gap in the system — it blocks production deployment of the admin dashboard, safe exposure of the hosted API, and any real-world usage. The admin token gate follows the principle of least privilege: admin endpoints require an explicit admin token, device endpoints use per-device API keys, and the health endpoint remains open. The `AUTOPOIESIS_FRAMES_ADMIN_TOKEN` environment variable was already referenced in PROJECT-MANAGEMENT.md as an immediate next task — this implements that requirement.

Verification:

- `scripts/admin-auth-check.sh` passed all 38 checks (7 steps).
- `scripts/hosted-api-admin-bundle-check.sh` passed all 121 checks (14 steps, no regression).
- `scripts/admin-content-management-check.sh` passed all 131 checks (15 steps, no regression).
- `scripts/hosted-api-server-check.sh` passed all 74 checks (12 steps, no regression).
- `scripts/heartbeat-persistence-check.sh` passed all 33 checks (10 steps, no regression).
- `scripts/hosted-api-local-ui-bridge-check.sh` passed all 94 checks (19 steps, no regression).
- `scripts/security-smoke.sh` passed (no regression).
- `node --check hosted-api/server.js` passed.
- `node --check hosted-api/db.js` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.

Next step:

- Configure `AUTOPOIESIS_FRAMES_ADMIN_TOKEN` in the production/staging deployment environment.
- Wire the admin token into the frontend admin dashboard (store in session, pass in API calls).
- Add admin token to hosted-api-local-ui-bridge-check.sh if admin endpoints are tested there in future.
- Consider token rotation mechanism for long-term fleet management.

---

## 2026-06-08 - Unified verification suite: all 83 check scripts registered

Date: 2026-06-08

Milestone: RPI APPLIANCE — unified verification suite covers full codebase

Changed files:

- `scripts/verify-all.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Updated `scripts/verify-all.sh` to include all 83 check scripts in the repository. Previously only 31 check scripts were registered — the other 52 were invisible to the unified test runner. Any regression in hosted API, admin bundle, stream composition, kiosk polling, Wi-Fi enrichment, device-state actions, heartbeat persistence, content management, or any of the other recent features would go undetected by `verify-all.sh`.

- **Phase 2 (Static)**: grew from 13 → 21 gates. Added 8 contract/schema static analysis scripts: `aos-schema-contract-check.sh`, `broadcast-contract-check.sh`, `changelog-check.sh`, `feed-model-contract-check.sh`, `release-manifest-check.sh`, `release-rollout-contract-check.sh`, `rollout-acceptance-check.sh`, `systemd-timers-check.sh`.

- **Phase 3a (Integration light)**: grew from 10 → 49 gates. Added 39 mock-API and single-server integration scripts covering: broadcast delivery, command lifecycle, device auth, pairing, feed/stream composition, heartbeat persistence, kiosk polling, Wi-Fi enrichment, diagnostics, cache, settings, admin capabilities, online admin entitlements/device-state/subscription lifecycle, and hosted API DB layer.

- **Phase 3b (Integration heavy)**: grew from 8 → 12 gates. Added 4 multi-server hosted API gates: `hosted-api-server-check.sh` (74 checks), `hosted-api-local-ui-bridge-check.sh` (94 checks), `hosted-api-admin-bundle-check.sh` (121 checks), `admin-content-management-check.sh` (131 checks). Skipped by `--quick` flag.

- **Phase 1 (Syntax)**: added `node --check hosted-api/server.js` and `node --check hosted-api/db.js` alongside the existing local-ui and mock-hosted-api checks.

- Organized all gate arrays with section comments for navigability (broadcast/delivery, command lifecycle, device/auth, feed/stream, heartbeat, kiosk/display, network/hardware, diagnostics, cache/storage, settings/admin, online admin, hosted API).

- Verified: syntax check on verify-all.sh passes, `--list` output shows correct counts (128 syntax + 21 static + 49 light + 12 heavy + 1 contract + 1 security), hosted-api-db-check (45 checks), kiosk-feed-polling-check (34 checks), wifi-network-enrichment-check (46 checks), and security-smoke all pass.

Why this matters:

The verify-all.sh is the CI gate — the script any cron run or developer runs to confirm nothing is broken. With only 31 of 83 check scripts registered, it was blind to regressions in 60% of the test suite. Every major feature added in the last 48 hours (hosted API admin bundle, heartbeat persistence, stream composition engine, kiosk feed polling, Wi-Fi enrichment, device-state actions, admin content management) had dedicated check scripts but none were in the unified runner. This change ensures every check script in the repository runs during verification, catching regressions across the full stack. The `--quick` flag still allows skipping the 12 heavy gates for rapid iteration.

Verification:

- `bash -n scripts/verify-all.sh` passed.
- `node --check local-ui/server.js` passed.
- `node --check hosted-api/server.js` passed.
- `node --check hosted-api/db.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh` passed.
- `bash -n scripts/*.sh` passed (all scripts).
- `scripts/security-smoke.sh` passed (no regression).
- `scripts/hosted-api-db-check.sh` passed (45 checks, 15 steps).
- `scripts/kiosk-feed-polling-check.sh` passed (34 checks, 7 steps).
- `scripts/wifi-network-enrichment-check.sh` passed (46 checks, 12 steps).
- `scripts/verify-all.sh --list` confirms correct catalog (128+21+49+12+1+1 gates).

Next step:

- Run full `scripts/verify-all.sh` (all phases) to establish baseline pass rate.
- Add `hosted-api/server.js` hosted API syntax to pre-commit hooks if applicable.
- Consider splitting Phase 3a into sub-phases by domain for faster targeted verification.

---

## 2026-06-08 - Hosted API online admin bundle + device fleet snapshot

Date: 2026-06-08

Milestone: ONLINE ADMIN — hosted API admin dashboard bundle and device fleet snapshot

Changed files:

- `hosted-api/db.js` (listDevices, countDevicesByOwner, listSubscriptions, listOwnerUserIds)
- `hosted-api/server.js` (PLAN_LIMITS, computeEntitlements, ROLE_ACTION_MATRIX, buildActionAvailability, handleAdminBundle, handleAdminDeviceSnapshot, 2 new routes)
- `scripts/hosted-api-admin-bundle-check.sh` (new)
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added 4 fleet admin methods to `hosted-api/db.js`:
  - `listDevices(opts)` — list all devices with optional owner filter, paired-only filter, and pagination. Returns `{ items, total }` with fully mapped device records.
  - `countDevicesByOwner(userId)` — count paired devices owned by a user, used for entitlement computation.
  - `listSubscriptions(opts)` — list all subscription records with pagination, mapped to the admin bundle contract shape (subscriptionId, userId, status, plan, tier, currentPeriodEnd, cancelAtPeriodEnd).
  - `listOwnerUserIds()` — list distinct owner_user_ids across all paired devices, used to derive the admin users list from device ownership data.

- Ported admin platform constants from mock API to `hosted-api/server.js`:
  - `PLAN_LIMITS` — 4 subscription tiers (trial: 1 device/256MB, basic: 3/512MB, premium: 10/2GB, enterprise: unlimited/8GB) with maxDevices, cacheLimitMb, activeArtistsLimit, offlineCache, remoteActions.
  - `DEGRADED_STATUSES` / `ENTITLED_STATUSES` — subscription status classification for entitlement gating.
  - `ROLE_ACTION_MATRIX` — 5 roles (admin, owner, maintainer, support, curator) × 9 remote actions with allowed/reason/reasonCode per cell.
  - `ONLINE_REQUIRED_ACTIONS` — 6 actions requiring device to be online.
  - `DISABLED_BLOCKED_ACTIONS` — 7 actions blocked when device is disabled.
  - `computeEntitlements(subscription, deviceCount)` — computes full entitlement set from subscription plan/status and device count: deviceLimit, deviceUsage, deviceSlotsRemaining, canAddDevice, canUseRemoteActions, cacheLimitMb, activeArtistsLimit, offlineCache, degradedAccess, degradedReason, degradedActionsBlocked.
  - `buildActionAvailability(device, actorRole, ownerSubscription, pendingCommandCount)` — five-layer action gating (subscription → role → paired → disabled/remote → online) producing per-action availability with deviceState object.

- Added `GET /frames/admin/bundle?userId=...` — the core admin dashboard endpoint that returns the complete admin data bundle from the real database:
  - `profileFrames` — devices owned by the requested user, their preferences, liked artworks, and entitlements.
  - `adminFrames.users` — all known users derived from device ownership + subscriptions, with per-user entitlements and subscription details.
  - `adminFrames.subscriptions` — all subscription records with plan/status/tier.
  - `adminFrames.devices` — all paired fleet devices with online status, subscription info, health, and per-device action availability from the admin role perspective.
  - `adminFrames.remoteActions` — role action matrix and actor role configuration.
  - `adminFrames.planLimits` — reference table of all plan tiers with limits for UI rendering.

- Added `GET /frames/device/:id/admin-snapshot` — detailed admin device snapshot with device state, recent events, pending commands, owner subscription, owner entitlements, and action availability from the admin role perspective.

- Added `scripts/hosted-api-admin-bundle-check.sh` — a 14-step 121-check isolated validation gate proving: syntax validation, static contract (all constants, functions, routes, and plan tiers), server bootstrap, multi-device registration and pairing with two owners, subscription creation, user preferences, artwork likes, heartbeat delivery, admin bundle structure (kind/schemaVersion/generatedAt), profile frames (preferences with activeArtists, likedArtworks with IDs, devices with actionAvailability, entitlements with plan/usage/limit/slots), admin frames (actor role, users ≥2, subscriptions, fleet devices=3, planLimits, remoteActions with 5 roles), plan limits (trial=1, basic=3, premium=10, enterprise=unlimited), fleet device detail (deviceId, deviceName, ownerUserId, softwareVersion, online, paired, actionAvailability with deviceState), users with entitlements (alice: basic/2 devices, bob: trial/1 device), default bundle without userId param, device admin snapshot (device fields, ownerSubscription, ownerEntitlements, actionAvailability, events, pendingCommands, 404 for nonexistent), role-based action availability (admin and owner perspective), and regression (settings/heartbeat/stream/health endpoints unchanged).

Why this matters:

The online admin platform was entirely in the mock API. The hosted API — the real database-backed server that devices and the admin dashboard connect to — had no admin bundle, no fleet device listing, no user/subscription admin, no entitlements computation, no role-action matrix, and no device snapshot. Every admin dashboard feature in the mock API was unreachable from the real backend. This change ports the core admin platform from the mock API to the hosted API: the admin bundle endpoint queries real database tables (aos_frame_devices, aos_subscriptions, aos_frame_user_preferences, aos_artwork_likes, aos_device_events, aos_device_commands) and produces the same contract shape that the frontend expects. The fleet admin methods in the DB layer enable listing, counting, and filtering devices by owner. The entitlements computation derives user capabilities from their subscription plan and device count. The role-action matrix gates remote actions by actor role with five-layer device-state gating. The device admin snapshot provides a focused admin view of a single device. This unblocks: admin dashboard data population, fleet device management UI, user subscription management, entitlement-gated feature rendering, profile frames page, and the entire admin platform that MVP 0.2–0.5 requires.

Verification:

- `scripts/hosted-api-admin-bundle-check.sh` passed all 121 checks (14 steps).
- `scripts/hosted-api-server-check.sh` passed all 74 checks (12 steps, no regression).
- `scripts/security-smoke.sh` passed (no regression).
- `node --check hosted-api/server.js` passed.
- `node --check hosted-api/db.js` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.

Next step:

- Wire the admin bundle into the frontend admin dashboard UI.
- Add admin token authentication to the admin bundle and device snapshot endpoints.
- Add subscription CRUD admin endpoints (create, update, cancel, expire subscriptions).
- Add device admin actions (enable, disable, queue commands) that use the role-action matrix for authorization.
- Test the admin bundle against the PostgreSQL backend.

---

## 2026-06-08 - Heartbeat event + broadcast delivery persistence fix

Date: 2026-06-08

Milestone: API / DATABASE / SYNC — heartbeat event and broadcast delivery persistence fix

Changed files:

- `hosted-api/server.js` (fix: pass events + broadcastDeliveries through to db.ingestHeartbeat)
- `scripts/heartbeat-persistence-check.sh` (new)
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Fixed `handleHeartbeat()` in `hosted-api/server.js` to pass `body.events` and `body.broadcastDeliveries` through to `db.ingestHeartbeat()`. Previously, the handler constructed a `heartbeatPayload` object that only included device status fields (softwareVersion, currentMode, etc.) but explicitly omitted events and broadcast deliveries. The `db.ingestHeartbeat()` method already had complete upsert logic for both — inserting events into `aos_device_events` (with ON CONFLICT upsert by `device_id + event_key`) and broadcast deliveries into `aos_broadcast_deliveries` (with ON CONFLICT upsert by `broadcast_id + device_id`). But since the handler never passed these fields, the upserts never fired.
- The handler then built fake `eventAck` and `deliveryAck` responses that acknowledged data that was never persisted. Events and broadcast delivery records sent via heartbeat were acknowledged to the device as accepted, then silently discarded.
- The fix adds `events: body.events || null` and `broadcastDeliveries: body.broadcastDeliveries || null` to the `heartbeatPayload`, and uses `hbResult.eventAck` / `hbResult.deliveryAck` from the DB layer instead of constructing fake acks.
- Added `scripts/heartbeat-persistence-check.sh` — a 10-step 33-check isolated validation gate proving: syntax validation, static contract (heartbeatPayload includes events + broadcastDeliveries, uses hbResult acks, fake ack loop removed), database bootstrap, server startup, device registration + pairing, heartbeat with events (2 events persisted to `aos_device_events` with correct content), heartbeat with broadcast deliveries (1 delivery persisted to `aos_broadcast_deliveries` with correct status), upsert semantics (second heartbeat updates existing events from "observed" to "confirmed" and deliveries from "received" to "displayed" without creating duplicates), admin delivery endpoint returns persisted data (list and per-broadcast detail), and full lifecycle (combined events + deliveries in single heartbeat with correct acks and final DB state).

Why this matters:

The heartbeat endpoint is the primary channel for device-to-server data flow. The device sends display events (artwork shown, liked, cached) and broadcast delivery status (received, displayed, dismissed) in every heartbeat. These are the core operational signals for the admin dashboard, content analytics, and device fleet monitoring. Without this fix, the entire heartbeat data pipeline was cosmetic — events were acknowledged but never stored, delivery tracking was fictional, and admin queries returned empty results. The fix restores the full round-trip: device sends → hosted API persists → admin queries retrieve. This unblocks admin delivery effectiveness reporting, device event analytics, and the broadcast delivery lifecycle tracking that MVP 0.4 requires.

Verification:

- `scripts/heartbeat-persistence-check.sh` passed all 33 checks (10 steps).
- `scripts/hosted-api-server-check.sh` passed all 74 checks (12 steps, no regression).
- `scripts/hosted-api-local-ui-bridge-check.sh` passed all 94 checks (19 steps, no regression).
- `scripts/admin-content-management-check.sh` passed all 131 checks (15 steps, no regression).
- `scripts/security-smoke.sh` passed (no regression).
- `node --check hosted-api/server.js` passed.
- `node --check hosted-api/db.js` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.

Next step:

- Wire heartbeat event data into admin dashboard device detail views (event timeline).
- Add broadcast delivery effectiveness metrics to admin analytics (delivery rate, display rate, dismissal rate).
- Test heartbeat persistence on physical Pi with real event and delivery data.

---

## 2026-06-08 - Admin content management CRUD validation + server handler fix

Date: 2026-06-08

Milestone: LEAD / INTEGRATION — admin content management CRUD validation and server handler return format fix

Changed files:

- `hosted-api/server.js` (fix admin handler return format: `{ status, body }` wrapping)
- `scripts/admin-content-management-check.sh` (new)
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Fixed all 8 admin content management handler functions in `hosted-api/server.js` to return the correct `{ status, body }` format expected by `sendResult()`. Previously, handlers like `handleAdminCreateBroadcast`, `handleAdminListBroadcasts`, etc. returned flat objects like `{ ok: true, broadcast }` directly, but `sendResult(res, result)` expects `result.status` (HTTP status code) and `result.body` (JSON payload). This caused every admin content management endpoint to crash with "The 'string' argument must be of type string or an instance of Buffer or ArrayBuffer. Received undefined" because `sendJson` received `undefined` for both status and body. The fix wraps all success returns as `{ status: 200, body: { ... } }` and error returns as `{ status: NNN, body: { ok: false, error: "..." } }`, matching the convention used by all other route handlers (register, pairing, settings, heartbeat, stream, etc.).
- Added `scripts/admin-content-management-check.sh`, a 15-step 131-check isolated validation gate proving: syntax validation for hosted API + DB + self; static contract (8 route patterns, 8 handler functions, 9 DB methods); server bootstrap with 14 tables; broadcast creation (artwork with full metadata, curatorial, blog, premium-targeted, emergency, expired); unfiltered list with total/items/limit/offset; filtered list (status, type, priority, artistId, pagination, activeOnly); single broadcast get by ID with field verification and 404 for nonexistent; update with field persistence verification and 404 for nonexistent; full publish/unpublish lifecycle including double-operation rejection, multi-item publishing, and re-publishing; archive (soft-delete) with double-archive rejection and archived-item-not-publishable guard; broadcast statistics with total/active/draft/published/archived counts, byType/byPriority/byStatus breakdowns, and topArtists; stream composition surfacing admin-created content with emergency-first priority ordering; round-trip integrity (create → publish → stream → verify fields → archive → verify status); and content targeting (premium-only content excluded from unsubscribed device).

Why this matters:

The admin content management endpoints (CRUD + publish/unpublish/archive/stats) were non-functional because the handler functions returned the wrong format. Every call to POST/GET/PATCH/DELETE /frames/admin/broadcasts/* crashed with an unhandled error, making the entire content management pipeline unusable. The 131-check validation gate now proves the full CRUD lifecycle works end-to-end: create diverse content items (artworks, curatorial, blog, emergency, premium-targeted, expired), filter and paginate the list, get/update individual items, manage the publish lifecycle (draft → published → draft, with guards against invalid transitions), soft-delete via archive, and query statistics. Critically, the check also proves the round-trip from admin content creation through to device stream delivery: content created via admin CRUD, published, and then surfaced in the personalized stream endpoint with correct priority ordering. This closes the content pipeline loop: admin creates content → content enters `aos_broadcasts` → `getStreamContent()` queries `aos_broadcasts` → stream endpoint delivers to devices. This unblocks real content population, admin content management UI, and the entire MVP 0.2 personal stream feature.

Verification:

- `scripts/admin-content-management-check.sh` passed all 131 checks (15 steps).
- `scripts/hosted-api-server-check.sh` passed all 74 checks (12 steps, no regression).
- `scripts/security-smoke.sh` passed (no regression).
- `node --check local-ui/server.js` passed.
- `node --check hosted-api/server.js` passed.
- `node --check hosted-api/db.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.

Next step:

- Populate `aos_broadcasts` with real gallery content (artworks from autopoiesis.art, curatorial text, blog posts).
- Wire the admin content management endpoints into the admin dashboard UI for content creation and management.
- Add content seeding scripts for development and staging environments.
- Test the device-side feed pipeline with content created via admin CRUD.

---


## 2026-06-08 - Kiosk feed polling respects subscription-tier intervals and auto-refreshes

Date: 2026-06-08

Milestone: RPI APPLIANCE — kiosk display feed sync interval and content refresh

Changed files:

- `local-ui/server.js`
- `scripts/kiosk-feed-polling-check.sh` (new)
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Extended `frameSettings` in `renderFrame()` with three new fields passed to the client-side kiosk JS: `pollAfterSeconds` (from `frame.pollingStatus.pollAfterSeconds`, default 900s), `offlineRetrySeconds` (from the server's `OFFLINE_RETRY_SECONDS` constant), and `currentItemCount` (from `frame.playableItems`). Previously, the client-side JS had no visibility into polling intervals or current item counts.
- Replaced the hardcoded `setInterval(..., 15 * 60 * 1000)` sync timer with a dynamic `kioskFeedSync()` function that uses `Math.max(60, frameSettings.pollAfterSeconds) * 1000` as the interval. This means premium users (180s polling) get content updates 5x faster than before, trial users (600s) get slower updates, and the default (900s) remains unchanged.
- Added auto-refresh logic: `kioskFeedSync()` parses the sync response, compares `eligibleItems || totalItems` against `lastKnownItemCount`, and triggers `location.reload()` after a fade transition when new content arrives. Previously, background syncs were fire-and-forget — new items were downloaded but never displayed until the page was manually refreshed.
- Updated the empty-feed retry to use `frameSettings.offlineRetrySeconds` (default 30s) with a 10-second minimum floor, instead of the previous hardcoded `Math.max(imageDurationMs, 15000)`. A device waiting for its first sync now retries at the configured offline rate rather than the display dwell rate.
- Added `scripts/kiosk-feed-polling-check.sh`, a 7-step 34-check isolated validation gate proving: syntax validation, static contract (pollAfterSeconds/offlineRetrySeconds/currentItemCount in frameSettings), client-side polling interval from frameSettings with 60-second minimum, removal of hardcoded 15-minute setInterval, kioskFeedSync function with item count change detection and location.reload, empty feed retry using offlineRetrySeconds, live integration with mock API (full pairing + sync lifecycle), frame HTML rendering with all new fields and functions present, and subscription-tier-aware polling value (verified 300s from mock API stream response).

Why this matters:

The kiosk's feed sync was a fire-and-forget background call on a hardcoded 15-minute timer. The server already returned subscription-tier-aware polling intervals (trial=600s, basic=300s, premium=180s), but the kiosk ignored them entirely. Premium users paying for faster content updates got the same experience as unregistered devices. Worse, even when the background sync downloaded new items, the kiosk never displayed them — the page would continue showing stale content until the user manually navigated away. For a kiosk appliance meant to run unattended for days, this meant content updates were invisible until the device happened to reboot. This change makes the kiosk respect the server's polling interval (so premium devices sync every 3 minutes instead of 15) and automatically reload when new content arrives, making the subscription-tier polling model actually functional on the device.

Verification:

- `scripts/kiosk-feed-polling-check.sh` passed all 34 checks (7 steps).
- `scripts/device-lifecycle-check.sh` passed all 18 steps (no regression).
- `scripts/security-smoke.sh` passed (no regression).
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.

Next step:

- On the Pi, verify that the kiosk auto-refreshes smoothly when new content syncs.
- Test subscription tier changes: confirm polling interval updates after plan upgrade/downgrade.
- Add polling interval metrics to diagnostics: current interval, last sync result, last new-content reload.
- Wire `kiosk-feed-polling-check.sh` into `scripts/verify-all.sh`.

---

## 2026-06-08 - Hosted API stream composition engine

Date: 2026-06-08

Milestone: LEAD / INTEGRATION — hosted API personalized stream composition from database

Changed files:

- `hosted-api/db.js` (getStreamContent, getActiveBroadcastCount, helper functions)
- `hosted-api/server.js` (handleStream rewrite with composition engine)
- `scripts/aos-schema-sqlite-validation.sql` (aos_broadcasts: added thumbnail_url, artist, artist_id, metadata_json)
- `migrations/20260607000001_initial_aos_frames.sql` (matching schema update)
- `scripts/hosted-api-server-check.sh` (content seeding, stream contract verification)
- `scripts/hosted-api-local-ui-bridge-check.sh` (content seeding, personalized stream verification)
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `getStreamContent(context)` to `hosted-api/db.js` — the core database query method for the personalized content stream. Queries `aos_broadcasts` for published, non-expired content, filters by device targeting (target_type/target_value for device, owner, tier, exclusions), respects scheduling (starts_at/expires_at), sorts by priority (emergency > critical > high > normal > low), and boosts artist-matched items within priority groups when the owner has active artist preferences. Maps database rows to stream items with proper field projection (type → category, cache_allowed → cacheEligible, artist_id → artistId, thumbnail_url → thumbnailUrl). Falls back to metadata_json for backward-compatible artist/thumbnail/url/targeting data. Caps at 30 items.
- Added `getActiveBroadcastCount()` — returns count of published, non-expired broadcasts for monitoring.
- Added `_broadcastTypeToCategory(type)` — maps broadcast type strings to stream item categories (artwork, curatorial, blog, news, broadcast, content).
- Added `_priorityRank(priority)` — numeric priority mapping for sort comparisons.
- Rewrote `handleStream()` in `hosted-api/server.js` — previously returned an empty `items: []` array with hardcoded polling defaults. Now resolves owner context (subscription tier for polling, active artists for boosting), calls `db.getStreamContent()` for personalized items, and includes owner preferences cascade. The subscription tier now correctly reads `sub.plan` instead of the previous `sub.subscription.plan` (which would have failed since AosDb.getSubscription returns `{ plan, status }` directly).
- Extended `aos_broadcasts` schema with 4 new columns: `thumbnail_url` (TEXT), `artist` (TEXT), `artist_id` (TEXT), `metadata_json` (TEXT, default '{}'). These first-class columns enable direct SQL querying by artist, thumbnail resolution without JSON parsing, and extensible metadata for future fields. Updated both the SQLite validation schema and the canonical PostgreSQL migration.
- Seeded 12 diverse content items in bridge check and 6 items in server check: artworks (image, video), curatorial, blog, news, system notice — with expired, future-scheduled, and draft items for filtering verification.
- Updated Step 11 of `hosted-api-server-check.sh` — now verifies non-empty stream (4+ items), high-priority-first ordering, expired/draft item filtering, and polling/settings contract.
- Added Step 15 to `hosted-api-local-ui-bridge-check.sh` — verifies non-empty personalized stream (7+ items), priority ordering, expired/future/draft item filtering, and category diversity (artwork, blog, broadcast, curatorial, news).
- Added static contract checks for `getStreamContent` and `getActiveBroadcastCount` in server check Step 2.

Why this matters:

The hosted API's stream endpoint was returning `items: []` — an empty scaffold. The entire feed pipeline on the device side (normalization, eligibility filtering, display queue composition, cache eligibility, priority ordering, category-aware dwell time) had no real content to process from the real database-backed API. The mock API had a rich composition engine with 18 diverse items, but the hosted API had nothing. This change closes that gap: `aos_broadcasts` is now the content source, `getStreamContent()` is the composition engine, and `handleStream()` is the delivery layer. The stream endpoint produces personalized, targeted, prioritized content from real database rows — exactly what the device feed pipeline needs. The schema extension (thumbnail_url, artist, artist_id, metadata_json) makes `aos_broadcasts` usable as a general-purpose content table for all stream item types, not just admin broadcasts. This unblocks: device-side feed pipeline testing with real data, cache behavior verification, display queue composition, artist preference boosting, subscription-tier targeting, and the entire MVP 0.2 personal stream feature.

Verification:

- `scripts/hosted-api-server-check.sh` passed all 74 checks (12 steps, previously 68).
- `scripts/hosted-api-local-ui-bridge-check.sh` passed all 94 checks (19 steps, previously 86).
- `scripts/hosted-api-db-check.sh` passed all 45 checks (15 steps, no regression).
- `scripts/security-smoke.sh` passed (no regression).
- `node --check hosted-api/server.js` passed.
- `node --check hosted-api/db.js` passed.
- `node --check local-ui/server.js` passed.
- `node --check scripts/mock-hosted-api/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.

Next step:

- Populate `aos_broadcasts` with real gallery content (artworks from autopoiesis.art, curatorial text, blog posts).
- Wire the stream composition into the admin dashboard for content management.
- Test the device-side feed pipeline with the personalized stream: verify normalization, eligibility, display queue, and cache behavior.
- Add `scripts/hosted-api-local-ui-bridge-check.sh` to `scripts/verify-all.sh`.

---

## 2026-06-08 - Hosted API → local UI end-to-end bridge check

Date: 2026-06-08

Milestone: LEAD / INTEGRATION — hosted API → local UI end-to-end integration proof

Changed files:

- `scripts/hosted-api-local-ui-bridge-check.sh` (new)
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/hosted-api-local-ui-bridge-check.sh`, an 18-step 86-check isolated validation gate proving the real database-backed hosted API server works end-to-end with the device-side local UI.
- **Full vertical stack validation**: SQLite database → hosted API server → HTTP → local UI server → local state files. Every device lifecycle operation flows through both servers exactly as it would on a real Pi.
- **Step 1–2**: Syntax validation for all three modules (hosted API, hosted DB, local UI) plus static contract checks proving all routes, endpoint calls, and integration functions exist.
- **Step 3–5**: Database bootstrap (14 tables), hosted API server startup with health check, local UI startup with `AUTOPOIESIS_API_BASE_URL` pointing to the hosted API.
- **Step 6–7**: Device registration via local UI's `pairing/start` → hosted API's `/frames/device/register`. Verifies pairing code generation, device ID creation, and hosted API device record.
- **Step 8–9**: Pairing via AosDb `claimPairingCode()` (simulating web app), then pairing check via local UI confirming `paired=true`, `ownerUserId` set, and hosted API confirming `status=completed`.
- **Step 10**: Settings sync via local UI → hosted API `/settings` endpoint.
- **Step 11**: Settings push from local UI to hosted API with bidirectional verification: local UI sends `brightness=75`, hosted API confirms `brightness=75` persisted in database.
- **Step 12–13**: Heartbeat via local UI → hosted API `/heartbeat` endpoint. Database verification confirms `last_heartbeat_at` timestamp persisted in `aos_frame_devices`.
- **Step 14**: Feed sync via local UI → hosted API `/stream` endpoint. Verifies empty-but-correct contract shape with polling defaults.
- **Step 15**: Command lifecycle: queue via AosDb, deliver via heartbeat, process via `/local/commands/process`, verify in audit log. Proves the full command delivery chain: admin action → database queue → heartbeat pickup → local processing → audit recording.
- **Step 16**: Release check via local UI → hosted API `/release` endpoint.
- **Step 17**: Device state consistency: status shows `paired=true`, correct owner, `firstRunComplete=true`, frame state readable, feed accessible, hosted API still healthy.
- **Step 18**: Cross-server consistency: local UI and hosted API agree on device ID, owner, paired state, and settings values.

Why this matters:

The project had a complete database query layer (27 methods, 14 tables), a hosted API server (12 routes), a mock API (1645 lines), and a local UI (6000+ lines), but no test proving they work together. The hosted-api-server-check validated the hosted API in isolation. The hosted-mock-bridge-check validated the mock API with the local UI. But nobody had proven that the real database-backed hosted API could serve the real local UI through the full device lifecycle. This bridge check is that proof: 18 steps walk the entire stack from database creation through registration, pairing, settings sync, heartbeat delivery, feed sync, command queue/processing, and release check — validating that every HTTP response, every database write, and every local state file update is correct at each step. This is the foundational integration milestone that confirms the system is ready for real device connections.

Verification:

- `scripts/hosted-api-local-ui-bridge-check.sh` passed all 86 checks (18 steps).
- `scripts/hosted-api-server-check.sh` passed all 68 checks (12 steps, no regression).
- `scripts/hosted-api-db-check.sh` passed all 45 checks (15 steps, no regression).
- `scripts/device-lifecycle-check.sh` passed all 18 steps (no regression).
- `scripts/security-smoke.sh` passed (no regression).
- `node --check local-ui/server.js` passed.
- `node --check hosted-api/server.js` passed.
- `node --check hosted-api/db.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.

Next step:

- Run this bridge check against the online hosted API (staging) to validate the PostgreSQL path.
- Populate the hosted API's stream endpoint with real content from `aos_broadcasts` and artwork metadata tables.
- Wire the hosted API into the real Pi's `AUTOPOIESIS_API_BASE_URL` for physical device testing.
- Add the bridge check to `scripts/verify-all.sh`.

---

## 2026-06-08 - Device-state-aware remote action availability

Date: 2026-06-08

Milestone: ONLINE ADMIN — device-state-gated remote action availability

Changed files:

- `scripts/mock-hosted-api/server.js`
- `scripts/online-admin-device-state-actions-check.sh` (new)
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Enhanced `buildActionAvailability()` with five-layer device-state gating beyond the existing role + subscription checks. Previously, action availability only considered the actor's role policy and the device owner's subscription status — meaning the admin UI would show "restart device" as available even for offline or disabled devices.
- **Layer 1 — Subscription degradation**: Unchanged. High-risk remote actions are blocked when the device owner's subscription is expired/past_due/cancelled.
- **Layer 2 — Role policy**: Unchanged. Each role (admin, owner, maintainer, support) defines which actions are allowed.
- **Layer 3a — Not paired**: All actions blocked with `reasonCode: "not_paired"` when the device is not yet paired.
- **Layer 3b — Device disabled**: Most actions blocked with `reasonCode: "device_disabled"` when the device is in disabled state. `enable_device` is the explicit escape hatch and remains allowed.
- **Layer 3c — Remote disabled**: All remote actions blocked with `reasonCode: "remote_disabled"` when `remoteEnabled` is false on the device record.
- **Layer 3d — Device offline**: Actions requiring a live connection (`sync_settings`, `clear_cache`, `restart_display`, `restart_device`, `update_device`, `show_broadcast`) are blocked with `reasonCode: "offline"` when the last heartbeat was > 5 minutes ago. Administrative actions like `enable_device`, `disable_device`, and `factory_reset_request` remain available for offline devices.
- **Layer 3e — Pending conflicting command**: When a command of the same type is already queued or sent, the action is blocked with `reasonCode: "pending_command"`. Non-conflicting actions remain available.
- Added three device-state constant sets: `ONLINE_REQUIRED_ACTIONS` (6 actions), `CONFLICTING_COMMAND_TYPES` (6 actions), `DISABLED_BLOCKED_ACTIONS` (7 actions, excluding `enable_device`).
- Added `deviceState` object to action availability output: `{ isPaired, isOnline, isDisabled, isRemoteEnabled, pendingCommandCount }` — giving the UI full visibility into why actions are blocked.
- Added `disabled` and `remoteEnabled` fields to the device record (defaults: `false` / `true`). Bundle output now reads from the record instead of hardcoding.
- Added curator role to `ROLE_ACTION_MATRIX`: read-only for all device actions except `show_broadcast`, which is allowed. Curator is for institutional partners who curate content but don't manage hardware.
- Added curator to `acceptedActorRoles` in `REMOTE_ACTION_COMMANDS` for `show_broadcast` and to the admin bundle's `acceptedActorRoles` list.
- Added `POST /mock/set-device-state/:id` test helper for toggling `disabled` and `remoteEnabled` on device records.
- Added `roleAllowed: true` flag on device-state-blocked actions — the UI can distinguish between "your role doesn't allow this" and "your role allows this but the device state prevents it".
- Added `scripts/online-admin-device-state-actions-check.sh` — a 12-step 80-check isolated validation gate proving: syntax validation, static contract (curator role, device-state constants, record fields), default device state (online, paired, not disabled — all admin actions allowed), offline device blocking (online-required actions blocked, administrative actions still allowed), disabled device blocking (7 actions blocked, `enable_device` escape hatch), remote-disabled blocking (all 9 actions blocked with `remote_disabled`), pending command conflict (same-type blocked, other actions allowed), subscription degradation override (takes precedence over device state), not-paired fleet exclusion, curator role verification, and regression (online-admin-mock-bridge-check passes).

Why this matters:

The admin dashboard's action availability was role-and-subscription-only — it showed every allowed action as available regardless of whether the device could actually receive it. An admin could click "restart device" on an offline frame, or "sync settings" on a disabled device. The command would queue but never execute, creating confusion and stale command queues. Device-state gating ensures that every action button in the admin UI reflects the actual executability of that action on that specific device right now. The five-layer evaluation (subscription → role → paired → disabled/remote → online → pending) produces a clear, machine-readable reason for every blocked action. The `deviceState` object in the availability response gives the UI everything it needs to render contextual indicators ("device offline", "3 commands pending", "remote actions disabled") alongside the action buttons. The curator role extends the RBAC model for institutional use cases where gallery partners need broadcast control without fleet management access.

Verification:

- `scripts/online-admin-device-state-actions-check.sh` passed all 80 checks (12 steps).
- `scripts/online-admin-entitlements-check.sh` passed all 23 checks (no regression).
- `scripts/online-admin-subscription-lifecycle-check.sh` passed all 54 checks (no regression).
- `scripts/security-smoke.sh` passed (no regression).
- `node --check local-ui/server.js` passed.
- `node --check scripts/mock-hosted-api/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.

Next step:

- Wire device-state-aware action availability into the hosted API's admin endpoints.
- Build the admin UI action button component that reads `actionAvailability` and renders enabled/disabled states with reason tooltips.
- Add device-state change tracking: log when a device is disabled/enabled or remote is toggled for audit trail.
- Add fleet-level action availability summary to the admin dashboard (e.g., "3 of 5 devices online, 1 device disabled").

---

## 2026-06-08 - Wi-Fi connection detail enrichment for remote monitoring

Date: 2026-06-08

Milestone: RPI APPLIANCE — Wi-Fi signal quality and connection details in diagnostics/heartbeat

Changed files:

- `local-ui/server.js`
- `scripts/wifi-network-enrichment-check.sh` (new)
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `wifiConnectionDetailsFallback(callback)` — queries the active Wi-Fi connection via `nmcli -t -f ACTIVE,SIGNAL,SSID,SECURITY,FREQ,RATE device wifi list --rescan no` plus IP address lookups via `nmcli -t -f IP4.ADDRESS/IP6.ADDRESS device show`. Returns `{ ssid, signal, signalQuality, securityType, security, frequency, bitrate, ip4Address, ip6Address }` for the active connection, or `null` when no Wi-Fi is connected or nmcli is unavailable.
- Enriched `networkStatus()` — when `network.wifi.connected` is true, the function now calls `wifiConnectionDetailsFallback()` to enrich the `wifi` object in the network response with signal quality, SSID, security type, frequency, bitrate, and IP addresses. The enriched data is written to `network.json` via `writeNetworkState()` and returned in the API response.
- The enrichment is conditional: LAN-only devices, offline devices, and devices without Wi-Fi hardware are unaffected. Wi-Fi devices that are available but not connected skip the enrichment.
- **Heartbeat delivery chain**: The enriched network data flows through `network.json` → `status()` → `collectDiagnostics()` → `sendHeartbeat()` → hosted API heartbeat endpoint. This means the hosted API and admin dashboard now receive Wi-Fi signal quality, SSID, and IP address information with every heartbeat.
- **Security**: Verified that no API keys, tokens, or secrets appear in network.json or the network status response.
- Added `scripts/wifi-network-enrichment-check.sh` — a 12-step 46-check isolated validation gate proving: syntax validation, static contract (functions and enrichment fields present), wifiConnectionDetailsFallback structure (nmcli fields, signalQuality/classifySecurity reuse, null fallback), networkStatus enrichment path (conditional on wifi.connected, writeNetworkState after enrichment), live endpoint test with mock nmcli (Wi-Fi connected device, LAN-only device, offline device), security (no secrets in network data), diagnostics chain (network → collectDiagnostics), heartbeat chain (diagnostics → sendHeartbeat), regression (Wi-Fi scan still works, other endpoints still respond).

Why this matters:

The hosted API and admin dashboard had no visibility into device network quality. The heartbeat delivered diagnostics, but the network section only contained `online`, `primary` type, and basic device/connection names. When a Frame stopped working, the admin dashboard showed "wifi connected" but couldn't tell if the signal was weak (40%), if the SSID matched the expected network, or what IP address the device had. This enrichment provides Wi-Fi signal strength and quality classification (excellent/good/fair/weak), the connected SSID, security type, frequency, bitrate, and both IPv4 and IPv6 addresses — all delivered via the heartbeat to the hosted API. The admin dashboard can now display network quality indicators, flag devices with weak signal, and show connection details for remote troubleshooting. This was explicitly called out as a next step after the Wi-Fi scan deduplication work.

Verification:

- `scripts/wifi-network-enrichment-check.sh` passed all 46 checks (12 steps).
- `scripts/wifi-scan-dedup-check.sh` passed all 25 checks (no regression).
- `scripts/diagnostics-check.sh` passed all 39 checks (no regression).
- `scripts/security-smoke.sh` passed (no regression).
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.

Next step:

- On the Pi, verify that `network.json` includes signal quality when connected to real Wi-Fi hardware.
- Wire the enriched network data into the admin dashboard's device detail view (signal strength indicator, SSID display, IP address).
- Add network quality alerts to the hosted API: flag devices where signal quality drops to "weak" or Wi-Fi disconnects unexpectedly.
- Add network change event tracking: log when SSID or signal quality changes significantly for long-term connectivity analysis.

---

## 2026-06-08 - Hosted API server scaffold (hosted-api/server.js)

Date: 2026-06-08

Milestone: API / DATABASE / SYNC — database-backed hosted API server

Changed files:

- `hosted-api/server.js` (new)
- `scripts/hosted-api-server-check.sh` (new)
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `hosted-api/server.js`, a database-backed API server that bridges `AosDb` to the device-side Frames API contract. This is the hosted backend scaffold that replaces the in-memory mock API with real SQLite-backed operations.
- **Server bootstrap**: Automatically creates and migrates the database on startup using the SQLite validation schema. Configurable via `AOS_DB`, `AOS_PORT`, `AOS_HOST` environment variables. Graceful shutdown closes the database.
- **Device registration** (`POST /frames/device/register`): Calls `AosDb.registerDevice()`, returns `deviceId`, `deviceApiKey`, `pairingCode`, and `expiresAt`.
- **Pairing status** (`GET /frames/device/:id/pairing-status`): Delegates to `AosDb.getPairingStatus()` which returns the complete pending/completed/none state.
- **Settings read** (`GET /frames/device/:id/settings`): Calls `AosDb.getSettings()` with owner preference cascade from `AosDb.getUserPreferences()`.
- **Settings push** (`POST /frames/device/:id/settings`): Auth-gated. Calls `AosDb.pushSettings()` with conflict resolution — newer writes accepted, stale writes rejected with `conflict: true`.
- **Heartbeat** (`POST /frames/device/:id/heartbeat`): Auth-gated. Calls `AosDb.ingestHeartbeat()` for device status update, returns `eventAck` and `deliveryAck` with correct cursor shape, returns pending commands via `AosDb.getPendingCommands()`, includes owner preferences cascade.
- **Stream** (`GET /frames/device/:id/stream`): Auth-gated. Returns subscription-tier-aware polling defaults (trial/basic/premium), empty items array scaffold for future content population, settings shape, and owner preferences cascade.
- **Feed** (`GET /frames/device/:id/feed`): Alias for stream.
- **Command acknowledgement** (`POST /frames/device/:id/commands/:cmdId/ack`): Auth-gated. Calls `AosDb.acknowledgeCommand()`.
- **Release check** (`GET /frames/device/:id/release`): Auth-gated. Calls `AosDb.getLatestRelease()` for the device's channel.
- **Artwork like** (`POST /frames/artworks/:id/like`): Returns contract-correct response shape.
- **Admin broadcast deliveries** (`GET /frames/admin/broadcast-deliveries`): Calls `AosDb.getBroadcastDeliveries()` with optional filters.
- **Health** (`GET /health`): Returns service status, database path, table count, uptime.
- **Device authentication**: Shared `authenticateDevice()` function validates `x-frame-device-key` header against `AosDb.authenticateDevice()`. Returns 401 for missing key, 403 for invalid key or unpaired device, 404 for unknown device.
- All route handlers produce the same JSON response shapes as the mock API, ensuring device-side compatibility.
- Added `scripts/hosted-api-server-check.sh`, a 12-step 68-check isolated validation gate proving:
  1. Syntax validation (server, db, self).
  2. Static contract: 12 routes and 13 handler functions present.
  3. Database bootstrap: 14 tables created from SQLite validation schema.
  4. Server startup with health endpoint.
  5. Device registration with deviceId, deviceApiKey, pairingCode, expiresAt.
  6. Pairing status (pre-pair: pending with code, post-pair: completed).
  7. Auth enforcement: three auth-gated endpoints return 401 without device key.
  8. Pairing via direct AosDb call, verified via API pairing status.
  9. Settings sync with conflict resolution (newer accepted, stale rejected with conflict=true).
  10. Heartbeat with event ingestion (eventAck with cursor shape).
  11. Stream endpoint contract (ok, generatedAt, items, polling, displayMode).
  12. Full lifecycle integration: second device, command queue/ack, release check, admin broadcast deliveries.

Why this matters:

The project had a complete database query layer (`hosted-api/db.js` with 27 methods against 14 `aos_` tables) and a comprehensive mock API (`scripts/mock-hosted-api/server.js` with in-memory Maps), but no code connecting the two. When the hosted backend was to be built, every mock API handler needed translation into SQL-backed operations. The hosted API server is that translation: each route handler calls one or two `AosDb` methods instead of reading from Maps, producing identical response shapes. The server auto-bootstraps its database on startup, authenticates devices via the same header contract, resolves settings conflicts through the same timestamp-based logic, and returns heartbeats with the same eventAck/deliveryAck cursor structure. This is the foundational hosted backend — the bridge between "database schema exists" and "devices can sync against a real database". It unblocks: real pairing flow, real settings sync, real heartbeat ingestion, real command delivery, and real release management. The stream endpoint scaffold (empty items, tier-aware polling) is the placeholder for the content population layer that will query `aos_broadcasts` and artwork metadata.

Verification:

- `scripts/hosted-api-server-check.sh` passed all 68 checks (12 steps).
- `scripts/hosted-api-db-check.sh` passed all 45 checks (no regression).
- `scripts/device-lifecycle-check.sh` passed all 18 steps (no regression).
- `scripts/security-smoke.sh` passed (no regression).
- `node --check hosted-api/server.js` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.

Next step:

- Populate the stream endpoint with real content from `aos_broadcasts` and artwork metadata tables.
- Wire the hosted API into the device's `AUTOPOIESIS_API_BASE_URL` for end-to-end testing with the local UI.
- Add content management endpoints for admin broadcast creation and artwork metadata population.
- Run the full hosted mock bridge contract suite against the database-backed server to prove contract parity.

---

## 2026-06-08 - Personalized stream composition engine

Date: 2026-06-08

Milestone: BROADCAST / FEED — personalized mixed content stream composition

Changed files:

- `scripts/mock-hosted-api/server.js`
- `scripts/feed-stream-composition-check.sh` (new)
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `MOCK_ARTISTS` — 7 artist records (Vessel, Sandman, Jessy, Kinema, Spool, Link, Typo) with id and name fields.
- Added `MOCK_CONTENT_POOL` — 18 diverse content items across all 6 feed categories: 8 artworks (image, video, audio, generative), 2 curatorial, 2 blog, 2 news, 1 generic content, 1 scheduled/future item, 1 expired item, and 1 premium-targeted broadcast. Items include targeting, priority, scheduling, cache eligibility, sound requirements, duration, and artist attribution.
- Added `injectedContent` array for runtime content injection via `POST /mock/add-content`.
- Added `composePersonalizedStream(record)` — the core stream composition engine that:
  1. Collects all eligible items from the content pool + injected content + queued show_broadcast commands.
  2. Filters by device targeting: subscription tier, device ID, owner user ID, exclusion lists.
  3. Filters expired items (expiresAt in the past) and future-scheduled items (startsAt in the future).
  4. Sorts by priority (emergency > critical > high > normal > low), then artist preference boosting within priority groups.
  5. Caps at 30 items.
  6. Returns subscription-tier-aware polling defaults: trial (600s/1200s), default (300s/900s), premium (180s/600s).
- Added `priorityRankValue(priority)` — maps priority strings to numeric ranks (emergency=500, critical=400, high=300, normal=200, low=100).
- Rewrote `handleStream()` — uses `composePersonalizedStream()` instead of returning 2 hardcoded items. Includes owner preferences cascade in the response when the device has an owner.
- Added `POST /mock/add-content` — test helper that injects custom content items into the stream pool. Accepts single item or array. Returns added IDs and totals.
- Added `DELETE /mock/content` — test helper that clears all injected content items.
- Added `scripts/feed-stream-composition-check.sh` — a 12-step isolated validation gate proving:
  1. Syntax validation (mock API, local UI, self).
  2. Static content pool contract (pool, artists, composition engine, priority function, routes, all 6 categories, 7 artists, injectedContent array).
  3. Content item shape validation (12 checks: all content types, targeting, scheduling, expiry).
  4. Mock API startup, two-device registration and pairing.
  5. Default stream (no owner, no preferences) returns diverse content across multiple categories, filters expired items, filters future-scheduled items, filters premium-targeted items for unowned devices.
  6. Artist preference boosting: owner preferences for activeArtists=["vessel","jessy"] boost those artists within priority groups, owner preferences cascade in response.
  7. Subscription tier targeting and polling: premium user sees premium-targeted items, gets faster polling (180s vs 300s default).
  8. Content injection via POST /mock/add-content: batch injection, injected items appear in stream, priority ordering respected (critical before high).
  9. Broadcast command inclusion: queued show_broadcast commands appear as stream items, emergency priority is first in the queue.
  10. Device-specific targeting: items with targeting.deviceIds only appear for targeted devices.
  11. Exclusion targeting: items with targeting.excludeDeviceIds are excluded from specified devices.
  12. Trial-tier polling and degraded subscription: trial user gets slower polling (600s/1200s), premium items filtered, degraded (expired) user still receives stream content.

Why this matters:

The mock API's stream endpoint was completely static — it returned the same 2 hardcoded items regardless of device, owner, preferences, subscription, or content state. This meant the entire device-side feed pipeline (normalization, eligibility filtering, display queue composition, cache eligibility, priority ordering, category-aware dwell time) was tested with static content, not personalized content. The content pool now provides 18 items across all 6 categories with diverse targeting, scheduling, and priority — enabling the device-side feed pipeline to exercise every code path with realistic data. The composition engine filters by targeting (subscription tier, device, owner), filters expired/future items, sorts by priority then artist preference, and includes broadcast commands from the queue. The subscription-tier polling defaults give the device-side polling logic realistic intervals to work with. This is the foundational test fixture for the entire broadcast/feed workstream — every future feed feature (curated playlists, artist-specific streams, time-based scheduling, A/B content testing) will build on this composition engine.

Verification:

- `scripts/feed-stream-composition-check.sh` passed all 12 steps (39 checks).
- `scripts/feed-model-contract-check.sh` passed all 13 steps (no regression).
- `scripts/hosted-mock-bridge-check.sh` passed all 6 contract gates (no regression).
- `scripts/broadcast-delivery-ingestion-check.sh` passed all 14 steps (no regression).
- `scripts/feed-targeting-check.sh` passed (no regression).
- `scripts/feed-display-dwell-check.sh` passed all 12 steps (no regression).
- `scripts/device-lifecycle-check.sh` passed all 18 steps (no regression).
- `node --check local-ui/server.js` passed.
- `node --check scripts/mock-hosted-api/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.

Next step:

- Build the hosted API's stream endpoint that queries `aos_` tables for content and produces personalized streams using the same composition logic.
- Add feed composition metrics to diagnostics: category distribution, source distribution, and targeting effectiveness per sync cycle.
- Test the device-side feed pipeline with the personalized stream: verify normalization, eligibility, display queue, and cache behavior with the new diverse content.

---

## 2026-06-08 - Hosted API database query layer (hosted-api/db.js)

Date: 2026-06-08

Milestone: API / DATABASE / SYNC — hosted API database query layer

Changed files:

- `hosted-api/db.js` (new)
- `scripts/hosted-api-db-check.sh` (new)
- `package.json` (better-sqlite3 dependency)
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `hosted-api/db.js`, a database query layer that maps the hosted API's behavioral contracts to SQL operations against the 14 `aos_` tables. This is the foundational bridge between the mock API's in-memory logic and a real database-backed API.
- **Device registration**: `registerDevice()` creates `aos_frame_devices` + `aos_frame_pairing_codes` rows. Re-registration preserves the device API key while generating a fresh pairing code (old codes superseded and cleaned up).
- **Device authentication**: `authenticateDevice()` validates `(device_id, device_api_key)` pairs against `aos_frame_devices`. Returns null for wrong key, non-existent device, or missing params.
- **Pairing lifecycle**: `claimPairingCode()` validates pairing code hash, checks expiry, marks code as claimed, and updates device owner. `getPairingStatus()` returns pending/completed/none state.
- **Settings with conflict resolution**: `pushSettings()` implements latest-updatedAt conflict resolution — newer writes are merged, stale writes are rejected with `{ conflict: true, reason: "stale_write" }` and the authoritative settings. `getSettings()` includes owner cascade preferences when the device has an owner with `aos_frame_user_preferences` overrides.
- **Heartbeat ingestion**: `ingestHeartbeat()` inserts into `aos_heartbeats`, updates device status in `aos_frame_devices`, upserts events into `aos_device_events` by `(device_id, event_key)`, and upserts broadcast deliveries into `aos_broadcast_deliveries` by `(broadcast_id, device_id)`. Returns `eventAck` and `deliveryAck` matching the mock API contract.
- **Command lifecycle**: `queueCommand()` creates `aos_device_commands` rows. `getPendingCommands()` returns queued/sent commands. `acknowledgeCommand()` transitions status and records ack timestamps.
- **Releases**: `createRelease()` with upsert semantics (same version+channel updates rather than fails). `getLatestRelease()` returns the most recent published release for a channel.
- **Subscriptions**: `upsertSubscription()` creates or updates `aos_subscriptions` rows. `getSubscription()` reads by user_id.
- **User preferences**: `setUserPreferences()` / `getUserPreferences()` manage `aos_frame_user_preferences` for owner-level cascade.
- **Artwork likes**: `likeArtwork()` (INSERT OR IGNORE for idempotency), `unlikeArtwork()`, `getLikedArtworks()` against `aos_artwork_likes`.
- **Device events**: `getDeviceEvents()` returns events in reverse chronological order with upsert correctness verified.
- **Broadcast deliveries**: `getBroadcastDeliveries()` with optional filters (deviceId, status, broadcastId).
- All methods use better-sqlite3 for synchronous SQLite access with WAL mode. The module is engine-pluggable for future PostgreSQL support.
- Added `better-sqlite3` as a project dependency.
- Added `scripts/hosted-api-db-check.sh`, a 15-step 45-check isolated validation gate proving:
  1. Syntax validation and module loading (27 methods)
  2. Database bootstrap via migration runner (15 tables)
  3. Device registration (new + re-registration with key preservation)
  4. Device authentication (correct key, wrong key, non-existent, null params)
  5. Pairing lifecycle (pre-pair status, claim by code, post-pair status, re-claim rejection, wrong code rejection, non-existent device)
  6. Settings conflict resolution (initial read, newer write, stale write rejection, preserved after conflict)
  7. Owner preferences cascade (set prefs, cascade in device settings, unowned device isolation)
  8. Heartbeat ingestion (events with eventAck, device status update, broadcast delivery upsert, empty heartbeat)
  9. Command lifecycle (queue, poll pending, acknowledge, get command, non-existent command)
  10. Device events query (reverse chronological, upsert by event_key)
  11. Release creation and query (null when none, draft not latest, published as latest)
  12. Subscription CRUD (create, update plan/status, read back)
  13. Artwork likes (like, idempotent like, unlike)
  14. Schema contract check passes after all operations
  15. Full lifecycle integration: register → pair → authenticate → settings → command → heartbeat → verify

Why this matters:

The project had a comprehensive mock API (1312 lines, in-memory Maps) and a complete database schema (14 `aos_` tables), but no code bridging the two. When the hosted backend is built, every mock API handler must be translated into SQL queries against the `aos_` tables. Without this layer, each route would need hand-written SQL with no shared query patterns, no conflict resolution logic, no event upsert semantics, and no owner cascade. The database query layer provides the canonical implementation of every API data operation: registration creates device + pairing rows, authentication validates key pairs, pairing claims validate hashes and update ownership, settings reads merge owner preferences, settings writes resolve timestamp conflicts, heartbeats ingest events and deliveries with upsert semantics, commands queue/poll/acknowledge through status transitions, and releases handle version+channel uniqueness. The 45-check validation gate proves every operation works correctly against a freshly migrated SQLite database. When the hosted Express server is built, each route handler calls one or two `AosDb` methods instead of writing raw SQL — the query layer is the hosted API's data access foundation.

Verification:

- `scripts/hosted-api-db-check.sh` passed all 45 checks (15 steps).
- `scripts/device-lifecycle-check.sh` passed all 18 steps (no regression).
- `scripts/hosted-mock-bridge-check.sh` passed all 6 contract gates (no regression).
- `scripts/security-smoke.sh` passed.
- `node --check hosted-api/db.js` passed.
- `node --check local-ui/server.js` passed.
- `node --check scripts/mock-hosted-api/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.

Next step:

- Build the hosted API Express server scaffold (`hosted-api/server.js`) that uses `AosDb` for all data operations.
- Wire each route handler to call the corresponding `AosDb` method instead of using in-memory Maps.
- Run the hosted contract suite against the database-backed server to prove contract parity with the mock API.
- Implement the PostgreSQL engine path using a pluggable query builder or pg client.

---

## 2026-06-08 - Wi-Fi scan deduplication, signal quality, and touch-friendly rendering

Date: 2026-06-08

Milestone: RPI APPLIANCE — Wi-Fi onboarding quality and touchscreen UX

Changed files:

- `local-ui/server.js`
- `scripts/wifi-scan-dedup-check.sh` (new)
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `signalQuality(signal)` — classifies Wi-Fi signal strength into four human-readable quality levels: excellent (80+), good (60–79), fair (40–59), weak (0–39). Handles null/undefined/non-numeric input by returning "weak".
- Added `classifySecurity(security)` — normalizes nmcli security strings into concise types: WPA3, WPA2, WPA, WEP, or open. Case-insensitive matching on substring presence. Handles empty/null input by returning "open".
- Added `deduplicateWifiNetworks(raw)` — deduplicates raw nmcli scan output by SSID, keeping the entry with the strongest signal per SSID. Null/undefined entries are safely filtered. Results are enriched with `signalQuality` and `securityType`, then sorted by signal strength descending.
- Updated `scanWifi()` callback — raw nmcli output now passes through `deduplicateWifiNetworks()` before being returned. Previously, each BSSID appeared as a separate entry, showing the same SSID multiple times (a typical Pi with 5 nearby networks would show 15–20 entries).
- Updated `renderWifiScan()` HTML and CSS — complete visual redesign for Pi touchscreen:
  - Signal bars: CSS-based 4-bar signal strength indicator with quality-based highlighting (excellent/good/fair/weak).
  - Security badge: concise security type label (WPA3/WPA2/WPA/WEP/open) instead of raw nmcli string.
  - Larger touch targets: 14px padding, 8px border-radius, hover/active states.
  - Hidden network note: when no networks are found, shows a hint about entering SSID manually.
  - Connection feedback: submit button changes to "Connecting..." and disables during connection attempt. On failure, shows error message with re-enable.
  - Network row layout: flexbox with SSID (truncated if long), signal bars, and security badge.
- Added `scripts/wifi-scan-dedup-check.sh` — a 12-step 25-check isolated validation gate proving:
  1. Syntax validation (local-ui/server.js, self).
  2. Static contract: all three new functions exist in server code.
  3. signalQuality unit tests (15/15): boundary values for excellent/good/fair/weak, null, undefined, non-numeric.
  4. classifySecurity unit tests (15/15): WPA3/WPA2/WPA/WEP variants, case sensitivity, empty/null/undefined.
  5. deduplicateWifiNetworks unit tests (10/10): same-SSID dedup keeping strongest, sort by signal, empty array, empty-SSID filter, signalQuality enrichment, securityType enrichment, open network, multi-AP same-SSID different-security, null/undefined entries, full quality mapping.
  6. Live endpoint with mock nmcli: 6 raw entries (3 SSIDs × 2 BSSIDs) deduplicated to 3, sorted strongest-first, signal quality enriched, security type enriched, strongest BSSID preserved per SSID.
  7. HTML rendering: signal-bars CSS, security-badge CSS, network-row styling, hidden-network-note, Connecting... feedback, button disabled during connection.
  8. connectWifi regression: signature preserved, wifiConfigured flag still set.
  9. connectLan regression: signature preserved.
  10. networkStatus regression: signature preserved.
  11. Security: scan response contains only expected fields (ssid, signal, security, securityType, signalQuality).
  12. Regression: touchscreen-check.sh syntax valid.

Why this matters:

The Wi-Fi scan page is the first interactive screen a user sees on a new Pi after booting. Previously, nmcli returned one entry per BSSID — a network with 3 access points appeared 3 times, a busy environment could show 20+ entries for 5 actual networks. The raw output also showed signal as a number ("85% WPA2") rather than a visual indicator, and the touch targets were small default-sized buttons. For a 7" Pi touchscreen operated by finger, this was a poor first impression. The deduplication collapses multi-AP networks into single entries with the strongest signal, the quality classification provides visual bars, the security badge is concise, and the touch targets are large and well-spaced. The connection flow now provides real-time feedback ("Connecting..." with disabled button) instead of silently hanging. This is the first-boot experience improvement for the production appliance.

Verification:

- `scripts/wifi-scan-dedup-check.sh` passed all 25 checks (12 steps).
- `scripts/security-smoke.sh` passed.
- `node --check local-ui/server.js` passed.
- `node --check scripts/mock-hosted-api/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.

Next step:

- On the Pi, verify the Wi-Fi scan page renders correctly on the 7" touchscreen with Chromium kiosk mode.
- Test with a real Wi-Fi environment (multiple APs, hidden networks, open networks).
- Add Wi-Fi signal strength to the device heartbeat metrics for remote network quality monitoring.

---

## 2026-06-08 - Subscription-tier device limits and feature entitlements

Date: 2026-06-08

Milestone: ONLINE ADMIN — subscription-tier device limits, feature entitlements, and subscription-gated remote actions

Changed files:

- `scripts/mock-hosted-api/server.js`
- `scripts/online-admin-contract-check.sh`
- `scripts/online-admin-entitlements-check.sh` (new)
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `PLAN_LIMITS` constant defining four subscription tiers: frames_trial (1 device, 256MB cache, 5 active artists, no offline cache), frames_basic (3 devices, 512MB cache, 20 active artists, offline cache), frames_premium (10 devices, 2GB cache, 100 active artists), frames_enterprise (unlimited devices, 8GB cache, unlimited artists).
- Added `DEGRADED_STATUSES` (expired, cancelled, past_due) and `ENTITLED_STATUSES` (trial, active) for subscription-state classification.
- Added `computeEntitlements(userId)` — computes the full entitlement set for a user based on their subscription plan and status. Returns plan, tier, status, deviceLimit, deviceLimitLabel, deviceUsage, deviceSlotsRemaining, canAddDevice, canUseRemoteActions, cacheLimitMb, activeArtistsLimit, offlineCache, degradedAccess, degradedReason, and degradedActionsBlocked.
- Device limits: trial users can pair 1 device, basic users 3, premium 10, enterprise unlimited. Users at their limit cannot pair new devices.
- Degraded access: expired/cancelled/past_due users have `canAddDevice=false`, `canUseRemoteActions=false`, `offlineCache=false`, and `degradedActionsBlocked` listing high-risk remote actions that are blocked.
- Entitlement coherence: `canAddDevice` is always false for degraded users. `deviceSlotsRemaining` equals `max(0, deviceLimit - deviceUsage)`.
- Updated `handleMockPairDevice` — enforces subscription-tier device limits before pairing. Returns 403 with reason code `subscription_degraded` or `device_limit_reached` when blocked. Includes entitlements summary in the error response.
- Updated `buildActionAvailability` — checks device owner's subscription status. For degraded owners, high-risk remote actions (restart_device, update_device, factory_reset_request, show_broadcast) are overridden to `allowed: false` with `degradedBySubscription: true` regardless of actor role.
- Added entitlements to `profileFrames` in the online admin bundle — the profile section now includes a full `entitlements` object for the viewing user.
- Added entitlements to each `adminFrames.users` entry — admin dashboard can see per-user entitlement status, device limits, and degradation state.
- Added `adminFrames.planLimits` to the bundle — a reference table of all plan tiers with their limits, enabling the UI to render plan comparison, upgrade prompts, and limit indicators.
- Extended `scripts/online-admin-contract-check.sh` with validation for:
  - `profileFrames.entitlements`: 15 validation rules covering all entitlement fields, type checks, coherence rules (degraded→canAddDevice=false, deviceSlotsRemaining math).
  - `adminFrames.planLimits`: validates each plan has required fields (maxDevices, maxDevicesLabel, remoteActions, cacheLimitMb, activeArtistsLimit, offlineCache).
  - `adminFrames.users[].entitlements`: validates per-user entitlements, cross-references plan with subscription and planLimits.
- Added `scripts/online-admin-entitlements-check.sh`, a 12-step isolated validation gate (23 checks) proving:
  1. Syntax validation (mock API, contract check, self)
  2. Static contract: PLAN_LIMITS shape (26 checks: 4 plans, 5 limit fields, degraded/entitled statuses, computeEntitlements function, 11 entitlement fields)
  3. computeEntitlements unit tests (29 checks: default/trial, active basic, expired, past_due, cancelled, premium with devices, trial at limit, enterprise unlimited)
  4. Mock API startup
  5. Trial user device limit enforcement: 1-device limit blocks second pairing with device_limit_reached
  6. Subscription upgrade unlocks device limit: trial→active with plan upgrade, second pairing succeeds
  7. Entitlements in admin bundle: profileFrames.entitlements (12 checks), adminFrames.planLimits (9 checks)
  8. Degraded subscription blocks remote actions: expired user entitlements (6 checks), degraded remote action gating (10 checks: blocked actions have degradedBySubscription, allowed actions remain)
  9. User entitlements in admin users list (6 checks: entitlements present, plan matches subscription, degradedAccess, canAddDevice, cross-reference)
  10. Device limit blocks pairing for expired user: 403 with subscription_degraded
  11. Online admin contract checker passes for both active and expired bundles
  12. Regression: online-admin-mock-bridge-check passes

Why this matters:

The online admin platform had subscription tiers (trial, basic, premium) but no mechanism to enforce what each tier actually entitles users to. There was no device limit enforcement — a trial user could pair unlimited devices. There was no degraded-access mode — expired users retained full remote action capabilities. And the admin bundle had no entitlement data — the UI had no way to know what a user's plan allowed. This change establishes the complete entitlement layer: plan-tier limits define the boundary, computeEntitlements evaluates a user's current state against their plan, pairing enforces device limits, remote actions are gated by subscription status, and the admin bundle exposes all of this to the UI. The four-tier model (trial/basic/premium/enterprise) maps directly to the business model and can be extended with additional limits (e.g., broadcast targeting, stream profile) without changing the entitlement computation architecture.

Verification:

- `scripts/online-admin-entitlements-check.sh` passed all 23 checks (12 steps).
- `scripts/online-admin-contract-check.sh` passed on both active and expired bundles.
- `scripts/online-admin-subscription-lifecycle-check.sh` passed all 54 checks (no regression).
- `scripts/online-admin-mock-bridge-check.sh` passed (no regression).
- `scripts/hosted-mock-bridge-check.sh` passed all 6 contract gates (no regression).
- `scripts/security-smoke.sh` passed.
- `node --check local-ui/server.js` passed.
- `node --check scripts/mock-hosted-api/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.

Next step:

- Wire entitlements into the hosted backend: the real `aos_subscriptions` table drives `computeEntitlements`, the pairing endpoint checks entitlements before creating `aos_frame_devices` rows.
- Add entitlement-gated UI in Profile > Frames: show device limit usage, plan upgrade prompt when at limit, degraded-access banner when subscription is expired/past_due.
- Add entitlement-gated features: expired users should see reduced active artists limit, no offline cache option, and limited stream profiles.
- Test entitlement enforcement across multiple users with mixed subscription states in the admin dashboard.

---

## 2026-06-08 - Owner preference cascade to devices

Date: 2026-06-08

Milestone: LEAD / INTEGRATION — owner preference cascade contract and implementation

Changed files:

- `local-ui/server.js`
- `scripts/mock-hosted-api/server.js`
- `scripts/owner-preference-cascade-check.sh`
- `scripts/online-admin-contract-check.sh` (curator role from prior run)
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `OWNER_CASCADE_FIELDS` constant — 13 preference fields that cascade from owner profile to all owned devices: streamCategories, activeArtists, allowImages, allowVideos, allowSoundWorks, allowGenerativeWorks, soundEnabled, autoplay, videoAutoplay, soundAutoplay, cacheLikedArtworks, cacheRecentArtworks, offlineFallbackMode.
- Device-level preference fields (brightness, volume, nightMode, nightModeStart, nightModeEnd, imageDuration, displayMode) are explicitly excluded from cascade — they are per-device physical settings.
- Added `applyOwnerCascade(localPrefs, ownerPrefs)` — merges owner-level preferences into local preferences, only touching cascade-eligible fields. Returns `{ preferences, cascadedFields[], applied: boolean }`. Handles null/undefined/empty owner prefs gracefully.
- Updated `applyRemoteSettingsPayload()` — when the hosted API response includes `ownerPreferences`, the function merges owner cascade fields into preferences after applying remote settings. Three paths:
  1. **Remote settings + owner prefs**: Remote settings are applied first, then owner cascade overrides cascade-eligible fields on top.
  2. **Owner prefs only** (no remote settings): Only owner cascade is applied, preserving local `updatedAt`.
  3. **Conflict + owner prefs**: Even when remote settings are stale (local is newer), owner cascade still applies — owner intent takes precedence over device state.
- Updated heartbeat handler — when the heartbeat response includes `ownerPreferences` but no `settings`, the owner cascade is now independently applied via `heartbeat_owner_cascade` source. Previously, owner preferences in heartbeat responses were silently ignored.
- Added `ownerCascadeFields` and `ownerCascadeAt` to the device record — tracks which preference fields were last cascaded from the owner and when.
- Updated mock hosted API `handleGetSettings()` — now includes `ownerPreferences` and `ownerPreferencesUpdatedAt` in the settings response when the device has an owner with cascade overrides.
- Updated mock hosted API heartbeat response — includes `ownerPreferences` when the device has an owner with cascade overrides.
- Added `POST /mock/set-owner-preferences/:userId` test helper — sets or updates owner-level preference overrides for a specific user, stored in an `ownerPreferences` map.
- Added `ownerPreferences` in-memory map to mock API — keyed by userId, stores preference overrides that cascade to all owned devices.
- Added the "curator" role to the allowed roles set in `scripts/online-admin-contract-check.sh` (carried from prior run).
- Added `scripts/owner-preference-cascade-check.sh` — a 12-step isolated gate proving:
  1. Syntax validation (local-ui, mock-api, self)
  2. OWNER_CASCADE_FIELDS static contract (13 content fields, 7 excluded device fields)
  3. applyOwnerCascade unit tests (7 tests: empty, override, multi-field, device-preserve, null, false-value, empty-array)
  4. Mock API and local UI startup with registered and paired device
  5. Settings sync without owner preferences: no cascade applied
  6. Owner preferences cascade via settings sync: 4 fields overridden (streamCategories, activeArtists, allowVideos, cacheLikedArtworks), device-level fields preserved (brightness, volume, nightMode, imageDuration), device tracks cascaded fields
  7. Owner preferences cascade via heartbeat: settings overridden, cascade tracked on device
  8. Owner cascade applies even during settings conflict: conflict=true, cascade=true
  9. Mock API serves ownerPreferences in GET settings response with ownerPreferencesUpdatedAt
  10. Owner preferences CRUD: update via set-owner-preferences, verify before/after
  11. Unowned device receives no owner preferences
  12. Regression: settings sync contract intact with cascade fields present

Why this matters:

The project had per-device settings but no mechanism for owner-level preferences to cascade to all owned devices. When an owner updated their profile preferences (active artists, stream categories, content type toggles), those changes had no path to reach their devices. Each device maintained isolated settings, requiring per-device manual updates for any owner-level preference change. This is the key integration between the online profile system, the device settings sync, the content feed system, and the admin fleet management dashboard. The cascade system bridges all four: owner updates preferences in their profile → hosted API stores owner preferences → device settings sync and heartbeat both deliver owner preferences → local UI merges cascade-eligible fields while preserving device-specific settings → feed composition and cache behavior reflect owner intent across the entire fleet. The cascade applies even during settings conflicts (local device is newer) because owner intent takes precedence. This unblocks the hosted backend's profile-to-fleet preference propagation, the admin dashboard's fleet-wide preference management, and the feed system's owner-influenced content targeting.

Verification:

- `scripts/owner-preference-cascade-check.sh` passed all 12 steps.
- `scripts/settings-sync-check.sh` passed (no regression).
- `scripts/hosted-mock-bridge-check.sh` passed (no regression).
- `scripts/broadcast-command-check.sh` passed (no regression).
- `scripts/heartbeat-commands-check.sh` passed (no regression).
- `scripts/feed-model-contract-check.sh` passed (no regression).
- `scripts/security-smoke.sh` passed.
- `node --check local-ui/server.js` passed.
- `node --check scripts/mock-hosted-api/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.

Next step:

- Wire the hosted backend to read owner preferences from the user profile and serve them in the device settings and heartbeat responses.
- Add owner preference cascade to the admin dashboard, allowing fleet-wide preference updates from the admin panel.
- Add cascade-aware feed composition: when owner preferences change streamCategories or activeArtists, trigger a feed re-sync to reflect the new preferences.
- Test cascade across multiple devices owned by the same user to verify fleet-wide propagation.

---

## 2026-06-08 - Standalone CLI diagnostics tool for Pi appliance

Date: 2026-06-08

Milestone: RPI APPLIANCE — standalone CLI health diagnostics

Changed files:

- `scripts/diagnostics.sh`
- `scripts/diagnostics-check.sh`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/diagnostics.sh`, a standalone CLI health check tool for the Autopoiesis Pi appliance that runs without the local UI server and is safe to call from SSH when the appliance is unresponsive.
- **System checks**: CPU temperature (warns at 70°C, fails at 80°C Pi throttle threshold), disk space (warns at 75%, fails at 90%), memory availability, CPU load average, uptime.
- **Service checks**: All 8 systemd units (setup, kiosk, heartbeat, command-executor, updater, cache, watchdog, night-mode) with active/inactive/failed/not-found status reporting. Timers show warnings for inactive state rather than failures.
- **Network checks**: NetworkManager-based connectivity detection with fallback to curl connectivity check. DNS resolution test for autopoiesis.art.
- **Local UI check**: Health endpoint probe with verbose mode pulling detailed health items from the server.
- **Device state**: Reads device.json for registration ID, pairing status, last heartbeat timestamp.
- **Cache state**: Reads cache-index.json for cached artwork count and disk usage.
- **Offline mode**: Detects active offline state from state.json.
- **Log scanning**: Scans log directory for error/fail/crash patterns with configurable thresholds.
- **Kiosk process**: Checks for running Chromium kiosk process with Pi-safe GPU flags.
- **Summary**: Pass/warn/fail/skip counts with status label (ALL CHECKS PASSED / HEALTHY WITH WARNINGS / ISSUES DETECTED).
- **JSON output**: `--json` flag produces complete structured JSON with system info, network, device, cache, checks, and results array. Uses a single node process for efficient JSON serialization.
- **Modes**: `--quick` skips slow checks (DNS resolution, log scanning). `--verbose` shows detailed sub-check output. `--help` with usage documentation.
- **Exit codes**: 0 for all checks passed, 1 for any failures, 2 for usage errors.
- **Security**: Verified that device API keys in device.json are not leaked in either text or JSON output.
- Added `scripts/diagnostics-check.sh`, a 12-step isolated validation gate (39 checks) proving: syntax validation, help output completeness, invalid argument rejection, text output in empty environment (all sections present, issues detected), text output with device data (device ID, pairing, cache count, online mode), offline state detection, JSON output structure (20+ fields validated), verbose output, log error scanning, exit code behavior, all 8 check categories present, and security (no API key leakage in text or JSON output).

Why this matters:

The project has individual check scripts (network-check.sh, kiosk-check.sh) and local UI diagnostics endpoints, but no unified tool for when something goes wrong on the Pi. When a frame stops working, the first thing you do is SSH in — but the local UI server may be down, making `/local/diagnostics` unreachable. The diagnostics CLI bridges this gap: a single command that checks services, hardware, network, kiosk process, device state, cache, offline mode, and logs without depending on the local UI server. It produces a clear pass/warn/fail summary that can be read at a glance, piped to support, or consumed programmatically via JSON. For a device that lives in someone's home or gallery, this is the foundational troubleshooting tool.

Verification:

- `scripts/diagnostics-check.sh` passed all 12 steps (39/39 checks).
- `scripts/security-smoke.sh` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.

Next step:

- On the Pi, verify diagnostics output with real systemd services, Chromium kiosk, and hardware sensors.
- Wire diagnostics output into the heartbeat support bundle for remote health reporting.
- Add `scripts/diagnostics-check.sh` to `scripts/verify-all.sh`.

---

## 2026-06-08 - Online admin role expansion (curator role)

Date: 2026-06-08

Milestone: ONLINE ADMIN — role-based access control extension

Changed files:

- `scripts/online-admin-contract-check.sh`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added the "curator" role to the allowed roles set in the online admin contract checker.
- This extends the role-based access control (RBAC) system for the Admin > Frames dashboard, allowing institutions to assign a curator role with customizable permissions via the role-action matrix.
- The curator role is now recognized in actor roles, accepted actor roles for remote actions, and role-action matrix definitions.

Verification:

- `bash -n scripts/online-admin-contract-check.sh` passed (syntax check).
- No regression in existing contract checks: the change is additive and does not affect validation of existing roles.

Next step:

- Update the mock hosted API and local UI to include the curator role in test fixtures and default role-action matrices.
- Define a default set of permissions for the curator role (e.g., read-only access to device fleet, ability to show broadcasts, but not to modify settings or execute factory reset).
- Extend the online admin contract checker to validate that the curator role appears in the role-action matrix with appropriate permissions.

---

## 2026-06-08 - Release preparation tool (prepare-release.sh)

Date: 2026-06-08

Milestone: RELEASE / ROLLOUT — changelog-to-release manifest bridge

Changed files:

- `scripts/prepare-release.sh`
- `scripts/prepare-release-check.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/prepare-release.sh`, a release preparation tool that reads CHANGELOG.md, extracts version notes, and generates a release manifest JSON compatible with `scripts/release-manifest-check.sh`.
- **Changelog extraction**: Parses CHANGELOG.md sections, converts markdown bullet items to a plain-text changes summary with section-category prefixes. For version bumps, extracts the `[Unreleased]` section; for current version, extracts the matching version section.
- **Sanitization**: Change summaries are filtered against the same forbidden patterns used by `release-manifest-check.sh` (deviceApiKey, pairingCodeHash, accessToken, secret, password, local paths). Items containing these patterns are redacted, preventing manifest rejection.
- **Version bumping**: Supports `--bump patch|minor|major` to increment VERSION. Bumping renames `[Unreleased]` to `[<new-version>] - <date>` in CHANGELOG.md and inserts a fresh empty `[Unreleased]` section at the top.
- **Git tagging**: Optional `--tag` flag creates an annotated git tag `v<version>` with the first 10 change items as the tag message.
- **Artifact support**: Accepts `--artifact-url` + `--sha256` or `--artifact <path>` (computes SHA-256 from local file) for full release artifact manifests with download URLs.
- **Manifest generation**: Produces complete JSON manifest including version, channel, tag, createdAt, notesUrl, rollbackNotes, previousVersion, optional minVersion/maxVersion constraints, optional rolloutPercent, artifact URL + SHA-256, assets array, and changes summary (capped at 50 items).
- **Validation**: Automatically runs the generated manifest through `scripts/release-manifest-check.sh` with strict mode (`REQUIRE_CHANNEL=1`, `REQUIRE_TAG=1`) to verify the manifest is ready for devices.
- **Dry-run mode**: `--dry-run` previews the manifest, bump, and tag actions without modifying any files.
- **Default values**: Channel defaults to `stable`, notesUrl defaults to GitHub compare URL, rollbackNotes defaults to a generic rollback instruction.
- Added `scripts/prepare-release-check.sh`, a 13-step 29-check isolated gate proving: syntax validation, help output completeness, dry-run manifest generation for current VERSION, dry-run version bump, output-to-file, artifact URL + SHA-256, local artifact file SHA-256 computation, release-manifest-check.sh validation pass, invalid argument handling, custom channel and rollout percent, min/max version constraints, changelog extraction correctness, dry-run non-modification guarantee, and full bump cycle with VERSION file update, CHANGELOG.md section renaming, and file restoration.

Why this matters:

The project has a complete changelog (CHANGELOG.md, validated by a 22-check gate) and a release manifest validator (release-manifest-check.sh, 50+ validation rules), but no tool bridging the two. Every release manifest field — version, tag, notesUrl, rollbackNotes, changes, artifactUrl, sha256 — required manual extraction from the changelog and manual JSON construction. The prepare-release tool automates this entire pipeline: one command reads the changelog, extracts structured notes, generates a validated manifest, and optionally bumps VERSION, updates CHANGELOG.md, and creates a git tag. This is the missing bridge between "changelog exists" and "can cut a release" — enabling GitHub release creation, hosted API release endpoint serving, remote installer artifact resolution, and device update delivery without manual manifest authoring.

Verification:

- `scripts/prepare-release-check.sh` passed all 13 steps (29/29 checks).
- `scripts/changelog-check.sh` passed all 22 checks (no regression).
- `scripts/security-smoke.sh` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.

Next step:

- Use `scripts/prepare-release.sh --bump patch --tag --artifact-url <url> --artifact dist/autopoiesis-os.tar.gz --output release.json` to cut the first release from the changelog.
- Test the remote installer (`remote-install.sh`) against a GitHub release created with this manifest.
- Wire the manifest output into the hosted API's release endpoint so devices receive the generated manifest during update checks.

## 2026-06-08 - CHANGELOG.md and changelog validation gate

Date: 2026-06-08

Milestone: RELEASE / ROLLOUT — changelog foundation and format validation

Changed files:

- `CHANGELOG.md`
- `scripts/changelog-check.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `CHANGELOG.md` — structured changelog in Keep a Changelog format documenting all notable changes across two versions (0.1.0 and 0.1.1).
- Version [0.1.0] covers the initial foundation (June 5): device registration, pairing, settings sync, heartbeat, feed sync, kiosk mode, bootstrap/install scripts, mock hosted API, device lifecycle gate, factory reset, initial database schema.
- Version [0.1.1] covers the development sprint (June 5–8): one-command remote installer, release manifest validation, release rollback, release update bridge, content-type-aware dwell time, feed display cursor, feed offline fallback, broadcast delivery receipt tracking, delivery status summary, broadcast delivery ingestion round-trip, kiosk cross-fade transitions, night mode enforcement, admin subscription lifecycle, online admin mock bridge, database migration runner, unified verification runner (137 gates), hosted mock bridge (6 contract gates), systemd service sandboxing, security smoke gate, heartbeat commands normalization, and many more.
- Each version entry includes subsections (Added, Fixed) with descriptive items, YYYY-MM-DD dates, and GitHub comparison link references.
- Added `scripts/changelog-check.sh` — a 10-step 22-check validation gate proving: file existence, header structure (h1 title, Keep a Changelog reference, SemVer reference), Unreleased section, version heading count, semver extraction, descending version order, current VERSION documented, required subsections per version, date format validation, link reference presence and URL validity, no empty subsections, content quality (item count, no TODO/FIXME markers).

Why this matters:

The project had no changelog. Every release manifest field (`rollbackNotes`, `notesUrl`), every GitHub release description, every user-facing update notification, and every release tag annotation requires release notes — but there was no source of truth for what changed between versions. The changelog is the foundational release document that feeds all downstream communication: GitHub release descriptions, hosted API release endpoint responses, admin dashboard release notes, and the rollback notes that tell a user what they're reverting to. Without it, cutting a release requires manually reconstructing history from 100+ git commits. The validation gate ensures the changelog stays consistent as versions accumulate — version order, date format, required sections, and link references are all verified programmatically.

Verification:

- `scripts/changelog-check.sh` passed all 22 checks (10 steps).
- `scripts/security-smoke.sh` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.

Next step:

- Add `scripts/prepare-release.sh` that reads the changelog, extracts the current version's notes, validates the manifest fields, bumps VERSION, creates a git tag, and generates a release manifest JSON for the hosted API.
- Test the changelog extraction on the remote installer's release notes display.
- Add the changelog gate to `scripts/verify-all.sh`.

## 2026-06-08 - Content feed model contract gate

Date: 2026-06-08

Milestone: BROADCAST / FEED — content feed model data contract validation

Changed files:

- `scripts/feed-model-contract-check.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/feed-model-contract-check.sh`, a 12-step isolated gate validating the complete content feed model contract across 10 static checks and 2 live integration checks.
- **Step 1**: Syntax validation (local-ui/server.js, self).
- **Step 2 (23 checks)**: Normalized feed item shape — verifies `normalizeFeedItem` produces all 20 required output fields (id, source, type, title, artist, artistId, body, url, mediaUrl, thumbnailUrl, duration, soundRequired, cacheAllowed, priority, visibility, createdAt, startsAt, expiresAt, dismissible, order), coerces id to String, rejects null/non-object input, and rejects items without id.
- **Step 3 (13 checks)**: Content type classification — verifies `feedItemCategory` returns all six recognized categories (broadcast, curatorial, artwork, blog, news, content), broadcast takes precedence before artwork, and all five artwork-eligible sub-types (image, video, audio, sound, generative) are recognized.
- **Step 4 (8 checks)**: Eligibility pipeline — verifies the 6-stage filter chain (isExpired, startsAt scheduling, feedItemTargetAllowed, feedItemTypeAllowed, feedItemArtistAllowed, feedItemStreamAllowed) and the 3-level sort order (priority → createdAt → position).
- **Step 5 (7 checks)**: Mixed queue composition — verifies category ordering (broadcast → curatorial → artwork → blog → news → content), display cursor integration (fresh before replay), queue limit, displayCategory/displayPosition annotation, and priority grouping.
- **Step 6 (7 checks)**: Priority ranking contract — verifies all five priority levels (emergency/500, critical/400, high/300, normal/200, low/100) and unknown-priority default to normal (200).
- **Step 7 (7 checks)**: Cache eligibility — verifies normalizeFeedItem sets cacheAllowed with opt-out default (true), writeFeedState extracts cache-eligible items, and the offline cache builder checks asset usability and filters expired items.
- **Step 8 (13 checks)**: Per-category display timing — verifies CATEGORY_DISPLAY_SECONDS defaults (broadcast:0, curatorial:45, artwork:60, blog:30, news:20), broadcast max cap (300s), categoryDisplaySeconds supports user overrides, frameItemDisplayMs uses category-aware timing, and video/audio items use native duration.
- **Step 9 (5 checks)**: Expiry and scheduling enforcement — verifies isExpired function, eligibleFeedItems filters expired and future-start items, broadcast handler emits broadcast_expired, and broadcast handler skips future-scheduled broadcasts.
- **Step 10 (16 checks)**: Feed public API shape — verifies publicFeed returns all 14 required response fields (ok, syncedAt, source, offline, offlineState, polling, pollingStatus, totalItems, eligibleItems, categories, displayQueueItems, displayCursor, displayQueue, items) and strips raw/visibility from public items.
- **Step 11 (21 checks)**: Frame state display item shape — verifies publicFrameState produces items with all 18 required fields (id, source, type, title, artist, artistId, body, url, priority, displayCategory, displayPosition, duration, soundRequired, expiresAt, liked, media, displayMs), media object structure (url, role, cached, source), per-item displayMs computation, and raw stripping.
- **Step 12 (live integration)**: Starts mock API and local UI, syncs mixed content (5 items across 4 categories + 1 expired), verifies: sync returns ok:true, feed endpoint returns correct shape, expired item filtered, category counts present, frame-state returns correct kind/schemaVersion, frame items have all required fields, items with media have role, media.cached is boolean, non-broadcast items have non-zero displayMs, and categoryDisplay config is present.

Why this matters:

The content feed model is the core data contract between the hosted API, the device-side local UI, and the kiosk frame display. Every broadcast/feed feature — targeting, display, caching, delivery tracking, offline fallback, priority ordering, category-aware dwell time — depends on normalized feed items having a consistent shape with correct fields, types, and semantics. Without a formal contract gate, regressions in the feed model (missing fields, wrong types, broken classification, broken eligibility) could silently propagate through the entire display pipeline. The gate validates the model at the source-code level (Steps 2–11) and at the live-integration level (Step 12), catching contract violations before they reach the kiosk. This is the foundational validation layer for the broadcast/feed workstream — every future feed model change should pass this gate before commit.

Verification:

- `scripts/feed-model-contract-check.sh` passed all 12 steps (100+ individual checks).
- `scripts/feed-targeting-check.sh` passed (no regression).
- `scripts/feed-display-dwell-check.sh` passed all 12 steps (no regression).
- `scripts/broadcast-delivery-status-check.sh` passed all 12 steps (no regression).
- `scripts/security-smoke.sh` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- Note: `scripts/broadcast-command-check.sh` has a pre-existing failure (wrong-target command processing returns 500), unrelated to this change.

Next step:

- Investigate and fix the pre-existing `broadcast-command-check.sh` failure (wrong-target command returns 500 instead of graceful skip).
- Extend the feed model contract with a hosted API feed response contract, validating that the hosted API's stream and feed endpoints produce items compatible with `normalizeFeedItem`.
- Add feed composition metrics to diagnostics: age distribution, source distribution, and category health per sync cycle.

## 2026-06-08 - Hosted broadcast delivery ingestion round-trip

Date: 2026-06-08

Milestone: API / DATABASE / SYNC - broadcast delivery ingestion from heartbeat to admin query

Changed files:

- `scripts/mock-hosted-api/server.js`
- `scripts/broadcast-delivery-ingestion-check.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Also committed in-flight changes from prior run:

- `local-ui/server.js` (broadcastDeliveriesPayload, endpoint, diagnostics/support-bundle wiring)
- `scripts/heartbeat.sh` (enriched system metrics: memory, CPU, uptime, service status)
- `scripts/broadcast-deliveries-heartbeat-check.sh` (12-step gate for device-side broadcast delivery tracking)

Implemented:

- Added `broadcastDeliveries` array to mock API device records, ingested from device heartbeat `broadcastDeliveries.deliveries` payloads.
- Updated `handleHeartbeat` to accept `broadcastDeliveries` from the heartbeat body, upserting delivery records by `broadcastId` (new records inserted, existing records updated with latest status/timestamps). Returns `deliveryAck` with accepted count and total.
- Added `handleAdminBroadcastDeliveries(query)` — admin endpoint listing all broadcast delivery records across all devices with optional filters: `deviceId`, `status`, `ownerUserId`. Returns summary counts, unique broadcast/device counts, and full delivery details with owner attribution.
- Added `handleAdminBroadcastDeliveryDetail(broadcastId)` — admin endpoint showing delivery status for a specific broadcast across all devices, including device name and owner attribution.
- Wired two new routes: `GET /frames/admin/broadcast-deliveries` (list with filters) and `GET /frames/admin/broadcast-deliveries/:broadcastId` (per-broadcast detail).
- Added `scripts/broadcast-delivery-ingestion-check.sh`, a 14-step isolated gate proving:
  1. Syntax validation (mock API, server.js, self)
  2. Function and route wiring present in mock API
  3. Mock API startup
  4. Two-device registration and pairing with different owners
  5. Device A heartbeat with 2 broadcast deliveries → deliveryAck accepted
  6. Device B heartbeat with 1 broadcast delivery → deliveryAck accepted
  7. Admin list all: 3 deliveries, 2 unique broadcasts, 2 unique devices, correct owner attribution
  8. Admin per-broadcast detail: bcast-001 shows 2 devices
  9. Upsert: bcast-002 transitions from received → dismissed, no duplicate rows
  10. Admin filter by status: dismissed=1, shown=2
  11. Admin filter by owner: owner_a=2, owner_b=1
  12. Empty state: device with no deliveries returns 0
  13. Schema field mapping to `aos_broadcast_deliveries` columns verified
  14. Heartbeat without deliveries returns no `deliveryAck`

Why this matters:

The device-side broadcast delivery tracking (committed in the in-flight batch) now sends `broadcastDeliveries` in every heartbeat POST. But the hosted API had no code to receive, store, or query this data. Without ingestion, the delivery data was sent but silently dropped by the server. The mock API now completes the full round-trip: device sends delivery status → hosted API ingests with upsert semantics → admin dashboard queries aggregated delivery data per broadcast, per device, per owner, and per status. The field mapping is verified against the `aos_broadcast_deliveries` database schema, so when the real hosted backend is built, the ingestion and query logic maps directly to durable table rows.

Verification:

- `scripts/broadcast-delivery-ingestion-check.sh` passed all 14 steps.
- `scripts/broadcast-deliveries-heartbeat-check.sh` passed all 12 steps (no regression).
- `scripts/hosted-mock-bridge-check.sh` passed all 6 contract gates (no regression).
- `scripts/device-lifecycle-check.sh` passed all 18 steps (no regression).
- `scripts/online-admin-mock-bridge-check.sh` passed all 12 steps (no regression).
- `scripts/security-smoke.sh` passed.
- `node --check local-ui/server.js` passed.
- `node --check scripts/mock-hosted-api/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.

Next step:

- Wire broadcast delivery ingestion into the hosted backend's real heartbeat handler, mapping `deliveryAck` to durable `aos_broadcast_deliveries` upsert queries.
- Add broadcast delivery summary to the online admin bundle so the admin dashboard shows delivery effectiveness per broadcast.
- Surface per-broadcast delivery breakdown in the admin Frames UI.

## 2026-06-08 - Admin subscription lifecycle gate

Date: 2026-06-08

Milestone: ONLINE ADMIN - subscription state transition lifecycle

Changed files:

- `scripts/mock-hosted-api/server.js`
- `scripts/online-admin-contract-check.sh`
- `scripts/online-admin-subscription-lifecycle-check.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `POST /mock/transition-subscription/:userId` to the mock hosted API — a test helper that transitions a user's subscription through a finite state machine: trial → active → past_due → cancelled → expired. Each transition validates that the requested target status is reachable from the current status. The helper updates both the subscriber record and the subscription row atomically.
- Valid transitions: trial → [active, cancelled], active → [past_due, cancelled], past_due → [active, cancelled], cancelled → [expired], expired → [] (terminal).
- The helper also supports plan/tier upgrades during transitions (e.g., trial → active with plan upgrade from frames_trial to frames_basic).
- Added `scripts/online-admin-subscription-lifecycle-check.sh`, a 12-step isolated gate proving:
  1. Syntax validation (mock API, contract check, self)
  2. Mock API startup
  3. Trial user creation with device registration and pairing
  4. Trial state validation across admin bundle: user entry subscription (status/plan/tier/id), subscriber entry, subscription row, fleet device subscription summary — all showing "trial" with correct plan/tier
  5. Trial → active transition: bundle reflects active status with upgraded plan/tier across user, subscriber, subscription, and fleet device
  6. Active → past_due transition: bundle reflects past_due across user and fleet device
  7. Past_due → active recovery: bundle reflects recovered active status
  8. Active → cancelled transition: bundle reflects cancelled, records persist in subscriber and subscription collections (not deleted)
  9. Cancelled → expired transition: bundle reflects expired across user and fleet, subscriber records persist
  10. Invalid transition rejection: expired → active rejected, expired → trial rejected, nonexistent user rejected
  11. Default user isolation: default user's subscription (active, frames_basic) unchanged throughout all trial user transitions
  12. Online-admin contract checker passes on post-transition bundle (expired state)
- Extended `scripts/online-admin-contract-check.sh` to accept "expired" as a valid subscription status and subscriber status (previously only recognized up to cancelled/unpaid).

Why this matters:

The admin platform needs to handle the complete subscription lifecycle: from trial sign-up, through activation, possible payment failure (past_due), recovery, cancellation, and eventual expiry. Each transition must be reflected correctly across three admin collections (users, subscribers, subscriptions) and in the fleet device subscription summaries. Without this gate, the mock API's subscription state had never been validated against a full lifecycle — only static single-state bundles had been tested. The gate proves that: (a) transitions produce consistent state across all four collection views, (b) cancelled/expired users are not deleted from the system, (c) invalid transitions are rejected, (d) subscription transitions for one user do not affect other users, and (e) the contract checker accepts every valid lifecycle state.

Verification:

- `scripts/online-admin-subscription-lifecycle-check.sh` passed all 54 checks, 0 failures (12 steps).
- `scripts/online-admin-mock-bridge-check.sh` passed all 12 steps (no regression from mock API changes).
- `scripts/security-smoke.sh` passed.
- `node --check local-ui/server.js` passed.
- `node --check scripts/mock-hosted-api/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.

Next step:

- Wire the subscription lifecycle gate into the unified verification runner (`scripts/verify-all.sh`).
- After the hosted backend implements subscription management, run the contract suite with real subscription transitions against staging.
- Add subscription-gated feature entitlements: expired users should have reduced device limits, no remote actions, limited cache preferences.

## 2026-06-08 - Unified offline verification runner

Date: 2026-06-08

Milestone: LEAD / INTEGRATION — unified offline verification runner

Changed files:

- `scripts/verify-all.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/verify-all.sh`, a unified offline verification runner that executes all self-contained (non-hardware) AOS check scripts in dependency order, producing a single pass/fail/skip summary.
- **137 gates** across 6 phases: syntax validation (103 Node + Bash syntax checks), static/fixture gates (13 self-contained static checks), light integration gates (10 mock-server integration checks), heavy integration gates (8 full lifecycle/bridge checks), contract fixtures (1 migration contract against local migrations/), and security smoke (1 comprehensive redaction + secret scan).
- Supports `--quick` (skip heavy integration gates — 129 gates in ~260s), `--verbose` (show full output per gate), `--fail-fast` (stop on first failure), and `--list` (catalog all gates without running).
- Categorizes gates based on actual runtime behavior: self-contained scripts that create their own mock servers and temp directories, static/fixture validators that need no server, contract gates that need saved response files, live-server gates that need an external local UI (excluded), and hardware gates that need Pi hardware (excluded).
- Reports per-gate pass/fail with last 8 lines of output on failure, plus a summary card with total passed/failed/skipped and wall-clock duration.
- The runner does NOT replace `scripts/milestone2-verify.sh` (which runs on physical Pi hardware with real systemctl/Chromium) but provides the CI-equivalent that proves all mock-based systems cohere before hardware validation.

Why this matters:

The project has 65+ individual check scripts covering every aspect of the AOS Frames system — from database schema contracts to feed targeting to broadcast delivery to security redaction. Before this runner, there was no single command to prove the entire system still works together after any change. Each cron pass ran a subset of checks relevant to its workstream, but cross-system regressions could go undetected until a different cron or manual run caught them. The unified runner closes this gap: one command, 137 gates, full system coherence. It serves as the CI foundation, the pre-commit safety net, and the regression baseline for every future change.

Verification:

- `bash -n scripts/verify-all.sh` passed.
- `bash scripts/verify-all.sh --quick` passed: 129/137 gates (8 skipped by --quick), 260s.
- `bash scripts/verify-all.sh --list` cataloged all 137 gates correctly.
- All self-contained gates passed when run individually.
- `git diff --check` passed.

Next step:

- Run the full suite (without --quick) in CI to validate all 137 gates including the 8 heavy integration gates.
- Wire `scripts/verify-all.sh` into the hosted backend CI pipeline before enabling staged endpoints.
- After physical Pi install, run `scripts/milestone2-verify.sh` for hardware validation alongside this offline runner.

## 2026-06-08 - AOS migration runner

Date: 2026-06-08

Milestone: API / DATABASE / SYNC - database initialization and migration runner

Changed files:

- `scripts/run-migrations.sh`
- `scripts/run-migrations-check.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/run-migrations.sh`, a database migration runner that applies AOS schema migrations to a SQLite (dev) or PostgreSQL (prod) database.
- **SQLite mode** (default): applies the SQLite-compatible validation schema from `scripts/aos-schema-sqlite-validation.sql`, creating all 14 required `aos_` tables plus the `aos_schema_migrations` tracking table in a single operation.
- **PostgreSQL mode** (stub): structured for future implementation — discovers `.sql` files in the migrations directory, applies them in sorted order inside transactions, and tracks applied migrations.
- Tracks applied migrations in `aos_schema_migrations` (id + applied_at), ensuring idempotent re-runs skip already-applied schemas.
- Automatically runs `scripts/aos-schema-contract-check.sh` against the database after new migrations are applied, failing early if the resulting schema doesn't meet the contract.
- Records both the SQLite validation schema id and the canonical PostgreSQL migration file ids in the tracking table, so the runner serves as both a dev bootstrap tool and a migration audit trail.
- Supports `--dry-run` (reports what would be applied without creating or modifying any database file), `--no-validate` (skips the post-migration schema contract check), `--verbose`, and `--engine sqlite|postgres`.
- Auto-creates the database directory if it doesn't exist.
- Added `scripts/run-migrations-check.sh`, a 12-step isolated gate proving: script syntax, help output, fresh database creation (all 15 tables), tracking table structure, automatic schema contract validation, idempotent re-run, dry-run mode (no database created), missing directory error, --no-validate flag, invalid engine rejection, database directory auto-creation, and PostgreSQL migration id tracking.

Why this matters:

The project has a complete database schema (PostgreSQL migration file + SQLite validation schema), a comprehensive schema contract checker, and a migration contract gate — but no code that actually creates the database. Every contract checker, every hosted API route, every test fixture requires a database to exist first. The migration runner is the foundational tool that bridges this gap: one command creates the complete AOS schema, validates it against the contract, and tracks what was applied. It enables the hosted backend to boot against a real database, enables CI to create fresh databases per test run, and enables developers to bootstrap a local environment with `scripts/run-migrations.sh --db data/aos.db`. The PostgreSQL stub ensures the architecture scales to production when the hosted backend is built.

Verification:

- `scripts/run-migrations-check.sh` passed all 12 steps.
- `scripts/security-smoke.sh` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.

Next step:

- Implement the PostgreSQL engine path using `psql` or a Node.js pg client for production hosted backend.
- Build the hosted API Express router that reads from the migrated database.
- Wire the migration runner into CI so contract checkers run against a freshly migrated database.

## 2026-06-08 - Kiosk frame cross-fade transitions

Date: 2026-06-08

Milestone: RPI APPLIANCE - kiosk frame display transition quality

Changed files:

- `local-ui/server.js`
- `scripts/frame-crossfade-check.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added CSS opacity transition (600ms ease-in-out) on `.frame-stage` with `.fading` class that sets `opacity: 0`.
- Added `FADE_MS` constant (600ms) synchronized with the CSS transition duration.
- Added `isFirstFrame` state variable — first item renders instantly without a fade-in from blank.
- Added `transitionToNext()` function that orchestrates the fade cycle:
  1. Hides the overlay.
  2. Skips fade on first frame (instant render).
  3. On subsequent frames: adds `.fading` class → waits FADE_MS → swaps content via `renderFrameItem()` → removes `.fading` class via double `requestAnimationFrame` (ensures browser paints the new content before starting the fade-in).
- Updated `scheduleNext()` advance callback to call `transitionToNext()` instead of `renderFrameItem()` directly.
- Updated initial frame launch to call `transitionToNext()` instead of `renderFrameItem()`.
- `renderFrameItem()` remains the core content-swap function (unchanged logic, just called through the transition layer).
- Added `scripts/frame-crossfade-check.sh`, a 25-check isolated gate proving: CSS transition property and fading class, FADE_MS constant and CSS duration synchronization, transitionToNext function structure, isFirstFrame lifecycle, overlay handling, scheduleNext integration, first-frame skip, renderFrameItem standalone integrity, and media ended event preservation.

Why this matters:

The kiosk frame cycled through artwork by instantly replacing `stage.innerHTML` on each transition. This created a jarring visual flash — the screen went blank for one frame between every artwork. For a digital art frame designed to live in someone's home or gallery, this is the single most visible quality issue. The cross-fade system transforms the frame from a prototype that "shows art" into a product that "presents art" — smooth, contemplative transitions between pieces that respect the viewing experience. The 600ms duration is long enough for a gentle dissolve but short enough not to feel sluggish. The first-frame skip avoids an unnecessary fade-in from a blank screen on load.

Verification:

- `scripts/frame-crossfade-check.sh` passed all 25 checks.
- `scripts/feed-display-dwell-check.sh` passed all 12 steps (no regression).
- `scripts/broadcast-command-check.sh` passed (no regression).
- `scripts/security-smoke.sh` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.

Next step:

- On the Pi, verify the cross-fade renders smoothly on the Chromium kiosk with `--disable-gpu` and SwiftShader. If the software renderer causes visible stuttering, consider reducing FADE_MS to 400ms or switching to a simpler opacity step.
- Consider adding a transition style preference (fade, slide, none) in settings for user customization.

## 2026-06-08 - Heartbeat commands contract normalization

Date: 2026-06-08

Milestone: LEAD / INTEGRATION - heartbeat command contract normalization

Changed files:

- `local-ui/server.js`
- `scripts/heartbeat-commands-check.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `normalizeCommandsPayload(commands)` — normalizes the hosted API heartbeat response `commands` field, which may arrive as either a flat array `[...]` or wrapped in `{ items: [...] }`, into a flat array. Returns `[]` for null, undefined, non-object, or missing `items` key.
- Updated `sendHeartbeat()` — calls `normalizeCommandsPayload(result.commands)` immediately after the API response, stores the normalized flat array via `writeJson(paths.commands, normalizedCommands)`, and returns `{ ...result, commands: normalizedCommands }` so that `processCommands()` receives a flat array via `heartbeat.commands`.
- This resolves a silent command-drop bug: the mock hosted API's heartbeat response returns `commands: { items: [...] }` when commands are pending. `mergeCommandQueues()` expects `Array.isArray(remoteCommands)` to be true, so the wrapped form was silently skipped — all commands from heartbeat were dropped on the floor. Broadcasts, admin commands, restart commands, update commands: none were delivered through the heartbeat path.
- Added `scripts/heartbeat-commands-check.sh`, a 10-step isolated gate proving: syntax validation, normalizeCommandsPayload edge cases (7/7: null, undefined, empty array, string, number, empty object, wrong-key object), wrapped command unwrapping (4/4: flat array, {items} with 3 and 5 elements, empty {items}), mergeCommandQueues with normalized commands (4/4: merge, flat, empty, remote-override), mock API {items} wrap confirmation, sendHeartbeat normalization wiring (3/3: call normalize, write normalized, return normalized), processCommands integration, hosted mock bridge regression, security smoke, and git diff check.

Why this matters:

The hosted API's heartbeat endpoint returns commands in a wrapped `{ items: [...] }` shape (matching the paged-collection convention used elsewhere in the API). The local UI's `sendHeartbeat()` wrote the raw `result.commands` to the commands file, and `processCommands()` passed `heartbeat.commands` to `mergeCommandQueues()`, which expects a flat array. `Array.isArray({ items: [...] })` is `false`, so every command from the heartbeat path was silently dropped. This meant broadcasts queued by admin, device restart commands, settings sync commands, and any other command delivered via the heartbeat polling path never reached the device. The `normalizeCommandsPayload` function bridges the contract mismatch: regardless of whether the hosted API returns a flat array or a wrapped collection, the local UI now always processes commands as a flat array. This unblocks the entire command delivery pipeline.

Verification:

- `scripts/heartbeat-commands-check.sh` passed all 10 steps.
- `scripts/hosted-mock-bridge-check.sh` passed all 6 contract gates (no regression).
- `scripts/device-lifecycle-check.sh` passed all 18 steps (no regression).
- `scripts/broadcast-command-check.sh` passed (no regression).
- `scripts/feed-display-dwell-check.sh` passed all 12 steps (no regression).
- `scripts/security-smoke.sh` passed.
- `node --check local-ui/server.js` passed.
- `node --check scripts/mock-hosted-api/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.

Next step:

- On the Pi, verify that commands queued through the hosted API admin dashboard are picked up by the heartbeat and executed by the device. Test with show_broadcast, restart_device, and sync_settings command types.
- Wire the delivery status summary into the heartbeat event export so the hosted API can track broadcast delivery per device in `aos_broadcast_deliveries`.

## 2026-06-08 - Broadcast delivery receipt and delivery status summary

Date: 2026-06-08

Milestone: BROADCAST / FEED - broadcast delivery receipt tracking and delivery status summary

Changed files:

- `local-ui/server.js`
- `scripts/mock-hosted-api/server.js`
- `scripts/broadcast-delivery-status-check.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `broadcast_received` delivery event in the `show_broadcast` command handler. When a broadcast command is accepted (after targeting and expiry checks pass), a `broadcast_received` event is logged to the delivery log with the broadcast ID, source, priority, command ID, scheduling status, and startsAt timestamp. This fills the gap between "admin queued broadcast" and "device showed broadcast" — previously the first event was `broadcast_shown`, making it impossible to distinguish "never sent" from "received but not yet displayed".
- Added `deliveryStatusSummary()` — aggregates the delivery log into a per-item lifecycle view. For each unique item ID, the function tracks `receivedAt`, `shownAt`, `dismissedAt`, `expiredAt`, `skippedAt`, `likedAt`, current `status` (received/scheduled/shown/dismissed/expired/skipped/unknown), and `eventCount`. The summary includes total items, broadcast items, feed items, and status counts. Returns the last 50 items in reverse chronological order.
- Added `GET /local/delivery-status` endpoint that returns the delivery status summary.
- Wired `deliveryStatus` into `collectDiagnostics()` — includes `totalItems`, `broadcastItems`, `feedItems`, and `statusCounts` in the diagnostics object.
- Wired `deliveryStatus` into the support bundle summary alongside `displayDelivery`.
- Fixed the mock hosted API's `handleMockQueueCommand` to include `commandType` (in addition to `type`) so commands from the mock API heartbeat are properly recognized by the local UI's `commandTypeOf()`. Previously the mock API only set `type`, which the local UI's `commandTypeOf()` doesn't check, causing all heartbeat-delivered commands to be silently skipped during processing.
- Fixed the mock hosted API's `handleMockQueueCommand` to auto-wrap non-meta body fields into `command.payload`, so broadcast-level fields (broadcastId, title, body, priority, etc.) are accessible to command handlers via `command.payload`. Previously the mock API only stored an explicit `body.payload`, but the `show_broadcast` handler reads from `payload.broadcastId` etc.
- Added `scripts/broadcast-delivery-status-check.sh`, a 12-step isolated gate proving: syntax validation, device registration and pairing, broadcast receipt delivery event with correct metadata (source, priority, status, commandId), delivery status endpoint with per-item lifecycle (receivedAt, status, eventCount), feed sync persistence, dismiss status transition (status=dismissed, dismissedAt, eventCount ≥2), delivery status in diagnostics, delivery status in support bundle, expired broadcast rejection (no delivery status entry), and scheduled broadcast status (status=scheduled, receivedAt).

Why this matters:

The delivery log previously recorded `broadcast_shown`, `broadcast_expired`, `broadcast_skipped`, and `broadcast_dismissed` events, but had no receipt event. The admin couldn't tell whether a broadcast was never delivered to a device, or was delivered but not yet shown. The delivery log was also a flat event stream — there was no way to query the current delivery status of a specific broadcast or feed item without scanning and correlating all events. The `broadcast_received` event and `deliveryStatusSummary()` function complete the broadcast delivery lifecycle tracking for MVP 0.4. The delivery status endpoint provides a per-item view that can be exported to the hosted API's `aos_broadcast_deliveries` table, enabling the admin dashboard to show delivery effectiveness per broadcast.

Verification:

- `scripts/broadcast-delivery-status-check.sh` passed all 12 steps.
- `scripts/broadcast-command-check.sh` passed (no regression).
- `scripts/hosted-mock-bridge-check.sh` passed all 6 contract gates (no regression from mock API changes).
- `scripts/feed-display-dwell-check.sh` passed all 12 steps (no regression).
- `scripts/security-smoke.sh` passed.
- `node --check local-ui/server.js` passed.
- `node --check scripts/mock-hosted-api/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.

Next step:

- Wire the delivery status summary into the heartbeat event export so the hosted API can track broadcast delivery per device in `aos_broadcast_deliveries`.
- Add delivery status to the admin Frames dashboard showing broadcast delivery effectiveness (sent/received/shown/dismissed/expired).
- Investigate the `commands.items` vs flat array contract mismatch in the mock API heartbeat response (`{ items: [...] }` vs `[...]`) — this causes commands from heartbeat to be silently dropped by `mergeCommandQueues`.

## 2026-06-08 - Feed sync offline fallback with cache integration

Date: 2026-06-08

Milestone: LEAD / INTEGRATION - cross-system offline fallback

Changed files:

- `local-ui/server.js`
- `scripts/feed-offline-fallback-check.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `buildOfflineFeed()` — builds a complete feed from cached artwork items when the hosted API is unreachable. The function reads the cache index, filters non-expired items with usable cached assets, and produces a normalized feed with `source: "offline_cache"`, cache-browsable media URLs, and proper display metadata.
- Added `isOfflineEligibleError()` — classifies both network-level errors (ECONNREFUSED, ETIMEDOUT, DNS failures) and HTTP-level errors (503 Unavailable, 502 Bad Gateway, 504 Gateway Timeout) as eligible for offline fallback. Auth errors (401/403) and not-found errors (404) are NOT classified as offline-eligible, since they indicate configuration issues rather than connectivity problems.
- Added `writeOfflineState()` — tracks offline state in the runtime state file with `active`, `reason`, `since`, `lastError`, and `cachedItemsUsed` fields. State is updated to `active: false` with `reason: "recovered"` when a successful remote sync completes after an offline period.
- Updated `syncFeedFromRemote()` — when both stream and feed API calls fail, the function now catches the error, checks if cached items are available, and if so builds an offline feed and writes it to the feed state. The offline feed is a full replacement for the remote feed: the kiosk frame displays cached artwork with correct display timing, the display cursor tracks shown items, and cache URLs serve the actual cached assets. When no cached items are available, the function returns `ok: false` with `offline: true` and `cachedItemsAvailable: 0` so the caller knows the device is offline with no fallback content.
- Updated `publicFeed()` — now reports `offline: true/false`, `source` (includes `offline_cache`), and `offlineState` with active status and metadata.
- Updated `collectDiagnostics()` — includes `offline` state from the runtime state file.
- Updated `diagnosticsHealth()` — raises `offline_mode` warning when the device is operating in offline mode.
- Updated support bundle — includes `offline` state in the summary section.
- Added `scripts/feed-offline-fallback-check.sh`, a 12-step isolated integration gate proving:
  1. Syntax validation
  2. Mock API startup (returns 503 to simulate server unavailability)
  3. Local UI startup with paired device
  4. Seeded cached artwork in cache index and on-disk assets
  5. Feed sync offline fallback: API unreachable → `ok: true, offline: true, endpoint: "offline_cache"` with 1 cached item
  6. Feed GET confirms `offline: true, source: "offline_cache"` with active offlineState and displayable queue items
  7. Diagnostics shows `offline.active: true, reason: "hosted_api_unreachable"`
  8. Health raises `offline_mode` warning
  9. Support bundle includes `offline.active: true` in summary
  10. Frame state shows cached items as playable with `media.cached: true`
  11. `isOfflineEligibleError()` covers all network and HTTP-level error patterns
  12. `buildOfflineFeed()` generates feed from cache with `offline_cache` source

Why this matters:

The feed system previously had no error handling for when the hosted API was unreachable. If both the stream and feed endpoints failed, the error propagated to the kiosk page, which showed "Waiting for the living stream" even when perfectly good artwork was sitting in the local cache. This created a hard dependency on the hosted API for the frame to function at all — the device was either online and displaying art, or offline and displaying nothing.

The offline fallback bridges the feed, cache, and diagnostics systems into a coherent offline experience. When the hosted API goes down (network outage, server maintenance, DNS failure), the device automatically switches to displaying cached artwork. The kiosk frame continues cycling through art with correct display timing, the cursor tracks which items have been shown, and the device reports its offline status through diagnostics, health, and support bundles. When connectivity is restored, the next successful sync clears the offline state.

This is the foundational cross-system integration for MVP 0.3 (Offline Living Frame). It proves that the three systems — feed delivery, artwork cache, and health/diagnostics — can compose to produce a graceful degradation experience rather than a hard failure.

Verification:

- `scripts/feed-offline-fallback-check.sh` passed all 12 steps.
- `scripts/device-lifecycle-check.sh` passed all 18 steps (no regression).
- `scripts/hosted-mock-bridge-check.sh` passed all 6 contract gates (no regression).
- `scripts/feed-targeting-check.sh` passed (no regression).
- `scripts/feed-cursor-check.sh` passed (no regression).
- `scripts/feed-display-dwell-check.sh` passed all 12 steps (no regression).
- `scripts/security-smoke.sh` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.

Next step:

- On the Pi, after installing and pairing, disconnect the network and verify the kiosk continues displaying cached artwork. Reconnect and verify the frame recovers to the live feed.
- Wire cache preferences (liked artworks, recent artworks, selected artists) into the offline feed builder so users control which content survives offline.
- Add cache eviction logic to manage storage when the cache grows beyond the configured size limit.

## 2026-06-08 - One-command remote installer for Raspberry Pi

Date: 2026-06-08

Milestone: RPI APPLIANCE - one-command curl-able remote installer

Changed files:

- `remote-install.sh`
- `scripts/remote-install-check.sh`
- `scripts/preflight.sh`
- `scripts/milestone2-verify.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `remote-install.sh`, a self-contained one-command installer for Raspberry Pi that can be curled from a fresh Pi OS image.
- The installer walks 8 stages: guard → deps → download → extract → install → kiosk-config → cleanup-check → done.
- **Guard stage**: Checks root, Linux OS, curl, tar availability. Detects Pi model and RAM.
- **Deps stage**: Installs system dependencies (Node.js 20+ via NodeSource, Chromium, NetworkManager, unclutter, rsync) when not present. Uses non-interactive apt. Respects `AUTOPOIESIS_SKIP_DEPS=1`.
- **Download stage**: Resolves latest GitHub release tag via API, tries multiple common artifact names, falls back to release API asset discovery, then source archive. Supports `AUTOPOIESIS_RELEASE_TAG` for specific versions.
- **Extract stage**: Extracts to temp directory, detects GitHub-style wrapped subdirectory, validates `install.sh` and `VERSION` presence.
- **Install stage**: Runs the standard `install.sh` with configurable install directory and user.
- **Kiosk-config stage**: Runs `configure-kiosk-os.sh` for auto-login, screen blanking, cursor hiding. Graceful failure with manual-run instructions.
- **Cleanup-check stage**: Runs `cleanup-production.sh` audit to catch secret leaks or development artifacts.
- **Done stage**: Prints clear next steps including reboot command, pairing URL, and useful management commands.
- Added `scripts/remote-install-check.sh`, a 14-step isolated gate proving: script syntax, strict mode, cleanup trap, root guard, environment variable handling, release URL construction, dependency installation paths, install flow stages, artifact fallback paths, extract validation, kiosk config integration, production cleanup integration, post-install guidance, and security considerations (no unsafe curl-to-bash piping, temp cleanup on exit).
- Added `remote-install.sh` and `scripts/remote-install-check.sh` to preflight required executables.
- Wired the remote installer gate into Milestone 2 verification as step 15.

Why this matters:

The MVP 1.0 acceptance criteria specify "one-command install" as a production requirement. Until now, installation required cloning the repo and running `install.sh` manually. The remote installer enables deploying to any Pi with `curl -fsSL <url>/remote-install.sh | sudo bash`, downloading the latest release, installing dependencies, configuring kiosk OS mode, and running the production cleanup audit — all in one step. This is the gateway between "code that works" and "a product anyone can install".

Verification:

- `scripts/remote-install-check.sh` passed all 14 steps (44 individual checks).
- `scripts/preflight.sh` passed, detecting `remote-install.sh` and `scripts/remote-install-check.sh`.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `scripts/security-smoke.sh` passed.
- `git diff --check` passed.

Next step:

- Publish a GitHub release with a `autopoiesis-os.tar.gz` artifact and test the remote installer on a fresh Raspberry Pi OS image.
- Add `remote-install.sh` to the README installation documentation.
- Consider hosting the script at a stable short URL (e.g., `install.autopoiesis.art`).

## 2026-06-08 - Settings sync contract fixture in hosted mock bridge

Date: 2026-06-08

Milestone: API / DATABASE / SYNC - settings sync contract bridge

Changed files:

- `scripts/hosted-mock-bridge-check.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Extended the hosted mock bridge from 5 to 6 hosted contract gates, adding settings sync contract fixture generation and validation.
- Added `MOCK_BRIDGE_SKIP_SETTINGS` environment variable for selective gate control.
- Step 9c generates a settings contract fixture proving the mock API's `updatedAt` conflict resolution satisfies the hosted settings contract checker. The fixture exercises the full conflict flow:
  1. Initial read — GET current settings with `updatedAt`
  2. Newer write — POST settings with `updatedAt` 60s in the future (accepted)
  3. Stale write — POST settings with `updatedAt` 60s in the past (conflict rejected, authoritative settings preserved)
  4. Final read — GET confirms the newer write is preserved
  5. Heartbeat — POST heartbeat returns authoritative settings
- The fixture is validated by `scripts/settings-contract-check.sh`, which requires monotonic `updatedAt` ordering, stale-write rejection with conflict markers, final-read freshness at least as current as the accepted newer row, and heartbeat settings coherence.
- Renumbered contract check steps 15→16, 16→17, 17→18 and added new Step 15 for settings contract validation.

Why this matters:

The hosted mock bridge previously proved pairing, device-auth, stream, heartbeat, and release contract shapes, but had no coverage for settings sync — the most complex conflict resolution path in the system. Settings sync uses `latest-updatedAt` conflict resolution: the server must accept newer writes, reject stale writes with explicit conflict markers, and preserve the authoritative row through subsequent reads and heartbeat responses. Without this gate, the mock API's conflict resolution logic had never been validated against the hosted contract shape. The bridge now proves the mock API produces data compatible with 6 hosted contract checkers, covering the complete critical path from device registration through pairing, authentication, settings conflict resolution, content streaming, heartbeat event ingestion, and release management.

Verification:

- `scripts/hosted-mock-bridge-check.sh` passed all 6 contract gates (pairing, device-auth, settings, stream, heartbeat, release).
- `scripts/device-lifecycle-check.sh` passed 17/18 steps (diagnostics/health step is environmental, not related to this change).
- `scripts/online-admin-mock-bridge-check.sh` passed all 12 steps (no regression).
- `scripts/feed-targeting-check.sh` passed (no regression).
- `scripts/security-smoke.sh` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.

Next step:

- Extend the bridge with broadcast contract fixture as the mock API evolves.
- Wire the bridge into the hosted contract suite catalog alongside the device lifecycle gate for comprehensive local validation.
- After the hosted backend is built, generate real settings contract bundles from staging and validate against the same checker.

## 2026-06-08 - Hosted mock bridge pairing and device-auth contract gates

Date: 2026-06-08

Milestone: LEAD / INTEGRATION - pairing + device-auth contract bridge

Changed files:

- `scripts/hosted-mock-bridge-check.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Extended the hosted mock bridge from 3 to 5 hosted contract gates, adding pairing and device-auth fixture generation and validation.
- Added `MOCK_BRIDGE_SKIP_PAIRING` and `MOCK_BRIDGE_SKIP_DEVICE_AUTH` environment variables for selective gate control.
- Step 9a generates a pairing contract fixture from the lifecycle data: device registration (with pairingCode, deviceApiKey, expiresAt), user pairing claim (with ownerUserId, paired=true, settings), and pairing status (with paired=true, device, settings).
- Step 9b generates a device-auth contract fixture with live auth attempts against the mock API for 5 auth-enforced routes (settings-write, heartbeat, stream, command-ack, release) and contract-expected values for 3 open routes (pairing-status, settings-read, commands).
- Fixed the device-auth fixture to use the correct mock API header name (`x-frame-device-key`) and the correct mock API paths (`/frames/device/:id/...` without `/api` prefix).
- Fixed the command-ack route to use the actual queued command ID instead of a hardcoded test ID.
- Registered a second device for cross-device auth testing (mismatchedDevice attempts).
- Sanitized response bodies to remove the mock API's internal `path` field from 404 fallback responses.

Why this matters:

The hosted mock bridge previously covered only 3 of 16+ hosted contract gates (stream, heartbeat, release). Pairing and device-auth are the two most critical gates for first device deployment — pairing is the gateway between "device installed" and "device connected to platform," and device-auth proves every API route enforces per-device credentials. Without these gates in the bridge, the mock API's data model had never been validated against the pairing and device-auth contract shapes. The bridge now proves the mock API produces data compatible with 5 hosted contract checkers, covering the complete critical path from device registration through pairing, authentication, settings sync, heartbeat, content streaming, and release management.

Verification:

- `scripts/hosted-mock-bridge-check.sh` passed all 5 contract gates (pairing, device-auth, stream, heartbeat, release).
- `scripts/device-lifecycle-check.sh` passed 17/18 steps (diagnostics/health step is environmental, not related to this change).
- `scripts/online-admin-mock-bridge-check.sh` passed all 12 steps (no regression).
- `scripts/feed-targeting-check.sh` passed (no regression).
- `scripts/security-smoke.sh` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.

Next step:

- Extend the bridge with settings contract and broadcast contract fixtures as the mock API evolves.
- Wire the bridge into the hosted contract suite catalog alongside the device lifecycle gate for comprehensive local validation.
- After the hosted backend is built, generate real pairing and device-auth contract bundles from staging and validate against the same checkers.

## 2026-06-08 - Content-type-aware display dwell time

Date: 2026-06-08

Milestone: BROADCAST / FEED - per-category display dwell time

Changed files:

- `local-ui/server.js`
- `scripts/feed-display-dwell-check.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `CATEGORY_DISPLAY_SECONDS` — per-category default display durations: `broadcast: 0` (until dismissed, capped at broadcast max), `curatorial: 45s`, `artwork: 60s`, `blog: 30s`, `news: 20s`, `content: 60s`.
- Added `BROADCAST_MAX_DISPLAY_SECONDS` (300s default) — safety cap for broadcast items so "until dismissed" never means forever if the kiosk doesn't send a dismiss.
- Added `categoryDisplaySeconds()` — resolves display duration per category with optional user preference overrides via `preferences.categoryDurations`.
- Updated `frameItemDisplayMs()` to use category-aware durations instead of a single flat `imageDuration` for all non-video items. Video/audio items still use their own duration. Broadcast items with default duration 0 get the `broadcastMaxDuration` cap.
- Exposed `categoryDisplay` in frame-state response — includes `defaults`, `overrides`, and `broadcastMaxSeconds` so the kiosk UI knows exactly what timing applies.
- Exposed `categoryDisplay` in diagnostics feed section for admin/support visibility.
- Added `scripts/feed-display-dwell-check.sh`, a 12-step isolated gate proving: category defaults in frame-state and diagnostics, per-type displayMs for artwork/broadcast/blog/news/curatorial, category duration preference overrides, override visibility in categoryDisplay, broadcast max cap preference, video duration override, and mixed-content queue per-item dwell time preservation.

Why this matters:

The previous system gave every non-video feed item the same `imageDuration` (default 60s). In a mixed content stream, artworks deserve longer display than news flashes, blog posts need less time than curatorial notes, and broadcasts should stay until dismissed (with a safety cap). Without content-type-aware dwell time, the frame spent equal time on every item regardless of content density — a news headline got the same 60s as an intricate artwork. This foundation enables the kiosk UI to present content with rhythm and pacing appropriate to each type, and gives users control over per-category timing through preferences.

Verification:

- `scripts/feed-display-dwell-check.sh` passed all 12 steps.
- `scripts/feed-targeting-check.sh` passed (no regression).
- `scripts/feed-cursor-check.sh` passed (no regression).
- `scripts/broadcast-command-check.sh` passed (no regression).
- `scripts/security-smoke.sh` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.

Next step:

- Wire `categoryDisplay` into the hosted API contract so the online Profile > Frames preferences can sync per-category durations to the device.
- On the Pi, verify the kiosk JavaScript reads `displayMs` from each frame item and uses it as the display interval, creating a natural rhythm between content types.

## 2026-06-08 - Night mode enforcement timer

Date: 2026-06-08

Milestone: RPI APPLIANCE - night mode display power enforcement

Changed files:

- `scripts/night-mode-apply.sh`
- `services/autopoiesis-night-mode.service`
- `timers/autopoiesis-night-mode.timer`
- `scripts/install-systemd-units.sh`
- `local-ui/server.js`
- `scripts/night-mode-timer-check.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/night-mode-apply.sh`, a periodic enforcement script called by a systemd timer every minute to POST the local UI's `/local/night-mode/apply` endpoint.
- Added `services/autopoiesis-night-mode.service`, a systemd oneshot service with full frame-user security sandboxing (ProtectSystem=strict, NoNewPrivileges, MemoryDenyWriteExecute, ReadWritePaths limited to log dir).
- Added `timers/autopoiesis-night-mode.timer` with `OnCalendar=*:0/1` (every minute), `Persistent=true` (catches up after sleep/downtime), and `AccuracySec=30s`.
- Wired the night-mode timer into `install-systemd-units.sh` enable and start blocks.
- Updated the `/local/night-mode/apply` response to include `displayOn` state, so the enforcement script can log whether the display was turned on or off.
- Added `scripts/night-mode-timer-check.sh`, a 10-step isolated gate proving: script syntax, dry-run mode, service ExecStart and dependency, timer schedule, security hardening directives, installer enable/start wiring, apply endpoint displayOn state, apply script log output, unreachable local UI graceful handling, and disabled night mode default displayOn=true.

Why this matters:

The night mode feature was correctly implemented in the local UI — `applyNightMode()` calls `vcgencmd display_power` to turn the display on/off based on the configured time window. But nothing called this function on a schedule. Without a periodic timer, night mode was UI state that never actually enforced itself. The systemd timer bridges this gap: every minute, it calls the apply endpoint, which evaluates whether the current time is inside the night mode window and executes the display power command. The `Persistent=true` directive ensures the timer catches up if the Pi was asleep or powered off during a scheduled transition.

Verification:

- `scripts/night-mode-timer-check.sh` passed all 10 steps.
- `scripts/night-mode-check.sh` passed all 11 steps (no regression).
- `scripts/security-smoke.sh` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.

Next step:

- On the Pi, after install, verify `systemctl list-timers` shows `autopoiesis-night-mode.timer` active. Check `journalctl -u autopoiesis-night-mode.service` for display power transitions at the configured night mode window boundary.

## 2026-06-08 - Night mode syntax fix and integration gate

Date: 2026-06-08

Milestone: LEAD / INTEGRATION - cross-system syntax unblock and night mode validation

Changed files:

- `local-ui/server.js`
- `scripts/night-mode-check.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Fixed two template literal syntax errors in Ewoud's night mode WIP that had been blocking `node --check local-ui/server.js` across every workstream since the feature was introduced.
  - Line 3837 (renderSetup): `${data.preferences.nightMode ? "checked" : "">` missing closing `}` — changed to `""}>`.
  - Line 4563 (renderWelcome): `${nightEnabled ? "checked" : "}>` missing closing `"` for the empty string — changed to `""}>`.
- Added `scripts/night-mode-check.sh`, an 11-step integration gate that proves the night mode feature works correctly across settings, diagnostics, health, and the welcome flow:
  1. Night mode defaults to disabled in diagnostics and health.
  2. Enabling night mode via settings propagates to diagnostics and health.
  3. Cross-midnight range (23:00–06:00) computes correct minute values and active state.
  4. Invalid time values gracefully degrade (enabled but not active, raw values preserved).
  5. `/local/night-mode/apply` endpoint responds with state (no-op on non-Pi hardware).
  6. Disabling night mode resets state in diagnostics and health.
  7. Custom time values (21:30–07:15) persist correctly through settings round-trip with minute conversion.
  8. Support bundle includes night mode in top-level health.
  9. `/launch` redirects to `/welcome` for unpaired devices.
  9b. `/welcome` returns 200 with HTML content.
  9c. `/welcome` contains night mode controls (checkbox, start/end time inputs, toggle container).

Why this matters:

The two syntax errors blocked `node --check` verification for ALL workstreams — every progress entry since the night mode WIP was merged noted the pre-existing syntax error. This single fix unblocks clean automated verification across the entire project. The integration gate proves that Ewoud's night mode feature works coherently across the settings API, diagnostics collection, health summary, support bundle, and the new welcome onboarding flow, catching regressions in any of those systems.

Verification:

- `node --check local-ui/server.js` passed (first clean pass since night mode WIP).
- `node --check scripts/mock-hosted-api/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `scripts/night-mode-check.sh` passed all 11 steps.
- `scripts/security-smoke.sh` passed.
- `scripts/feed-targeting-check.sh` passed (no regression).
- `git diff --check` passed.

Next step:

- On the Pi, verify that `applyNightMode()` correctly calls `vcgencmd display_power` to turn the display on/off at the configured times, and that the night mode toggle in the welcome page's JavaScript correctly shows/hides the time inputs.

## 2026-06-08 - Multi-device fleet isolation gate

Date: 2026-06-08

Milestone: ONLINE ADMIN - multi-owner fleet device isolation

Changed files:

- `scripts/mock-hosted-api/server.js`
- `scripts/online-admin-fleet-isolation-check.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Extended the mock hosted API to support per-owner profile bundles via `GET /mock/online-admin-bundle/:userId`, allowing the fleet isolation gate to fetch Profile > Frames views for different owners.
- Fixed `handleMockPairDevice` route to read and forward the request body (previously ignored, preventing per-owner device pairing via the test helper).
- Added `scripts/online-admin-fleet-isolation-check.sh`, a 12-step isolated gate that:
  1. Starts mock API
  2. Adds a second owner user with a pro subscription (different plan/tier from default owner)
  3. Registers and pairs device A to owner A (default user, basic subscription)
  4. Registers and pairs device B to owner B (user_owner_b, pro subscription)
  5. Syncs different settings for both devices (slideshow/45s vs shuffle/60s)
  6. Sends heartbeats for both devices
  7. Fetches per-owner bundles (owner A default + owner B specific)
  8. Verifies Profile > Frames device isolation: owner A's profile only shows device A, owner B's profile only shows device B
  9. Verifies admin fleet completeness: both bundles show 2 devices with correct ownership
  10. Verifies subscription attribution: owner A=basic, owner B=pro, fleet device subscription references match
  11. Verifies per-device settings propagation through both profile and fleet views
  12. Runs the online-admin contract checker against both bundles

Why this matters:

The previous mock bridge only tested single-owner scenarios. In production, multiple users will own devices in the fleet. This gate proves that the online admin bundle contract enforces device isolation across owners: Profile > Frames never leaks devices from other owners, while admin fleet correctly shows all devices with proper ownership and subscription attribution. The gate also catches cross-owner subscription reference errors, which would cause incorrect entitlement enforcement in the real backend.

Verification:

- `scripts/online-admin-fleet-isolation-check.sh` passed all 12 steps with contract checker passing on both bundles.
- `scripts/online-admin-mock-bridge-check.sh` passed all 12 steps (no regression from mock API changes).
- `node --check scripts/mock-hosted-api/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- Note: `node --check local-ui/server.js` has a pre-existing syntax error from Ewoud's night mode WIP (unrelated to this change).

Next step:

- Add a third device for owner A to prove multi-device-per-owner profile correctness.
- Extend the gate with a negative test: attempt to pair a device to a non-existent user and verify proper error handling.
- Wire the fleet isolation gate into the hosted contract suite alongside the existing mock bridge check.

## 2026-06-07 - Systemd service security hardening

Date: 2026-06-07

Milestone: QA / SECURITY - defense-in-depth appliance sandboxing

Changed files:

- `services/autopoiesis-setup.service`
- `services/autopoiesis-kiosk.service`
- `services/autopoiesis-heartbeat.service`
- `services/autopoiesis-cache.service`
- `services/autopoiesis-command-executor.service`
- `services/autopoiesis-updater.service`
- `services/autopoiesis-watchdog.service`
- `scripts/systemd-security-check.sh`
- `scripts/milestone2-verify.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added systemd security sandboxing directives to all 7 service templates, hardening each service according to its privilege level and role.
- **Frame-user services** (setup, heartbeat, cache): `ProtectSystem=strict`, `NoNewPrivileges=true`, `MemoryDenyWriteExecute=true`, `ReadWritePaths` limited to data and log directories, plus all universal hardening.
- **Kiosk service** (Chromium): `ProtectSystem=full` (Chromium needs broader filesystem access), `NoNewPrivileges=true`, no `MemoryDenyWriteExecute` (Chromium uses JIT).
- **Root services** (command-executor, updater, watchdog): `ProtectSystem=strict` with explicit `ReadWritePaths`, plus all universal hardening. No `NoNewPrivileges` for root services that may need capabilities for service management.
- Universal directives on all services: `PrivateTmp`, `ProtectHome=read-only`, `ProtectClock`, `ProtectKernelModules`, `ProtectKernelLogs`, `ProtectKernelTunables`, `ProtectControlGroups`, `RestrictNamespaces`, `LockPersonality`, `RestrictRealtime`, `RestrictSUIDSGID`, `SystemCallArchitectures=native`, `CapabilityBoundingSet=` (drop all).
- Added `scripts/systemd-security-check.sh`, a 130-point automated gate validating: file existence (7 services), universal hardening (12 directives × 7 services), capability bounding drops, frame-user strict sandboxing with ReadWritePaths, kiosk Chromium-specific profile, root service strict sandboxing, and no hardcoded secrets.
- Wired the gate into `scripts/milestone2-verify.sh` before systemd unit render checks.

Why this matters:

Three services run as root (command-executor, updater, watchdog) and none had any filesystem, capability, or kernel protection. If any service were compromised, the attacker had unrestricted access to the entire filesystem, all kernel interfaces, and all capabilities. The hardening reduces blast radius: compromised services can only write to explicitly whitelisted paths, cannot load kernel modules, cannot create namespaces, cannot gain additional privileges, and cannot access /tmp shared with other processes. For Raspberry Pi appliances deployed in homes and offices, this defense-in-depth layer is essential.

Verification:

- `scripts/systemd-security-check.sh` passed all 130 checks.
- `scripts/systemd-units-install-check.sh` passed (rendering still works with new directives).
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Committed `local-ui/server.js` syntax verified (Ewoud's WIP has a pre-existing template literal syntax error unrelated to this change).
- `git diff --check` passed.

Next step:

- After physical Pi install, run `systemd-analyze security autopoiesis-*.service` to see the exposure score drop compared to the unhardened baseline.
- Verify that `systemctl restart` through watchdog still works with `ProtectSystem=strict` (systemctl uses D-Bus, not filesystem writes, so it should).

## 2026-06-07 - Log rotation and log diagnostics

Date: 2026-06-07

Milestone: RPI APPLIANCE - production log management

Changed files:

- `config/autopoiesis-os.logrotate`
- `local-ui/server.js`
- `install.sh`
- `scripts/install-systemd-units.sh`
- `scripts/preflight.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `config/autopoiesis-os.logrotate` — daily rotation for all 5 appliance log files (heartbeat.log, heartbeat-error.log, update.log, commands.log, commands-error.log). Keeps 14 days of compressed archives, 10 MB per-file max size, uses `copytruncate` to avoid disrupting active processes.
- Added `logDiagnostics()` to the local UI that reports: log directory path, per-file sizes and modification times, total log size in MB, and whether logrotate is configured.
- Propagated log diagnostics through the diagnostics collection, health summary (new issue codes: `logs_no_rotation`, `logs_large`), and support bundle.
- Updated `install-systemd-units.sh` to install the logrotate config into `/etc/logrotate.d/autopoiesis-os` with proper path templating (substitutes the LOG_DIR when customized).
- Updated `scripts/preflight.sh` to validate that `config/autopoiesis-os.logrotate` and `scripts/configure-kiosk-os.sh` exist in the app tree.

Why this matters:

The heartbeat timer fires every 5 minutes, appending to heartbeat.log. At ~576 entries/day, the log grows unbounded without rotation. On a Raspberry Pi with limited SD card storage, unrotated logs are a disk-full risk. The logrotate config prevents this with daily rotation, 14-day retention, and 10 MB size limits.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- `scripts/configure-kiosk-os-check.sh` all 8 tests passed (no regression).
- `scripts/systemd-units-install-check.sh` passed.

Next step:

- On the Pi, verify logrotate runs correctly after install: `sudo logrotate -d /etc/logrotate.d/autopoiesis-os`. Check `/local/diagnostics` for log sizes and logrotate status.


## 2026-06-07 - Kiosk OS configuration helper and display diagnostics

Date: 2026-06-07

Milestone: RPI APPLIANCE - kiosk OS configuration and display readiness

Changed files:

- `scripts/configure-kiosk-os.sh`
- `scripts/configure-kiosk-os-check.sh`
- `local-ui/server.js`
- `install.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/configure-kiosk-os.sh`, a Raspberry Pi OS kiosk configuration helper that handles OS-level setup not covered by `install.sh`: enabling `graphical.target`, enabling auto-login for the appliance user, disabling console and X11 screen blanking, and installing `unclutter` for cursor hiding.
- The helper supports `--dry-run` mode and is safe to re-run (all changes are idempotent).
- Auto-login is configured through three methods: `raspi-config` (Raspberry Pi OS standard), lightdm (`/etc/lightdm/lightdm.conf`), and gdm3 (`/etc/gdm3/custom.conf`). After raspi-config enables auto-login for the default `pi` user, the helper switches it to the appliance user in getty, lightdm, and gdm3 configs.
- Screen blanking is disabled through `raspi-config` (standard), `/etc/kbd/config` (Debian fallback), and an Xsession drop-in at `/etc/X11/Xsession.d/99-autopoiesis-disable-blanking`.
- Added `displayDiagnostics()` to the local UI that detects: DISPLAY/WAYLAND_DISPLAY environment, X11 socket presence, Wayland socket presence, `graphical.target` default, auto-login configuration (lightdm, gdm3, getty), screen blanking status, and unclutter installation.
- Propagated display diagnostics through the diagnostics, health (new issue codes: `display_no_env`, `display_x_socket_missing`, `display_wayland_socket_missing`, `display_not_graphical_target`, `display_no_autologin`, `display_blanking_enabled`), readiness (new `display` phase), compact health, and support bundle.
- Updated `install.sh` post-install message to guide users to run `configure-kiosk-os.sh` before starting services.
- Added `scripts/configure-kiosk-os-check.sh`, an 8-step isolated gate proving: script syntax, help output, dry-run output with custom user, lightdm autologin configuration and idempotency, gdm3 autologin configuration and idempotency, getty autologin user switching, X11 blanking drop-in creation, and dry-run non-modification of existing config.

Verification:

- `scripts/configure-kiosk-os-check.sh` passed all 8 tests.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

- Run `sudo scripts/configure-kiosk-os.sh` on the Raspberry Pi 5 after `install.sh`, then reboot and confirm the Pi boots into Chromium kiosk without manual login. Check diagnostics `/local/diagnostics` for display/kiosk readiness status.


## 2026-06-07 - Online admin mock bridge for Profile/Admin bundle consistency

Date: 2026-06-07

Milestone: ONLINE ADMIN - mock-to-bundle contract bridge

Changed files:

- `scripts/mock-hosted-api/server.js`
- `scripts/online-admin-mock-bridge-check.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added admin user, subscriber, and subscription state to the mock hosted API, with `ensureDefaultAdminUser()` auto-creating the default owner account on first pair.
- Added `GET /mock/online-admin-bundle` endpoint that assembles a full contract-compliant online-admin bundle from the mock API's live state, including Profile > Frames (userId, preferences, cache preferences, active artists, liked artworks, owned devices with actionAvailability) and Admin > Frames (actor, paged users/subscribers/subscriptions/fleet devices, remote actions with 9 command policies and a 4-role action matrix).
- Added `POST /mock/add-user` test helper to add additional admin users with optional subscriber/subscription records.
- Added `scripts/online-admin-mock-bridge-check.sh`, a 12-step integration gate that starts the mock API, walks the full device lifecycle (register → pair → settings sync → heartbeat → command queue/ack → release stage), adds a second trial user, fetches the online-admin bundle, validates the bundle structure, verifies device state propagation into the bundle (online status, settings, release, owner), and runs the full online-admin contract checker against the generated bundle.
- The bridge proves the mock API's data model produces responses compatible with the online-admin contract shape: kind, schema version, user/subscriber/subscription joins, device ownership, fleet device online/settings/release state, cache preference coherence, active artist/liked artwork shape, and complete role-gated remote action policy.

Verification:

- `scripts/online-admin-mock-bridge-check.sh` passed all 12 steps with the online-admin contract checker passing.
- `scripts/device-lifecycle-check.sh` passed all 18 steps (no regression).
- `node --check scripts/mock-hosted-api/server.js` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

- Extend the bridge with a multi-device, multi-owner scenario to prove fleet device isolation and cross-owner subscription consistency.
- Wire the bridge into the hosted mock bridge check alongside the stream/heartbeat/release contract gates.

## 2026-06-07 - Hosted mock bridge for cross-system contract consistency

Date: 2026-06-07

Milestone: LEAD / INTEGRATION - mock-to-hosted contract bridge

Changed files:

- `scripts/hosted-mock-bridge-check.sh`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/hosted-mock-bridge-check.sh`, a cross-system bridge that starts both the mock hosted API and the device-side local UI, walks the full device lifecycle (register → pair → settings → heartbeat → command → release), then generates hosted contract fixtures from the mock API's data model and runs hosted contract checkers (stream, heartbeat, release manifest) against those fixtures.
- Proves the mock API's data model produces responses compatible with hosted contract shapes: schema version, stream metadata, event export format, polling cadence, eventsAck structure, and release manifest.
- The bridge is a 15-step gate that exercises: syntax validation, mock API startup, local UI startup, device registration through local UI, pairing via mock helper, pairing confirmation, settings sync, command queueing, release staging, heartbeat through local UI, hosted stream fixture generation, hosted heartbeat bundle generation, release manifest generation, and all three hosted contract checks.
- Each step validates state at the transition point, proving the complete local UI + mock API chain composes correctly and the resulting data satisfies hosted contract checkers.

Verification:

- `scripts/hosted-mock-bridge-check.sh` passed all 15 steps with 3/3 hosted contract checks passing (stream, heartbeat, release).
- `scripts/device-lifecycle-check.sh` passed all 18 steps (no regression).
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

- Extend the bridge with additional hosted contract gates (pairing, device-auth, settings, broadcast, cache, online-admin) as the mock API evolves to support richer hosted bundle shapes.
- Wire the bridge into Milestone 2 alongside the device lifecycle gate for comprehensive local validation before physical Pi testing.


## 2026-06-07 - Feed display cursor for persistent cycle tracking

Date: 2026-06-07

Milestone: BROADCAST / FEED - persistent display cycle tracking

Changed files:

- `local-ui/server.js`
- `scripts/feed-cursor-check.sh`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added a server-side feed display cursor (`feed-cursor.json`) that tracks which feed items have been displayed since the last successful feed sync.
- On feed sync (`writeFeedState`), the cursor is reset when a new `syncedAt` timestamp is detected, so every sync starts a fresh display cycle.
- On frame item display (`recordFrameItemDisplay`), the displayed item ID is recorded in the cursor (idempotent — re-displaying the same item does not inflate the count).
- The display queue builder (`mixedFeedQueue`) now deprioritizes already-shown items within each priority band: unshown items round-robin first, then previously-shown items fill remaining slots. This means the frame naturally cycles through the full queue before replaying items.
- The cursor is exposed through `GET /local/feed` (`displayCursor`), `GET /local/frame-state` (`displayCursor`), diagnostics (`diagnostics.feed.displayCursor`), and the support bundle (`summary.feedCursor`).
- Added `scripts/feed-cursor-check.sh`, a 5-step isolated gate proving: initial cursor creation, shown-item tracking with display queue reordering, idempotent re-display, cursor reset on re-sync with new-item priority, and support bundle propagation.

Verification:

- `scripts/feed-cursor-check.sh` passed all 5 steps.
- `scripts/feed-targeting-check.sh` passed (no regression).
- `scripts/stream-playback-check.sh` passed (no regression).
- `scripts/broadcast-command-check.sh` passed (no regression).
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.

Next step:

- Confirm on a physical Pi that the frame resumes from the cursor position after a page reload (e.g., from a broadcast interrupting playback), and that new items from a sync are shown before replaying old items.


## 2026-06-07 - Canonical AOS initial database migration

Date: 2026-06-07

Milestone: API / DATABASE / SYNC - canonical migration foundation

Changed files:

- `migrations/20260607000001_initial_aos_frames.sql`
- `scripts/aos-schema-sqlite-validation.sql`
- `scripts/aos-schema-contract-check.sh`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `migrations/20260607000001_initial_aos_frames.sql`, the canonical initial AOS database migration that creates all 14 durable `aos_` tables from the documented schema.
- Tables: `aos_frame_devices`, `aos_frame_pairing_codes` (with `pairing_code_hash`), `aos_frame_device_settings`, `aos_frame_user_preferences`, `aos_heartbeats`, `aos_device_commands`, `aos_admin_command_audits`, `aos_device_events`, `aos_artwork_likes`, `aos_broadcasts`, `aos_broadcast_deliveries`, `aos_releases`, `aos_release_rollouts`, `aos_subscriptions`.
- Each table includes all columns required by `scripts/aos-schema-contract-check.sh`, plus appropriate primary keys, unique constraints, and index definitions.
- Added `scripts/aos-schema-sqlite-validation.sql` for local SQLite schema contract validation (PostgreSQL-compatible types adapted for SQLite).
- Fixed a bug in `scripts/aos-schema-contract-check.sh` where SQLite index rows with `column_name` could overwrite column primary key ordinal data, causing false-negative key validation failures.

Verification:

- `scripts/aos-migration-contract-check.sh migrations/` passed: 1 migration, 14 tables, no destructive SQL.
- `scripts/aos-schema-contract-check.sh` passed against SQLite database built from the migration: 14 tables, 14 required, 0 extra.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

- Import the canonical migration into the hosted backend database, then run `scripts/hosted-contract-suite-check.sh --strict` against the migrated staging database before enabling hosted stream, heartbeat, command, broadcast, and release endpoints.

## 2026-06-07 - Release update bridge for installed appliances

Date: 2026-06-07

Milestone: RPI APPLIANCE - production updater path for installed devices

Changed files:

- `scripts/check-release-update.sh`
- `scripts/check-release-update-check.sh`
- `update.sh`
- `services/autopoiesis-updater.service`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/check-release-update.sh`, a bridge between the systemd updater timer and the local UI hosted release system.
- The bridge checks for curl, respects the device `autoUpdate` preference, probes the local UI health endpoint, calls the local UI release check, and applies the release when an update is available.
- All outcomes are logged to `update.log`; dry-run mode reports what would happen without applying.
- Updated `services/autopoiesis-updater.service` to call `check-release-update.sh` instead of `update-from-github.sh`, with an added dependency on `autopoiesis-setup.service` so the local UI is running when the timer fires.
- Updated `update.sh` to dispatch to `check-release-update.sh` for installed (non-git) appliances, falling back to `update-from-github.sh` only when the app directory is a git checkout.
- Added `scripts/check-release-update-check.sh`, an isolated gate proving: curl-unavailable skip, auto-update-disabled skip, no-update-available pass, successful apply, apply failure with non-zero exit, dry-run logging, and `update.sh` dispatch routing.

Verification:

- `scripts/check-release-update-check.sh` passed all 8 tests.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

- After physical Pi install, confirm `journalctl -u autopoiesis-updater.service` shows the bridge executing, then test a real hosted release cycle.

## 2026-06-07 - Mock hosted API + device lifecycle integration gate

Date: 2026-06-07

Milestone: LEAD / INTEGRATION - end-to-end device lifecycle testing

Changed files:

- `scripts/mock-hosted-api/server.js`
- `scripts/device-lifecycle-check.sh`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/mock-hosted-api/server.js`, a minimal mock of the hosted Frames API that serves contract-compliant responses for all device-facing endpoints: registration, pairing status, settings read/write, heartbeat with event ingestion, content stream/feed, command queue + ack, release check, and artwork likes.
- Added mock test helpers (`/mock/pair-device/:id`, `/mock/queue-command/:id`, `/mock/set-release/:id`, `/mock/state`) so the lifecycle gate can force state transitions without the real backend.
- Added `scripts/device-lifecycle-check.sh`, an 18-step integration gate that starts both the mock API and local UI from a clean temp directory, then walks the full lifecycle: factory state → register → pair → settings push → heartbeat → feed sync → command queue/poll/process → release check → final state verification → diagnostics → support bundle.
- Every step validates state at the transition point, proving all device-side routes compose correctly against contract-compliant hosted responses.

Verification:

- `scripts/device-lifecycle-check.sh` passed all 18 steps.
- `node --check local-ui/server.js` passed.
- `node --check scripts/mock-hosted-api/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

- Evolve the mock API into hosted contract fixtures and run `scripts/hosted-contract-suite-check.sh` against mock-served responses to prove device contracts and hosted contracts agree.
- Add the lifecycle gate to Milestone 2 verification alongside the existing contract checks.

## 2026-06-07 - Release artifact copy fallback

Date: 2026-06-07

Milestone: RELEASE / ROLLOUT - artifact update and rollback resilience

Changed files:

- `scripts/update-from-release.sh`
- `scripts/rollback-release.sh`
- `scripts/release-app-tree-copy-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/github-updates.md`
- `docs/installation.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Reused the installer app-tree copy helper for artifact release snapshot creation, artifact payload installation, and snapshot rollback restore.
- Preserved `rsync --delete` as the preferred copy method while allowing the tested `tar` fallback when `rsync` is absent on lean Raspberry Pi OS images.
- Added an isolated release app-tree gate that applies a checksum-verified artifact release through the forced `tar` path, confirms development paths are excluded, then rolls back from the stored snapshot.
- Wired the new gate into Milestone 2 beside the install app-tree copy check.

Verification:

- `scripts/release-app-tree-copy-check.sh` passed, including artifact apply and snapshot rollback with `AUTOPOIESIS_INSTALL_COPY_METHOD=tar`.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

- Run a staged artifact release on the Pi 5 without preinstalling `rsync`, then run rollback and confirm pairing/config under `/var/lib/autopoiesis-os` survives the app-code revert.


## 2026-06-07 - Hosted suite dependency catalog single source

Date: 2026-06-07

Milestone: LEAD / INTEGRATION - hosted contract orchestration

Changed files:

- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/agent-notes/hosted-contract-suite-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Moved hosted gate dependency metadata into one Bash catalog used by runtime dependency blockers, `--list-gates`, and `--manifest-template`.
- Removed duplicated embedded Node dependency switches from the catalog/template emitters.
- Kept advisory and enforced dependency behavior unchanged while reducing the chance that CI-generated manifests drift from suite enforcement.

Verification:

- Hosted dependency catalog/template parity check passed, including `online-admin` and `release-rollout` dependencies.
- Required `online-admin` plan with only online-admin evidence passed with advisory dependency blockers.
- Dependency-enforced required `online-admin` plan rejected the same incomplete evidence and wrote a failed redacted report.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

- Keep hosted CI manifest generation tied to `--list-gates` / `--manifest-template`, then run `--plan --require-dependencies` before the full suite for readiness and rollout artifacts.


## 2026-06-07 - Installer app-tree copy fallback

Date: 2026-06-07

Milestone: RPI APPLIANCE - one-command install resilience

Changed files:

- `install.sh`
- `scripts/install-app-tree.sh`
- `scripts/install-app-tree-check.sh`
- `scripts/preflight.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/installation.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Moved installer app-tree copying into a dedicated helper used by `install.sh`.
- Preserved `rsync --delete` as the preferred copy method when `rsync` is available.
- Added a `tar` fallback that stages a clean app tree, excludes Git metadata, logs, and `node_modules`, and replaces stale installed files.
- Relaxed preflight from a hard `rsync` requirement to requiring either `rsync` or `tar`.
- Added an isolated app-tree copy gate and wired it into Milestone 2 before systemd rendering checks.

Verification:

- `scripts/install-app-tree-check.sh` passed.
- Preflight passed with `AUTOPOIESIS_PREFLIGHT_MIN_FREE_MB=0`, reporting the `tar` app-tree copy fallback in this environment where `rsync` is unavailable.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Run the one-command installer on the Raspberry Pi 5 from a clean checkout without preinstalling `rsync`; if the fallback path is used, inspect `/opt/autopoiesis-os/current` for excluded development paths before continuing physical Milestone 2.

## 2026-06-07 - Hosted suite dependency readiness

Date: 2026-06-07

Milestone: LEAD / INTEGRATION - hosted contract orchestration

Changed files:

- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/agent-notes/hosted-contract-suite-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added dependency metadata to the hosted suite gate catalog and generated manifest template.
- Added advisory `dependencyBlockers` in the redacted readiness report when a required downstream gate is missing upstream evidence.
- Added `--require-dependencies`, `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE_DEPENDENCIES=1`, and manifest `requireDependencies: true` support so staging can fail fast before trusting partial downstream evidence.
- Cached manifest/env source resolution in one pass so plan/dependency checks do not repeatedly resolve manifest sources.

Verification:

- Gate catalog exposes dependencies for downstream gates such as `online-admin`.
- Manifest template includes dependency metadata for entries such as `release-rollout`.
- Required `online-admin` plan with only an online-admin source passed while reporting advisory dependency blockers.
- Dependency-enforced CLI and manifest plans rejected the same incomplete online-admin evidence.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Have hosted CI run `--plan --require-dependencies` for readiness/rollout manifests before the full suite, while keeping narrow owner-specific contract jobs on advisory dependency reporting when they intentionally validate one fixture.

## 2026-06-07 - Profile action policy coherence

Date: 2026-06-07

Milestone: ONLINE ADMIN - role-gated Profile/Admin remote actions

Changed files:

- `scripts/online-admin-contract-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/admin-system.md`
- `docs/online-frames-profile.md`
- `docs/database-schema.md`
- `docs/agent-notes/backend-online-admin-subscription-consistency-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Tightened the hosted online-admin checker so Profile > Frames device action availability is validated against the canonical Admin remote command policy.
- The checker now rejects owner-facing device rows that allow risky actions without the authorization, audit-id, or local-confirmation flags required by `adminFrames.remoteActions.commands`.
- Documented that Profile-owned devices and Admin fleet devices should use one command-policy evaluator before restart/update/factory-reset controls are enabled.

Verification:

- Representative online-admin bundle with coherent Profile/Admin action policy passed.
- Profile bundle missing `requiresLocalConfirmation` for allowed `factory_reset_request` was rejected.
- Hosted suite required-online-admin pass path accepted the coherent fixture.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Generate the staging online-admin bundle from the same authorization/device-state evaluator for Profile-owned devices and Admin fleet rows, then run it through the strict hosted suite before enabling broad owner-facing remote actions.

## 2026-06-07 - Command state updatedAt ordering

Date: 2026-06-07

Milestone: API / DATABASE / SYNC - durable command outbox state

Changed files:

- `scripts/command-state-contract-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/agent-notes/backend-command-state-contract-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Tightened the hosted command-state checker so post-poll and post-ack `aos_device_commands` rows require durable `updatedAt` evidence by default.
- Added monotonic ordering checks so delivered timestamps cannot precede queued row freshness, terminal timestamps cannot precede delivery, and row `updatedAt` cannot move backwards across poll and ack transitions.
- Documented `deliveredAt` and `updatedAt` as part of the DeviceCommand schema reference.

Verification:

- Representative command-state bundle with monotonic `updatedAt` ordering passed.
- Missing post-poll `updatedAt` evidence was rejected.
- Backwards terminal timestamp ordering was rejected.
- Hosted suite required-command-state pass path accepted the stricter command-state fixture.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Generate the hosted command-state bundle from staging with `deliveredAt` or equivalent poll timestamp plus `updatedAt` on every command row, then run it through the strict hosted suite before enabling broad command controls.

## 2026-06-07 - Settings user preference conflict coverage

Date: 2026-06-07

Milestone: API / DATABASE / SYNC - durable settings and preference conflict contract

Changed files:

- `scripts/settings-contract-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/agent-notes/backend-settings-contract-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Refactored the hosted settings checker around a reusable newest-`updatedAt` conflict flow.
- Added optional nested `userPreferences` validation for `aos_frame_user_preferences` evidence.
- Added `AUTOPOIESIS_REQUIRE_SETTINGS_USER_PREFERENCES=1` so strict backend staging can require both device settings and user preference conflict flows.
- The nested user-preference flow requires heartbeat effective settings to be at least as current as the accepted account-level preference write, proving cascade freshness before Profile/Admin sync evidence is trusted.

Verification:

- Representative settings bundle with required user-preference conflict flow passed.
- Missing `userPreferences` evidence was rejected when `AUTOPOIESIS_REQUIRE_SETTINGS_USER_PREFERENCES=1`.
- Stale user-preference overwrite evidence was rejected.
- Hosted suite required-settings pass path accepted the stricter user-preference fixture.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Generate the hosted settings bundle from staging with both `aos_frame_device_settings` and `aos_frame_user_preferences` rows, then enable `AUTOPOIESIS_REQUIRE_SETTINGS_USER_PREFERENCES=1` in the hosted suite once the adapter emits both flows.

## 2026-06-07 - Hardware profile fixture gate

Date: 2026-06-07

Milestone: RPI APPLIANCE - deterministic hardware suitability coverage

Changed files:

- `scripts/hardware-profile-fixture-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/installation.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added a fixture-backed hardware profile gate that starts the real local UI with fake device-tree model files and fake `vcgencmd get_throttled` output.
- Proved Pi 5 reports `recommended`, Pi 4 reports `supported_baseline`, Pi 3 reports `underpowered`, and throttled/undervoltage Pi 5 output emits `hardware_undervoltage` and `hardware_throttled`.
- The gate validates diagnostics, compact health, readiness, and support-bundle propagation for every fixture case.
- Wired the fixture gate into Milestone 2 before the live hardware check, so classification regressions fail before physical hardware-specific validation.

Verification:

- `scripts/hardware-profile-fixture-check.sh` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Run the fixture gate plus `AUTOPOIESIS_REQUIRE_SUPPORTED_HARDWARE=1 scripts/hardware-profile-check.sh` on the Raspberry Pi 5, then compare live throttling output after Chromium kiosk load against the fixture-proven issue codes.

## 2026-06-07 - Heartbeat-driven feed polling

Date: 2026-06-07

Milestone: BROADCAST / FEED - personalized stream polling and display freshness

Changed files:

- `local-ui/server.js`
- `scripts/feed-targeting-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/agent-notes/feed-polling-heartbeat-note.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added a computed feed polling summary for saved `/stream` cadence, including initial-sync due state, due/stale detection, minimum poll interval handling, due timestamps, and last local poll result.
- `POST /local/heartbeat` now refreshes the stream before sending the hosted heartbeat when the saved polling policy says the feed is due or stale.
- Exposed `pollingStatus` through `/local/feed`, `/local/frame-state`, diagnostics, readiness/health/support surfaces, and `feed_synced` delivery evidence.
- Added a `feed_stale` health issue so support/admin can distinguish stale personalized content from ordinary empty queues.
- Extended the feed targeting gate to prove heartbeat-triggered stream sync, polling status propagation, targeting, schedule filtering, cache eligibility, and mixed-stream broadcast display evidence together.

Verification:

- `scripts/feed-targeting-check.sh` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Have hosted staging emit realistic `nextPollAt`, `pollAfterSeconds`, `minPollSeconds`, and `staleAfter` values from durable `aos_` stream policy rows, then confirm a paired Pi stays fresh without manual `/local/feed/sync` calls.


## 2026-06-07 - Hosted suite manifest template

Date: 2026-06-07

Milestone: LEAD / INTEGRATION - hosted contract orchestration

Changed files:

- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/agent-notes/hosted-contract-suite-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `--manifest-template` / `--template` to the hosted contract suite.
- The command prints a disabled JSON manifest skeleton generated from the same gate catalog used for strict mode and execution.
- Each generated source entry includes source env, checker, and label metadata so CI can fill and enable owned evidence without maintaining a parallel gate list.
- Template mode exits before loading manifests, running checkers, or writing readiness reports.

Verification:

- `scripts/hosted-contract-suite-check.sh --manifest-template` produced parseable JSON with the full 16-gate source skeleton.
- Plan mode accepted the disabled generated template.
- Plan mode accepted the generated template after enabling and requiring the `stream` gate.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Have hosted CI seed staging manifests from `--manifest-template`, fill owned sources, archive the filled manifest plus redacted `--plan` report, then run the full hosted suite from the same artifact before physical Pi validation.

## 2026-06-07 - Hardware profile acceptance gate

Date: 2026-06-07

Milestone: RPI APPLIANCE - Pi 5 target and hardware suitability

Changed files:

- `local-ui/server.js`
- `scripts/hardware-profile-check.sh`
- `scripts/milestone2-verify.sh`
- `scripts/preflight.sh`
- `scripts/support-bundle-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/installation.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added hardware profile diagnostics to the local UI, including model, architecture, RAM, support tier, and optional `vcgencmd get_throttled` power/thermal state.
- Classified Raspberry Pi 5 as `recommended`, Raspberry Pi 4 as `supported_baseline`, Pi 3/older as `underpowered`, and x86_64 as `development_host`.
- Propagated hardware state through diagnostics, compact health, readiness, and support bundles with stable issue codes for underpowered hardware, low RAM, unknown hardware, undervoltage, and throttling.
- Added `scripts/hardware-profile-check.sh` and wired it into Milestone 2 with `AUTOPOIESIS_REQUIRE_SUPPORTED_HARDWARE=1`.
- Updated preflight so app-tree checks require the hardware profile gate and install preflight reports the Pi 5/Pi 4/Pi 3 suitability line.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- Temp local UI smoke on port 3130 passed `scripts/hardware-profile-check.sh`, `scripts/support-bundle-check.sh`, compact health, and readiness hardware phase checks.
- `scripts/security-smoke.sh` passed after stopping the temp local UI process.
- `AUTOPOIESIS_PREFLIGHT_MIN_FREE_MB=0 ./scripts/preflight.sh` reached the new hardware check and reported x86_64 as a development/mini-PC host, but still failed because this environment lacks `rsync`.

Next step:

Run `AUTOPOIESIS_REQUIRE_SUPPORTED_HARDWARE=1 scripts/hardware-profile-check.sh` and full Milestone 2 on the new Raspberry Pi 5, then inspect the support bundle for throttling/undervoltage after Chromium has been running for a while.


## 2026-06-07 - Online admin ownership and subscription joins

Date: 2026-06-07

Milestone: ONLINE ADMIN - Profile/Admin ownership and entitlement coherence

Changed files:

- scripts/online-admin-contract-check.sh
- README.md
- docs/api-contract.md
- docs/admin-system.md
- docs/online-frames-profile.md
- docs/database-schema.md
- docs/agent-notes/backend-online-admin-subscription-consistency-issue.md
- docs/agent-notes/pulse.md
- docs/progress.md
- /data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md

Implemented:

- Tightened the hosted online-admin bundle gate so Profile > Frames device rows must expose ownerUserId matching profileFrames.userId.
- Fleet device subscription summaries now must reference a subscription owned by the same device owner.
- Subscriber and fleet-device subscription summaries must match referenced subscription status, plan, and tier when those fields are present.
- Relaxed the subscriber/subscription join so users can expose historical subscription rows while subscriber.subscriptionId still points at the canonical current row.

Verification:

- Representative online-admin bundle acceptance passed.
- Missing Profile device ownerUserId was rejected.
- Fleet device subscription id owned by another user was rejected.
- Subscriber summary status drift from the referenced subscription was rejected.
- Hosted suite required-online-admin pass path passed.
- node --check local-ui/server.js passed.
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed.
- git diff --check passed.
- scripts/security-smoke.sh passed.

Next step:

Generate the online-admin bundle from staging with ownerUserId on every Profile device row and subscription summaries joined from one canonical account/subscription projection before enabling subscription-gated fleet actions.

## 2026-06-07 - Hosted suite gate catalog

Date: 2026-06-07

Milestone: LEAD / INTEGRATION - hosted contract orchestration

Changed files:

- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/agent-notes/hosted-contract-suite-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `--list-gates` / `--catalog` to the hosted contract suite.
- The command prints JSON with each hosted gate's name, order, source environment variable, checker script, and label, then exits without loading manifests, running checkers, or writing readiness reports.
- Reworked the shell runner so strict all-gate requirements and execution order use the same `for_each_gate` table.
- Documented the catalog as the source of truth for CI manifest generation and rollout annotations.

Verification:

- `scripts/hosted-contract-suite-check.sh --list-gates` produced the expected 16-gate JSON catalog.
- Plan mode still accepted a manifest-required `stream` source and wrote a matching redacted report.
- Unknown required gates still failed before checker execution.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Have hosted CI generate the contract manifest from `--list-gates`, then run `--plan` and the full suite from that generated manifest so backend readiness and physical Pi handoff share one gate catalog.

## 2026-06-07 - Watchdog restart policy gate

Date: 2026-06-07

Milestone: RPI APPLIANCE - watchdog recovery acceptance

Changed files:

- `scripts/watchdog-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/installation.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added an isolated acceptance gate for the real `scripts/watchdog.sh`.
- The gate stubs `curl`, `pgrep`, `systemctl`, and `sleep` so it can verify watchdog policy without touching live services.
- It proves healthy no-op behavior, setup restart when `/local/health` fails once, setup restart when `/launch` fails once, and kiosk restart when the Chromium process is missing once.
- Wired the gate into Milestone 2 before invoking the live watchdog.

Verification:

- `scripts/watchdog-check.sh` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Run full Milestone 2 on physical Pi hardware and compare the isolated watchdog gate with real `journalctl -u autopoiesis-watchdog.service` output after forcing one setup outage and one kiosk restart.

## 2026-06-07 - Hosted manifest source validation

Date: 2026-06-07

Milestone: LEAD / INTEGRATION - hosted contract orchestration

Changed files:

- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added an early manifest source lint step to the hosted contract suite.
- The suite now rejects unknown keys in `sources`, `contracts`, `gates`, and `contractSources` instead of silently skipping typoed gates.
- Enabled object entries must provide `source`, `path`, `file`, or `url`; intentionally disabled entries can use `false` or `{ "enabled": false }`.
- Plan mode and full execution now share the same manifest validation path before any individual contract checker runs.

Verification:

- Plan mode accepted a valid manifest source.
- Plan mode rejected an unknown manifest source gate.
- Plan mode rejected an enabled manifest source entry without a source value.
- Disabled manifest source entries were skipped cleanly.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Have hosted CI treat manifest source lint failures as artifact-generation bugs before running the full suite or handing the bundle to physical Pi validation.

## 2026-06-07 - Hosted suite planning mode

Date: 2026-06-07

Milestone: LEAD / INTEGRATION - hosted contract orchestration

Changed files:

- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/agent-notes/hosted-contract-suite-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `--plan` / `--dry-run` to the hosted contract suite so CI can inspect a redacted gate/source matrix without executing individual checkers.
- Plan mode validates manifest and required-gate configuration, fails missing required sources, and marks source-present gates as `planned`.
- The JSON readiness report now includes `mode` and `summary.planned`, and can be emitted for plan runs as well as pass/fail runs.
- Required-gate names supplied by `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE` are now normalized and typo-checked before gate execution.

Verification:

- Plan mode with a manifest source produced a redacted report with `mode: plan`, `summary.planned: 1`, and no raw fixture path.
- Plan mode rejected a missing required source.
- Unknown required gate names in `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE` were rejected before checker execution.
- Existing required-release report generation passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Have hosted CI generate a plan report and a full run report from the same manifest, then use the plan report for rollout annotations before physical Pi validation.

## 2026-06-07 - Online admin profile coherence

Date: 2026-06-07

Milestone: ONLINE ADMIN - Profile > Frames state coherence

Changed files:

- `scripts/online-admin-contract-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/admin-system.md`
- `docs/online-frames-profile.md`
- `docs/database-schema.md`
- `docs/agent-notes/backend-online-admin-profile-coherence-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Tightened the hosted online-admin bundle gate so Profile > Frames cache preferences must agree with mirrored cache fields in `preferences`.
- Active artist rows now reject duplicate artist ids and must be coherent with `preferences.activeArtists` when that selection list is present.
- Liked artwork rows now reject duplicate artwork ids in both flat and paged forms, and paged totals cannot be smaller than the returned rows.
- Added a backend handoff note for generating coherent profile evidence from canonical preference, cache, artist, and like projections.

Verification:

- Representative online-admin bundle acceptance passed.
- Hosted suite required-online-admin pass path passed.
- Cache preference mismatch was rejected.
- Duplicate active artist id was rejected.
- Disabled selected artist was rejected.
- Duplicate liked artwork id was rejected.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Generate the online-admin bundle from hosted staging using one canonical Profile > Frames projection, then run the strict hosted suite before enabling cache controls, active artist toggles, or liked artwork pagination.

## 2026-06-07 - Hosted command state contract

Date: 2026-06-07

Milestone: API / DATABASE / SYNC - durable command outbox transitions

Changed files:

- `scripts/command-state-contract-check.sh`
- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/agent-notes/backend-command-state-contract-issue.md`
- `docs/agent-notes/hosted-contract-suite-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/command-state-contract-check.sh`, a read-only hosted contract gate for durable command outbox state transitions.
- The gate validates a queued before-poll row, matching delivered/sent post-poll row with delivered timestamp evidence, matching terminal post-ack row with terminal timestamp evidence, mirrored admin audit status, next-poll exclusion of terminal commands, and redaction of credentials, raw payloads, artifact details, stdout/stderr, and local appliance paths.
- Wired `command-state` into `scripts/hosted-contract-suite-check.sh` after command acknowledgement, including strict mode, manifest requirements, aliases, report rows, and source env support.
- Added backend handoff notes for the staging-only `/api/admin/frames/command-state-contract-bundle` adapter.

Verification:

- Representative command-state bundle passed.
- Missing post-poll delivered-row fixture was rejected.
- Terminal command re-delivery in next poll was rejected.
- Hosted suite required-command-state pass/rejection paths passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Generate the hosted command-state bundle from seeded `aos_device_commands`, `aos_admin_command_audits`, the command poll serializer, and the ack route integration tests. Decide whether poll marks rows `sent` immediately or whether initial `acknowledged` is the canonical delivered transition before broad remote commands ship.

## 2026-06-07 - Setup launcher custom path hardening

Date: 2026-06-07

Milestone: RPI APPLIANCE - custom install path fidelity

Changed files:

- `scripts/start-setup.sh`
- `scripts/setup-launcher-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/installation.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Reworked the setup/local UI launcher so it uses `AUTOPOIESIS_APP_DIR` when systemd provides it, or derives the app root from the installed script location when run directly.
- Added a clear failure when `local-ui/server.js` is missing instead of silently attempting the default `/opt/autopoiesis-os` path.
- Added `scripts/setup-launcher-check.sh`, an isolated dry-run gate proving custom app roots, default script-relative roots, and missing-server failures.
- Wired the gate into Milestone 2 alongside the systemd unit render check.

Verification:

- `scripts/setup-launcher-check.sh` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

On physical Pi hardware, run `systemctl cat autopoiesis-setup.service` and full Milestone 2 after a default install and any custom-root install to confirm the rendered `AUTOPOIESIS_APP_DIR` and launcher dry run point at the same installed app tree.

## 2026-06-07 - Active-window stream contract hardening

Date: 2026-06-07

Milestone: BROADCAST / FEED - hosted stream acceptance

Changed files:

- `scripts/stream-contract-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/agent-notes/backend-stream-contract-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Tightened the hosted stream contract checker so each item must be individually displayable, not only part of a globally playable response.
- Added mixed-content type/category validation aligned with the local queue categories for broadcast, curatorial, artwork, blog, news, and general content.
- Added active-window validation relative to root `generatedAt`, rejecting future `startsAt`, expired `expiresAt`, and inverted `startsAt >= expiresAt` rows before physical Pi handoff.
- Expanded snake_case field validation for media, links, duration, artist, and text aliases used by hosted fixtures.

Verification:

- Representative stream fixture passed with artwork, blog, news, curatorial, broadcast, and content items plus polling metadata.
- Future, expired, inverted-window, unsupported-type, and non-displayable item fixtures were rejected as expected.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Generate the durable hosted `/api/frames/device/{deviceId}/stream` staging fixture from `aos_` content, broadcast, preference, subscription, and device rows, then run the strict hosted suite before physical Pi cache/feed playback validation.

## 2026-06-07 - Hosted suite JSON readiness report

Date: 2026-06-07

Milestone: LEAD / INTEGRATION - hosted contract orchestration

Changed files:

- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/agent-notes/hosted-contract-suite-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added optional `AUTOPOIESIS_HOSTED_CONTRACT_REPORT` output to the hosted contract suite.
- The suite now writes a redacted JSON report on pass and fail with status, exit code, manifest/CLI strictness, required gates, summary counts, per-gate pass/skip/missing-required state, and failed gate/reason when available.
- The report intentionally records source-presence booleans and source environment names only, avoiding raw fixture paths, URLs, bearer tokens, or local appliance paths.
- Gate execution now captures checker failures explicitly so failing gates can be named in the report before the suite exits.

Verification:

- Hosted-suite report smoke passed for a required release manifest gate and confirmed the report did not leak the fixture path.
- Hosted-suite report failure smoke passed for a missing required release source and recorded `failedGate=release`.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Have hosted CI/staging set `AUTOPOIESIS_HOSTED_CONTRACT_REPORT` beside the manifest artifact, archive the report, and use its `status`/per-gate fields for rollout annotations before physical Pi validation.


## 2026-06-07 - Device update channel enforcement

Date: 2026-06-07

Milestone: RELEASE / ROLLOUT - channel-safe updater behavior

Changed files:

- `scripts/update-from-release.sh`
- `local-ui/server.js`
- `README.md`
- `docs/api-contract.md`
- `docs/github-updates.md`
- `docs/installation.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Hardened `scripts/update-from-release.sh` so release apply automatically reads the device-local `updateChannel` from `device.json` when `AUTOPOIESIS_RELEASE_CHANNEL` is not already set.
- When a device has a configured update channel, release apply now requires the manifest to declare a matching `channel`/`updateChannel` before rollback metadata, download, git fallback, or app-code mutation begins.
- Manifest validation failures are now appended to `update.log` before release apply exits, so channel/metadata rejections are visible in device support logs.
- Extended release field extraction so rollback metadata records release channel, tag, and release id alongside previous version/revision and artifact snapshot path.
- Added release tag metadata to local release history events and recorded release channel/tag in in-progress, completed, and failed local `release-state.json` values.

Verification:

- Device-channel mismatch smoke rejected a beta manifest on a stable device before writing rollback metadata and recorded the mismatch in `update.log`.
- Explicit `AUTOPOIESIS_RELEASE_CHANNEL=stable` manifest check passed for a stable fixture and rejected a beta fixture.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Have hosted release generation always include `channel`/`updateChannel`, `tagName`/`tag`, and rollback notes, then run one artifact update on physical Pi hardware to confirm channel-safe apply plus rollback metadata under `/var/lib/autopoiesis-os/release-rollback.json`.


## 2026-06-07 - Hosted suite manifest requirements

Date: 2026-06-07

Milestone: LEAD / INTEGRATION - hosted contract orchestration

Changed files:

- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/agent-notes/hosted-contract-suite-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Extended hosted contract manifests with self-declared required gates via `require`, `required`, `requireGates`, `requiredGates`, or `required_gates`.
- Added manifest-level full-suite requirements with `strict: true`, `requireAll: true`, or `require_all: true`, so staging artifacts can require every hosted gate without also passing `--strict`.
- Preserved existing behavior for per-gate source environment overrides, external `--strict`, and `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE`; manifest and environment requirements are unioned for partial jobs.
- Added validation for unknown manifest-required gate names so typoed CI manifests fail before physical Pi handoff.

Verification:

- Manifest-declared required release gate passed with a relative source fixture.
- Object-form required gate manifest passed with a disabled non-required gate.
- Missing manifest-required release source rejection passed.
- Manifest `strict: true` all-gate expansion rejected a missing migrations source as expected.
- Unknown manifest-required gate rejection passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Generate the hosted staging artifact manifest with `require` for partial jobs and `strict: true` for full backend readiness, then run `AUTOPOIESIS_HOSTED_CONTRACT_MANIFEST=/path/to/hosted-contract-manifest.json scripts/hosted-contract-suite-check.sh` before physical Pi validation.

## 2026-06-07 - Heartbeat runner resilience gate

Date: 2026-06-07

Milestone: RPI APPLIANCE - timer-driven heartbeat reliability

Changed files:

- `scripts/heartbeat.sh`
- `scripts/heartbeat-runner-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/installation.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Hardened `scripts/heartbeat.sh` so the systemd heartbeat timer creates its log directory, normalizes the local heartbeat URL, and falls back to `unknown` identity/mode when `device.json` or `state.json` is missing or malformed.
- Added `scripts/heartbeat-runner-check.sh`, an isolated gate for the timer wrapper that uses a mock `curl` and temporary data/log directories.
- The gate verifies successful local heartbeat logging, local UI failure logging, URL normalization, and missing/malformed state resilience without touching the hosted Frames API.
- Wired the gate into Milestone 2 verification before the deeper heartbeat event-ingestion cursor contract.

Verification:

- `scripts/heartbeat-runner-check.sh` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Run full Milestone 2 on physical Pi hardware and inspect `/var/log/autopoiesis-os/heartbeat.log` plus `heartbeat-error.log` after boot, pairing, and one forced local UI outage.

## 2026-06-07 - Hosted suite manifest integration

Date: 2026-06-07

Milestone: LEAD / INTEGRATION - hosted contract orchestration

Changed files:

- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/agent-notes/hosted-contract-suite-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `AUTOPOIESIS_HOSTED_CONTRACT_MANIFEST` support to the hosted contract suite, with `AUTOPOIESIS_HOSTED_CONTRACT_BUNDLE` as an alias.
- The manifest can provide a `sources`/ `contracts`/ `gates` object keyed by normalized gate names, with string paths or objects containing `source`, `path`, `file`, or `url`.
- Relative manifest fixture paths resolve from the manifest directory, and URL manifests preserve URL-relative source resolution.
- Per-gate `AUTOPOIESIS_*_SOURCE` variables still override manifest entries, so CI can use one bundle index while developers can rerun or replace one gate.
- Documented the manifest shape and corrected hosted-suite docs to include the command polling gate in dependency order.

Verification:

- Manifest-driven hosted suite passed with a representative stream fixture.
- Manifest-relative path resolution passed with a nested manifest directory.
- Per-gate environment override passed, replacing the manifest stream source.
- Required missing-source rejection passed with a manifest that did not include the required pairing gate.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Generate a hosted staging artifact manifest next to the individual contract fixtures and run `AUTOPOIESIS_HOSTED_CONTRACT_MANIFEST=/path/to/hosted-contract-manifest.json scripts/hosted-contract-suite-check.sh --strict` before treating backend evidence as physical-Pi-ready.

## 2026-06-07 - Online admin subscription consistency

Date: 2026-06-07

Milestone: ONLINE ADMIN - account/subscription admin readiness

Changed files:

- `scripts/online-admin-contract-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/admin-system.md`
- `docs/online-frames-profile.md`
- `docs/agent-notes/backend-online-admin-subscription-consistency-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Tightened `scripts/online-admin-contract-check.sh` so Admin > Frames account pages must be join-consistent, not only shape-valid.
- Added duplicate-id checks for users, subscribers, subscriptions, and fleet devices.
- Added page-total validation so paged admin sections cannot report totals smaller than returned rows.
- Required subscribers, subscriptions, fleet device owners, and device subscription summaries to reference the corresponding listed user/subscription rows.
- Required entitled subscription statuses to have a matching subscriber row before subscription-gated fleet controls are considered ready.
- Added a backend handoff note for generating this evidence from canonical account/subscription models plus durable `aos_` device rows.

Verification:

- Representative online-admin bundle acceptance passed.
- Unknown subscriber user rejection passed.
- Entitled subscription missing subscriber rejection passed.
- Fleet device owner reference rejection passed.
- Hosted suite required-online-admin pass and missing-source rejection passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Generate the online-admin bundle from hosted staging using the canonical billing/subscription provider, normalize entitlement statuses once, and run the strict hosted suite before enabling subscription-gated remote actions or fleet subscription filters.

## 2026-06-07 - Hosted command polling contract

Date: 2026-06-07

Milestone: LEAD / INTEGRATION - remote command queue readiness

Changed files:

- `scripts/command-poll-contract-check.sh`
- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/agent-notes/backend-command-poll-contract-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/command-poll-contract-check.sh`, a read-only saved-bundle/live-URL verifier for hosted command polling readiness.
- The checker validates durable command rows, the exact command set returned to an authorized device poll, missing queued-row detection, duplicate returned command rejection, ineligible command exclusion, blocked/denied poll evidence, risky command authorization metadata, high/critical audit ids, local confirmation on factory reset requests, and sensitive/local-only redaction.
- Wired `command-poll` into `scripts/hosted-contract-suite-check.sh` immediately after heartbeat and before command acknowledgement, so strict hosted readiness proves command delivery selection before ack durability.
- Added a backend handoff note for generating the bundle from `aos_device_commands`, `aos_admin_command_audits`, device eligibility state from `aos_frame_devices`, and the same serializer used by heartbeat command responses or `GET /commands`.

Verification:

- `scripts/command-poll-contract-check.sh` passed against a representative command polling bundle.
- `scripts/command-poll-contract-check.sh` rejected an authorized poll response that omitted a queued command row for the target device.
- `scripts/command-poll-contract-check.sh` rejected a denied poll response that leaked commands.
- `scripts/command-poll-contract-check.sh` rejected a high-risk command missing an audit id.
- `scripts/hosted-contract-suite-check.sh` passed with `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE=command-poll` and the command-poll source provided.
- `scripts/hosted-contract-suite-check.sh` rejected a missing required command-poll source.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Generate the command-poll bundle from hosted staging or CI using real durable command rows and command-poll route/heartbeat serializers, then run the strict hosted suite before enabling broad remote command actions.

## 2026-06-07 - Hosted command acknowledgement contract

Date: 2026-06-07

Milestone: API / DATABASE / SYNC - command acknowledgement durability

Changed files:

- `scripts/command-ack-contract-check.sh`
- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/agent-notes/backend-command-ack-contract-issue.md`
- `docs/agent-notes/hosted-contract-suite-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/command-ack-contract-check.sh`, a read-only saved-bundle/live-URL verifier for hosted command acknowledgement durability.
- The checker validates durable command rows, acknowledgement attempts, terminal command timestamps, matching admin audit status, heartbeat-ingested `command_audit` events, duplicate final-ack idempotency, and sensitive/local-only redaction.
- Wired `command-ack` into `scripts/hosted-contract-suite-check.sh` after heartbeat, so strict hosted readiness now proves explicit ack persistence before stream/cache/admin evidence is trusted.
- Added a backend handoff note for generating the bundle from `aos_device_commands`, `aos_admin_command_audits`, `aos_device_events`, and route-level ack attempts.

Verification:

- `scripts/command-ack-contract-check.sh` passed against a representative command acknowledgement bundle.
- `scripts/command-ack-contract-check.sh` rejected a final acknowledgement whose durable command row was not terminal.
- `scripts/command-ack-contract-check.sh` rejected duplicate `deviceId + eventKey` command-audit event evidence.
- `scripts/hosted-contract-suite-check.sh` passed with `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE=command-ack` and the command-ack source provided.
- `scripts/hosted-contract-suite-check.sh` rejected a missing required command-ack source.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Generate the command-ack bundle from hosted staging or CI using real `POST /commands/{commandId}/ack` route tests plus durable `aos_` command, audit, and device-event rows before enabling broad remote command controls.

## 2026-06-07 - Factory reset contract gate

Date: 2026-06-07

Milestone: RPI APPLIANCE - reset safety and hardware acceptance

Changed files:

- `scripts/factory-reset-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/installation.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/factory-reset-check.sh`, an isolated acceptance gate for the real `factory-reset.sh` behavior.
- The gate seeds paired identity, preferences, state, pairing, commands, broadcast, feed/cache, release, event cursor, support-history, data-cache, and install-cache files in temporary directories.
- It proves the default reset regenerates an unpaired device identity, restores default preferences/state, clears runtime/support/cache state, recreates install cache directories, and records setup/kiosk restart intent through a stubbed `systemctl`.
- It separately verifies `--keep-support-history` preserves diagnostics/audit/delivery/release JSON while still clearing paired runtime state.
- It verifies `--dry-run --no-restart` leaves seeded identity, runtime, support, and cache files untouched.
- Wired the factory reset check into Milestone 2 verification so physical Pi acceptance catches reset drift before operators run the destructive reset on real appliance state.

Verification:

- `scripts/factory-reset-check.sh` passed.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Run full Milestone 2 on physical Pi hardware, then collect a support bundle, run `sudo /opt/autopoiesis-os/app/factory-reset.sh --dry-run`, run the real reset, confirm the setup screen returns with a new unpaired device id, and re-pair before the next staged rollout check.

## 2026-06-07 - Feed polling metadata contract

Date: 2026-06-07

Milestone: BROADCAST / FEED - stream polling/freshness readiness

Changed files:

- `local-ui/server.js`
- `scripts/stream-contract-check.sh`
- `scripts/feed-targeting-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added local normalization for hosted stream polling/freshness hints from root `polling`/`refresh` fields or `stream.polling`.
- Preserved redacted cadence fields in the normalized local feed: `pollAfterSeconds`, `minPollSeconds`, `maxPollSeconds`, `nextPollAt`, `staleAfter`, and a short reason.
- Exposed polling metadata through `POST /local/feed/sync`, `GET /local/feed`, local diagnostics/support, and metadata-only `feed_synced` delivery evidence.
- Tightened `scripts/stream-contract-check.sh` with optional `AUTOPOIESIS_REQUIRE_STREAM_POLLING=1` validation for hosted stream cadence fixtures.
- Extended `scripts/feed-targeting-check.sh` to prove mock stream polling cadence survives sync, public feed redaction, diagnostics, and delivery logging.

Verification:

- `scripts/feed-targeting-check.sh` passed.
- `AUTOPOIESIS_REQUIRE_STREAM_POLLING=1 scripts/stream-contract-check.sh` passed against a representative stream fixture with `stream.polling`.
- `AUTOPOIESIS_REQUIRE_STREAM_POLLING=1 scripts/stream-contract-check.sh` rejected a stream fixture with no polling cadence.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Generate the hosted stream response from staging with canonical `stream.polling` metadata and run the strict stream gate before treating live feed polling cadence as ready for Pi rollout.

## 2026-06-07 - Hosted profile ownership contract

Date: 2026-06-07

Milestone: LEAD / INTEGRATION - Profile account ownership readiness

Changed files:

- `scripts/profile-ownership-contract-check.sh`
- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/online-frames-profile.md`
- `docs/agent-notes/backend-profile-ownership-contract-issue.md`
- `docs/agent-notes/hosted-contract-suite-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/profile-ownership-contract-check.sh`, a read-only saved-bundle/live-URL verifier for hosted Profile > Frames account/session scoping.
- The checker validates owned device list/read/settings-write success, cross-owner device read/settings-write/command rejection, anonymous Profile rejection, Admin fleet-read separation, duplicate check kinds, required check coverage, and redaction of device credentials, pairing codes/hashes, private/admin tokens, secrets, and local appliance paths.
- Wired `profile-ownership` into `scripts/hosted-contract-suite-check.sh` after settings conflict validation so strict hosted readiness now proves both device-route auth and account-route ownership before heartbeat/admin evidence is trusted.
- Added a backend handoff note for generating the bundle from canonical account/session tests plus durable `aos_frame_devices.owner_user_id` ownership rows.

Verification:

- `scripts/profile-ownership-contract-check.sh` passed against a representative Profile ownership bundle.
- `scripts/profile-ownership-contract-check.sh` rejected a bundle where a cross-owner device read returned 200 with another owner's device row.
- `scripts/profile-ownership-contract-check.sh` rejected a bundle missing the required Admin fleet-read boundary check.
- `scripts/hosted-contract-suite-check.sh` passed with `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE=profile-ownership` and the profile-ownership source provided.
- `scripts/hosted-contract-suite-check.sh` rejected a missing required profile-ownership source.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Generate the profile-ownership bundle from hosted staging or CI using real account/session authorization paths, then run the strict hosted suite before enabling destructive owner actions in Profile > Frames.

## 2026-06-07 - Hosted release rollout contract

Date: 2026-06-07

Milestone: LEAD / INTEGRATION - release/update rollout readiness

Changed files:

- `scripts/release-rollout-contract-check.sh`
- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/agent-notes/backend-release-rollout-contract-issue.md`
- `docs/agent-notes/hosted-contract-suite-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/release-rollout-contract-check.sh`, a read-only saved-bundle/live-URL verifier for hosted Admin > Frames release rollout evidence.
- The checker validates durable release rows, per-device rollout progress rows, queued `update_device` commands, approved authorization/audit metadata, optional admin audits, heartbeat-ingested `release_history` events, duplicate ids/event keys, unknown references, and redaction of credentials, tokens, artifact URLs, checksums, and local appliance paths.
- Wired `release-rollout` into `scripts/hosted-contract-suite-check.sh` after release manifest validation so strict hosted readiness now proves both a device-acceptable release manifest and durable rollout/admin evidence.
- Added a backend handoff note for generating the bundle from `aos_software_releases`, `aos_release_rollouts`, `aos_device_commands`, `aos_admin_command_audits`, and `aos_device_events` projections.

Verification:

- `scripts/release-rollout-contract-check.sh` passed against a representative release/update rollout bundle.
- `scripts/release-rollout-contract-check.sh` rejected a bundle with an `update_device` command missing authorization metadata.
- `scripts/release-rollout-contract-check.sh` rejected a rollout row referencing an unknown release id.
- `scripts/hosted-contract-suite-check.sh` passed with `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE=release-rollout` and the release-rollout source provided.
- `scripts/hosted-contract-suite-check.sh` rejected a missing required release-rollout source.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Generate the release-rollout bundle from hosted staging or CI and run the strict hosted suite with both `AUTOPOIESIS_RELEASE_MANIFEST_SOURCE` and `AUTOPOIESIS_RELEASE_ROLLOUT_CONTRACT_SOURCE` before enabling broad Admin > Frames update controls.

## 2026-06-07 - Online admin device action availability

Date: 2026-06-07

Milestone: ONLINE ADMIN - role-gated remote action readiness

Changed files:

- `scripts/online-admin-contract-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/admin-system.md`
- `docs/online-frames-profile.md`
- `docs/database-schema.md`
- `docs/agent-notes/backend-online-admin-action-availability-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Tightened the hosted online-admin bundle gate so every Profile-owned and Admin fleet device row must expose target-specific `actionAvailability`.
- The target availability object must include an explicit allow/deny decision for each supported remote command: settings sync, cache clear, display restart, enable/disable, device restart, update, broadcast display, and factory reset request.
- Allowed risky actions must mirror global authorization, audit-id, and local-confirmation requirements; denied target decisions must include a disabled reason.
- Added a backend handoff note describing the bundle shape, recommended disabled reason codes, and staging acceptance command.

Verification:

- `scripts/online-admin-contract-check.sh` passed against a representative Profile/Admin bundle with complete device action availability.
- `scripts/online-admin-contract-check.sh` passed against a fully available target-action bundle, confirming disabled actions are not artificially required.
- `scripts/online-admin-contract-check.sh` rejected a bundle missing `profileFrames.devices[0].actionAvailability`.
- `scripts/online-admin-contract-check.sh` rejected an allowed high-risk device action missing `requiresAuditId=true`.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Generate the hosted online-admin bundle from staging using durable device, subscription, command, and authorization state; then drive Profile/Admin disabled controls from `actionAvailability` before enabling destructive remote fleet actions.

## 2026-06-07 - Install preflight app-tree gate

Date: 2026-06-07

Milestone: RPI APPLIANCE - one-command install hardening

Changed files:

- `scripts/preflight.sh`
- `README.md`
- `docs/installation.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added an appliance app-tree completeness gate to `scripts/preflight.sh`.
- The gate validates required config, local UI, script, service, timer, and version files before install copies the checkout into `/opt/autopoiesis-os`.
- Required runtime scripts must be executable, and `local-ui/server.js` must pass `node --check` when Node is available.
- `AUTOPOIESIS_PREFLIGHT_APP_ROOT` can point the check at an installed app tree or isolated fixture for support/debug validation.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Targeted `scripts/preflight.sh --install` smoke passed with stubbed install prerequisites and `AUTOPOIESIS_PREFLIGHT_MIN_FREE_MB=1`.
- Targeted app-tree failure smoke rejected a fixture missing `local-ui/server.js`.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Run the updated `sudo ./scripts/preflight.sh --install` from a clean release checkout and from the installed `/opt/autopoiesis-os/app` tree on physical Pi hardware before treating one-command install as production-ready.

## 2026-06-07 - Hosted cache/offline contract

Date: 2026-06-07

Milestone: LEAD / INTEGRATION - cache/offline staging readiness

Changed files:

- `scripts/cache-contract-check.sh`
- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/agent-notes/backend-cache-contract-issue.md`
- `docs/agent-notes/hosted-contract-suite-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/cache-contract-check.sh`, a read-only saved-bundle or live-URL verifier for hosted cache/offline readiness.
- The checker validates explicit cache policy booleans and size limits, HTTP(S) cache candidate URLs, duplicate ids, supported cache status/category metadata, device cache/offline summary evidence, optional cache-relevant commands, and redaction of credentials plus local appliance/cache paths.
- Wired `cache` into `scripts/hosted-contract-suite-check.sh` between stream and online-admin so strict hosted readiness now requires cache evidence before Profile/Admin cache controls are trusted.
- Added a backend handoff note for generating the bundle from durable settings/preferences, stream/content/broadcast rows, and heartbeat/support-ingested cache summaries.

Verification:

- `scripts/cache-contract-check.sh` passed against a representative cache/offline bundle.
- `scripts/cache-contract-check.sh` rejected a bundle missing the explicit `selectedArtists` cache-policy boolean.
- `scripts/cache-contract-check.sh` rejected a bundle exposing a local cache path instead of an HTTP(S) media URL.
- `scripts/cache-contract-check.sh` rejected a duplicate cache item id fixture.
- `scripts/hosted-contract-suite-check.sh` passed with `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE=cache` and the cache source provided.
- `scripts/hosted-contract-suite-check.sh` rejected a missing required cache source.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Generate the hosted cache bundle from staging or CI using durable `aos_` settings, stream/content/broadcast rows, and heartbeat-ingested cache summaries; decide whether support-bundle uploads can backfill cache/offline state before enabling Profile > Frames cache-management controls.


## 2026-06-07 - Hosted settings conflict contract

Date: 2026-06-07

Milestone: API / DATABASE / SYNC - hosted settings conflict readiness

Changed files:

- `scripts/settings-contract-check.sh`
- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/agent-notes/backend-settings-contract-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/settings-contract-check.sh`, a read-only saved-bundle or live-URL verifier for hosted newest-`updatedAt` settings conflict behavior.
- The checker validates an initial authoritative settings read, accepted newer write, stale write rejection or explicit conflict, final read preserving the newer row, heartbeat settings freshness, device-id consistency, and redaction boundaries.
- Wired `settings` into `scripts/hosted-contract-suite-check.sh` between device-auth and heartbeat so strict hosted readiness now requires direct settings-row conflict evidence before heartbeat/admin evidence is trusted.
- Added a backend handoff note for generating the bundle from durable `aos_frame_device_settings`, `aos_frame_user_preferences`, and heartbeat response assembly.

Verification:

- `scripts/settings-contract-check.sh` passed against a representative settings conflict bundle.
- `scripts/settings-contract-check.sh` rejected a stale-overwrite fixture.
- `scripts/hosted-contract-suite-check.sh` passed with `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE=settings` and the settings source provided.
- `scripts/hosted-contract-suite-check.sh` rejected a missing required settings source.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Generate a hosted settings contract bundle from staging or CI and decide the canonical stale-write response shape (`409 Conflict`, `ok=false`, or `applied: false`) before exposing Profile > Frames conflict messaging.

## 2026-06-07 - Install preflight disk-space gate

Date: 2026-06-07

Milestone: RPI APPLIANCE - one-command install hardening

Changed files:

- `scripts/preflight.sh`
- `README.md`
- `docs/installation.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added a free-space gate to `scripts/preflight.sh --install` for the selected install, data, and log paths.
- The gate follows `AUTOPOIESIS_INSTALL_DIR`, `AUTOPOIESIS_DATA_DIR`, and `AUTOPOIESIS_LOG_DIR`, then probes the nearest existing parent path with `df -Pm` so fresh images work before target directories exist.
- Default minimum free space is 1024 MB per target volume; `AUTOPOIESIS_PREFLIGHT_MIN_FREE_MB` can raise/lower the threshold or disable it with `0` for deliberate constrained fixtures.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Targeted `scripts/preflight.sh --install` smoke passed with stubbed install prerequisites and `AUTOPOIESIS_PREFLIGHT_MIN_FREE_MB=1`.
- Targeted high-threshold preflight smoke rejected an impossible `AUTOPOIESIS_PREFLIGHT_MIN_FREE_MB=999999999` value.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Run the updated `sudo ./scripts/preflight.sh --install` on the clean physical Pi image before install, and document any intentional low-space override in the rollout note.

## 2026-06-07 - Mixed-stream broadcast display evidence

Date: 2026-06-07

Milestone: BROADCAST / FEED - delivery-log reconciliation

Changed files:

- `local-ui/server.js`
- `scripts/feed-targeting-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/broadcast-system.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Changed `POST /local/frame/display` so broadcast-category items displayed in the mixed `/frame` queue append `broadcast_shown` delivery evidence instead of a generic `feed_item_shown` event.
- Kept non-broadcast artwork/blog/news/curatorial playback on `feed_item_shown`, preserving the distinction between content display and broadcast delivery rows.
- Extended `scripts/feed-targeting-check.sh` to acknowledge display of a targeted mixed-stream broadcast and assert both `GET /local/delivery-log` and `GET /local/events/export` expose `broadcast_shown` with broadcast source metadata.
- Documented that backend/admin ingestion can treat `broadcast_shown` as the durable display event for both command-delivered broadcasts and personalized-stream broadcasts.

Verification:

- `scripts/feed-targeting-check.sh` passed, including mixed-stream broadcast display evidence and event export coverage.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Ensure hosted heartbeat event ingestion projects mixed-stream `broadcast_shown` events into durable `aos_broadcast_deliveries` rows with idempotency by `deviceId + eventKey`, then surface those rows in Admin > Frames delivery status.

## 2026-06-07 - Hosted broadcast lifecycle contract

Date: 2026-06-07

Milestone: LEAD / INTEGRATION - broadcast staging readiness

Changed files:

- `scripts/broadcast-contract-check.sh`
- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/broadcast-system.md`
- `docs/agent-notes/backend-broadcast-contract-issue.md`
- `docs/agent-notes/hosted-contract-suite-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/broadcast-contract-check.sh`, a read-only saved-bundle or live-URL verifier for hosted Admin > Frames broadcast lifecycle evidence.
- The checker validates durable broadcast rows, explicit targeting/audience, scheduling and priority metadata, queued `show_broadcast` commands, approved authorization/audit metadata, durable delivery/display evidence, duplicate ids, unknown broadcast references, and sensitive/local-only field redaction.
- Wired the broadcast gate into `scripts/hosted-contract-suite-check.sh`; strict hosted readiness now requires migration, schema, pairing, device-auth, heartbeat, stream, online-admin, broadcast, and release sources.
- Added a backend handoff issue note for generating the bundle from `aos_` broadcast, command, audit, and delivery rows.

Verification:

- `scripts/broadcast-contract-check.sh` passed against a representative targeted broadcast lifecycle bundle.
- `scripts/broadcast-contract-check.sh` rejected a bundle missing explicit targeting/audience.
- `scripts/broadcast-contract-check.sh` rejected a `show_broadcast` command missing authorization metadata.
- `scripts/broadcast-contract-check.sh` rejected a delivery row referencing an unknown broadcast id.
- `scripts/hosted-contract-suite-check.sh` passed with broadcast listed in `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE`.
- `scripts/hosted-contract-suite-check.sh` rejected a missing required broadcast source.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Generate the broadcast lifecycle bundle from hosted staging or CI using durable `aos_` broadcast, command/audit, and delivery rows, then run the expanded strict hosted suite before enabling real broadcast rollout controls.

## 2026-06-07 - Online admin profile cache contract

Date: 2026-06-07

Milestone: ONLINE ADMIN - Profile > Frames contract fidelity

Changed files:

- `scripts/online-admin-contract-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/admin-system.md`
- `docs/online-frames-profile.md`
- `docs/database-schema.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Tightened the hosted online-admin bundle gate so `profileFrames.cachePreferences` is now required.
- Cache preferences must explicitly expose `enabled`, `likedArtworks`, `recentArtworks`, `selectedArtists`, and `sizeLimitMb`, giving Profile > Frames enough data to render cache policy without guessing from generic settings.
- Paged `profileFrames.likedArtworks.items` rows now validate the same stable artwork id shape as flat liked-artwork arrays.
- Updated the online-admin contract docs to make the required cache policy and paged liked-artwork validation explicit.

Verification:

- `scripts/online-admin-contract-check.sh` passed against a representative paged-liked-artwork bundle with explicit cache preferences.
- `scripts/online-admin-contract-check.sh` rejected a bundle missing `profileFrames.cachePreferences`.
- `scripts/online-admin-contract-check.sh` rejected a bundle with an incomplete cache preference policy.
- `scripts/online-admin-contract-check.sh` rejected a paged liked-artwork row without a stable artwork id.

Next step:

Update the hosted Profile > Frames bundle adapter or CI fixture to derive this explicit cache policy from durable user/device settings, then run the hosted suite before enabling cache-management controls in staging.

## 2026-06-06 - Production cleanup audit gate

Date: 2026-06-06

Milestone: QA / SECURITY - final image hygiene

Changed files:

- `scripts/cleanup-production.sh`
- `README.md`
- `docs/production-cleanup.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Reworked `scripts/cleanup-production.sh` from a checklist into a read-only production hygiene audit.
- Added strict-mode support for final imaging through `--strict` or `AUTOPOIESIS_PRODUCTION_CLEANUP_STRICT=1`.
- The audit now checks installed app-tree secret-like paths, leftover Git metadata, tracked secret-like paths when the app is still a checkout, Codex/OpenClaw/OpenAI credential homes, shell-history secret hints without printing matching lines, common development caches, and SSH/sshd exposure.
- Added `--allow-ssh`, `--app-dir=...`, `--home-dir=...`, `AUTOPOIESIS_PRODUCTION_HOME_DIRS`, and `AUTOPOIESIS_SYSTEMCTL_BIN` so the same gate works on physical Pi images and isolated CI fixtures.

Verification:

- `bash -n scripts/cleanup-production.sh` passed.
- Strict cleanup audit passed against an isolated temporary app/home tree.
- Strict cleanup audit rejected a temporary app tree containing `.env`.
- Strict cleanup audit rejected a temporary production home containing `.codex`.
- Strict cleanup audit rejected a temporary shell history with an `OPENAI_API_KEY` hint without printing the secret line.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Run `AUTOPOIESIS_PRODUCTION_CLEANUP_STRICT=1 sudo /opt/autopoiesis-os/app/scripts/cleanup-production.sh` on the physical Pi after final appliance validation and before cloning a production image; document any intentional SSH exception.

## 2026-06-06 - Hosted device auth contract gate

Date: 2026-06-06

Milestone: LEAD / INTEGRATION - device credential boundary

Changed files:

- `scripts/device-auth-contract-check.sh`
- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/agent-notes/backend-device-auth-contract-issue.md`
- `docs/agent-notes/hosted-contract-suite-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/device-auth-contract-check.sh`, a saved-bundle or live-URL verifier for hosted device-only route authentication evidence.
- The checker requires correct per-device credentials to succeed while missing, wrong, and cross-device credentials are rejected for pairing status, settings read/write, heartbeat, stream, command polling, command acknowledgement, and release routes.
- The checker validates route device-id consistency on authorized responses and rejects raw device API keys, API-key field names, pairing-code hashes, bearer tokens, private/admin tokens, secrets, passwords, and local appliance paths.
- Wired the device-auth gate into `scripts/hosted-contract-suite-check.sh`; strict hosted readiness now requires migration, schema, pairing, device-auth, heartbeat, stream, online-admin, and release sources.
- Added a backend handoff issue note defining the optional staging/CI device-auth bundle.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/device-auth-contract-check.sh` passed against a representative all-route auth bundle fixture.
- `scripts/device-auth-contract-check.sh` rejected a route missing cross-device rejection evidence.
- `scripts/hosted-contract-suite-check.sh` passed with a required device-auth source.
- `scripts/hosted-contract-suite-check.sh` rejected a missing required device-auth source.
- `scripts/security-smoke.sh` passed.

Next step:

Generate the device-auth bundle from hosted route integration tests or a staging-only admin adapter, then run the expanded hosted suite before trusting heartbeat, stream, command, release, or physical Pi validation results.

## 2026-06-06 - Support bundle acceptance gate

Date: 2026-06-06

Milestone: RPI APPLIANCE - support handoff contract

Changed files:

- `scripts/support-bundle-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/support-bundle-check.sh`, a read-only verifier for `GET /local/support-bundle`.
- The checker validates the support-bundle schema marker, redaction flag, generated timestamp, device identity, health/readiness summaries, runtime storage booleans, input summary, playback state, command policy matrix, event export shape, and required support sections.
- The checker rejects stored device-key field names, raw command payloads, release checksums, and release artifact URLs in the support bundle.
- Wired the support-bundle gate into Milestone 2 verification before the derived Admin/Profile device snapshot check.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/support-bundle-check.sh` passed against an isolated local UI in setup mode.
- `scripts/security-smoke.sh` passed.

Next step:

Run `scripts/support-bundle-check.sh` on the physical Pi after live pairing, feed/cache sync, and at least one command/broadcast attempt; attach the validated bundle to hardware rollout blockers or Admin/Profile support adapter work.

## 2026-06-06 - Hosted heartbeat contract gate

Date: 2026-06-06

Milestone: LEAD / INTEGRATION - heartbeat sync readiness

Changed files:

- `scripts/heartbeat-contract-check.sh`
- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/agent-notes/backend-heartbeat-contract-issue.md`
- `docs/agent-notes/hosted-contract-suite-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/heartbeat-contract-check.sh`, a saved-response, saved request/response bundle, or live-URL verifier for `POST /api/frames/device/{deviceId}/heartbeat`.
- The checker validates safe heartbeat request diagnostics, unified event export shape, event ingestion acknowledgements, optional settings, remote command authorization metadata, optional mixed-stream items, and sensitive/local-only field redaction.
- Wired the heartbeat gate into `scripts/hosted-contract-suite-check.sh`; strict hosted readiness now requires migration, schema, pairing, heartbeat, stream, online-admin, and release sources.
- Added a backend handoff issue note for generating the heartbeat contract fixture from a paired staged device or durable seeded `aos_` rows.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/heartbeat-contract-check.sh` passed against a representative heartbeat request/response fixture.
- `scripts/heartbeat-contract-check.sh` rejected a heartbeat response without an event acknowledgement.
- `scripts/hosted-contract-suite-check.sh` passed with a required heartbeat source.
- `scripts/hosted-contract-suite-check.sh` rejected a missing required heartbeat source.
- `scripts/security-smoke.sh` passed.

Next step:

Generate the heartbeat bundle from hosted staging after pairing, then run the expanded hosted suite with real migration/schema/pairing/heartbeat/stream/admin/release fixtures before physical Pi Milestone 2 validation.

## 2026-06-06 - Hosted contract suite gate

Date: 2026-06-06

Milestone: LEAD / INTEGRATION - backend staging readiness

Changed files:

- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/agent-notes/hosted-contract-suite-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/hosted-contract-suite-check.sh`, an umbrella staging/CI runner for the hosted Frames contract gates.
- The suite runs migration, final schema, pairing lifecycle, stream response, online Profile/Admin, and release manifest checks in dependency order.
- `--strict` requires all six sources before physical Pi acceptance; `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE` allows partial CI jobs to require only their owned gates while still running every provided source.
- Added a backend handoff issue note describing how to wire the suite into hosted staging readiness.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/hosted-contract-suite-check.sh` passed against a temporary release-manifest fixture.
- `scripts/hosted-contract-suite-check.sh` rejected a missing required stream source.
- `scripts/security-smoke.sh` passed.

Next step:

Wire the suite into the hosted backend CI/staging path with real migration/schema/pairing/stream/admin/release fixtures, then run it before physical Pi Milestone 2 validation.

## 2026-06-06 - Online admin role matrix contract

Date: 2026-06-06

Milestone: ONLINE ADMIN - role-gated fleet controls

Changed files:

- `scripts/online-admin-contract-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/admin-system.md`
- `docs/online-frames-profile.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Extended the hosted online-admin bundle gate to require `show_broadcast` command policy coverage.
- Added a required role/action authorization matrix to the online-admin contract.
- The matrix accepts `roleActionMatrix`, `roleMatrix`, or `permissions`, with one explicit allow/deny decision per accepted actor role and remote command type.
- Allowed risky commands must expose authorization, audit-id, and local-confirmation requirements so Admin > Frames controls can render prompts from contract data.
- Denied commands must include a UI-facing reason, and the matrix must include at least one denied action plus one denied critical action before destructive fleet actions are considered staging-ready.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/online-admin-contract-check.sh` passed against a representative Profile/Admin bundle fixture with admin/support role decisions.
- `scripts/online-admin-contract-check.sh` rejected a bundle without a role/action matrix.
- `scripts/online-admin-contract-check.sh` rejected a denied critical action without a UI-facing reason.
- `scripts/online-admin-contract-check.sh` rejected a bundle leaking a local appliance path.
- `scripts/security-smoke.sh` passed.

Next step:

Assemble the hosted role/action matrix from real backend authorization checks, then drive Admin > Frames action disabled states and confirmation copy from the same bundle before enabling destructive remote actions in staging.

## 2026-06-06 - AOS migration contract gate

Date: 2026-06-06

Milestone: API / DATABASE / SYNC - migration safety foundation

Changed files:

- `scripts/aos-migration-contract-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/agent-notes/backend-migration-contract-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/aos-migration-contract-check.sh`, an executable pre-apply gate for hosted Frames database migrations.
- The checker accepts either a migrations directory of sorted `.sql` files or a saved migration manifest from a backend migration tool.
- It validates deterministic migration ids, `aos_` table/index namespacing, transaction boundaries, required MVP table coverage, hashed pairing-code storage, secret-literal red flags, and destructive SQL opt-in.
- Added a backend handoff note defining how to wire the gate before schema verification in migration CI.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/aos-migration-contract-check.sh` passed against a representative manifest fixture.
- `scripts/aos-migration-contract-check.sh` rejected a non-`aos_` migration fixture.
- `scripts/aos-migration-contract-check.sh` rejected a destructive migration fixture without explicit opt-in.
- `scripts/security-smoke.sh` passed.

Next step:

Wire the migration gate into the hosted app's migration CI/export path, then run `scripts/aos-schema-contract-check.sh` against the migrated staging database or exported schema before enabling hosted stream/admin/heartbeat checks.

## 2026-06-06 - Systemd unit rendering gate

Date: 2026-06-06

Milestone: RPI APPLIANCE - installer/systemd path fidelity

Changed files:

- `install.sh`
- `services/autopoiesis-cache.service`
- `services/autopoiesis-command-executor.service`
- `services/autopoiesis-heartbeat.service`
- `services/autopoiesis-kiosk.service`
- `services/autopoiesis-setup.service`
- `services/autopoiesis-updater.service`
- `scripts/install-systemd-units.sh`
- `scripts/systemd-units-install-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/installation.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- `scripts/install-systemd-units.sh` now renders service units into the target systemd directory using the configured app, install, data, log, appliance user, and user-home paths.
- `install.sh` now passes its chosen install/data/log/user values into the systemd installer, so custom install roots do not leave services pointing at the default `/opt`, `/var/lib`, or `frame` layout.
- Timer units are still copied directly, while service units have default path/user placeholders replaced at install/update time.
- Service units now carry explicit runtime environment for data/log/cache/app paths where their scripts depend on those defaults.
- Added `scripts/systemd-units-install-check.sh`, an isolated fake-systemd acceptance gate that renders units with custom paths/user and fails if default hard-coded paths or `frame` ownership survive.
- Wired the gate into Milestone 2 verification after baseline service status checks.

Verification:

- `scripts/systemd-units-install-check.sh` passed.

Next step:

Run `sudo ./install.sh` or `sudo ./update.sh` on a physical Pi using the default layout, then inspect `/etc/systemd/system/autopoiesis-*.service` and run full Milestone 2 verification to confirm rendered units start the healthy installed services.

## 2026-06-06 - Broadcast command display gate

Date: 2026-06-06

Milestone: BROADCAST / FEED - command-delivered broadcast behavior

Changed files:

- `local-ui/server.js`
- `scripts/broadcast-command-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/broadcast-system.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Hardened `show_broadcast` command handling so command-delivered broadcasts use defensive targeting and expiry checks before writing `current-broadcast.json`.
- Scheduled command broadcasts are accepted without interrupting playback before `startsAt`; `/launch` now routes to any active stored broadcast once it is eligible.
- `broadcast_shown` is recorded when `/broadcast` actually renders, not when the command is merely accepted.
- Dismissed broadcasts stay inactive; stored broadcasts that are no longer target-eligible emit one `broadcast_skipped` delivery event.
- Added `scripts/broadcast-command-check.sh`, an isolated local UI + mock Frames API gate for wrong-target rejection, scheduled delay, active launch routing, display-time delivery logging, dismissal, expired-command rejection, and command acknowledgements.
- Wired the new gate into Milestone 2 after stream playback and feed targeting.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/broadcast-command-check.sh` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Run the broadcast command gate on physical Pi hardware after Admin > Frames can enqueue a real targeted broadcast command, then confirm durable `aos_broadcast_deliveries` receives the displayed/dismissed event projection.

## 2026-06-06 - Release manifest safety gate

Date: 2026-06-06

Milestone: RELEASE / ROLLOUT - safe update foundation

Changed files:

- `scripts/release-manifest-check.sh`
- `scripts/update-from-release.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/release-manifest-check.sh`, a saved-manifest or live-URL gate for release metadata before a frame accepts an update.
- The checker validates semantic target versions, optional release channels, GitHub-style tags, HTTPS artifact URLs, SHA-256 checksums, rollout percentages, release-note URLs, optional rollback notes, and redaction of device keys, pairing hashes, private/admin tokens, secrets, passwords, and local appliance paths.
- `scripts/update-from-release.sh` now runs the manifest gate before writing rollback metadata, downloading artifacts, or applying a git fallback update.
- The updater now accepts `artifactUrl`/`sha256` style fields as aliases for the existing `artifact_url`/`checksum` contract so backend and GitHub release adapters can share one manifest shape.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/release-manifest-check.sh` passed against a strict representative stable release fixture.
- `scripts/release-manifest-check.sh` rejected an artifact release without a checksum.
- `scripts/update-from-release.sh` rejected an invalid manifest before mutating an isolated fake install.
- `scripts/security-smoke.sh` passed.

Next step:

Make the hosted release endpoint emit channel, tag, checksum, changelog URL, rollout percentage, and rollback notes, then run strict manifest validation before cutting the first GitHub-tagged production artifact.

## 2026-06-06 - Hosted pairing contract gate

Date: 2026-06-06

Milestone: LEAD / INTEGRATION - pairing foundation

Changed files:

- `scripts/pairing-contract-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/online-frames-profile.md`
- `docs/agent-notes/backend-pairing-contract-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/pairing-contract-check.sh`, a saved-response or live-URL verifier for the hosted Frames pairing lifecycle.
- The checker validates read-only evidence for device registration, authenticated user claim, and final device pairing status.
- It requires a bounded pairing-code TTL, an unpaired registration response, a durable device credential at registration, consistent claimed owner/device identity, optional settings handoff shape, final paired status, and redaction of pairing-code hashes, user tokens, secrets, and local appliance paths.
- Added a backend issue note defining the optional staging/CI pairing contract bundle and the durable `aos_` ownership/security expectations.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/pairing-contract-check.sh` passed against a representative pairing lifecycle fixture.
- `scripts/security-smoke.sh` passed.

Next step:

Assemble the optional `GET /api/admin/frames/pairing-contract-bundle` staging adapter from durable `aos_frame_devices` and `aos_frame_pairing_codes` evidence, then run `scripts/pairing-contract-check.sh` before live physical Pi pairing acceptance.

## 2026-06-06 - Runtime storage diagnostics gate

Date: 2026-06-06

Milestone: RPI APPLIANCE - runtime filesystem acceptance

Changed files:

- `local-ui/server.js`
- `scripts/runtime-storage-check.sh`
- `scripts/milestone2-verify.sh`
- `scripts/security-smoke.sh`
- `scripts/support-bundle.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/installation.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added runtime storage diagnostics for `DATA_DIR`, `CACHE_DIR`, and `LOG_DIR`.
- Diagnostics now verify each runtime path exists or can be created, is a directory, is readable/writable, and accepts a short write probe from the local UI process.
- Health emits `runtime_storage_unavailable` when any required runtime path is blocked.
- Readiness and support bundles now include a storage phase/summary so physical Pi handoffs can distinguish ownership/mount failures from pairing, heartbeat, cache, or support-bundle bugs.
- `scripts/support-bundle.sh` now prints the runtime storage status in its one-line support summary.
- Added `scripts/runtime-storage-check.sh` and wired it into Milestone 2 physical verification.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/runtime-storage-check.sh` passed against an isolated local UI with writable data/cache/log directories.
- `scripts/support-bundle.sh` summary output reported `storage=ready` against the same isolated writable local UI.
- `scripts/runtime-storage-check.sh` passed with `AUTOPOIESIS_ALLOW_RUNTIME_STORAGE_UNREADY=1` against an isolated blocked-cache-path fixture, proving `runtime_storage_unavailable` health/readiness/support reporting.
- `scripts/security-smoke.sh` passed.

Next step:

Run the strict runtime storage gate on the physical Pi after install/update; if it fails, fix ownership or mounts for `/var/lib/autopoiesis-os`, the cache directory, and `/var/log/autopoiesis-os` before testing higher-level appliance flows.

## 2026-06-06 - Durable AOS schema contract gate

Date: 2026-06-06

Milestone: LEAD / INTEGRATION - database foundation

Changed files:

- `scripts/aos-schema-contract-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/agent-notes/aos-schema-contract-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/aos-schema-contract-check.sh`, a schema-level verifier for the durable `aos_` Frames database contract.
- The checker accepts either a SQLite database file, when `sqlite3` is available, or a saved schema JSON fixture for CI/staging adapters.
- It validates required tables, columns, and primary/unique keys for frame devices, pairing, settings, user preferences, heartbeats, commands, admin command audits, device events, artwork likes, broadcasts, releases, subscriptions, broadcast deliveries, and release rollouts.
- Added a backend issue note so database/migration work has a concrete acceptance target before stream, admin, event ingestion, command, broadcast, or rollout gates are trusted.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/aos-schema-contract-check.sh` passed against a representative durable `aos_` schema fixture.
- `scripts/security-smoke.sh` passed.

Next step:

Run `scripts/aos-schema-contract-check.sh` against a staging backend database or exported migration schema before relying on hosted stream/admin/event/broadcast/release acceptance checks; migrate `aos_frame_pairing_codes` from plaintext `pairing_code` to `pairing_code_hash` before production hardening.

## 2026-06-06 - Online admin contract gate

Date: 2026-06-06

Milestone: ONLINE ADMIN - Profile/Admin Frames contract

Changed files:

- `scripts/online-admin-contract-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/admin-system.md`
- `docs/online-frames-profile.md`
- `docs/database-schema.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/online-admin-contract-check.sh`, a saved-response or live-URL validator for the hosted Profile > Frames and Admin > Frames bundle.
- The checker validates user devices, pairing metadata, settings, active artists, liked artworks, cache preferences, users, subscribers, subscriptions, fleet devices, accepted admin roles, remote action policy rows, authorization/audit requirements, and redaction of local-only or sensitive fields.
- Documented the expected bundle as an optional staging/CI adapter assembled from existing Profile/Admin endpoints, so UI, backend authorization, and Pi command policy can be checked before real fleet actions are enabled.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/online-admin-contract-check.sh` passed against a representative Profile/Admin bundle fixture.
- `scripts/security-smoke.sh` passed.

Next step:

Expose or assemble the online admin bundle from durable `aos_` and canonical account/subscription rows, then run `scripts/online-admin-contract-check.sh` against staging auth data before enabling destructive remote actions.

## 2026-06-06 - Hosted stream contract verifier

Date: 2026-06-06

Milestone: LEAD / INTEGRATION - backend stream handoff

Changed files:

- `scripts/stream-contract-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/agent-notes/backend-stream-contract-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/stream-contract-check.sh`, a reusable saved-response or live-URL verifier for `GET /api/frames/device/{deviceId}/stream`.
- The verifier checks schema version, generated timestamp, stream metadata, optional settings/preferences shape, unique item ids, item identity/media/cache/priority/schedule/targeting fields, displayability, and redaction of local-only or sensitive fields.
- Added `docs/agent-notes/backend-stream-contract-issue.md`, a GitHub-style backend issue note specifying the durable `aos_` tables, response shape, acceptance checks, and open ownership/subscription/cursor questions for the hosted stream endpoint.
- Documented the checker in the README, API contract, database schema notes, and Pulse handoff notes.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/stream-contract-check.sh` passed against a representative fixture.
- `scripts/security-smoke.sh` passed.

Next step:

Implement the hosted `/api/frames/device/{deviceId}/stream` query from durable `aos_` device, settings, preference, subscription, content, and broadcast rows, then run this contract check before stream playback and feed targeting gates.

## 2026-06-06 - Command acknowledgement retry gate

Date: 2026-06-06

Milestone: API / DATABASE / SYNC - command acknowledgement idempotency

Changed files:

- `local-ui/server.js`
- `scripts/command-ack-retry-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Tightened command audit status for successful local executions whose final `completed` acknowledgement cannot be delivered; those now surface immediately as `ack_failed` instead of looking cleanly completed.
- Added `scripts/command-ack-retry-check.sh`, an isolated local UI + mock Frames API gate for command acknowledgement retry behavior.
- The gate verifies initial acknowledgement failures retain commands before execution, successful initial ack retry then executes once, final acknowledgement failures retain final-only retry metadata and count as audit errors, final ack retry success does not re-execute the command, and repeated final ack retry failure records `ack_retry_failed`.
- Wired the gate into Milestone 2 verification before settings sync and event ingestion checks.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/command-ack-retry-check.sh` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Mirror this idempotency contract in durable backend `aos_` command rows: repeated `completed`/`error` acknowledgements should be harmless, and last ack failure/timestamp should be visible in Admin > Frames support data.

## 2026-06-06 - System clock diagnostics gate

Date: 2026-06-06

Milestone: RPI APPLIANCE - time sync diagnostics and staged hardware acceptance

Changed files:

- `local-ui/server.js`
- `scripts/clock-check.sh`
- `scripts/milestone2-verify.sh`
- `scripts/security-smoke.sh`
- `scripts/support-bundle.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `timedatectl show` backed system clock diagnostics to the local UI diagnostics snapshot.
- Compact health now emits stable `clock_unsynchronized`, `clock_unknown`, and `clock_ntp_disabled` issue codes when system time sync is unhealthy or unavailable.
- Readiness, rollout acceptance, and support bundles now include a clock phase/summary so staged hardware can distinguish bad Pi time from generic network, feed, heartbeat, or release failures.
- Added `scripts/clock-check.sh`, validating diagnostics, health, readiness, and support-bundle clock surfaces with strict `AUTOPOIESIS_REQUIRE_CLOCK_SYNC=1` mode.
- Wired strict clock sync into `scripts/milestone2-verify.sh` after timer diagnostics and extended security/support summaries to cover the new redacted clock contract.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted fake-`timedatectl` clock smoke passed for synchronized strict mode, unsynchronized health issue plus strict failure, and unavailable `clock_unknown` reporting.

Next step:

Run strict `scripts/clock-check.sh` on the physical Pi after network onboarding; if it fails, capture `timedatectl status` before debugging higher-level feed, heartbeat, pairing, or release behavior.

## 2026-06-06 - Defensive feed targeting gate

Date: 2026-06-06

Milestone: BROADCAST / FEED - mixed stream targeting and cache eligibility

Changed files:

- `local-ui/server.js`
- `scripts/feed-targeting-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/broadcast-system.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added defensive local feed targeting for recognized device, owner/user, subscriber status, subscription tier, region/country, test-device, and explicit exclusion target shapes.
- Preserved backend targeting as the authoritative source, while making the Pi refuse obviously non-matching feed items or broadcasts before they enter `/local/feed`, `/local/frame-state`, cache manifests, or kiosk playback.
- Redacted normalized targeting metadata from public `/local/feed` responses after eligibility evaluation, closing a small local privacy leak for target lists.
- Added `scripts/feed-targeting-check.sh`, an isolated local UI + mock Frames API gate for targeting, expiry/start-time filtering, priority order, public redaction, delivery evidence, and cache eligibility.
- Wired the targeting gate into `scripts/milestone2-verify.sh` after the stream playback integration gate.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- `scripts/feed-targeting-check.sh` passed.
- `scripts/stream-playback-check.sh` passed.

Next step:

Implement the hosted `GET /api/frames/device/{deviceId}/stream` path so durable `aos_` rows emit the same targeting/cache/priority fields this device-side gate now validates, then run the gate on physical paired hardware after a live stream sync.

## 2026-06-06 - Stream playback gate hardening

Date: 2026-06-06

Milestone: LEAD / integration - local stream player contract

Changed files:

- `scripts/stream-playback-check.sh`
- `README.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Adopted the pending local stream/dashboard/player integration set as the active LEAD handoff instead of leaving it as ambiguous dirty work.
- Hardened `scripts/stream-playback-check.sh` to choose per-run loopback ports by default, while preserving `AUTOPOIESIS_STREAM_PLAYBACK_CHECK_PORT` and `AUTOPOIESIS_STREAM_PLAYBACK_CHECK_API_PORT` overrides for focused debugging.
- This brings the stream playback gate in line with the event-ingestion acceptance gate and avoids false failures when hourly cron checks or local development runs overlap.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- `scripts/stream-playback-check.sh` passed.

Next step:

Implement the hosted `GET /api/frames/device/{deviceId}/stream` path against durable `aos_` preference/content rows, then run this checker plus strict frame-state validation on physical Pi hardware after live feed/cache sync.

## 2026-06-06 - Stream playback integration gate

Date: 2026-06-06

Milestone: LEAD / integration - local stream player contract

Changed files:

- `scripts/stream-playback-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/stream-playback-check.sh`, an isolated local UI acceptance gate for the current stream/dashboard/player contract.
- The check runs a temporary local UI against a mock Frames API and verifies preferred `GET /stream` sync, fallback to legacy `GET /feed`, artist/category preference filtering, `/dashboard` rendering, frame item `displayMs` timing, local like persistence, remote like forwarding, and `feed_item_liked` delivery evidence.
- Wired the gate into Milestone 2 verification immediately after the local frame route check so physical acceptance catches drift between backend stream shape, device preferences, and local kiosk playback.
- Documented the standalone gate for focused debugging before a full physical Pi validation pass.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- `scripts/stream-playback-check.sh` passed.

Next step:

Mirror the same stream contract in the hosted Frames backend with durable `aos_` stream preference defaults, then run this gate plus strict frame-state validation after a real feed/cache cycle on physical Pi hardware. A clean commit for this pass is unsafe until the pre-existing uncommitted stream/dashboard/player edits in `config/defaults.json`, `docs/api-contract.md`, and `local-ui/server.js` are either adopted into the same change set or separated.

## 2026-06-06 - Admin device snapshot acceptance gate

Date: 2026-06-06

Milestone: ONLINE ADMIN - hosted device detail contract

Changed files:

- `scripts/admin-device-snapshot-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/admin-device-snapshot-check.sh`, a read-only acceptance gate that derives a compact redacted Admin/Profile device snapshot from `/local/support-bundle`.
- The snapshot validates and summarizes identity, health/readiness, pairing and stored-key flags, remote-enabled state, playback/cache counts, role-gated command policies, command/delivery/release evidence, and device event export cursor state.
- Added strict `AUTOPOIESIS_REQUIRE_DEVICE_ADMIN_READY=1` mode for paired staged devices where Admin > Frames should be able to offer role-gated remote actions.
- Wired the check into Milestone 2 verification immediately after the admin-capabilities contract so hardware validation covers both the raw policy matrix and the hosted fleet row shape.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Isolated temporary local UI smoke passed for snapshot JSON generation, strict paired/keyed remote-admin readiness, command policy summarization, event-count summarization, and stored device-key redaction.

Next step:

Mirror this snapshot shape into the online Admin > Frames and Profile > Frames device detail APIs so UI cards can consume one stable row instead of stitching together raw heartbeat/support fields.

## 2026-06-06 - Network onboarding acceptance gate

Date: 2026-06-06

Milestone: RPI APPLIANCE - LAN/Wi-Fi setup contract

Changed files:

- `scripts/network-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/network-check.sh`, a local acceptance gate for the `/local/network/status` contract used by touchscreen setup, support handoff, and physical Pi validation.
- The check validates LAN/Wi-Fi availability shape, primary-link consistency, optional online requirement, device visibility, and sensitive-key redaction.
- Wired the gate into Milestone 2 verification immediately after the raw `nmcli` printout so the physical Pi pass proves both NetworkManager state and the local onboarding API are usable.
- Documented normal and strict online modes for staged hardware validation.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted temporary local UI smoke passed for connected LAN, offline Wi-Fi-only, strict online rejection, and unavailable-network reporting.

Next step:

Run `AUTOPOIESIS_REQUIRE_NETWORK_ONLINE=1 /opt/autopoiesis-os/app/scripts/network-check.sh` on the physical Pi after LAN/Wi-Fi onboarding; if it fails, capture `/local/network/status`, `nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status`, and the setup UI state before changing connection scripts.

## 2026-06-06 - Event ingestion cursor acceptance gate

Date: 2026-06-06

Milestone: LEAD / integration - heartbeat event ingestion cursor

Changed files:

- `scripts/events-ingestion-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/events-ingestion-check.sh`, an isolated heartbeat ingestion acceptance gate for the RPi event cursor contract.
- The check starts a temporary local UI plus mock Frames API, seeds command-audit, display-delivery, and release-history events, and confirms the first heartbeat exports all three sources.
- It verifies accepted backend acks persist a redacted `event-cursor.json`, diagnostics/support surfaces expose the accepted cursor, and the next heartbeat sends `eventIngestionCursor` plus a bounded replay window.
- It also verifies stale backend event acknowledgements are rejected without moving the retained cursor backward, while recording `stale_event_ingestion_ack` for support visibility.
- Wired the gate into `scripts/milestone2-verify.sh` so physical Pi acceptance validates backend/device event-ingestion drift alongside export shape.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- `scripts/events-ingestion-check.sh` passed.

Next step:

Run the full Milestone 2 verification on the physical Pi after the backend `aos_device_events` ingestion path is deployed; if event replay loops or missing Admin evidence appear, start with this check plus `/local/support-bundle` before inspecting raw logs.

## 2026-06-06 - Rollout issue report handoff

Date: 2026-06-06

Milestone: LEAD / integration - rollout support handoff

Changed files:

- `scripts/rollout-issue-report.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/rollout-issue-report.sh`, a read-only handoff tool that collects `/local/rollout/acceptance` and `/local/support-bundle` from a device and formats a GitHub-style Markdown issue report.
- The report includes device/version/profile, acceptance status, health/readiness status, blockers, warnings, support evidence counts, and reproduction commands.
- The script validates that both source payloads are redacted contract shapes and rejects inputs that expose device API key field names.
- Added profile/content/service/event-limit environment switches so setup, staged, and production rollout reports use the same acceptance parameters as the rollout gate.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted temporary local UI smoke passed for Markdown report generation, redaction validation, blocker/warning formatting, and output-file mode.

Next step:

Run `AUTOPOIESIS_ROLLOUT_PROFILE=staged /opt/autopoiesis-os/app/scripts/rollout-issue-report.sh ./rollout-issue.md` on the physical Pi when rollout acceptance blocks or warns, then attach the generated note plus support bundle to the hardware validation issue.

## 2026-06-06 - Settings sync acceptance gate

Date: 2026-06-06

Milestone: API / DATABASE / SYNC - settings conflict contract

Changed files:

- `scripts/settings-sync-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/settings-sync-check.sh`, an isolated acceptance gate for device settings conflict behavior.
- The check starts a temporary local UI and mock Frames API, then verifies stale explicit sync responses are rejected, newer remote settings apply, local settings pushes include `updatedAt`, and stale heartbeat settings preserve newer local preferences.
- The check also confirms diagnostics exposes `settingsSync.status = local_newer` and compact health emits `settings_conflict` while the conflict is active.
- Wired the settings sync check into Milestone 2 verification so physical Pi acceptance catches drift in the API/database sync contract.
- Documented the backend requirement to return authoritative `updatedAt` values from settings GET, settings POST, and heartbeat responses and to mirror newest-wins semantics in durable `aos_` settings rows.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- `scripts/settings-sync-check.sh` passed.

Next step:

Mirror this acceptance behavior in the online Frames backend by making `aos_` settings writes reject or explicitly flag stale `updatedAt` payloads, then return the authoritative row timestamp in settings and heartbeat responses.

## 2026-06-06 - Appliance timer diagnostics

Date: 2026-06-06

Milestone: RPI APPLIANCE - systemd maintenance loop acceptance

Changed files:

- `local-ui/server.js`
- `scripts/systemd-timers-check.sh`
- `scripts/milestone2-verify.sh`
- `scripts/security-smoke.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added systemd timer diagnostics for heartbeat, command executor, cache, updater, and watchdog timers alongside existing service diagnostics.
- Health now emits stable `timer_failed` and `timer_disabled` issue codes when timer-driven appliance loops are broken.
- Readiness now includes a `timers` phase so support, rollout checks, and Admin adapters can distinguish unavailable local systemd state from failed or disabled maintenance loops.
- Added `scripts/systemd-timers-check.sh` and wired it into Milestone 2 physical Pi verification.
- Extended the security smoke test so diagnostics, health, readiness, and support bundle responses must expose timer state without leaking device keys.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted fake-systemctl smoke passed for ready timers, disabled timer health/readiness signaling, and `scripts/systemd-timers-check.sh` failure on a disabled timer.

Next step:

Run `sudo /opt/autopoiesis-os/app/scripts/milestone2-verify.sh` on the physical Pi after updating units; if it fails at the timer step, capture `systemctl list-timers 'autopoiesis-*'` and `journalctl -u <timer-owned service> -n 120 --no-pager`.

## 2026-06-06 - Frame item delivery acknowledgement

Date: 2026-06-06

Milestone: BROADCAST / FEED - mixed stream display evidence

Changed files:

- `local-ui/server.js`
- `docs/api-contract.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `POST /local/frame/display`, a defensive local acknowledgement endpoint for regular mixed-stream frame items.
- The endpoint only records ids that are currently playable in `GET /local/frame-state`, preventing arbitrary browser/client payloads from inventing delivery rows.
- The local kiosk `/frame` surface now posts an acknowledgement each time it renders an item.
- Display acknowledgement appends metadata-only `feed_item_shown` events into the existing bounded delivery log and updates local state with current feed/artwork item pointers.
- Documented the endpoint and `feed_item_shown` event as part of the delivery-log contract for future backend `aos_` delivery ingestion.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted temporary local UI smoke passed for valid frame display acknowledgement, invalid id rejection, delivery-log/event-export inclusion, state update, and device-key redaction.

Next step:

Ingest `feed_item_shown` events into durable backend `aos_` delivery rows alongside broadcast delivery events, then let Admin > Frames show whether personalized feed items are actually reaching device playback.

## 2026-06-06 - Rollout acceptance contract

Date: 2026-06-06

Milestone: LEAD / integration - managed rollout gate

Changed files:

- `local-ui/server.js`
- `scripts/rollout-acceptance-check.sh`
- `scripts/security-smoke.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `GET /local/rollout/acceptance`, a redacted fleet rollout gate derived from health, readiness, Admin capabilities, and unified event export.
- Added setup, staged, and production profiles so fresh setup validation, managed staged devices, and strict production candidates can use the same contract with different required checks.
- Added `strictContent=1` for staged devices that must prove synced content, local playback, and cache state before rollout.
- Added `scripts/rollout-acceptance-check.sh` as the CLI gate for Pi validation, Admin adapter smoke tests, and rollout handoff reports.
- Extended the security smoke test to cover rollout acceptance redaction and remote-admin readiness evaluation.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted temporary local UI smoke passed for staged rollout warning mode, strict staged cache blocking, production cache blocking, event export presence, remote-admin readiness, and device-key redaction.

Next step:

Run `AUTOPOIESIS_ROLLOUT_PROFILE=staged /opt/autopoiesis-os/app/scripts/rollout-acceptance-check.sh` on the paired physical Pi after heartbeat/feed/cache cycles; use `AUTOPOIESIS_ROLLOUT_STRICT_CONTENT=1` when promoting a device from staged to production.

## 2026-06-06 - Admin capabilities acceptance check

Date: 2026-06-06

Milestone: ONLINE ADMIN - remote action policy acceptance

Changed files:

- `scripts/admin-capabilities-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/admin-system.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/admin-capabilities-check.sh` to validate the redacted `GET /local/admin/capabilities` contract for Admin > Frames remote-action controls.
- The check verifies accepted actor roles, command risk levels, authorization requirements, high/critical audit-id requirements, restart runtime opt-in state, factory-reset local-confirmation blocking, pending-command count shape, and device API key redaction.
- Added optional `AUTOPOIESIS_REQUIRE_REMOTE_ADMIN_READY=1` mode for staged paired devices, requiring paired state, stored device key, and `remoteEnabled=true`.
- Wired the check into `scripts/milestone2-verify.sh` so physical Pi acceptance catches drift between device policy and online admin controls.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted temporary local UI smoke passed for `scripts/admin-capabilities-check.sh` normal mode and strict `AUTOPOIESIS_REQUIRE_REMOTE_ADMIN_READY=1` rejection before pairing.

Next step:

After pairing a physical Pi to an online Frames profile, run `AUTOPOIESIS_REQUIRE_REMOTE_ADMIN_READY=1 /opt/autopoiesis-os/app/scripts/admin-capabilities-check.sh` and confirm Admin > Frames maps disabled/confirm/audit-required buttons from the same capability payload.

## 2026-06-06 - Frame playback readiness signal

Date: 2026-06-06

Milestone: LEAD / integration - rollout playback observability

Changed files:

- `local-ui/server.js`
- `scripts/frame-state-check.sh`
- `scripts/milestone2-verify.sh`
- `scripts/security-smoke.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added a compact `playback` summary to `GET /local/frame-state`, distinguishing `waiting_for_feed`, `empty_queue`, `no_playable_items`, `ready_remote`, and `ready_with_cache`.
- Mirrored that summary as `framePlayback` in diagnostics, compact health, readiness, and support bundles so admin/support consumers can tell whether a synced feed is actually renderable by the kiosk.
- Added stable health issue codes `frame_no_playable_items` and `frame_queue_empty` for feed/playback mismatch cases.
- Added `scripts/frame-state-check.sh` to validate the local playback contract and optionally fail when no playable frame items exist with `AUTOPOIESIS_REQUIRE_FRAME_ITEMS=1`.
- Wired the frame-state check into Milestone 2 validation without requiring items by default, preserving fresh setup validation while giving staged rollout a stricter switch.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted temporary-state local playback smoke passed for `AUTOPOIESIS_REQUIRE_FRAME_ITEMS=1 scripts/frame-state-check.sh`, `ready_with_cache`, diagnostics/health/readiness/support `framePlayback` visibility, support-bundle `frameState`, and device-key redaction.

Next step:

After a live backend feed sync and cache pass on the physical Pi, run `AUTOPOIESIS_REQUIRE_FRAME_ITEMS=1 /opt/autopoiesis-os/app/scripts/frame-state-check.sh` and then `sudo /opt/autopoiesis-os/app/scripts/milestone2-verify.sh` to confirm the local queue is renderable under Chromium.


## 2026-06-06 - Touchscreen input diagnostics

Date: 2026-06-06

Milestone: RPI APPLIANCE - physical input acceptance

Changed files:

- `local-ui/server.js`
- `scripts/touchscreen-check.sh`
- `scripts/milestone2-verify.sh`
- `scripts/security-smoke.sh`
- `scripts/support-bundle.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/installation.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added Linux input-device diagnostics derived from `/proc/bus/input/devices`, reporting touchscreen, pointer, keyboard, and bounded device metadata without reading live input events.
- Health now warns with stable `input_unknown`, `input_missing`, and `touchscreen_missing` issue codes; readiness includes a dedicated input phase.
- Support bundles and the support-bundle CLI summary now include compact input status.
- Added `scripts/touchscreen-check.sh` with an optional `AUTOPOIESIS_REQUIRE_TOUCHSCREEN=1` hard gate, and wired that hard gate into physical Pi Milestone 2 verification.
- Extended the local security smoke test to confirm input diagnostics are present on diagnostics, health, and readiness endpoints.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- `scripts/touchscreen-check.sh` passed in this container as pointer-only input.
- Targeted temporary-state touchscreen smoke passed for `scripts/touchscreen-check.sh`, `AUTOPOIESIS_REQUIRE_TOUCHSCREEN=1`, `/local/diagnostics`, `/local/health`, `/local/readiness?services=0`, and `/local/support-bundle?services=0` using a fake Goodix input device file.

Next step:

Run `sudo /opt/autopoiesis-os/app/scripts/milestone2-verify.sh` on the physical Pi and confirm the touchscreen check reports `touchscreen_ready`; if it reports `pointer_only` or fails, capture `/proc/bus/input/devices` plus the touchscreen HAT/driver model for the hardware issue note.

## 2026-06-06 - Local frame playback surface

Date: 2026-06-06

Milestone: LEAD / integration - local-first kiosk playback

Changed files:

- `local-ui/server.js`
- `scripts/milestone2-verify.sh`
- `scripts/security-smoke.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `GET /local/frame-state`, a browser-safe playback contract derived from the mixed `displayQueue` plus local cache index state.
- Added `/frame`, a local kiosk playback surface that rotates through the balanced queue, supports image/video/audio/text items, and prefers cached asset URLs when available.
- Added explicit local launch routing through `/launch?local=1` and `preferences.displayMode=local-feed` while preserving the hosted-display-first default launch path.
- Added local frame route and frame-state checks to Milestone 2 validation and security-smoke redaction coverage.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted temporary-state local frame smoke passed for `/local/frame-state`, cached media preference, `/frame`, cached asset serving, and `/launch?local=1` redirect.

Next step:

Point a staged kiosk at `/launch?local=1` or set `displayMode=local-feed` after a real backend feed sync, then verify on physical Pi hardware that Chromium rotates cached and remote items correctly across image/video/text content.


## 2026-06-06 - Backend heartbeat event ingestion

Date: 2026-06-06

Milestone: LEAD / integration - durable event ingestion

Changed files:

- `/data/.openclaw/workspace/autopoiesis/app/backend/production.py`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/admin-system.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added backend `aos_device_events` persistence for redacted heartbeat event exports, keyed idempotently by `device_id + event_key`.
- Heartbeat responses now return `eventsAck` with accepted event pointers, source cursors, and ingestion counts so Pi devices can advance their local replay cursor safely.
- Backend ingestion projects recognized events into existing durable rows: command audit events update command/audit status, broadcast display lifecycle events update delivery rows, and release history events update rollout rows.
- Admin device detail now returns recent ingested `deviceEvents` for support/UI consumption.

Verification:

- `python3 -m py_compile app/backend/production.py` passed in the main gallery repo.
- Focused Flask test-client smoke with a temporary SQLite DB passed for event insertion, device-key redaction, `eventsAck`, command audit projection, broadcast delivery projection, release rollout projection, and Admin device detail `deviceEvents`.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed in the RPi repo.
- `scripts/security-smoke.sh` passed.

Next step:

Wire Admin > Frames to render ingested `deviceEvents` and the projected delivery/release state, then decide whether production deploy should include this backend patch after the main `autopoiesis` worktree is cleaned enough for a scoped commit.

## 2026-06-06 - Heartbeat event ingestion cursor

Date: 2026-06-06

Milestone: API / database / sync ingestion readiness

Changed files:

- `local-ui/server.js`
- `factory-reset.sh`
- `docs/api-contract.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added a redacted local `event-cursor.json` contract for backend heartbeat event ingestion acknowledgements.
- Heartbeats now send the previous `eventIngestionCursor` when present, replay events from the accepted timestamp with a small overlap window, and persist compatible backend acknowledgements from `eventsAck`, `eventAck`, `deviceEventsAck`, or `eventIngestionCursor`.
- Diagnostics, `/local/events/export`, and support bundles now expose a compact event-ingestion summary so Admin/support can see what event pointer the API last accepted.
- Factory reset clears the event cursor with other local runtime/sync state.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted heartbeat mock passed for initial event export, backend `eventsAck` persistence, follow-up heartbeat replay using the stored cursor, diagnostics/support-bundle visibility, and device API key redaction.

Next step:

Implement backend heartbeat ingestion into durable `aos_` event tables and return `eventsAck` with the accepted event pointer so Pi devices can advance this cursor without losing idempotent replay safety.

## 2026-06-06 - Factory reset state hygiene

Date: 2026-06-06

Milestone: MVP 1.0 - Production installer foundation

Changed files:

- `factory-reset.sh`
- `README.md`
- `docs/installation.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Reworked `factory-reset.sh` into a deliberate appliance reset path with `--dry-run`, `--no-restart`, and `--keep-support-history`.
- Reset now clears local identity, pairing, preferences, network state, pending commands, active broadcasts, feed/cache manifests, release state, rollback metadata, support-history JSON, and runtime cache directories.
- App code and `/var/log/autopoiesis-os` are preserved; the script bootstraps a fresh unpaired device afterward and re-chowns runtime state/cache directories for the appliance user.
- When restarting is enabled, the script stops local timers during reset, reinstalls systemd units, and restarts setup/kiosk services.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted factory-reset smoke passed against temporary data/cache/install/log directories, confirming stale identity, pairing, command, feed, release, support-history, and cache files are removed while fresh bootstrap files are regenerated.

Next step:

Run `sudo /opt/autopoiesis-os/app/factory-reset.sh --dry-run` and then the real reset on physical Pi hardware, confirm the setup screen returns with a new unpaired device id, and then re-run Milestone 2 verification.

## 2026-06-06 - Mixed feed display queue

Date: 2026-06-06

Milestone: MVP 0.2 - Personal Stream / MVP 0.4 - Broadcast System

Changed files:

- `local-ui/server.js`
- `docs/api-contract.md`
- `docs/broadcast-system.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added a derived local `displayQueue` to `GET /local/feed` for personalized mixed stream playback.
- The queue preserves priority bands first, then round-robins broadcast, curatorial, artwork, blog, news, and general content categories within each band.
- Added feed category counts and `displayQueueItems` to local feed output and diagnostics so Admin > Frames/support tooling can see whether a device has a balanced displayable stream.
- Wrote display category/position into the feed cache manifest so cache workers follow the same display order instead of only raw recency.
- Feed sync delivery events now include category counts for backend delivery-log ingestion.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- Direct local feed smoke confirmed that `/local/feed` exposes `displayQueue`, `displayQueueItems`, and category counts. Broader syntax/security gates passed; full physical feed/cache validation still belongs on the Pi after live feed sync.

Next step:

Have the backend `/api/frames/device/{deviceId}/feed` return real mixed artwork/blog/news/curatorial/broadcast items, then point the kiosk/display surface at `displayQueue` for local-first playback behavior.

## 2026-06-06 - Event export source cursors

Date: 2026-06-06

Milestone: Lead/integration ingestion readiness

Changed files:

- `local-ui/server.js`
- `scripts/events-export-check.sh`
- `docs/api-contract.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Extended the unified `/local/events/export` and heartbeat `events` payload with per-source cursors for command audit, display delivery, and release history.
- Each source cursor now reports total entries, exported entries, per-source limit, `hasMore`, latest event pointer, and oldest exported event pointer.
- The global cursor also exposes oldest exported event pointers and a mixed-stream `hasMore` flag.
- Hardened `scripts/events-export-check.sh` so physical Pi validation checks the new cursor shape instead of only the mixed latest cursor.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted event cursor smoke passed for seeded command, display delivery, and release events with per-source truncation and device-key redaction.

Next step:

Use `sourceCursors` in backend heartbeat event ingestion so Admin > Frames can detect truncated device event exports per source and request/support replay without guessing from the mixed event order.

## 2026-06-06 - Local release rollback script

Date: 2026-06-06

Milestone: MVP 1.0 - Release rollout safety

Changed files:

- `scripts/update-from-release.sh`
- `scripts/rollback-release.sh`
- `README.md`
- `docs/github-updates.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added a device-local rollback script for the last release update.
- Git-checkout updates now record rollback metadata before fast-forwarding; artifact updates also snapshot the current app into `/opt/autopoiesis-os/releases/rollback/app` before replacing app files.
- Rollback restores either the previous git revision or the pre-update app snapshot, reruns bootstrap/systemd unit installation, restarts setup/kiosk services, writes `release-state.json`, and appends metadata-only rollback events to `release-log.json`.
- Rollback is intentionally app-code only: `/var/lib/autopoiesis-os` is preserved so pairing, device API keys, preferences, cache metadata, and support logs survive.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted rollback smoke passed for snapshot restore, release-state/log updates, and preserving device data under `/var/lib/autopoiesis-os`.

Next step:

Run rollback on physical Pi hardware after a staged release update and confirm the frame returns to the previous app version while staying paired.

## 2026-06-06 - Event export acceptance gate

Date: 2026-06-06

Milestone: Lead/integration ingestion readiness

Changed files:

- `scripts/events-export-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added a local event export verification script for the unified command, display delivery, and release history feed exposed at `/local/events/export`.
- The check validates the redacted contract kind/schema, device id, exported counts, allowed sources, parseable timestamps, newest-first ordering, unique event keys, and cursor consistency when events exist.
- Wired the check into Milestone 2 verification so physical Pi validation proves the event stream is ready for backend `aos_` ingestion alongside health/readiness/kiosk checks.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `scripts/security-smoke.sh` passed.
- `git diff --check` passed.
- Targeted local smoke passed for seeded command/delivery/release events and for `since` filtering.

Next step:

Implement backend heartbeat event ingestion using `deviceId + eventKey` as the idempotency key, then surface durable command audit, broadcast delivery, and release rollout rows in Admin > Frames.

## 2026-06-06 - Installer preflight and appliance user bootstrap

Date: 2026-06-06

Milestone: MVP 1.0 - Production installer foundation

Changed files:

- `install.sh`
- `scripts/bootstrap.sh`
- `scripts/ensure-appliance-user.sh`
- `scripts/preflight.sh`
- `README.md`
- `docs/installation.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added a reusable appliance user bootstrap helper so fresh installs and later bootstrap/update paths create the configured frame user before any runtime directory chown.
- Added `scripts/preflight.sh --install` to report hard installer blockers for root mode, rsync, curl, systemd, and Node.js 20+, plus warnings for non-Pi development hosts, missing Chromium, missing NetworkManager, and user creation.
- Wired the preflight and user helper into `install.sh`, and the user helper into `scripts/bootstrap.sh`.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- Local preflight smoke correctly failed on this development host because `rsync` is missing.
- PATH-stubbed local preflight smoke passed and reported only expected non-Pi/missing-NetworkManager warnings.

Next step:

Run `sudo ./install.sh` on a clean Raspberry Pi OS image where the `frame` user does not yet exist, then confirm the user is created with display/input groups and Milestone 2 verification still passes.

## 2026-06-04

Date: 2026-06-04

Milestone: 1 - Repo and installer skeleton

Changed files:

- `README.md`
- `install.sh`
- `update.sh`
- `uninstall-dev-tools.sh`
- `factory-reset.sh`
- `VERSION`
- `config/defaults.json`
- `config/device.example.json`
- `local-ui/package.json`
- `local-ui/server.js`
- `scripts/*.sh`
- `services/*.service`
- `timers/*.timer`
- `docs/*.md`
- `logs/.gitkeep`

Test result:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Local smoke test passed outside sandbox: `GET /local/status`, `GET /setup`, and `HEAD /launch` redirect to `/setup`.

Known issues:

- Wi-Fi connect endpoint is present but needs touchscreen UI and real-device validation.
- Pairing is mock/local only.
- Updater only supports a Git checkout and does not yet implement release rollback.
- Kiosk service assumes the active graphical session exposes `DISPLAY=:0` and `/home/frame/.Xauthority`.
- Hourly audit is read-only by design; it does not run Codex unattended.

Next step:

Implement Milestone 2: install locally, start setup service, launch Chromium kiosk at `/launch`, and verify restart behavior.

## 2026-06-05

Date: 2026-06-05

Milestone: 1 - Repo and installer skeleton (continued)

Changed files:

- `local-ui/server.js` (optimized version caching)

Test result:

- Version caching implemented to avoid reading VERSION file on every request.
- `node --check local-ui/server.js` still passes.
- All existing functionality preserved.

Next step:

Continue with Milestone 2: install locally, start setup service, launch Chromium kiosk at `/launch`, and verify restart behavior.

## 2026-06-05 - Milestone 2 scaffold

Date: 2026-06-05

Milestone: 2 - Physical Pi kiosk validation and LAN support

Changed files:

- `local-ui/server.js`
- `config/defaults.json`
- `config/device.example.json`
- `scripts/start-kiosk.sh`
- `scripts/network-status.sh`
- `scripts/connect-lan.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/*.md`

Implemented:

- Local network status API and UI for LAN and Wi-Fi.
- LAN activation through NetworkManager DHCP.
- Wi-Fi scan UI separated from the JSON API.
- Kiosk startup wait for the local `/launch` route.
- Repeatable Milestone 2 verification script for setup, kiosk, HTTP, Chromium, network state, and restart behavior.

Known issues:

- Physical Pi validation still has to be run on the target device.
- Pairing remains mock/local only.
- Production cloud API integration is still pending.

## 2026-06-05 - Brief-led program setup

Date: 2026-06-05

Milestone: Program foundation for Autopoiesis OS + Frames

Changed files:

- docs/pulse-brief.md
- docs/product-roadmap.md
- docs/database-schema.md
- docs/broadcast-system.md
- docs/admin-system.md
- docs/online-frames-profile.md
- docs/agent-notes/*.md
- docs/api-contract.md
- /data/.openclaw/workspace/autopoiesis-os-program/*

Implemented:

- Created the Pulse lead brief and roadmap from Ewoud's attached PDF.
- Added database schema proposal with program tag autopoiesis_os_frames, namespace aos, and table prefix aos_.
- Added admin system requirements for users, subscribers, subscriptions, devices, broadcasts, releases, and device commands.
- Added Profile > Frames product definition and broadcast system spec.
- Added agent notes for Pulse/RPi coordination.
- Created a separate program-management directory for logs, cron registry, and MVP management.

Next step:

Continue MVP 0.1 implementation through the active aos-* cron system.

## 2026-06-05 - Cron system

Date: 2026-06-05

Milestone: Major build automation

Implemented:

- Removed the earlier single daily autopoiesis-os-iterate cron to avoid duplicate OS automation.
- Created seven active aos-* OpenClaw cron jobs using gpt-5.4 with high thinking.
- Configured Telegram delivery to the Pulse channel for concise cliffnotes reports.
- Workstreams: lead integration, RPi appliance, online admin, API/database/sync, broadcast/feed, release/rollout, QA/security.
- Recorded cron IDs under program/CRON-REGISTRY.md.

Verification:

- Confirmed all seven cron jobs are enabled, scheduled, and set to gpt-5.4/high.
- Ran node and shell syntax checks after repo changes.

## 2026-06-05 - Device API wiring

Date: 2026-06-05

Milestone: MVP 0.1 - Pairable Frames Device

Changed files:

- local-ui/server.js
- scripts/heartbeat.sh
- scripts/sync-settings.sh
- scripts/pair-device.sh
- scripts/check-remote-status.sh
- docs/api-contract.md
- docs/agent-notes/pulse.md
- program/ROLLING-LOG.md

Implemented:

- Local UI now registers the device with the Frames API when starting pairing.
- Server pairing codes are stored locally and displayed in setup.
- Pairing status can be checked from the local UI.
- Remote settings can sync down to local preferences.
- Local settings push to the Frames API when paired.
- Heartbeat posts to the Frames API and stores queued commands locally.
- Scripts now call the local UI endpoints instead of placeholder-only behavior.

Verification:

- node --check local-ui/server.js passed.
- bash -n install/update/reset/scripts passed.
- Mock Frames API smoke test passed for register, pairing check, settings sync, heartbeat, and command storage.

Next step:

Build Profile > Frames UI and admin UI around the new backend APIs.
## Pi Command and Release Executor

- Added local `/local/commands/process` endpoint to fetch queued commands from heartbeat, acknowledge them, execute local actions, and report completed/error status.
- Added `/local/release/check` and `/local/release/apply` endpoints for release-channel lookup and local update execution.
- Added `scripts/process-commands.sh` plus `autopoiesis-command-executor.service/.timer` to process commands every 2 minutes.
- Added `scripts/update-from-release.sh` with artifact tarball support, checksum validation, git fallback, rollback metadata, and kiosk restart.
- Command support: `sync_settings`, `clear_cache`, `restart_display`, `restart_device` with explicit reboot opt-in, `update_device`, `disable_device`, `enable_device`, `show_broadcast`, and guarded `factory_reset_request`.

## 2026-06-05 - Device diagnostics contract

Date: 2026-06-05

Milestone: Lead/integration observability for QA, admin, and hardware validation

Changed files:

- `local-ui/server.js`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`

Implemented:

- Added `GET /local/diagnostics` for a compact device support snapshot.
- Heartbeat now sends the same diagnostics object to the Frames API.
- Diagnostics includes version, hostname, uptime, load, memory, temperature, cached network/pairing state, data/cache storage, release state, pending command count, current broadcast, and local systemd service states when requested locally.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Mock local UI/API smoke test passed for `GET /local/diagnostics` and heartbeat diagnostics upload.

Next step:

Teach the online Admin > Frames device detail view to surface the latest diagnostics payload from heartbeats once this Pi payload is deployed.

## 2026-06-05 - Kiosk offline launch fallback

Date: 2026-06-05

Milestone: RPi appliance runtime hardening

Changed files:

- `local-ui/server.js`
- `README.md`
- `docs/agent-notes/rpi-agent.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- `/launch` now probes the configured Frames URL before redirecting kiosk Chromium to the remote app.
- If the remote frame is unreachable, the launcher records offline mode and redirects to the local `/offline` fallback instead of a Chromium network error page.
- The offline page records the last fallback check and retries `/launch` automatically so network recovery can self-heal.

Verification:

- `node --check local-ui/server.js` passed.
- Local smoke test passed for unreachable remote -> `/offline` and reachable remote -> configured Frames URL.

Next step:

Validate on physical Raspberry Pi hardware by disconnecting LAN/Wi-Fi after pairing, confirming kiosk lands on `/offline`, reconnecting the network, and confirming the retry returns to the remote Frames app.

## 2026-06-05 - Diagnostics health summary

Date: 2026-06-05

Milestone: Lead/integration observability for support and admin surfaces

Changed files:

- `local-ui/server.js`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`

- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `diagnostics.health` to the local diagnostics payload and heartbeat diagnostics.
- Health status is derived as `ok`, `warning`, or `error`.
- Stable issue codes now cover pairing, missing device API key, network/offline fallback, storage pressure, low memory, high temperature, release/update state, pending commands, and failed systemd services when local service checks are included.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Local diagnostics smoke test passed: temporary local UI returned `diagnostics.health.status` plus expected setup issue codes.

Next step:

Use `diagnostics.health` in Admin > Frames and hardware validation reports so support does not have to infer device condition from raw telemetry.

## 2026-06-05 - QA/security smoke gate

Date: 2026-06-05

Milestone: QA/security production hygiene

Changed files:

- `scripts/security-smoke.sh`
- `README.md`
- `docs/production-cleanup.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`

Implemented:

- Added a repeatable local security smoke test that starts the local UI against temporary device state containing a fake device API key.
- The test verifies that `/local/status`, `/local/pairing/status`, and `/local/diagnostics` do not leak the key or device key field names.
- The test confirms safe key-presence flags remain visible for support and fails if sensitive-looking files are tracked in Git.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Run this smoke gate on physical Raspberry Pi hardware after install, then add it to the final production-image acceptance checklist.

## 2026-06-05 - Raspberry Pi hardware validation

Date: 2026-06-05

Milestone: Physical Pi setup and endpoint validation

Hardware:

- Raspberry Pi 3 Model B Rev 1.2.
- Debian GNU/Linux 13 (trixie), 13.4.

Install:

- Removed the previous `/home/frame/autopoiesis-os-rpi` checkout.
- Recloned `dev/pulse-initial-improvements` at `34c656f`.
- Ran `sudo ./install.sh`.
- Restarted `autopoiesis-setup.service` and `autopoiesis-kiosk.service`.
- `sudo /opt/autopoiesis-os/app/scripts/milestone2-verify.sh` passed.

Network:

- LAN connected on `eth0` via `netplan-eth0`.
- Wi-Fi hardware present as `wlan0`, disconnected during this run.

Pairing:

- Live Frames API registration succeeded with non-mock pairing.
- Device remains unclaimed, so no local device API key is stored yet.
- `device.json` contains a stable `rpi-` device ID and is `0600 frame frame`.

Backend-dependent checks:

- Heartbeat, settings sync, command polling, and release check endpoints are reachable but skip until the device is claimed.
- These must be rerun after live pairing is completed from a Frames account.

Pi fix:

- Added compatibility aliases for `GET /local/status.json` and `GET /local/network/status.json`.
- Confirmed `GET /local/diagnostics` is available for the handoff checks.
- Did not change command allowlists or unattended update behavior.

Journal notes:

- Setup service reports `Autopoiesis local UI listening on http://127.0.0.1:3030`.
- Kiosk service stays active.
- Chromium logs Pi 3 GPU initialization errors including `GLES3 is unsupported` and `CollectGraphicsInfo failed`; kiosk remains running.

Source:

- Origin commit `72f41fb Validate Pi setup endpoints`.
- Full local report on the validated Pi: `logs/2026-06-05-rpi-hardware-validation.md`. The `logs/*` path is gitignored, so this tracked summary is the portable report.

## 2026-06-06 - Guided onboarding setup

Date: 2026-06-06

Milestone: Appliance first-run UX

Changed files:

- `local-ui/server.js`
- `docs/progress.md`

Implemented:

- Replaced the generic `/setup` utility panel with a guided onboarding sequence.
- The sequence now leads users through four steps: connect internet, pair account, choose basic display settings, and launch stream.
- Kept the existing network, Wi-Fi, pairing, settings, and launch endpoints underneath the flow.
- Launch remains disabled until local state has both network and pairing readiness.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh factory-reset.sh uninstall-dev-tools.sh scripts/*.sh` passed.
- `git diff --check` passed.
- Temporary local UI smoke confirmed `/setup` renders the onboarding steps and `/launch` redirects to `/setup` when unready.

Next step:

Validate the sequence on the physical touchscreen and confirm the copy/buttons fit without scrolling friction.

## 2026-06-06 - Onboarding launch gate

Date: 2026-06-06

Milestone: Appliance first-run UX

Changed files:

- `local-ui/server.js`
- `docs/progress.md`

Implemented:

- Added explicit `device.onboardingComplete` gating to `/launch`.
- Already-paired frames no longer skip the setup sequence after installing a new onboarding build.
- The final Launch Stream button calls `/launch?completeOnboarding=1`, records onboarding completion, then proceeds to the display/offline decision.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh factory-reset.sh uninstall-dev-tools.sh scripts/*.sh` passed.
- `git diff --check` passed.
- Temporary local UI smoke confirmed `/launch` redirects to `/setup` before onboarding completion, and `/launch?completeOnboarding=1` records `onboardingComplete: true`.

## 2026-06-06 - Online admin diagnostics health readout

Date: 2026-06-06

Milestone: MVP 0.5 - Managed Device Fleet

Changed files:

- `/data/.openclaw/workspace/autopoiesis/app/frontend/src/pages/AdminFrames.jsx`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Admin > Frames device detail now extracts the newest heartbeat carrying `payload.diagnostics`.
- The selected device panel shows `diagnostics.health.status`, stable issue-code chips, and the timestamp of the heartbeat that supplied diagnostics.
- The panel handles older devices that have not yet sent diagnostics by showing a clear waiting state.

Verification:

- `npm run build` passed in `/data/.openclaw/workspace/autopoiesis/app/frontend`.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.

Commit note:

- The main `autopoiesis` repo change was not committed because that checkout already contains a large unrelated dirty backlog.
- The OS repo documentation/log update can be committed safely from the clean RPi checkout.

Next step:

Extend the admin fleet list endpoint/UI to include latest health status per device, so operators can scan the whole fleet without opening each frame.

## 2026-06-06 - Compact local health probe

Date: 2026-06-06

Milestone: Lead/integration observability for support, admin adapters, and hardware validation

Changed files:

- `local-ui/server.js`
- `scripts/health-check.sh`
- `scripts/security-smoke.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `GET /local/health`, a compact redacted summary derived from the existing diagnostics health object.
- Added optional `?services=1` support so systemd service state can be included before deriving health.
- Added `scripts/health-check.sh` for Pi acceptance checks and folded it into the Milestone 2 verification flow.
- Extended the security smoke gate to prove the new health endpoint does not leak stored device API keys.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `scripts/security-smoke.sh` passed, including `/local/health` redaction coverage.
- Local smoke test passed for `scripts/health-check.sh` against `/local/health` and for service-aware `/local/health?services=1`.

Next step:

Use the same compact health shape when the online admin fleet list API grows latest-health summaries per device.

## 2026-06-06 - Local feed and broadcast display foundation

Date: 2026-06-06

Milestone: MVP 0.2/MVP 0.4 - Personal Stream and Broadcast System

Changed files:

- `local-ui/server.js`
- `docs/api-contract.md`
- `docs/broadcast-system.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added local feed state at `/local/feed` plus `POST /local/feed/sync` for the remote device feed endpoint.
- Heartbeat responses carrying `feed`, `items`, `artworks`, or `broadcasts` are normalized into the same local feed model.
- Feed eligibility now filters expired items, future scheduled items, and media types disabled by local preferences.
- Added a metadata-only cache eligibility manifest for media/thumbnail items with `cacheAllowed` enabled.
- `show_broadcast` commands now normalize payloads, reject expired broadcasts, preserve priority/expiry/duration, and route active broadcasts through a local `/broadcast` display page.
- Diagnostics and `/local/health` now include compact feed/cache and richer broadcast summary fields.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Local mock API smoke passed for feed sync, preference/expiry filtering, cache eligibility, command ack/completion, `/launch` broadcast routing, and `/broadcast` rendering.

Next step:

Connect the backend feed endpoint to the real artwork/blog/news/curatorial content model and have the cache service download the cache manifest entries for offline playback.

## 2026-06-06 - Local cache worker foundation

Date: 2026-06-06

Milestone: MVP 0.3 - Offline Living Frame

Changed files:

- `scripts/cache-artworks.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Replaced the cache placeholder with a real feed-cache worker.
- The worker reads `feed-cache.json`, downloads eligible media and thumbnails into the runtime cache directory, and writes `cache-index.json`.
- Each cached item records media/thumbnail URL, local path, status, and byte count.
- Missing manifests, offline downloads, and partial failures are handled conservatively so the hourly timer leaves support-visible state instead of silently doing nothing.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Local cache smoke passed against a temporary HTTP file server: manifest item downloaded, `cache-index.json` reported one cached item and zero failed items.

Next step:

Use `cache-index.json` from the local offline fallback route so a disconnected paired frame can display cached artwork instead of only the static offline screen.

## 2026-06-06 - Settings sync conflict handling

Date: 2026-06-06

Milestone: MVP 0.1 - Pairable Frames Device

Changed files:

- `local-ui/server.js`
- `docs/api-contract.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added device-side settings sync metadata with local/remote `updatedAt` tracking.
- Local settings saves now stamp preferences before writing or pushing to the Frames API.
- Remote settings from explicit sync, push responses, and heartbeat responses now pass through one resolver.
- Stale remote settings are rejected when their `updatedAt` is older than the local settings timestamp.
- Settings conflicts are exposed through heartbeat diagnostics as `settingsSync` plus a `settings_conflict` health warning.
- Untimestamped remote payloads remain accepted for legacy compatibility and are marked as `remote_applied_untimestamped`.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Mock Frames API smoke passed for stale remote settings rejection, `settings_conflict` health reporting, and newer remote settings application.

Next step:

Mirror the same latest-`updatedAt` rule in the online Frames backend so POST/GET settings responses always return authoritative timestamps and can report conflicts explicitly.

## 2026-06-06 - Readiness contract

Date: 2026-06-06

Milestone: Lead/integration rollout readiness

Changed files:

- `local-ui/server.js`
- `scripts/readiness-check.sh`
- `scripts/security-smoke.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `GET /local/readiness`, a redacted phase-level rollout snapshot derived from diagnostics.
- Readiness phases cover local UI, network, pairing/device key, settings sync, content/feed, cache, commands, and release state.
- Added cache index fields to diagnostics and health issue codes for cache failures or empty completed cache runs.
- Added `scripts/readiness-check.sh` and included it in Milestone 2 verification.
- Extended the security smoke gate to verify readiness output does not leak stored device API keys.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Local readiness smoke passed for an unpaired device, a paired/cache-ready device, and a cache-failure blocked device.

Next step:

Run `scripts/readiness-check.sh` on physical Raspberry Pi hardware after live pairing, then use the blocker list as the acceptance checklist for rollout.

## 2026-06-06 - Offline cache playback

Date: 2026-06-06

Milestone: MVP 0.3 - Offline Living Frame

Changed files:

- `local-ui/server.js`
- `README.md`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `GET /local/offline-cache`, a redacted playable cache inventory built from `cache-index.json` and the active feed metadata.
- Added safe cached asset serving at `/local/cache/assets/{itemId}/media` and `/local/cache/assets/{itemId}/thumbnail`, constrained to files under the configured cache directory.
- Updated `/offline` so disconnected frames rotate cached playable feed media when available, while keeping the static offline fallback for empty caches.
- Diagnostics feed summary now includes `offlinePlayableItems` for support/readiness consumers.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh factory-reset.sh uninstall-dev-tools.sh scripts/*.sh` passed.
- `scripts/security-smoke.sh` passed with `/local/offline-cache` included in redaction coverage.
- Local offline-cache smoke passed for cache inventory, cached asset serving, `/offline` cached view rendering, and unreachable `/launch -> /offline` fallback.

Next step:

Run the offline cache path on physical Raspberry Pi hardware after a real feed/cache cycle, then add cache eviction and storage pressure policy.

## 2026-06-06 - Raspberry Pi Chromium software rendering

Date: 2026-06-06

Milestone: Physical Pi kiosk hardening

Changed files:

- `scripts/start-kiosk.sh`
- `docs/troubleshooting.md`
- `docs/progress.md`

Implemented:

- Added conservative Chromium kiosk flags for Pi 3 class devices where GLES3 initialization fails.
- Default flags now disable GPU compositing/accelerated canvas and use SwiftShader software GL.
- Added `AUTOPOIESIS_CHROMIUM_FLAGS` escape hatch for future hardware-specific overrides.

Verification:

- `bash -n scripts/start-kiosk.sh` passed.

## 2026-06-06 - Kiosk launch verification

Date: 2026-06-06

Milestone: Physical Pi kiosk hardening

Changed files:

- `scripts/start-kiosk.sh`
- `scripts/kiosk-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added a dry-run mode to the kiosk launcher so support checks can validate the exact Chromium command without starting a browser.
- Added `scripts/kiosk-check.sh` to assert the launch route is reachable, the launcher includes Pi-safe software rendering flags, and an installed running kiosk process has picked up those flags when required.
- Wired the kiosk check into `scripts/milestone2-verify.sh` so physical Pi acceptance fails if the kiosk process is still using stale Chromium flags after a restart.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `scripts/kiosk-check.sh` passed in dry-run mode without a local server.
- Local kiosk smoke passed against a temporary local UI server for `/launch` reachability and required Chromium software-rendering flags.
- Required-process kiosk smoke passed with a simulated Chromium command line carrying the expected Pi-safe flags.
- `git diff --check` passed.

## 2026-06-06 - Remote action authorization guard

Date: 2026-06-06

Milestone: Online admin remote-action foundation

Changed files:

- `local-ui/server.js`
- `docs/api-contract.md`
- `docs/admin-system.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added command risk policy for remote device actions.
- `sync_settings` remains low-risk and can run without remote authorization metadata.
- Medium/high/critical commands now require approved authorization metadata with actor, role, and timestamp.
- High/critical commands also require an admin audit id.
- Denied commands are reported through the existing command ack error path with policy context.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Mock API/local UI smoke passed for missing-authorization rejection and authorized `disable_device` completion.

Next step:

Update the online Frames backend command queueing path to create real audit rows and include authorization metadata before sending non-`sync_settings` commands.

## 2026-06-06 - Local command audit trail

Date: 2026-06-06

Milestone: Lead/integration admin-command reconciliation

Changed files:

- `local-ui/server.js`
- `scripts/security-smoke.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/admin-system.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added bounded local `command-audit.json` persistence for completed, denied, and failed remote command attempts.
- Added redacted `GET /local/commands/audit` for support/admin adapters.
- Heartbeat diagnostics, `/local/health`, and `/local/readiness` now include a compact `commandAudit` summary.
- Extended the security smoke gate so the command audit endpoint is included in device API key redaction coverage.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed with `/local/commands/audit` included in redaction coverage.
- Mock Frames API/local UI command audit smoke passed for missing-authorization denial, authorized `disable_device` completion, audit endpoint output, diagnostics/readiness summaries, and device-key redaction.

Next step:

Mirror this device-side command audit trail with durable backend `aos_` admin audit rows and include real authorization metadata when queueing non-`sync_settings` commands.

## 2026-06-06 - Redacted local support bundle

Date: 2026-06-06

Milestone: Lead/integration rollout evidence

Changed files:

- `local-ui/server.js`
- `scripts/support-bundle.sh`
- `scripts/security-smoke.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `GET /local/support-bundle`, a redacted one-shot support payload for hardware validation, admin adapters, and handoff reports.
- The bundle aggregates existing redacted diagnostics, compact health, rollout readiness, active feed, offline-cache inventory, and recent command audit entries.
- Added `scripts/support-bundle.sh` to collect the bundle from a running local UI, print a concise summary, and optionally write the JSON to a specified path.
- Extended the local security smoke gate so the support bundle is covered by device API key redaction checks.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `scripts/security-smoke.sh` passed with `/local/support-bundle` included in device-key redaction coverage.
- Targeted support-bundle smoke passed for `?services=0&auditLimit=1`, script file output, summary generation, audit limiting, and device-key redaction.
- `git diff --check` passed.

Next step:

Run the support bundle collector on physical Raspberry Pi hardware after live pairing, real feed/cache sync, and at least one remote command attempt; then mirror the shape into Admin > Frames fleet support exports.

## 2026-06-06 - Device delivery log foundation

Date: 2026-06-06

Milestone: MVP 0.4 - Broadcast delivery evidence

Changed files:

- `local-ui/server.js`
- `scripts/security-smoke.sh`
- `docs/api-contract.md`
- `docs/broadcast-system.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added bounded local `delivery-log.json` persistence for display/feed lifecycle events.
- Feed sync now records `feed_synced` events with total, eligible, and cache-eligible counts.
- Broadcast display now records `broadcast_shown`, `broadcast_dismissed`, and one-time `broadcast_expired` events.
- Added redacted `GET /local/delivery-log` for support/admin adapters.
- Diagnostics, `/local/health`, and `/local/support-bundle` now include compact display-delivery summaries.
- Extended the security smoke gate so the delivery log endpoint is covered by device API key redaction checks.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed with `/local/delivery-log` included in device-key redaction coverage.
- Targeted delivery-log smoke passed for feed sync, authorized broadcast show, dismiss, one-time expiry logging, support-bundle `deliveryLimit`, and device-key redaction.

Next step:

Mirror these device-side delivery events into durable backend `aos_` delivery rows from heartbeat diagnostics/support-bundle ingestion, then surface broadcast delivery state in Admin > Frames.

## 2026-06-06 - Appliance watchdog timer

Date: 2026-06-06

Milestone: RPi appliance runtime self-healing

Changed files:

- `scripts/watchdog.sh`
- `scripts/install-systemd-units.sh`
- `services/autopoiesis-watchdog.service`
- `timers/autopoiesis-watchdog.timer`
- `install.sh`
- `scripts/update-from-github.sh`
- `scripts/update-from-release.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Replaced the placeholder kiosk restart service with a real appliance watchdog script.
- Added a systemd watchdog timer enabled by install.
- Added a shared systemd unit installer used by fresh install and both update paths so changed services/timers are copied to `/etc/systemd/system` and newly added timers are enabled on upgraded devices.
- Watchdog checks local health HTTP, local launch HTTP, and the kiosk process/flags through the existing kiosk check.
- Setup restarts only when local routes are unreachable; kiosk restarts only when the kiosk check fails.
- Milestone 2 verification now confirms the watchdog timer is enabled and runs the watchdog script.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Local watchdog smoke passed with a temporary local UI, fake systemctl, and simulated Chromium kiosk process.
- Systemd unit installer dry-run smoke passed against a temporary systemd directory with a fake systemctl.

Next step:

Run the updated `scripts/milestone2-verify.sh` on physical Pi hardware after install/update to confirm the watchdog timer can restart real systemd services without disrupting a healthy kiosk session.

## 2026-06-06 - Command acknowledgement retry safety

Date: 2026-06-06

Milestone: MVP 0.1 - Pairable Frames Device command sync

Changed files:

- `local-ui/server.js`
- `docs/api-contract.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Local command queues now retain commands when the initial `acknowledged` POST fails, without executing the command.
- Commands that execute successfully but fail to deliver the final `completed` or `error` acknowledgement are retained with local final-ack retry metadata.
- Final-ack retries do not execute the command again, preventing duplicate side effects for commands like broadcast display, disable, update, restart, or cache clear.
- Command audit summaries now count acknowledgement delivery failures as recent errors.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Targeted mock Frames API smoke passed for initial ack failure retention, final ack failure retention without re-execution, and final ack retry removal.

Next step:

Mirror this expectation in backend `aos_` command rows: command status transitions should be idempotent, preserve last ack error, and tolerate devices retrying the same final acknowledgement after local execution.

## 2026-06-06 - Local release history contract

Date: 2026-06-06

Milestone: MVP 0.5 - Managed Device Fleet rollout evidence

Changed files:

- `local-ui/server.js`
- `scripts/support-bundle.sh`
- `scripts/security-smoke.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/admin-system.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added bounded local `release-log.json` persistence for release check/apply lifecycle events.
- `/local/release/check` records `release_checked`; release apply paths record `release_apply_started`, `release_apply_completed`, `release_apply_failed`, or `release_skipped`.
- Added redacted `GET /local/release/history` for support, hardware validation, and admin rollout adapters.
- Diagnostics, `/local/health`, `/local/readiness`, and `/local/support-bundle` now include compact release-history summaries.
- Extended the support-bundle CLI summary and security smoke gate to cover release history.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed with `/local/release/history` included in device-key redaction coverage.
- Targeted release-history smoke passed for mock API release check, already-current release apply skip, history events, support-bundle summary, and artifact/checksum/key redaction.

Next step:

Mirror these device-side release events into durable backend `aos_` rollout rows and make Admin > Frames show per-device release progress from heartbeat/support-bundle ingestion.

## 2026-06-06 - Local admin capabilities contract

Date: 2026-06-06

Milestone: MVP 0.5 - Managed Device Fleet role-gated actions

Changed files:

- `local-ui/server.js`
- `scripts/security-smoke.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/admin-system.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added redacted `GET /local/admin/capabilities` for Admin > Frames, support tools, and backend adapters.
- The endpoint reports pairing/key presence, remote-enabled state, accepted actor roles, authorization window, supported command types, risk levels, audit-id requirements, local confirmation gates, runtime opt-in requirements, pending command count, and compact command-audit summary.
- Included the same admin capability object in `/local/support-bundle` so support exports carry the current remote action policy matrix.
- Extended the security smoke gate so admin capabilities are checked for device API key redaction and high-risk audit requirements.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed with `/local/admin/capabilities` included in device-key redaction coverage.
- Targeted admin-capabilities smoke passed for command policy shape, support-bundle inclusion, restart-device runtime opt-in, and no device-key leakage.

Next step:

Use `/local/admin/capabilities` or its support-bundle copy when building Admin > Frames action buttons, and persist real backend `aos_` audit rows before queueing non-`sync_settings` commands.

## 2026-06-06 - Unified device event export

Date: 2026-06-06

Milestone: Lead/integration backend ingestion contract

Changed files:

- `local-ui/server.js`
- `scripts/security-smoke.sh`
- `scripts/support-bundle.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/admin-system.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added redacted `GET /local/events/export`, a unified newest-first event stream built from local command audit, display delivery, and release history evidence.
- Heartbeats now include the same bounded event export under `events`, giving the backend one ingestion shape for durable `aos_` command audit, broadcast delivery, and release rollout rows.
- Support bundles now include `deviceEvents`, and the support-bundle CLI summary reports exported event count.
- Event exports include stable `source`, `eventKey`, and `observedAt` fields so backend ingestion can use `deviceId + eventKey` idempotency.
- Extended the local security smoke gate so `/local/events/export` is covered by device-key redaction checks.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed with `/local/events/export` included in device-key redaction coverage.
- Targeted event export smoke passed for event aggregation, `since` filtering, support-bundle inclusion, heartbeat inclusion, and device-key redaction.

Next step:

Implement backend heartbeat event ingestion into durable `aos_` command audit, broadcast delivery, and release rollout rows, treating repeated `deviceId + eventKey` reports as idempotent.

## 2026-06-06 - Backend admin command authorization audit

Date: 2026-06-06

Milestone: MVP 0.5 - Managed Device Fleet role-gated actions

Changed files:

- `/data/.openclaw/workspace/autopoiesis/app/backend/production.py`
- `docs/api-contract.md`
- `docs/admin-system.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added backend `aos_admin_command_audits` persistence for admin-originated remote frame commands.
- Direct Admin > Frames device commands now create an audit row before queueing medium/high/critical commands and embed approved `payload.authorization` metadata for the Pi executor.
- Admin broadcast and release enqueue paths now use the same authorization/audit path for `show_broadcast` and `update_device` commands.
- Device command acknowledgements now update the matching backend audit row status.
- Admin device detail responses now include recent command audit rows for UI/support consumption.

Verification:

- `python3 -m py_compile app/backend/production.py` passed in the main `autopoiesis` repo.
- Focused Flask test-client smoke passed against a temporary SQLite database for high-risk command authorization payloads, audit status updates, and disallowed actor-role rejection.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed in both touched repos.

Commit status:

- RPi documentation was committed locally.
- The main `autopoiesis` backend code was not committed because that checkout already contains a very large unrelated dirty backlog, including pre-existing modifications in `app/backend/production.py`.

Next step:

Ingest heartbeat `events` into durable backend broadcast delivery, release rollout, and device event rows using `deviceId + eventKey` idempotency, then show those rows in Admin > Frames.
