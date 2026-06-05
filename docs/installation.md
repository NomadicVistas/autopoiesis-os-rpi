# Installation

Run from a checkout:

```bash
sudo ./install.sh
```

The installer:

- creates `/opt/autopoiesis-os`
- creates `/var/lib/autopoiesis-os`
- creates `/var/log/autopoiesis-os`
- copies this repo into `/opt/autopoiesis-os/current`
- links `/opt/autopoiesis-os/app`
- bootstraps initial JSON config
- installs systemd services and timers

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

This checks that the setup service is active, the kiosk service is active, the local launcher responds, Chromium is running, NetworkManager reports device state, and both services restart cleanly.

LAN setup:

```bash
sudo /opt/autopoiesis-os/app/scripts/connect-lan.sh
/opt/autopoiesis-os/app/scripts/network-status.sh
```

The local UI also exposes LAN and Wi-Fi setup at:

```txt
http://localhost:3030/network
```
