# Database Performance and Bugfix Note

## Summary
- Fixed bug in `storedSettingsUpdatedAt` function in `hosted-api/db.js` where `isValidUpdatedAt(undefined)` was returning `true`. Changed to explicitly check for `undefined`/`null` before calling `isValidUpdatedAt`.
- Fixed syntax error in migration `20260609000004_add_performance_indexes.sql` that was causing "near 'add': syntax error" due to incorrect SQL formatting.
- Added covering indexes migration `20260609000006_add_covering_indexes.sql` to improve sync performance by enabling index-only scans for `aos_frame_device_settings` and `aos_frame_user_preferences` tables.

## Impact
- Resolves test failures in hosted-api-db-check.sh related to settings updatedAt handling.
- Enables performance improvements for feed generation, device listing, pairing, commands, admin audits, broadcasts, artwork likes, and user tokens via proper indexing.
- Covering indexes reduce I/O for settings and preferences queries during device synchronization.

## Verification
- `node --check local-ui/server.js` passed
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed
- `hosted-api-db-check.sh` passes all 45 checks

## Files Changed
- `hosted-api/db.js` (bug fix)
- `migrations/sqlite/20260609000004_add_performance_indexes.sql` (syntax fix)
- `migrations/sqlite/20260609000006_add_covering_indexes.sql` (new migration)

## Related Work
This work unblocks multiple workstreams in the priority chain: profile → database → API → pairing → sync → kiosk → feed → cache → broadcast → updates → admin → rollout.