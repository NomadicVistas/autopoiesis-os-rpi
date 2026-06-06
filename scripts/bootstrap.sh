#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${AUTOPOIESIS_APP_DIR:-/opt/autopoiesis-os/app}"
DATA_DIR="${AUTOPOIESIS_DATA_DIR:-/var/lib/autopoiesis-os}"
LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"
INSTALL_DIR="${AUTOPOIESIS_INSTALL_DIR:-/opt/autopoiesis-os}"
USER_NAME="${AUTOPOIESIS_USER:-frame}"
VERSION="$(tr -d '\n' < "$APP_DIR/VERSION")"

"$APP_DIR/scripts/ensure-appliance-user.sh"

install -d -o "$USER_NAME" -g "$USER_NAME" "$DATA_DIR" "$LOG_DIR"
install -d -o "$USER_NAME" -g "$USER_NAME" "$INSTALL_DIR/cache/artworks" "$INSTALL_DIR/cache/metadata" "$INSTALL_DIR/cache/fallback"

if [[ ! -f "$DATA_DIR/device.json" ]]; then
  "$APP_DIR/scripts/generate-device-id.sh" > "$DATA_DIR/device-id"
  DEVICE_ID="$(cat "$DATA_DIR/device-id")"
  sed \
    -e "s/\"rpi-generated-uuid\"/\"$DEVICE_ID\"/" \
    -e "s/\"softwareVersion\": \"0.1.0\"/\"softwareVersion\": \"$VERSION\"/" \
    "$APP_DIR/config/device.example.json" > "$DATA_DIR/device.json"
  chmod 600 "$DATA_DIR/device.json"
  chown "$USER_NAME:$USER_NAME" "$DATA_DIR/device.json" "$DATA_DIR/device-id"
fi

if [[ ! -f "$DATA_DIR/preferences.json" ]]; then
  node -e "const fs=require('fs');const d=require('$APP_DIR/config/defaults.json');fs.writeFileSync('$DATA_DIR/preferences.json', JSON.stringify(d.preferences,null,2)+'\n')"
  chmod 600 "$DATA_DIR/preferences.json"
  chown "$USER_NAME:$USER_NAME" "$DATA_DIR/preferences.json"
fi

if [[ ! -f "$DATA_DIR/state.json" ]]; then
  node -e "const fs=require('fs');const d=require('$APP_DIR/config/defaults.json');d.state.lastBootAt=new Date().toISOString();fs.writeFileSync('$DATA_DIR/state.json', JSON.stringify(d.state,null,2)+'\n')"
  chmod 600 "$DATA_DIR/state.json"
  chown "$USER_NAME:$USER_NAME" "$DATA_DIR/state.json"
fi

touch "$DATA_DIR/cache-index.json"
chown "$USER_NAME:$USER_NAME" "$DATA_DIR/cache-index.json"
