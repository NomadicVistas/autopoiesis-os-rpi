#!/usr/bin/env bash
set -euo pipefail

RELEASE_JSON="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${AUTOPOIESIS_APP_DIR:-/opt/autopoiesis-os/app}"
INSTALL_DIR="${AUTOPOIESIS_INSTALL_DIR:-/opt/autopoiesis-os}"
DATA_DIR="${AUTOPOIESIS_DATA_DIR:-/var/lib/autopoiesis-os}"
LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"
STAGING_DIR="$INSTALL_DIR/releases/staging"
ROLLBACK_DIR="$INSTALL_DIR/releases/rollback"
ROLLBACK_BACKUP_DIR=""
ROLLBACK_FILE="$DATA_DIR/release-rollback.json"

mkdir -p "$LOG_DIR" "$INSTALL_DIR/releases" "$DATA_DIR"

if [[ -z "$RELEASE_JSON" || ! -f "$RELEASE_JSON" ]]; then
  echo "$(date -Is) release update failed: missing release json" >> "$LOG_DIR/update.log"
  exit 2
fi

read_device_update_channel() {
  node -e "const fs=require('fs');const p=process.argv[1];try{const d=JSON.parse(fs.readFileSync(p,'utf8'));const c=d.updateChannel||d.update_channel||d.releaseChannel||d.release_channel;if(typeof c==='string'&&c.trim())process.stdout.write(c.trim());}catch{}" "$DATA_DIR/device.json"
}

read_release_field() {
  local field="$1"
  node -e "const fs=require('fs');const p=process.argv[1];const f=process.argv[2];const aliases={artifact_url:['artifact_url','artifactUrl','assetUrl','downloadUrl'],checksum:['checksum','sha256','artifactSha256','artifact_sha256'],version:['version','targetVersion','target_version'],channel:['channel','updateChannel','update_channel'],tag:['tagName','tag_name','tag'],release_id:['id','releaseId','release_id']};const d=JSON.parse(fs.readFileSync(p,'utf8'));const r=d.release||d;for(const k of aliases[f]||[f]){if(typeof r[k]==='string'&&r[k].trim()){process.stdout.write(r[k].trim());process.exit(0);}}process.stdout.write('');" "$RELEASE_JSON" "$field"
}

app_tree_owner() {
  if [[ -n "${AUTOPOIESIS_USER:-}" ]]; then
    printf '%s:%s' "$AUTOPOIESIS_USER" "${AUTOPOIESIS_GROUP:-$AUTOPOIESIS_USER}"
    return
  fi
  if [[ -e "$APP_DIR" ]]; then
    stat -c '%U:%G' "$APP_DIR" 2>/dev/null && return
  fi
  printf '%s:%s' "$(id -un)" "$(id -gn)"
}

copy_app_tree() {
  local source_dir="$1"
  local target_dir="$2"
  local owner_group owner group
  owner_group="$(app_tree_owner)"
  owner="${owner_group%%:*}"
  group="${owner_group#*:}"
  "$SCRIPT_DIR/install-app-tree.sh" "$source_dir" "$target_dir" "$owner" "$group"
}

if [[ -z "${AUTOPOIESIS_RELEASE_CHANNEL:-}" ]]; then
  DEVICE_UPDATE_CHANNEL="$(read_device_update_channel)"
  if [[ -n "$DEVICE_UPDATE_CHANNEL" ]]; then
    export AUTOPOIESIS_RELEASE_CHANNEL="$DEVICE_UPDATE_CHANNEL"
  fi
fi

if [[ -n "${AUTOPOIESIS_RELEASE_CHANNEL:-}" && -z "${AUTOPOIESIS_RELEASE_REQUIRE_CHANNEL+x}" ]]; then
  export AUTOPOIESIS_RELEASE_REQUIRE_CHANNEL=1
fi

if ! MANIFEST_CHECK_OUTPUT="$("$SCRIPT_DIR/release-manifest-check.sh" "$RELEASE_JSON" 2>&1)"; then
  echo "$(date -Is) release update failed: $MANIFEST_CHECK_OUTPUT" >> "$LOG_DIR/update.log"
  echo "$MANIFEST_CHECK_OUTPUT" >&2
  exit 2
fi
echo "$MANIFEST_CHECK_OUTPUT" >> "$LOG_DIR/update.log"

VERSION_TARGET="$(read_release_field version)"
ARTIFACT_URL="$(read_release_field artifact_url)"
CHECKSUM="$(read_release_field checksum)"
RELEASE_CHANNEL="$(read_release_field channel)"
RELEASE_TAG="$(read_release_field tag)"
RELEASE_ID="$(read_release_field release_id)"

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
write_rollback_metadata() {
  node -e "const fs=require('fs');const file=process.argv[1];const previousVersion=process.argv[2];const previousRevision=process.argv[3]||null;const targetVersion=process.argv[4];const backupDir=process.argv[5]||null;const releaseChannel=process.argv[6]||null;const releaseTag=process.argv[7]||null;const releaseId=process.argv[8]||null;fs.writeFileSync(file, JSON.stringify({previousVersion,previousRevision,targetVersion,backupDir,releaseChannel,releaseTag,releaseId,startedAt:new Date().toISOString()}, null, 2)+'\n')" "$ROLLBACK_FILE" "$PREVIOUS_VERSION" "$PREVIOUS_REV" "$VERSION_TARGET" "$ROLLBACK_BACKUP_DIR" "$RELEASE_CHANNEL" "$RELEASE_TAG" "$RELEASE_ID"
}

if [[ -z "$ARTIFACT_URL" ]]; then
  echo "$(date -Is) release $VERSION_TARGET has no artifact_url; applying git fast-forward without setup-service restart" >> "$LOG_DIR/update.log"
  if [[ ! -d "$APP_DIR/.git" ]]; then
    echo "$(date -Is) release update failed: installed app is not a git checkout and no artifact_url was supplied" >> "$LOG_DIR/update.log"
    exit 2
  fi
  write_rollback_metadata
  git -C "$APP_DIR" fetch origin main
  git -C "$APP_DIR" pull --ff-only origin main
  "$APP_DIR/scripts/bootstrap.sh"
  if [[ "$(id -u)" -eq 0 ]]; then
    "$APP_DIR/scripts/install-systemd-units.sh"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart autopoiesis-kiosk.service || true
  fi
  echo "$(date -Is) release updated from $PREVIOUS_VERSION to $VERSION_TARGET via git" >> "$LOG_DIR/update.log"
  exit 0
fi

TMP_ARCHIVE="$(mktemp -t autopoiesis-release.XXXXXX.tar.gz)"
cleanup() { rm -f "$TMP_ARCHIVE"; rm -rf "$STAGING_DIR"; }
trap cleanup EXIT

rm -rf "$ROLLBACK_DIR"
mkdir -p "$ROLLBACK_DIR/app"
copy_app_tree "$APP_DIR" "$ROLLBACK_DIR/app"
ROLLBACK_BACKUP_DIR="$ROLLBACK_DIR/app"
write_rollback_metadata

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

copy_app_tree "$PAYLOAD_DIR" "$APP_DIR"
"$APP_DIR/scripts/bootstrap.sh"
if [[ "$(id -u)" -eq 0 ]]; then
  "$APP_DIR/scripts/install-systemd-units.sh"
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl restart autopoiesis-kiosk.service || true
fi

echo "$(date -Is) release updated from $PREVIOUS_VERSION to $VERSION_TARGET" >> "$LOG_DIR/update.log"
