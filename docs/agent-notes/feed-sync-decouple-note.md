# Feed Sync Decouple Note

Date: 2026-06-08

## Problem

The feed content sync (`syncFeedFromRemote()`) only ran when the kiosk browser's JavaScript polling loop called `POST /local/feed/sync`. If the browser crashed, was in setup mode, or was between page loads, the feed never synced. This meant:

1. `feed-cache.json` never got populated
2. `cache-artworks.sh` had nothing to download
3. Offline fallback degraded over time (stale cache, no new content)
4. Fresh boots had empty cache until the browser loaded and polled

## Solution

Created `scripts/feed-sync.sh` — a standalone script that calls `POST /local/feed/sync` on the local UI server, independent of the browser.

Updated `services/autopoiesis-cache.service` to run feed-sync.sh as `ExecStartPre` before cache-artworks.sh.

## Pipeline

Before:
```
cache timer → cache-artworks.sh (reads stale feed-cache.json)
browser JS → /local/feed/sync (only when browser running)
```

After:
```
cache timer → feed-sync.sh (syncs feed, writes feed-cache.json)
            → cache-artworks.sh (downloads from fresh manifest)
```

## Error Handling

- curl unavailable: skip (exit 0)
- local UI unreachable: skip (exit 0)
- sync fails: exit 1 (systemd tracks failure)
- dry run: JSON output without calling endpoint

## Design Decisions

- Uses `ExecStartPre` in systemd (not a wrapper script) so the cache service tracks feed-sync failures independently
- Does not bypass the local UI server (calls `/local/feed/sync` endpoint) to reuse all existing sync logic, offline fallback, and state management
- Writes to `feed-sync.log` (separate from heartbeat.log) for diagnostics isolation
- JSON output mode for programmatic consumption by future admin dashboard polling
