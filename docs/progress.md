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
