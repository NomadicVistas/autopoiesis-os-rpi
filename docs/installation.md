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
