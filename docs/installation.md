# Installation

Run from a checkout:

```bash
sudo ./scripts/preflight.sh --install
sudo ./install.sh
```

The installer:

- creates `/opt/autopoiesis-os`
- creates the appliance user if it does not already exist
- creates `/var/lib/autopoiesis-os`
- creates `/var/log/autopoiesis-os`
- copies this repo into `/opt/autopoiesis-os/current`
- links `/opt/autopoiesis-os/app`
- bootstraps initial JSON config
- installs systemd services and timers

The preflight reports hard blockers such as missing root privileges for install
mode, `rsync`, `curl`, `systemctl`, or Node.js older than 20. It warns, but
does not stop, when Chromium or NetworkManager are missing so support can still
prepare an image and see exactly why kiosk or Wi-Fi setup will be limited.

Start services:

```bash
sudo systemctl start autopoiesis-setup.service autopoiesis-kiosk.service
```

Check status:

```bash
systemctl status autopoiesis-setup.service autopoiesis-kiosk.service
```

Milestone 2 physical Pi verification:

```bash
sudo /opt/autopoiesis-os/app/scripts/milestone2-verify.sh
```

This checks that the setup service is active, the kiosk service is active, the local launcher responds, Chromium is running with the expected kiosk flags, Linux sees a touchscreen-class input device, NetworkManager reports device state, and both services restart cleanly.

LAN setup:

```bash
sudo /opt/autopoiesis-os/app/scripts/connect-lan.sh
/opt/autopoiesis-os/app/scripts/network-status.sh
```

The local UI also exposes LAN and Wi-Fi setup at:

```txt
http://localhost:3030/network
```

## Factory Reset

Use the installed script when a device needs to return to a fresh, unpaired
state without reinstalling app code:

```bash
sudo /opt/autopoiesis-os/app/factory-reset.sh --dry-run
sudo /opt/autopoiesis-os/app/factory-reset.sh
```

The reset clears local identity, pairing, preferences, network state, pending
commands, active broadcasts, feed/cache manifests, release state, and local
support-history JSON. It preserves the installed app code and
`/var/log/autopoiesis-os`. Use `--keep-support-history` when support needs the
recent diagnostics/audit/delivery/release JSON files for a handoff before
re-pairing.
