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

Run this before production imaging and after changing local JSON endpoints. It verifies that local status, pairing status, and diagnostics responses redact the stored device API key while still reporting safe key-presence flags for support.
