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

## 2026-06-05 - Raspberry Pi hardware validation

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

- Added `GET /local/status.json`, `GET /local/network/status.json`, and `GET /local/diagnostics` for the handoff checks.
- Added sanitized local diagnostics to heartbeat payloads.
- Did not change command allowlists or unattended update behavior.

Journal notes:

- Setup service reports `Autopoiesis local UI listening on http://127.0.0.1:3030`.
- Kiosk service stays active.
- Chromium logs Pi 3 GPU initialization errors including `GLES3 is unsupported` and `CollectGraphicsInfo failed`; kiosk remains running.

Full local report:

- `logs/2026-06-05-rpi-hardware-validation.md` on the validated Pi. The `logs/*` path is gitignored, so this tracked summary is the portable report.
