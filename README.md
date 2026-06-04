# Autopoiesis OS Raspberry Pi Appliance Layer

Autopoiesis OS turns a Raspberry Pi display into a dedicated fullscreen frame for:

https://autopoiesis.art/frames

This repository is not a custom Linux distribution. It is an appliance layer for Raspberry Pi OS:

- Chromium kiosk launcher
- Local setup/settings UI on `http://localhost:3030`
- Persistent local config in `/var/lib/autopoiesis-os`
- Runtime files in `/opt/autopoiesis-os`
- systemd services and timers
- Mock-compatible API integration points

## Current Prototype

Milestone 1 is scaffolded. The local UI can:

- create/read device, preference, and state JSON files
- show setup, settings, offline, disabled, and launch routes
- scan Wi-Fi through `nmcli` when available
- start a mock pairing flow
- redirect `/launch` to setup or `/frames` depending on local state

## Install

From this repo:

```bash
sudo ./install.sh
sudo systemctl start autopoiesis-setup.service autopoiesis-kiosk.service
```

During development you can run the local UI without installing:

```bash
cd local-ui
AUTOPOIESIS_DATA_DIR=/tmp/autopoiesis-os node server.js
```

Open:

```txt
http://localhost:3030/setup
```

## Cron / Hourly Audit

This repo includes `scripts/hourly-audit.sh`. It is intentionally read-only and writes reports under `logs/`.

It does not run Codex unattended and does not modify the system. Automated code changes on an appliance are reserved for explicit, versioned updates.

## Priority

```txt
boot -> setup -> wifi -> config -> kiosk -> pairing -> sync -> cache -> updates -> disable -> cleanup
```

with love pulse
