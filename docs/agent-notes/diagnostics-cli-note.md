# Diagnostics CLI Note

## What

`scripts/diagnostics.sh` — a standalone CLI health check tool for the Raspberry Pi appliance.

## Design Decisions

- **Zero dependency on local UI server**: All checks read files directly or use system commands (systemctl, nmcli, curl, pgrep). The local UI health endpoint is checked via curl but failure is reported as a check failure, not a script error.
- **Single node process for JSON**: The `--json` flag writes all collected data to a temp file (key=value format) and pipes a single heredoc node script to build the JSON. This avoids spawning dozens of node processes.
- **Pi-specific thresholds**: CPU temp warns at 70°C and fails at 80°C (Pi thermal throttle). Disk warns at 75% and fails at 90%.
- **Timer vs service distinction**: Timer units that are "inactive" get a warning (normal between runs) rather than a failure (like service units).

## Check Categories (10)

1. `disk_space` — disk usage percentage
2. `cpu_temp` — thermal zone temperature
3. `svc_*` — 8 systemd units (setup, kiosk, heartbeat, command-executor, updater, cache, watchdog, night-mode)
4. `network` — nmcli or curl-based connectivity check
5. `dns` — autopoiesis.art resolution (skipped with --quick)
6. `local_ui` — health endpoint probe
7. `device_id`, `pairing`, `last_heartbeat` — device.json state
8. `cache` — cache-index.json count and disk size
9. `offline_mode` — state.json offline.active
10. `logs` — error/fail/crash pattern scan (skipped with --quick)
11. `kiosk_process` — pgrep for Chromium --kiosk with --disable-gpu

## Usage on Pi

```bash
# Quick health check
sudo /opt/autopoiesis-os/app/scripts/diagnostics.sh

# JSON for scripting/remote collection
sudo /opt/autopoiesis-os/app/scripts/diagnostics.sh --json

# Skip slow checks
sudo /opt/autopoiesis-os/app/scripts/diagnostics.sh --quick

# Full details
sudo /opt/autopoiesis-os/app/scripts/diagnostics.sh --verbose
```

## Integration Points

- Wire into heartbeat support bundle for remote health reporting
- Add to `scripts/verify-all.sh` as a gate
- Can be called by the watchdog script for enhanced failure reporting
