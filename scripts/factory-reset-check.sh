#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

APP_DIR="$TMP_DIR/app"
INSTALL_DIR="$TMP_DIR/install"
DATA_DIR="$TMP_DIR/data"
CACHE_DIR="$DATA_DIR/cache"
LOG_DIR="$TMP_DIR/log"
SYSTEMCTL="$TMP_DIR/systemctl"
SYSTEMCTL_LOG="$TMP_DIR/systemctl.log"
USER_NAME="$(id -un)"

fail() {
  echo "factory reset check failed: $*" >&2
  exit 1
}

require_file() {
  local file="$1"
  [[ -f "$file" ]] || fail "missing file $file"
}

require_absent() {
  local path="$1"
  [[ ! -e "$path" ]] || fail "expected $path to be removed"
}

require_empty_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || fail "missing directory $dir"
  if find "$dir" -mindepth 1 -print -quit | grep -q .; then
    fail "expected $dir to be empty"
  fi
}

require_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq "$expected" "$file" || fail "$file does not contain: $expected"
}

read_json_value() {
  local file="$1"
  local expr="$2"
  node -e "const fs=require('fs');const data=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));const value=($expr);process.stdout.write(value === undefined || value === null ? '' : String(value));" "$file"
}

seed_app() {
  mkdir -p "$APP_DIR/scripts"
  cp -a "$ROOT_DIR/config" "$APP_DIR/config"
  cp "$ROOT_DIR/VERSION" "$APP_DIR/VERSION"
  cp "$ROOT_DIR/scripts/bootstrap.sh" "$APP_DIR/scripts/bootstrap.sh"
  cp "$ROOT_DIR/scripts/generate-device-id.sh" "$APP_DIR/scripts/generate-device-id.sh"
  cp "$ROOT_DIR/scripts/ensure-appliance-user.sh" "$APP_DIR/scripts/ensure-appliance-user.sh"
  chmod +x "$APP_DIR/scripts/"*.sh
}

seed_state() {
  rm -rf "$DATA_DIR" "$CACHE_DIR" "$INSTALL_DIR/cache" "$LOG_DIR" "$SYSTEMCTL_LOG"
  mkdir -p "$DATA_DIR" "$CACHE_DIR/media" "$INSTALL_DIR/cache/artworks" "$LOG_DIR"
  cat >"$DATA_DIR/device.json" <<'JSON'
{
  "deviceId": "old-device-id",
  "deviceName": "Seeded Paired Frame",
  "paired": true,
  "pairingCode": "123456",
  "deviceApiKey": "secret-key-that-must-not-survive",
  "ownerUserId": "owner-before-reset",
  "softwareVersion": "0.0.0"
}
JSON
  printf 'old-device-id\n' >"$DATA_DIR/device-id"
  cat >"$DATA_DIR/preferences.json" <<'JSON'
{"displayMode":"local-feed","brightness":10}
JSON
  cat >"$DATA_DIR/state.json" <<'JSON'
{"currentMode":"frame","remoteDisabled":true}
JSON
  for file in \
    pairing.json \
    network.json \
    commands.json \
    current-broadcast.json \
    feed.json \
    feed-cache.json \
    cache-index.json \
    event-cursor.json \
    release.json \
    release-state.json \
    release-rollback.json \
    diagnostics.json \
    command-audit.json \
    delivery-log.json \
    release-log.json; do
    printf '{"seeded":true,"file":"%s"}\n' "$file" >"$DATA_DIR/$file"
  done
  printf 'cached media\n' >"$CACHE_DIR/media/artwork.bin"
  printf 'install cache\n' >"$INSTALL_DIR/cache/artworks/artwork.bin"
}

run_reset() {
  AUTOPOIESIS_ALLOW_NON_ROOT_FACTORY_RESET=1 \
    AUTOPOIESIS_APP_DIR="$APP_DIR" \
    AUTOPOIESIS_INSTALL_DIR="$INSTALL_DIR" \
    AUTOPOIESIS_DATA_DIR="$DATA_DIR" \
    AUTOPOIESIS_CACHE_DIR="$CACHE_DIR" \
    AUTOPOIESIS_LOG_DIR="$LOG_DIR" \
    AUTOPOIESIS_USER="$USER_NAME" \
    AUTOPOIESIS_SYSTEMCTL_BIN="$SYSTEMCTL" \
    "$ROOT_DIR/factory-reset.sh" "$@"
}

