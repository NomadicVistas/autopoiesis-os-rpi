# Progress

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
