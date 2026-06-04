#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${AUTOPOIESIS_DATA_DIR:-/var/lib/autopoiesis-os}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run with sudo: sudo ./factory-reset.sh" >&2
  exit 1
fi

install -d "$DATA_DIR"
rm -f "$DATA_DIR/device.json" "$DATA_DIR/preferences.json" "$DATA_DIR/pairing.json" "$DATA_DIR/state.json" "$DATA_DIR/cache-index.json"
/opt/autopoiesis-os/app/scripts/bootstrap.sh
systemctl restart autopoiesis-setup.service autopoiesis-kiosk.service
