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
