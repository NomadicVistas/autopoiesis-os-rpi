# Release Safe Updater Note

Date: 2026-06-08

## What Changed

`scripts/update-from-release.sh` was rewritten with a production-safe update lifecycle.

## Key Additions

1. **Service lifecycle**: Services (kiosk, setup, heartbeat, display, feed-sync, poll-release timer) are stopped before app tree replacement and restarted after. Only services that were active before the update are restarted. Restart order is reversed from stop order.

2. **Pre-flight checks**:
   - Same-version skip — avoids unnecessary restarts
   - Disk space check — ≥200MB (configurable), gracefully skipped if `df` unavailable
   - Downgrade guard — blocks older versions unless `AUTOPOIESIS_ALLOW_DOWNGRADE=1`

3. **State tracking**:
   - `release-state.json` — current state (in_progress/completed/failed/skipped)
   - `release-log.json` — structured event history (last 200 entries)

4. **Bootstrap failure recovery**: If bootstrap fails after app tree replacement, attempts rollback from backup before failing.

## Files Created

- `$DATA_DIR/release-state.json` — update state
- `$DATA_DIR/release-log.json` — event log

## Backward Compatibility

The script's CLI interface is unchanged: `scripts/update-from-release.sh <release.json>`. All existing environment variables are respected. New environment variables:

- `AUTOPOIESIS_UPDATE_MIN_DISK_MB` — minimum disk space in MB (default: 200)
- `AUTOPOIESIS_ALLOW_DOWNGRADE` — set to `1` to allow downgrading

## Integration Points

- The hosted API can read `release-state.json` and `release-log.json` via heartbeat for admin dashboard visibility
- The local UI diagnostics can surface `release-state.json` status
- The admin device snapshot can include update state from heartbeat events

## Physical Pi Testing Needed

- Verify service stop/start works correctly with systemd
- Verify disk space check works on Pi storage
- Verify rollback after bootstrap failure works with real services
- Test full OTA update cycle: v0.1.1 → newer release
