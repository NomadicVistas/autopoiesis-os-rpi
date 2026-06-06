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

## Security Smoke

```bash
/opt/autopoiesis-os/app/scripts/security-smoke.sh
```

Run this before production imaging and after changing local JSON endpoints. It verifies that local status, pairing status, diagnostics, health, readiness, and offline-cache responses redact the stored device API key while still reporting safe key-presence flags for support.
