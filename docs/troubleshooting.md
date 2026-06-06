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

## Diagnostics

```bash
curl -fsS http://127.0.0.1:3030/local/diagnostics
```

The diagnostics endpoint is the quickest support snapshot for hardware testing. It reports software version, uptime, memory, temperature, network and pairing state, cache footprint, release state, pending command count, current broadcast, and local Autopoiesis service states when systemd is available.

Read `.diagnostics.health.status` first. It is `ok`, `warning`, or `error`, with `.diagnostics.health.issues[]` carrying stable issue codes such as `network_offline`, `offline_fallback`, `device_key_missing`, `storage_low`, `temperature_high`, `release_error`, `commands_pending`, and `service_failed`.

For quick acceptance checks, use the compact health probe:

```bash
/opt/autopoiesis-os/app/scripts/health-check.sh
curl -fsS http://127.0.0.1:3030/local/health
curl -fsS 'http://127.0.0.1:3030/local/health?services=1'
```

`/local/health` returns the derived status, issue codes, device identity, mode, network/pairing state, release summary, pending command count, current broadcast, and timestamp without exposing stored API keys.

For one-step support handoff, collect the redacted support bundle:

```bash
/opt/autopoiesis-os/app/scripts/support-bundle.sh ./support-bundle.json
curl -fsS http://127.0.0.1:3030/local/support-bundle
```

The bundle combines diagnostics, compact health, rollout readiness, active feed state, offline-cache inventory, recent command audit entries, recent delivery events, recent release history, and the unified device event export. It is intended for hardware validation notes and admin support adapters, and it should stay free of stored device API keys, raw command payloads, release artifact URLs, checksums, and absolute cache asset paths.

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

## Security Smoke

```bash
/opt/autopoiesis-os/app/scripts/security-smoke.sh
```

Run this before production imaging and after changing local JSON endpoints. It verifies that local status, pairing status, diagnostics, health, readiness, support-bundle, offline-cache, command audit, delivery log, release history, and event export responses redact the stored device API key while still reporting safe key-presence flags for support.
