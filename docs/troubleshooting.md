# Troubleshooting

## Local UI

```bash
systemctl status autopoiesis-setup.service
journalctl -u autopoiesis-setup.service -n 100 --no-pager
```

## Kiosk

```bash
systemctl status autopoiesis-kiosk.service
journalctl -u autopoiesis-kiosk.service -n 100 --no-pager
```

The appliance watchdog runs every two minutes after boot. It checks the local
health route, the local launch route, and the running Chromium kiosk command. It
restarts `autopoiesis-setup.service` only when local HTTP routes stop responding,
and restarts `autopoiesis-kiosk.service` only when the kiosk process or launch
flags fail validation.

```bash
systemctl status autopoiesis-watchdog.timer
journalctl -u autopoiesis-watchdog.service -n 120 --no-pager
sudo /opt/autopoiesis-os/app/scripts/watchdog.sh
```

If the screen is blank and the journal shows `GLES3 is unsupported`,
`CreateGLContext failed`, or `CollectGraphicsInfo failed`, update to the latest
kiosk launcher and restart the service. Pi 3 class devices default to Chromium
software rendering flags because hardware GL can fail before the UI paints.

```bash
sudo systemctl restart autopoiesis-kiosk.service
sudo journalctl -u autopoiesis-kiosk.service -n 120 --no-pager
/opt/autopoiesis-os/app/scripts/kiosk-check.sh
```

For hardware-specific testing, add extra flags through
`AUTOPOIESIS_CHROMIUM_FLAGS` in a systemd override.

## Network

```bash
/opt/autopoiesis-os/app/scripts/network-status.sh
nmcli device status
nmcli networking connectivity
```

## LAN

```bash
sudo /opt/autopoiesis-os/app/scripts/connect-lan.sh
nmcli device show eth0
```

If the Ethernet device is not `eth0`, read the device name from `network-status.sh` and pass it explicitly:

```bash
sudo /opt/autopoiesis-os/app/scripts/connect-lan.sh enp1s0
```

## Wi-Fi

```bash
nmcli device wifi list
nmcli connection show
```

## Logs

```bash
ls -lah /var/log/autopoiesis-os
```

## Cache

```bash
/opt/autopoiesis-os/app/scripts/cache-artworks.sh
cat /var/lib/autopoiesis-os/cache-index.json
```

The cache worker reads `/var/lib/autopoiesis-os/feed-cache.json`, downloads eligible media and thumbnails into the runtime cache, and writes `/var/lib/autopoiesis-os/cache-index.json`. Failed downloads are recorded in the index and log instead of aborting the whole timer pass.

Inspect the playable offline inventory and a cached asset through the local UI rather than reading absolute paths from a browser:

```bash
curl -fsS http://127.0.0.1:3030/local/offline-cache
curl -fsSI http://127.0.0.1:3030/local/cache/assets/<item-id>/media
```

When `/launch` cannot reach the remote Frames display, `/offline` uses this cache inventory to rotate local media. If the inventory is empty, it falls back to the static offline status screen and keeps retrying `/launch`.

For local-first playback testing, inspect the browser-safe queue and open the local frame route:

```bash
curl -fsS http://127.0.0.1:3030/local/frame-state
./scripts/frame-state-check.sh
curl -fsS http://127.0.0.1:3030/frame >/dev/null
curl -fsSI 'http://127.0.0.1:3030/launch?local=1'
```

`/local/frame-state` is derived from `/local/feed` and `cache-index.json`. Cached assets are preferred, but remote media URLs remain available for online local playback. The response includes a compact `playback` summary, and diagnostics/readiness/support bundles mirror it as `framePlayback`. Use `AUTOPOIESIS_REQUIRE_FRAME_ITEMS=1 ./scripts/frame-state-check.sh` after a real feed sync when physical validation should fail on an empty playable queue.

Use `preferences.displayMode=local-feed` or `/launch?local=1` when the kiosk should use the device-local frame surface instead of the hosted display first.

## Diagnostics

```bash
curl -fsS http://127.0.0.1:3030/local/diagnostics
```

