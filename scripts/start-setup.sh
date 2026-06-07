#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${AUTOPOIESIS_APP_DIR:-}"
if [[ -z "$APP_DIR" ]]; then
  APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

LOCAL_UI_DIR="${AUTOPOIESIS_LOCAL_UI_DIR:-$APP_DIR/local-ui}"
SERVER_JS="$LOCAL_UI_DIR/server.js"

if [[ ! -f "$SERVER_JS" ]]; then
  echo "Autopoiesis local UI server not found at $SERVER_JS" >&2
  exit 2
fi

if [[ "${AUTOPOIESIS_SETUP_DRY_RUN:-0}" == "1" ]]; then
  printf 'cd %q\nexec node %q\n' "$LOCAL_UI_DIR" "$SERVER_JS"
  exit 0
fi

cd "$LOCAL_UI_DIR"
exec node "$SERVER_JS"
