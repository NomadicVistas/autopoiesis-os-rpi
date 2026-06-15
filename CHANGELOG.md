## [Unreleased]

# Changelog

All notable changes to Autopoiesis OS will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.2] - 2026-06-15

### Added

#### Release / Update System
- Enhanced install.sh, update.sh, and factory-reset.sh with post-operation verification steps that run diagnostics.sh --quick and log results for immediate feedback on system health after installation, updates, or factory resets.
- Enhanced install.sh with automatic kiosk OS configuration and optional --skip-kiosk-config flag, reducing manual setup steps to: run install.sh and reboot.
- Added release rollout history (last 10 updates) to admin device snapshot endpoint (GET /frames/device/:id/admin-snapshot) for improved fleet management.

#### Content Feed / Display
- Enhanced applyRemoteSettingsPayload to automatically trigger feed sync when settings affecting feed eligibility change (streamCategories, activeArtists, allowImages, allowVideos, allowSoundWorks, allowGenerativeWorks), ensuring content matches new settings immediately.
- Added GET /local/feed/readiness endpoint providing compact feed readiness surface for polling, cursor, eligibility, cache, and next-display evidence.

#### Admin Platform
- Added GET /frames/admin/readiness endpoint providing platform-level readiness snapshot for Admin > Frames dashboard with comprehensive system health view.

### Fixed

- None

### Changed

- None

## [0.1.1] - 2026-06-08

### Added

