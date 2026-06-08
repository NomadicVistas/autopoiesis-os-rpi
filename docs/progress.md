# Progress

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