The diagnostics endpoint is the quickest support snapshot for hardware testing. It reports software version, uptime, memory, temperature, touchscreen/input visibility, network and pairing state, cache footprint, release state, pending command count, current broadcast, and local Autopoiesis service states when systemd is available.

Read `.diagnostics.health.status` first. It is `ok`, `warning`, or `error`, with `.diagnostics.health.issues[]` carrying stable issue codes such as `network_offline`, `offline_fallback`, `device_key_missing`, `storage_low`, `temperature_high`, `touchscreen_missing`, `release_error`, `commands_pending`, and `service_failed`.

For quick acceptance checks, use the compact health probe:

```bash
/opt/autopoiesis-os/app/scripts/health-check.sh
curl -fsS http://127.0.0.1:3030/local/health
curl -fsS 'http://127.0.0.1:3030/local/health?services=1'
```

`/local/health` returns the derived status, issue codes, device identity, mode, network/pairing state, release summary, pending command count, current broadcast, and timestamp without exposing stored API keys.

For touchscreen hardware checks:

```bash
/opt/autopoiesis-os/app/scripts/touchscreen-check.sh
AUTOPOIESIS_REQUIRE_TOUCHSCREEN=1 /opt/autopoiesis-os/app/scripts/touchscreen-check.sh
```

The first form reports Linux input metadata without failing pointer-only development hosts. The required form is used by Milestone 2 physical Pi verification and fails when no touchscreen-class device is visible in `/proc/bus/input/devices`.

For one-step support handoff, collect the redacted support bundle:

```bash
/opt/autopoiesis-os/app/scripts/support-bundle.sh ./support-bundle.json
curl -fsS http://127.0.0.1:3030/local/support-bundle
```

The bundle combines diagnostics, compact health, rollout readiness, touchscreen/input summary, active feed state, local frame playback state, offline-cache inventory, recent command audit entries, recent delivery events, recent release history, and the unified device event export. It is intended for hardware validation notes and admin support adapters, and it should stay free of stored device API keys, raw command payloads, release artifact URLs, checksums, and absolute cache asset paths.

For backend/admin ingestion checks, fetch the same redacted event stream directly:

```bash
curl -fsS 'http://127.0.0.1:3030/local/events/export?limit=25'
```

## Release Rollout

```bash
curl -fsS http://127.0.0.1:3030/local/release/history
curl -fsS http://127.0.0.1:3030/local/support-bundle
```

The release history endpoint shows recent check/apply lifecycle events without artifact URLs, checksums, stdout/stderr, local paths, or stored device API keys. Use it with `release-state.json` and `/var/log/autopoiesis-os/update.log` when an update command fails.

If a release leaves the frame unhealthy, run the local rollback script from the Pi:

    sudo /opt/autopoiesis-os/app/scripts/rollback-release.sh
    curl -fsS http://127.0.0.1:3030/local/release/history

Rollback restores only app code from the previous git revision or the pre-update app snapshot. It intentionally preserves `/var/lib/autopoiesis-os`, including pairing, device API keys, preferences, cache metadata, and support logs.

## Factory Reset

Use factory reset when a frame should become a fresh, unpaired device without
reinstalling the appliance layer:

```bash
sudo /opt/autopoiesis-os/app/factory-reset.sh --dry-run
sudo /opt/autopoiesis-os/app/factory-reset.sh
```

The script stops the local timers while it clears state, removes local identity,
pairing, preferences, pending commands, broadcasts, feed/cache manifests,
release state, and runtime cache directories, then bootstraps a fresh device and
restarts setup/kiosk services. App code and `/var/log/autopoiesis-os` are
preserved. Add `--keep-support-history` if `diagnostics.json`,
`command-audit.json`, `delivery-log.json`, and `release-log.json` should survive
for a support handoff.

## Security Smoke

```bash
/opt/autopoiesis-os/app/scripts/security-smoke.sh
```

Run this before production imaging and after changing local JSON endpoints. It verifies that local status, pairing status, diagnostics, health, readiness, support-bundle, frame-state, offline-cache, command audit, delivery log, release history, and event export responses redact the stored device API key while still reporting safe key-presence, input-diagnostics, and playback-readiness flags for support.
