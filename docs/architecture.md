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
3. `autopoiesis-kiosk.service` starts Chromium in kiosk mode at `http://localhost:3030/launch`.
4. The launcher decides whether to show setup, disabled, offline, or the remote frames URL.

## Design Constraint

The current development Pi keeps the desktop OS because the product needs a screen interface. Production can later move to Raspberry Pi OS Lite plus a minimal display stack.
