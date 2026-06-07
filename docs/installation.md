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
- copies this repo into `/opt/autopoiesis-os/current`, excluding Git metadata,
  logs, and `node_modules`
- links `/opt/autopoiesis-os/app`
- bootstraps initial JSON config
- installs systemd services and timers

The systemd installer renders service units from the active install
configuration. If `AUTOPOIESIS_INSTALL_DIR`, `AUTOPOIESIS_DATA_DIR`,
`AUTOPOIESIS_LOG_DIR`, `AUTOPOIESIS_USER`, or `AUTOPOIESIS_USER_HOME` are
overridden, the installed units inherit those values instead of silently
falling back to `/opt/autopoiesis-os`, `/var/lib/autopoiesis-os`, or `frame`.
The setup launcher also uses `AUTOPOIESIS_APP_DIR` or its own installed
location to find `local-ui/server.js`, so customized install roots do not
start a rendered service that immediately jumps back to the default path.

The preflight reports hard blockers such as an incomplete appliance app tree,
a `local-ui/server.js` syntax failure, missing root privileges for install
mode, no app-tree copy tool (`rsync` or `tar`), `curl`, `systemctl`,
Node.js older than 20, or less than
1024 MB free on the selected install, data, or log volumes. It warns, but does
not stop, when Chromium or NetworkManager are missing so support can still
prepare an image and see exactly why kiosk or Wi-Fi setup will be limited.
It also reports hardware suitability: Raspberry Pi 5 is the recommended target,
Raspberry Pi 4 4GB is the supported baseline, and Raspberry Pi 3 or older boards
are flagged as underpowered for Chromium kiosk rollout.

Use `AUTOPOIESIS_PREFLIGHT_APP_ROOT` to point the app-tree check at an
installed app or isolated fixture. The default is the repository root that
contains the running `scripts/preflight.sh`.

Use `AUTOPOIESIS_PREFLIGHT_MIN_FREE_MB` to raise or lower the disk-space
threshold for a build image. Set it to `0` only when intentionally bypassing
the check for a constrained test fixture.

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

This checks that the setup service is active, the kiosk service is active, the
installer app-tree copy helper excludes development-only paths and deletes stale
installed files, the systemd unit renderer preserves configured appliance paths/users, the local
setup launcher honors the configured app path, the local launcher responds,
runtime data/cache/log paths are writable, the heartbeat
timer wrapper tolerates missing pre-pairing state and records local UI failures,
Chromium is
running with the expected kiosk flags, the fixture-backed hardware profile
matrix passes, the live hardware profile is supported, Linux sees a touchscreen-class input
device, NetworkManager reports device state, the watchdog restart policy passes
its isolated acceptance gate, and both services restart cleanly.

Release updates use the local `device.json` `updateChannel` as the default
expected channel. A production or staged frame on `stable` will reject a `beta`,
`dev`, or channel-less manifest before it writes rollback metadata or mutates
app code. Override `AUTOPOIESIS_RELEASE_CHANNEL` only for an explicit test.

Isolated systemd render verification:

```bash
/opt/autopoiesis-os/app/scripts/systemd-units-install-check.sh
```

Isolated app-tree copy verification:

~~~bash
/opt/autopoiesis-os/app/scripts/install-app-tree-check.sh
~~~

Isolated setup launcher path verification:

~~~bash
/opt/autopoiesis-os/app/scripts/setup-launcher-check.sh
~~~

Isolated watchdog restart policy verification:

~~~bash
/opt/autopoiesis-os/app/scripts/watchdog-check.sh
~~~

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

Before exercising reset on real hardware state, run the isolated contract gate:

```bash
/opt/autopoiesis-os/app/scripts/factory-reset-check.sh
```

It uses temporary runtime directories and a stubbed `systemctl`, then proves the
default reset, `--keep-support-history`, and `--dry-run` behavior.
