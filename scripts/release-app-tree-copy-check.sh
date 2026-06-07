#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "release app-tree copy check failed: $*" >&2
  exit 1
}

require_file() {
  local file="$1"
  [[ -f "$file" ]] || fail "missing expected file: $file"
}

require_absent() {
  local path="$1"
  [[ ! -e "$path" && ! -L "$path" ]] || fail "unexpected path copied or retained: $path"
}

write_bootstrap_pair() {
  local dir="$1"
  mkdir -p "$dir/scripts"
  cat >"$dir/scripts/bootstrap.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'bootstrap %s\n' "$(tr -d '\n' < "$(dirname "$0")/../VERSION")" >> "${AUTOPOIESIS_LOG_DIR}/bootstrap.log"
SH
  cat >"$dir/scripts/install-systemd-units.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemd install %s\n' "$(tr -d '\n' < "$(dirname "$0")/../VERSION")" >> "${AUTOPOIESIS_LOG_DIR}/systemd.log"
SH
  chmod +x "$dir/scripts/bootstrap.sh" "$dir/scripts/install-systemd-units.sh"
}

APP_DIR="$TMP_DIR/install/app"
INSTALL_DIR="$TMP_DIR/install"
DATA_DIR="$TMP_DIR/data"
LOG_DIR="$TMP_DIR/logs"
PAYLOAD_DIR="$TMP_DIR/payload"
ARTIFACT="$TMP_DIR/release.tar.gz"
RELEASE_JSON="$TMP_DIR/release.json"
BIN_DIR="$TMP_DIR/bin"

mkdir -p "$BIN_DIR"
for command_name in awk bash cat chmod curl date dirname find grep gzip head id install mkdir mktemp mv node printf rm sha256sum stat tar tr wc; do
  command_path="$(command -v "$command_name")"
  ln -s "$command_path" "$BIN_DIR/$command_name"
done

mkdir -p "$APP_DIR/.git" "$APP_DIR/node_modules/pkg" "$APP_DIR/logs" "$DATA_DIR" "$LOG_DIR" "$PAYLOAD_DIR"
printf '1.0.0\n' >"$APP_DIR/VERSION"
printf 'old git metadata\n' >"$APP_DIR/.git/config"
printf 'old dependency\n' >"$APP_DIR/node_modules/pkg/index.js"
printf 'old local log\n' >"$APP_DIR/logs/old.log"
write_bootstrap_pair "$APP_DIR"

printf '{"updateChannel":"stable"}\n' >"$DATA_DIR/device.json"

mkdir -p "$PAYLOAD_DIR/.git" "$PAYLOAD_DIR/node_modules/pkg" "$PAYLOAD_DIR/logs"
printf '1.1.0\n' >"$PAYLOAD_DIR/VERSION"
printf 'new git metadata\n' >"$PAYLOAD_DIR/.git/config"
printf 'new dependency\n' >"$PAYLOAD_DIR/node_modules/pkg/index.js"
printf 'new local log\n' >"$PAYLOAD_DIR/logs/new.log"
write_bootstrap_pair "$PAYLOAD_DIR"

tar -C "$PAYLOAD_DIR" -czf "$ARTIFACT" .
CHECKSUM="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
cat >"$RELEASE_JSON" <<JSON
{
  "version": "1.1.0",
  "channel": "stable",
  "tag": "v1.1.0",
  "artifactUrl": "file://$ARTIFACT",
  "sha256": "$CHECKSUM",
  "rollbackNotes": "Restore the previous app snapshot if health checks fail."
}
JSON

AUTOPOIESIS_APP_DIR="$APP_DIR" \
  AUTOPOIESIS_INSTALL_DIR="$INSTALL_DIR" \
  AUTOPOIESIS_DATA_DIR="$DATA_DIR" \
  AUTOPOIESIS_LOG_DIR="$LOG_DIR" \
  AUTOPOIESIS_RELEASE_ALLOW_INSECURE_URLS=1 \
  AUTOPOIESIS_INSTALL_COPY_METHOD=tar \
  AUTOPOIESIS_INSTALL_COPY_SKIP_CHOWN=1 \
  PATH="$BIN_DIR" \
  "$ROOT_DIR/scripts/update-from-release.sh" "$RELEASE_JSON"

grep -qx '1.1.0' "$APP_DIR/VERSION" || fail "artifact update did not install target version"
require_file "$DATA_DIR/release-rollback.json"
require_absent "$APP_DIR/.git/config"
require_absent "$APP_DIR/node_modules/pkg/index.js"
require_absent "$APP_DIR/logs/new.log"

AUTOPOIESIS_APP_DIR="$APP_DIR" \
  AUTOPOIESIS_INSTALL_DIR="$INSTALL_DIR" \
  AUTOPOIESIS_DATA_DIR="$DATA_DIR" \
  AUTOPOIESIS_LOG_DIR="$LOG_DIR" \
  AUTOPOIESIS_INSTALL_COPY_METHOD=tar \
  AUTOPOIESIS_INSTALL_COPY_SKIP_CHOWN=1 \
  PATH="$BIN_DIR" \
  "$ROOT_DIR/scripts/rollback-release.sh"

grep -qx '1.0.0' "$APP_DIR/VERSION" || fail "rollback did not restore previous version"
require_file "$DATA_DIR/release-state.json"
require_file "$DATA_DIR/release-log.json"
require_absent "$APP_DIR/.git/config"
require_absent "$APP_DIR/node_modules/pkg/index.js"
require_absent "$APP_DIR/logs/old.log"

echo "Release app-tree copy check passed."
