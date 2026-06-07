# Feed Display Cursor

## Date: 2026-06-07

## What

Server-side persistent feed display cursor that tracks which feed items have been displayed since the last successful feed sync, so the frame does not replay the same items after page reloads from broadcasts, settings changes, or feed syncs.

## Implementation

- `feed-cursor.json` stores `{ syncedAt, shownItemIds[], updatedAt }`
- `feedCursorMarkShown(itemId)` — idempotent, appends to shownItemIds
- `feedCursorReset(syncedAt)` — clears shownItemIds on new feed sync
- `mixedFeedQueue` — within each priority band, unshown items round-robin first, then previously-shown items
- Cursor reset triggers when `writeFeedState` detects a new `syncedAt` timestamp

## Exposed Through

- `GET /local/feed` → `displayCursor` field
- `GET /local/frame-state` → `displayCursor` field
- Diagnostics → `diagnostics.feed.displayCursor`
- Support bundle → `summary.feedCursor`

## Verification

- `scripts/feed-cursor-check.sh` — 5-step gate: cursor creation, shown tracking with queue reordering, idempotent re-display, re-sync reset, support bundle propagation
- No regressions in feed-targeting-check, stream-playback-check, or broadcast-command-check

## Physical Pi Validation Needed

- Confirm frame resumes from cursor position after broadcast interrupt → page reload
- Confirm new sync items appear before replayed items in the actual Chromium kiosk
- Verify cursor file persists across device restarts under `/var/lib/autopoiesis-os`

## Bounds

- `FEED_CURSOR_MAX_SHOWN` defaults to 500 (env configurable)
- Oldest entries trimmed when limit exceeded
