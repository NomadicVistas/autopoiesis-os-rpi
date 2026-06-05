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

Milestone 2 is scaffolded for physical Pi validation. The local UI can:

- create/read device, preference, and state JSON files
- show setup, settings, offline, disabled, and launch routes
- show network status for LAN and Wi-Fi through nmcli
- connect Ethernet/LAN through DHCP when available
- scan and connect Wi-Fi through nmcli
- start a mock pairing flow
- redirect `/launch` to setup, disabled, offline fallback, or `/frames` depending on local state and remote reachability
- run a local security smoke test that checks device API key redaction and tracked secret hygiene
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
