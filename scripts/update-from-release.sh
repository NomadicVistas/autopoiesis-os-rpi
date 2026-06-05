#!/usr/bin/env bash
set -euo pipefail

RELEASE_JSON="${1:-}"
APP_DIR="${AUTOPOIESIS_APP_DIR:-/opt/autopoiesis-os/app}"
INSTALL_DIR="${AUTOPOIESIS_INSTALL_DIR:-/opt/autopoiesis-os}"
DATA_DIR="${AUTOPOIESIS_DATA_DIR:-/var/lib/autopoiesis-os}"
LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"
STAGING_DIR="$INSTALL_DIR/releases/staging"
ROLLBACK_FILE="$DATA_DIR/release-rollback.json"

mkdir -p "$LOG_DIR" "$INSTALL_DIR/releases" "$DATA_DIR"

if [[ -z "$RELEASE_JSON" || ! -f "$RELEASE_JSON" ]]; then
  echo "$(date -Is) release update failed: missing release json" >> "$LOG_DIR/update.log"
  exit 2
fi

read_release_field() {
  local field="$1"
  node -e "const fs=require('fs');const p=process.argv[1];const f=process.argv[2];const d=JSON.parse(fs.readFileSync(p,'utf8'));const r=d.release||d;process.stdout.write(String(r[f]||''));" "$RELEASE_JSON" "$field"
}

VERSION_TARGET="$(read_release_field version)"
ARTIFACT_URL="$(read_release_field artifact_url)"
CHECKSUM="$(read_release_field checksum)"

if [[ -z "$VERSION_TARGET" ]]; then
  echo "$(date -Is) release update failed: release has no version" >> "$LOG_DIR/update.log"
  exit 2
fi

PREVIOUS_VERSION="unknown"
[[ -f "$APP_DIR/VERSION" ]] && PREVIOUS_VERSION="$(tr -d '\n' < "$APP_DIR/VERSION")"
PREVIOUS_REV=""
if [[ -d "$APP_DIR/.git" ]]; then
  PREVIOUS_REV="$(git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null || true)"
fi
node -e "const fs=require('fs');fs.writeFileSync(process.argv[1], JSON.stringify({previousVersion:process.argv[2],previousRevision:process.argv[3],targetVersion:process.argv[4],startedAt:new Date().toISOString()}, null, 2)+'\n')" "$ROLLBACK_FILE" "$PREVIOUS_VERSION" "$PREVIOUS_REV" "$VERSION_TARGET"

if [[ -z "$ARTIFACT_URL" ]]; then
  echo "$(date -Is) release $VERSION_TARGET has no artifact_url; applying git fast-forward without setup-service restart" >> "$LOG_DIR/update.log"
  if [[ ! -d "$APP_DIR/.git" ]]; then
    echo "$(date -Is) release update failed: installed app is not a git checkout and no artifact_url was supplied" >> "$LOG_DIR/update.log"
    exit 2
  fi
  git -C "$APP_DIR" fetch origin main
  git -C "$APP_DIR" pull --ff-only origin main
  "$APP_DIR/scripts/bootstrap.sh"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart autopoiesis-kiosk.service || true
  fi
  echo "$(date -Is) release updated from $PREVIOUS_VERSION to $VERSION_TARGET via git" >> "$LOG_DIR/update.log"
  exit 0
fi

TMP_ARCHIVE="$(mktemp -t autopoiesis-release.XXXXXX.tar.gz)"
cleanup() { rm -f "$TMP_ARCHIVE"; rm -rf "$STAGING_DIR"; }
trap cleanup EXIT

curl -fL "$ARTIFACT_URL" -o "$TMP_ARCHIVE"
if [[ -n "$CHECKSUM" ]]; then
  printf '%s  %s\n' "$CHECKSUM" "$TMP_ARCHIVE" | sha256sum -c -
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
tar -xzf "$TMP_ARCHIVE" -C "$STAGING_DIR"

PAYLOAD_DIR="$STAGING_DIR"
if [[ $(find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l) -eq 1 && $(find "$STAGING_DIR" -mindepth 1 -maxdepth 1 | wc -l) -eq 1 ]]; then
  PAYLOAD_DIR="$(find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
fi

rsync -a --delete --exclude '.git' "$PAYLOAD_DIR/" "$APP_DIR/"
"$APP_DIR/scripts/bootstrap.sh"

if command -v systemctl >/dev/null 2>&1; then
  systemctl restart autopoiesis-kiosk.service || true
fi

echo "$(date -Is) release updated from $PREVIOUS_VERSION to $VERSION_TARGET" >> "$LOG_DIR/update.log"
