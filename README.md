# Autopoiesis OS Raspberry Pi Appliance Layer

Autopoiesis OS turns a Raspberry Pi display into a dedicated fullscreen frame for:

https://autopoiesis.art/display?shuffle=1

This repository is not a custom Linux distribution. It is an appliance layer for Raspberry Pi OS:

- Chromium kiosk launcher
- Local setup/settings UI on `http://localhost:3030`
- Persistent local config in `/var/lib/autopoiesis-os`
- Runtime files in `/opt/autopoiesis-os`
- systemd services and timers
- Mock-compatible API integration points

## Current Prototype

Milestone 2 is scaffolded for physical Pi validation. The local UI can:

- create/read device, preference, and state JSON files
- show setup, settings, offline, disabled, and launch routes
- show network status for LAN and Wi-Fi through nmcli
- connect Ethernet/LAN through DHCP when available
- scan and connect Wi-Fi through nmcli
- start a mock pairing flow
- redirect `/launch` to setup, disabled, offline fallback, or the live display route depending on local state and remote reachability
- build a local cache index from eligible feed media through the hourly cache timer
- show cached feed media on `/offline` when the live display is unreachable
- expose a compact `/local/health` probe for support, admin adapters, and hardware acceptance checks
- expose a phase-level `/local/readiness` probe for setup, pairing, sync, content, cache, commands, and release rollout checks
- expose a redacted `/local/support-bundle` for one-step hardware/support handoff collection
- expose a metadata-only `/local/commands/audit` trail for recent remote command attempts
- expose a metadata-only `/local/release/history` trail for local release check/apply outcomes
- run a local security smoke test that checks device API key redaction and tracked secret hygiene
- run a kiosk check that proves the Chromium launch command uses Pi-safe software rendering flags
- run a local watchdog timer that restarts setup/kiosk services only when liveness checks fail
- reinstall and enable systemd units during install/update so new timers reach existing devices
- verify setup, kiosk, HTTP, Chromium, network, and restart behavior on a Pi

## Install

From this repo:

```bash
sudo ./install.sh
sudo systemctl start autopoiesis-setup.service autopoiesis-kiosk.service
sudo /opt/autopoiesis-os/app/scripts/milestone2-verify.sh
sudo /opt/autopoiesis-os/app/scripts/security-smoke.sh
```

During development you can run the local UI without installing:

```bash
cd local-ui
AUTOPOIESIS_DATA_DIR=/tmp/autopoiesis-os node server.js
```

Run the local security smoke test before shipping an image or exposing the local UI beyond localhost:

```bash
./scripts/security-smoke.sh
```

Check the compact local health summary:

```bash
./scripts/health-check.sh
```

Check the kiosk launch command and any running kiosk process:

```bash
./scripts/kiosk-check.sh
```

Run the same liveness checks used by the systemd watchdog:

```bash
sudo /opt/autopoiesis-os/app/scripts/watchdog.sh
```

Check rollout readiness across the local integration phases:

```bash
./scripts/readiness-check.sh
```

Collect a redacted local support bundle:

```bash
./scripts/support-bundle.sh ./support-bundle.json
```

Run one local cache refresh after a feed sync:

```bash
./scripts/cache-artworks.sh
```

Open:

```txt
http://localhost:3030/setup
```

Network setup is available at:

```txt
http://localhost:3030/network
```

## Cron / Hourly Audit

This repo includes `scripts/hourly-audit.sh`. It is intentionally read-only and writes reports under `logs/`.

It does not run Codex unattended and does not modify the system. Automated code changes on an appliance are reserved for explicit, versioned updates.

## Priority

```txt
boot -> setup -> lan/wifi -> config -> kiosk -> pairing -> sync -> cache -> updates -> disable -> cleanup
```

with love pulse
