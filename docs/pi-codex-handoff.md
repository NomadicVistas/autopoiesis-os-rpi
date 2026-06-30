# Pi Codex Handoff

This note is for future Codex passes on the Raspberry Pi appliance.

## What Changed

- The touchscreen local UI in `local-ui/server.js` was tuned for low-height LCDs, especially `800x480`.
- The main change is stronger compact styling for:
  - `/welcome`
  - `/dashboard`
  - `/frame`
  - `/offline`
- The goal was to keep pairing/login and first-action controls visible without awkward scrolling on the Pi screen.

## What To Check On Real Hardware

After updating the Pi, validate these on the actual LCD:

1. Welcome flow
   - Pairing code is fully visible
   - Main action buttons are reachable
   - No important content is cut off at `800x480`

2. Dashboard
   - "Next step" card fits cleanly
   - Action buttons remain on-screen
   - Tiles do not push the page below the fold unnecessarily

3. Frame
   - Empty-state copy fits
   - Artwork overlay is readable and closable
   - Tap targets feel comfortable on the touchscreen

4. Offline
   - Fallback media and metadata fit together
   - Retry/status information remains visible

## Useful Local Commands

Run the local UI directly without install:

```bash
cd /data/.openclaw/workspace/autopoiesis-os-rpi/local-ui
AUTOPOIESIS_DATA_DIR=/tmp/autopoiesis-os \
AUTOPOIESIS_CACHE_DIR=/tmp/autopoiesis-os/cache \
AUTOPOIESIS_LOG_DIR=/tmp/autopoiesis-os/logs \
node server.js
```

Syntax check:

```bash
node --check /data/.openclaw/workspace/autopoiesis-os-rpi/local-ui/server.js
```

## If The Pi Still Feels Too Tight

Prioritize these next:

1. Reduce header/hero height further on `max-height` breakpoints.
2. Collapse button rows to a single primary action plus a smaller secondary row.
3. Shrink dashboard tiles or convert them into a horizontal status strip.
4. Make overlay cards shorter with scrollable detail instead of full-height growth.

## Scope Boundary

- This pass changed only the local UI rendering/styling in `local-ui/server.js`.
- No hosted API behavior was changed for the LCD-fit work.
