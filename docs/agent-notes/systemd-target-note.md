# systemd Target Note

## 2026-06-09 — autopoiesis.target appliance lifecycle grouping

### What

Added `services/autopoiesis.target` — a systemd target that groups all 8 appliance services and 6 timers under a single lifecycle unit.

### Why

The Autopoiesis Frame appliance has 14 systemd units (8 services + 6 timers) that must be managed as a coherent group. Previously:

- Factory reset manually enumerated 9 units to stop and 2 to restart
- Install enabled each unit individually
- No way to `systemctl stop` the entire appliance at once
- No way to `systemctl status` the appliance as a whole

This is the standard systemd pattern for multi-service Linux appliances (nginx, PostgreSQL, Docker all use targets).

### Design

- `autopoiesis.target` declares `Wants=` for all long-running services (setup, kiosk) and all timers (heartbeat, cache, command-executor, updater, watchdog, night-mode)
- Every service and timer file declares `PartOf=autopoiesis.target`
- `Wants=` provides forward dependency: starting the target starts all units
- `PartOf=` provides reverse dependency: stopping/restarting the target stops/restarts all units

### Lifecycle

| Operation | Before | After |
|-----------|--------|-------|
| Stop all  | 9 individual systemctl stop commands | `systemctl stop autopoiesis.target` |
| Start all | enable 8 units + start 6 timers | `systemctl start autopoiesis.target` |
| Restart all | Manual enumeration | `systemctl restart autopoiesis.target` |
| Status | `systemctl status autopoiesis-*` (shell glob) | `systemctl status autopoiesis.target` |

### Factory reset

`factory-reset.sh` now uses `systemctl stop autopoiesis.target` for the stop phase and `systemctl start autopoiesis.target` for the restart phase after re-installation. The target's `PartOf=` propagation ensures all services and timers are stopped, including ones that might be added in the future.

### Files changed

- `services/autopoiesis.target` (new)
- `services/autopoiesis-*.service` (8 files: added `PartOf=autopoiesis.target`)
- `timers/autopoiesis-*.timer` (6 files: added `PartOf=autopoiesis.target`)
- `scripts/install-systemd-units.sh` (install and enable target)
- `factory-reset.sh` (target-based stop/start)
- `scripts/preflight.sh` (target in required files)
- `scripts/systemd-units-install-check.sh` (target + PartOf verification)
- `scripts/factory-reset-check.sh` (target-based stop/start assertions)
- `scripts/systemd-timers-check.sh` (added missing night-mode timer)

### Future

- The target enables future admin tooling: `systemctl is-active autopoiesis.target` for health checks
- Remote admin commands can target the whole appliance via the target
- Update rollback can `systemctl restart autopoiesis.target` after reverting
