#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "install app-tree check failed: $*" >&2
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

SOURCE_DIR="$TMP_DIR/source"
TARGET_DIR="$TMP_DIR/install/current"

mkdir -p "$SOURCE_DIR/.git" "$SOURCE_DIR/logs" "$SOURCE_DIR/node_modules/pkg" "$SOURCE_DIR/scripts"
printf 'version one\n' >"$SOURCE_DIR/VERSION"
printf 'runtime script\n' >"$SOURCE_DIR/scripts/start-setup.sh"
printf 'secret git data\n' >"$SOURCE_DIR/.git/config"
printf 'old log\n' >"$SOURCE_DIR/logs/install.log"
printf 'dependency\n' >"$SOURCE_DIR/node_modules/pkg/index.js"

mkdir -p "$TARGET_DIR"
printf 'stale\n' >"$TARGET_DIR/stale.txt"

AUTOPOIESIS_INSTALL_COPY_METHOD=tar \
  AUTOPOIESIS_INSTALL_COPY_SKIP_CHOWN=1 \
  "$ROOT_DIR/scripts/install-app-tree.sh" "$SOURCE_DIR" "$TARGET_DIR" frame frame

require_file "$TARGET_DIR/VERSION"
require_file "$TARGET_DIR/scripts/start-setup.sh"
require_absent "$TARGET_DIR/stale.txt"
require_absent "$TARGET_DIR/.git/config"
require_absent "$TARGET_DIR/logs/install.log"
require_absent "$TARGET_DIR/node_modules/pkg/index.js"

rm -f "$SOURCE_DIR/VERSION"
printf 'version two\n' >"$SOURCE_DIR/SECOND"
printf 'stale again\n' >"$TARGET_DIR/stale-again.txt"

AUTOPOIESIS_INSTALL_COPY_METHOD=tar \
  AUTOPOIESIS_INSTALL_COPY_SKIP_CHOWN=1 \
  "$ROOT_DIR/scripts/install-app-tree.sh" "$SOURCE_DIR" "$TARGET_DIR" frame frame

require_file "$TARGET_DIR/SECOND"
require_absent "$TARGET_DIR/VERSION"
require_absent "$TARGET_DIR/stale-again.txt"
require_absent "$TARGET_DIR/.git/config"
require_absent "$TARGET_DIR/logs/install.log"
require_absent "$TARGET_DIR/node_modules/pkg/index.js"

echo "Install app-tree copy check passed."