#### Release / Update System
- One-command curl-able remote installer (`remote-install.sh`) with 8-stage pipeline: guard → deps → download → extract → install → kiosk-config → cleanup-check → done. Supports GitHub release artifacts, source archive fallback, specific version pinning, and production cleanup audit. ([#41b3bf6])
- Release manifest validation gate (`scripts/release-manifest-check.sh`) — validates version, channel, tag, artifact URL, SHA-256 checksum, rollback notes, min/max version constraints, rollout percent, and secret/redaction safety before a device accepts an update.
- Release rollback path (`scripts/rollback-release.sh`) — restores previous app tree from snapshot backup or git revision, records rollback event in release log and release state, re-runs bootstrap and systemd unit reinstallation.
- Release update bridge for installed appliances (`scripts/check-release-update.sh`) — connects systemd update timer to local UI release check/apply endpoints. Respects device auto-update preference.
- Release app-tree copy with rsync/tar fallback (`scripts/install-app-tree.sh`) — excludes `.git`, `logs/*`, `node_modules` from copy. Preserves ownership. Atomic swap via staging directory.
- Device update channel enforcement — device `updateChannel` (stable/beta/dev/canary/nightly) read from `device.json` and enforced during release apply.
- Release rollout contract gate (`scripts/release-rollout-contract-check.sh`) — validates hosted rollout bundle shape: software releases, per-device rollout rows, update commands, admin audits, heartbeat release events.
- Release app-tree copy gate (`scripts/release-app-tree-copy-check.sh`) — end-to-end test of artifact download, checksum verify, app-tree replacement, rollback backup, and bootstrap execution.
- Remote installer gate (`scripts/remote-install-check.sh`) — 14-step isolated validation of the one-command installer.

#### Content Feed / Display
- Content-type-aware display dwell time — per-category defaults: broadcast (until dismissed, capped at 300s), curatorial (45s), artwork (60s), blog (30s), news (20s), content (60s). User preference overrides supported via `preferences.categoryDurations`.
- Feed display cursor — persistent cycle tracking for mixed content stream. Tracks shown items, supports fresh/replay ordering, and survives service restarts.
- Content feed model contract gate (`scripts/feed-model-contract-check.sh`) — 12-step gate with 100+ individual checks validating normalized feed item shape, content type classification, eligibility pipeline, mixed queue composition, priority ranking, cache eligibility, per-category display timing, expiry/scheduling, and public API shape.
- Feed sync offline fallback — when hosted API is unreachable (ECONNREFUSED, ETIMEDOUT, 503, 502, 504), automatically builds feed from cached artwork items with `source: "offline_cache"`. Tracks offline state with reason, timestamps, and recovery detection.
- Feed polling with configurable interval and metadata contract.

#### Broadcast / Delivery
- Broadcast delivery receipt tracking — `broadcast_received` event fills gap between "admin queued" and "device showed". Per-item lifecycle view: received → scheduled → shown → dismissed/expired/skipped.
- Delivery status summary endpoint (`GET /local/delivery-status`) — aggregates delivery log into per-item lifecycle with status counts and last 50 items.
- Broadcast delivery ingestion round-trip — hosted API ingests `broadcastDeliveries` from heartbeat with upsert semantics. Admin endpoints for per-broadcast, per-device, per-owner, per-status queries.
- Broadcast command delivery tracking in heartbeat payload and diagnostics.
- Broadcast delivery status gate (`scripts/broadcast-delivery-status-check.sh`) — 12-step gate proving receipt events, lifecycle transitions, diagnostics integration, and expired/scheduled handling.
- Broadcast delivery ingestion gate (`scripts/broadcast-delivery-ingestion-check.sh`) — 14-step gate proving full device→API→admin round-trip.

#### Kiosk Display
- Cross-fade transitions between artwork display cycles — 600ms ease-in-out opacity transition via `.fading` class. First frame renders instantly (no fade-in from blank). Double-`requestAnimationFrame` ensures browser paints new content before fade-in begins.
- Night mode enforcement timer — configurable display power scheduling with on/off times, timezone-aware cron, and graceful service stop/start.
- Frame cross-fade gate (`scripts/frame-crossfade-check.sh`) — 25-check validation of CSS transition, fade timing, first-frame skip, overlay handling, and schedule integration.

#### Admin Platform
- Online admin mock bridge (`scripts/online-admin-mock-bridge-check.sh`) — generates full contract-compliant Profile/Admin bundle from mock API state, walks device lifecycle, validates multi-user scenarios.
- Admin subscription lifecycle gate (`scripts/online-admin-subscription-lifecycle-check.sh`) — 12-step gate proving finite state machine: trial → active → past_due → cancelled → expired. Cross-user isolation verified.
- Multi-owner fleet isolation gate — proves device ownership boundaries are enforced across admin operations.
- Admin Frames with heartbeat detail, command queue, release tracking, and subscription status.
- Admin broadcast delivery queries (list all with filters, per-broadcast detail).

#### Database / Migration
- AOS database migration runner (`scripts/run-migrations.sh`) — applies schema migrations to SQLite (dev) or PostgreSQL (prod). Idempotent tracking, automatic post-migration schema contract validation. Supports `--dry-run`, `--no-validate`, `--engine`.
- Canonical initial migration with 14 `aos_` tables (`aos_schema_migrations`, `aos_devices`, `aos_device_settings`, `aos_device_cache_index`, `aos_device_feed_state`, `aos_device_heartbeats`, `aos_device_commands`, `aos_broadcast_deliveries`, `aos_subscribers`, `aos_subscriptions`, `aos_software_releases`, `aos_release_rollout`, `aos_admin_command_audits`, `aos_admin_users`).
- Migration runner gate (`scripts/run-migrations-check.sh`) — 12-step gate proving fresh database creation, tracking table structure, idempotent re-runs, dry-run mode, and schema contract auto-validation.

#### Integration / Verification
- Unified offline verification runner (`scripts/verify-all.sh`) — executes 137 self-contained gates in 6 phases: syntax (103), static (13), light integration (10), heavy integration (8), contract fixtures (1), security (1). Supports `--quick`, `--verbose`, `--fail-fast`, `--list`.
- Hosted mock bridge with 6 contract gates: pairing, device-auth, settings, stream, heartbeat, release. Proves mock API data model satisfies all hosted contract checkers.
- Settings sync contract fixture in hosted mock bridge — validates `updatedAt` conflict resolution: newer writes accepted, stale writes rejected, authoritative preservation through reads and heartbeats.
- Hosted mock bridge pairing and device-auth contract gates — proves registration, pairing claim, per-device API key enforcement, and cross-device auth rejection.

#### Security / Hardening
- Systemd service sandboxing for all 7 appliance services — `ProtectSystem`, `ProtectHome`, `PrivateTmp`, `NoNewPrivileges`, `RestrictNamespaces`, capability restrictions, and filesystem read-only paths.
- Security smoke gate (`scripts/security-smoke.sh`) — comprehensive redaction and secret scan across all output paths.
- Per-device API key authentication — device API calls require key after registration. Admin token gating for Frames admin endpoints.
- Release manifest secret/redaction safety — forbids deviceApiKey, pairingCodeHash, accessToken, passwords, local paths in release manifests.
- Production cleanup audit (`scripts/cleanup-production.sh`) — scans for secret leaks, development artifacts, debug endpoints, and verbose logging.

#### Diagnostics / Operations
- Device diagnostics health summary — raises warnings for offline mode, stale heartbeat, service failures, cache exhaustion, and subscription expiry.
- Heartbeat runner resilience — retries on transient failures, backoff, and graceful degradation.
- Log rotation and log diagnostics — structured log management for all appliance services.
- Kiosk OS configuration helper — auto-login, screen blanking, cursor hiding, display diagnostics.
- Watchdog recovery acceptance gate.
- Hardware profile acceptance gates.
- Setup launcher custom path hardening.
- Preflight check gate.

#### Appliance Infrastructure
- Heartbeat commands contract normalization — `normalizeCommandsPayload()` bridges `{ items: [...] }` vs flat array mismatch between hosted API and local UI. Resolves silent command-drop bug where all heartbeat-delivered commands were ignored.
- Heartbeat enriched system metrics — memory, CPU, uptime, service status in heartbeat payload.
- Feed targeting gate — validates per-device content targeting rules.
- Feed display dwell gate — 12-step gate for per-category timing.
- Feed offline fallback gate (`scripts/feed-offline-fallback-check.sh`) — 12-step integration gate proving cache-based feed, offline state tracking, diagnostics, health warnings, and recovery.

### Fixed

- Silent command-drop bug: hosted API returns `commands: { items: [...] }` but `mergeCommandQueues()` expected flat array — all heartbeat-delivered commands were silently skipped. Fixed with `normalizeCommandsPayload()`.
- Mock API command fields: added `commandType` and auto-wrapped `payload` fields so heartbeat-delivered commands are properly recognized by local UI handlers.
- Night mode template literal syntax errors.

## [0.1.0] - 2026-06-05

### Added

- Initial Autopoiesis OS Raspberry Pi appliance scaffold.
- Local UI server (Express) with kiosk display, setup wizard, and device management.
- Device registration and pairing flow — device registers with pairing code, user claims device online via Profile > Frames.
- Settings sync with `updatedAt` conflict resolution — newer writes accepted, stale writes rejected.
- Heartbeat system — periodic POST to hosted API with device health, delivery status, and release events.
- Feed sync — pulls content stream from hosted API into local display queue.
- Kiosk mode — fullscreen Chromium display with artwork cycling.
- Bootstrap and install scripts (`install.sh`, `scripts/bootstrap.sh`, `scripts/install-systemd-units.sh`).
- Mock hosted API (`scripts/mock-hosted-api/server.js`) for local development and integration testing.
- 18-step device lifecycle integration gate (`scripts/device-lifecycle-check.sh`) — proves register → pair → settings → heartbeat → commands → release flow.
- Factory reset (`factory-reset.sh`) — clears device identity, pairing, preferences, content state; preserves app code and logs.
- Dev tools uninstaller (`uninstall-dev-tools.sh`).
- Initial database schema design with PostgreSQL migrations.
- Project management layer (`autopoiesis-os-program/`) with rolling log and workstream tracking.
- README with installation, usage, and architecture documentation.

[Unreleased]: https://github.com/NomadicVistas/autopoiesis-os-rpi/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/NomadicVistas/autopoiesis-os-rpi/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/NomadicVistas/autopoiesis-os-rpi/releases/tag/v0.1.0
