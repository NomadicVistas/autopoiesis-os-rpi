# Diagnostics Enhancement — Feed Sync, Heartbeat, Release State, Offline Readiness

Date: 2026-06-09

## What Changed

Enhanced `scripts/diagnostics.sh` with 4 new diagnostic sections:

1. **Feed Sync** — reads `feed-sync.log` for last sync time, items received, source; checks `feed-cache.json` item count
2. **Heartbeat Delivery** — reads `heartbeat.log` for last heartbeat, success/failure counts; checks `delivery-log.json` for pending broadcast deliveries
3. **Updates** — reads `release-state.json` for update lifecycle status (completed/in_progress/failed/skipped/idle)
4. **Offline Readiness** — composite score from cache count + fallback media files, with pass/warn/fail thresholds

JSON output extended with `feedSync`, `heartbeat`, `release`, and `offlineReadiness` objects.

## Why

The diagnostics script is the primary troubleshooting tool for Pi appliances. Without feed-sync and heartbeat visibility, a device with an empty feed cache and failed heartbeats would report "all checks passed" (cache count was just a warning). The offline readiness composite gives operators a single actionable number instead of requiring mental combination of multiple check results.

## Testing

- `diagnostics-check.sh`: 39/39 checks pass, no regression
- Human-readable and JSON output verified for all new sections

## Next

- Test with populated logs on physical Pi
- Add display/touchscreen hardware health section
- Wire diagnostics JSON into heartbeat payload for remote visibility