validate_default_reset() {
  require_file "$DATA_DIR/device.json"
  require_file "$DATA_DIR/device-id"
  require_file "$DATA_DIR/preferences.json"
  require_file "$DATA_DIR/state.json"
  require_file "$DATA_DIR/cache-index.json"
  require_file "$LOG_DIR/factory-reset.log"

  local device_id paired api_key software_version mode
  device_id="$(read_json_value "$DATA_DIR/device.json" "data.deviceId")"
  paired="$(read_json_value "$DATA_DIR/device.json" "data.paired")"
  api_key="$(read_json_value "$DATA_DIR/device.json" "data.deviceApiKey")"
  software_version="$(read_json_value "$DATA_DIR/device.json" "data.softwareVersion")"
  mode="$(read_json_value "$DATA_DIR/state.json" "data.currentMode")"

  [[ -n "$device_id" ]] || fail "device id was not regenerated"
  [[ "$device_id" != "old-device-id" ]] || fail "old device id survived reset"
  [[ "$(tr -d '\n' < "$DATA_DIR/device-id")" == "$device_id" ]] || fail "device-id file does not match device.json"
  [[ "$paired" == "false" ]] || fail "device remained paired after reset"
  [[ -z "$api_key" ]] || fail "device API key survived reset"
  [[ "$software_version" == "$(tr -d '\n' < "$APP_DIR/VERSION")" ]] || fail "software version was not bootstrapped"
  [[ "$mode" == "setup" ]] || fail "state did not return to setup mode"

  for file in \
    pairing.json \
    network.json \
    commands.json \
    current-broadcast.json \
    feed.json \
    feed-cache.json \
    event-cursor.json \
    release.json \
    release-state.json \
    release-rollback.json \
    diagnostics.json \
    command-audit.json \
    delivery-log.json \
    release-log.json; do
    require_absent "$DATA_DIR/$file"
  done

  require_empty_dir "$CACHE_DIR"
  [[ -d "$INSTALL_DIR/cache/artworks" ]] || fail "install cache artwork directory was not restored"
  [[ -d "$INSTALL_DIR/cache/metadata" ]] || fail "install cache metadata directory was not restored"
  [[ -d "$INSTALL_DIR/cache/fallback" ]] || fail "install cache fallback directory was not restored"
  require_contains "$SYSTEMCTL_LOG" "stop autopoiesis.target"
  require_contains "$SYSTEMCTL_LOG" "start autopoiesis.target"
}

validate_keep_support_history() {
  for file in diagnostics.json command-audit.json delivery-log.json release-log.json; do
    require_file "$DATA_DIR/$file"
    require_contains "$DATA_DIR/$file" '"seeded":true'
  done
  require_absent "$DATA_DIR/pairing.json"
  require_absent "$DATA_DIR/commands.json"
  require_empty_dir "$CACHE_DIR"
}

validate_dry_run() {
  require_file "$DATA_DIR/device.json"
  require_file "$DATA_DIR/pairing.json"
  require_file "$DATA_DIR/commands.json"
  require_file "$DATA_DIR/diagnostics.json"
  require_file "$CACHE_DIR/media/artwork.bin"
  require_file "$INSTALL_DIR/cache/artworks/artwork.bin"
  local device_id
  device_id="$(read_json_value "$DATA_DIR/device.json" "data.deviceId")"
  [[ "$device_id" == "old-device-id" ]] || fail "dry-run mutated device identity"
}

printf '#!/usr/bin/env bash\nprintf '"'"'%%s\n'"'"' "$*" >> %q\n' "$SYSTEMCTL_LOG" >"$SYSTEMCTL"
chmod +x "$SYSTEMCTL"

seed_app

seed_state
run_reset
validate_default_reset

seed_state
run_reset --keep-support-history --no-restart
validate_keep_support_history

seed_state
DRY_RUN_OUTPUT="$TMP_DIR/dry-run.out"
run_reset --dry-run --no-restart >"$DRY_RUN_OUTPUT"
validate_dry_run
require_contains "$DRY_RUN_OUTPUT" "would remove file $DATA_DIR/device.json"
require_contains "$DRY_RUN_OUTPUT" "Factory reset dry run complete."

echo "Factory reset check passed."
