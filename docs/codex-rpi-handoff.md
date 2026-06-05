# Codex RPi Handoff

This repository is the Raspberry Pi appliance layer for Autopoiesis OS / Frames.
It runs on top of Raspberry Pi OS and should stay boring, resilient, and easy to
recover in the field.

## Current State

The branch `dev/pulse-initial-improvements` contains the current MVP line:

- local setup/settings UI on `http://localhost:3030`
- LAN and Wi-Fi setup through NetworkManager / `nmcli`
- pairing flow with mock fallback when the backend is unreachable
- device registration, API key storage, heartbeat, settings sync, and command polling
- guarded command execution for restart, reboot, factory reset, and release updates
- systemd services/timers for kiosk, setup, heartbeat, cache, updater, and command executor

The paired web/API backend lives in the main `autopoiesis` repository. Relevant
backend commits there end at `a36e000df Harden Frames admin and device API auth`.

## Next Mission On Real Hardware

Work from the actual Raspberry Pi, not only a mock environment. Validate the
appliance path end to end:

1. Pull the latest `dev/pulse-initial-improvements` branch.
2. Run install from a clean Pi OS image or a disposable test device:

   ```bash
   sudo ./install.sh
   sudo systemctl restart autopoiesis-setup.service autopoiesis-kiosk.service
   sudo /opt/autopoiesis-os/app/scripts/milestone2-verify.sh
   ```

3. Verify first boot lands on setup, network setup works for LAN and Wi-Fi, and
   kiosk only advances to `/frames` after the device has enough local config.
4. Pair against the live Frames API and confirm:
   - `device.json` contains a stable `device_id`
   - the API key is stored locally with restrictive permissions
   - heartbeat updates reach the backend
   - settings sync pulls backend preferences without destroying local fallback state
   - queued remote commands are acknowledged exactly once
5. Test release update behavior with a harmless test release before any real
   rollout command.

## Guardrails

- Do not commit secrets, API keys, live tokens, local `device.json`, or logs with
  private data.
- Do not weaken command allowlists to make tests pass.
- Do not add unattended self-modifying Codex behavior to the appliance.
- Prefer small commits with one hardware finding or fix per commit.
- Keep generated files, `node_modules`, build outputs, and local runtime state out
  of git.
- If hardware behavior disagrees with mocks, trust the hardware and update the
  mock coverage after the fix.

## Useful Checks

```bash
node --check local-ui/server.js
bash -n scripts/*.sh install.sh update.sh factory-reset.sh uninstall-dev-tools.sh
sudo systemctl status autopoiesis-setup.service autopoiesis-kiosk.service
sudo journalctl -u autopoiesis-setup.service -u autopoiesis-kiosk.service -n 200 --no-pager
curl -fsS http://localhost:3030/local/status.json
curl -fsS http://localhost:3030/local/network/status.json
```

## Report Back

Leave a concise hardware report in `docs/progress.md` or a new dated file under
`logs/` if it is operational evidence. Include:

- Pi model and OS version
- wired/wireless network result
- pairing result
- heartbeat result
- command execution result
- release update result
- exact failures with journal excerpts when something breaks
