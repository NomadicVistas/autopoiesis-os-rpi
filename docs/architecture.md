# Architecture

Autopoiesis OS is an appliance layer on Raspberry Pi OS.

## Runtime Paths

Application:

```txt
/opt/autopoiesis-os/app
```

Persistent data:

```txt
/var/lib/autopoiesis-os
```

Logs:

```txt
/var/log/autopoiesis-os
```

## Boot Flow

1. Raspberry Pi OS boots into the existing graphical target.
2. `autopoiesis-setup.service` starts the local Node launcher on port `3030`.
3. `autopoiesis-kiosk.service` waits briefly for the local launcher and starts Chromium in kiosk mode at `http://localhost:3030/launch`.
4. The launcher decides whether to show setup, disabled, offline, or the remote display URL.

## Network Flow

The local launcher treats Ethernet/LAN as the easiest path to internet access:

1. `GET /local/network/status` reads NetworkManager state through `nmcli`.
2. Connected Ethernet is recorded as `networkType: "lan"` and `lanConfigured: true`.
3. `POST /local/lan/connect` asks NetworkManager to activate the first Ethernet device with DHCP.
4. Wi-Fi remains available for installations without LAN via the local scan/connect screen.

## Design Constraint

The current development Pi keeps the desktop OS because the product needs a screen interface. Production can later move to Raspberry Pi OS Lite plus a minimal display stack.
