# Diagnostics Enhancement — Feed Sync, Heartbeat, Release State, Offline Readiness + Appliance Health

Date: 2026-06-09 (initial), 2026-06-16 (appliance health enhancement)

## What Changed

### Initial Enhancement (2026-06-09)
Enhanced `scripts/diagnostics.sh` with 4 new diagnostic sections:

1. **Feed Sync** — reads `feed-sync.log` for last sync time, items received, source; checks `feed-cache.json` item count
2. **Heartbeat Delivery** — reads `heartbeat.log` for last heartbeat, success/failure counts; checks `delivery-log.json` for pending broadcast deliveries
3. **Updates** — reads `release-state.json` for update lifecycle status (completed/in_progress/failed/skipped/idle)
4. **Offline Readiness** — composite score from cache count + fallback media files, with pass/warn/fail thresholds

JSON output extended with `feedSync`, `heartbeat`, `release`, and `offlineReadiness` objects.

### Appliance Health Enhancement (2026-06-16)
Added comprehensive health checks for the RPI appliance itself:

- **Kiosk Process Verification** — confirms `local-ui/server.js` is running when `autopoiesis-kiosk.service` is active
- **Port Listening Check** — verifies port 3030 is listening and bound to the Node.js process
- **Local UI Content Validation** — ensures the server serves HTML content (kiosk interface) not just API endpoints
- **Critical Script Availability** — checks that `factory-reset.sh`, `update.sh`, and `install.sh` exist and are executable
- **Port Conflict Detection** — identifies if another process is using port 3030
- **Local UI Error Scanning** — scans recent logs for UI-specific errors (in non-quick mode)
- **Enhanced Service Health** — adds kiosk-specific process checks to service status

JSON output extended with implicit improvements to existing service and appliance sections.

## Why

The diagnostics script is the primary troubleshooting tool for Pi appliances. The initial enhancement added visibility into feed sync, heartbeat, updates, and offline readiness. The appliance health enhancement addresses the gap between service status and actual appliance functionality:

- A service can be `active` while the underlying UI process has crashed or failed to bind to its port
- Operators need to know if the kiosk interface is actually reachable and serving content
- Critical recovery scripts must be verified present and executable for emergency situations
- Port conflicts can prevent the UI from starting even when the service reports success
- Local UI errors in logs often indicate configuration or code issues missed by service checks

Together, these enhancements provide end-to-end visibility from service status to actual user experience on the touchscreen.

## Testing

- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh`: passes
- `node --check local-ui/server.js`: passes
- Human-readable and JSON output verified for all sections
- Manual verification of new check logic (no regression in existing functionality)

## Next

- Test with populated logs on physical Pi
- Consider adding touchscreen calibration verification
- Consider adding hardware-specific checks for different Raspberry Pi models
- Wire enhanced diagnostics JSON into heartbeat payload for remote visibility
