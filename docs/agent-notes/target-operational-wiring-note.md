# Target Operational Wiring Note

Date: 2026-06-09
Agent: Pulse
Workstream: RPI Appliance

## What

Wired `autopoiesis.target` composite status into all operational tooling: diagnostics, heartbeat log, preflight validation, and install/remote-install hints.

## Why

The `autopoiesis.target` systemd target was created (2026-06-09 systemd-target commit) to group all 8 services and 6 timers under a single lifecycle unit. But no operational tool checked target status:

- `diagnostics.sh` checked 8 individual services but had no composite "is the appliance healthy" indicator
- `heartbeat.sh` logged 7 individual services (missing night-mode) but not the target
- `preflight.sh` validated night-mode service but not the night-mode timer file
- `install.sh` and `remote-install.sh` printed `systemctl start autopoiesis-setup.service autopoiesis-kiosk.service` instead of the simpler `systemctl start autopoiesis.target`

## Changes

1. **diagnostics.sh**: New "Appliance" section at top of services area checks `systemctl is-active autopoiesis.target`. Adds `appliance.targetActive` (boolean) and `appliance.targetStatus` (string) to JSON output. Active → pass, inactive/failed → fail, not_found → warn.

2. **heartbeat.sh**: Added `SERVICE_NIGHT_MODE` and `APPLIANCE_TARGET` to service checks. Log line now includes `nightMode=` and `applianceTarget=` fields.

3. **preflight.sh**: Added `timers/autopoiesis-night-mode.timer` to required files list (was missing — only the service file was checked).

4. **install.sh**: Updated next-step hint from `systemctl start autopoiesis-setup.service autopoiesis-kiosk.service` to `systemctl start autopoiesis.target`.

5. **remote-install.sh**: Updated "start services" hint to `systemctl start autopoiesis.target` and "check status" hint to `systemctl status autopoiesis.target`.

## Verification

- `scripts/diagnostics-check.sh` — 39/39 pass (no regression)
- `scripts/systemd-security-check.sh` — 130/130 pass
- `scripts/factory-reset-check.sh` — pass
- `scripts/systemd-units-install-check.sh` — pass
- JSON output confirmed: `appliance: { targetActive: false, targetStatus: "not_found" }` in sandbox (expected)
- Human-readable output confirmed: new "Appliance" section with target check
- All `bash -n` and `node --check` pass

## Next

- Test on physical Pi: verify `appliance.targetStatus` reports `active` when target is running
- Add `appliance_target` assertion to `diagnostics-check.sh` (needs mock systemctl)
- Wire `appliance.targetActive` into the heartbeat payload sent to the hosted API
- Consider adding `systemctl is-failed autopoiesis.target` for failed-unit detection
