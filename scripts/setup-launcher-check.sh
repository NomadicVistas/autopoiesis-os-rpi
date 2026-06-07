#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "setup launcher check failed: $*" >&2
  exit 1
}

require_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq "$expected" "$file" || fail "$file does not contain: $expected"
}

require_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq "$unexpected" "$file"; then
    fail "$file still contains hardcoded default path: $unexpected"
  fi
}

CUSTOM_APP_DIR="$TMP_DIR/custom-app"
CUSTOM_LOCAL_UI_DIR="$CUSTOM_APP_DIR/local-ui"
mkdir -p "$CUSTOM_LOCAL_UI_DIR"
cp "$ROOT_DIR/local-ui/server.js" "$CUSTOM_LOCAL_UI_DIR/server.js"

AUTOPOIESIS_APP_DIR="$CUSTOM_APP_DIR" \
  AUTOPOIESIS_SETUP_DRY_RUN=1 \
  "$ROOT_DIR/scripts/start-setup.sh" >"$TMP_DIR/custom.out"

require_contains "$TMP_DIR/custom.out" "$CUSTOM_LOCAL_UI_DIR"
require_contains "$TMP_DIR/custom.out" "$CUSTOM_LOCAL_UI_DIR/server.js"
require_not_contains "$TMP_DIR/custom.out" "/opt/autopoiesis-os"

AUTOPOIESIS_SETUP_DRY_RUN=1 \
  "$ROOT_DIR/scripts/start-setup.sh" >"$TMP_DIR/default.out"

require_contains "$TMP_DIR/default.out" "$ROOT_DIR/local-ui"
require_contains "$TMP_DIR/default.out" "$ROOT_DIR/local-ui/server.js"
require_not_contains "$TMP_DIR/default.out" "/opt/autopoiesis-os"

if AUTOPOIESIS_APP_DIR="$TMP_DIR/missing-app" \
  AUTOPOIESIS_SETUP_DRY_RUN=1 \
  "$ROOT_DIR/scripts/start-setup.sh" >"$TMP_DIR/missing.out" 2>"$TMP_DIR/missing.err"; then
  fail "missing local-ui/server.js did not fail"
fi
require_contains "$TMP_DIR/missing.err" "Autopoiesis local UI server not found"

echo "setup launcher check passed: start-setup honors configured and installed app paths"
