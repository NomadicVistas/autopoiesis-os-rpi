#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${AUTOPOIESIS_DATA_DIR:-/var/lib/autopoiesis-os}"
CACHE_DIR="${AUTOPOIESIS_CACHE_DIR:-$DATA_DIR/cache}"
LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"
MANIFEST_JSON="${AUTOPOIESIS_FEED_CACHE_JSON:-$DATA_DIR/feed-cache.json}"
INDEX_JSON="${AUTOPOIESIS_CACHE_INDEX_JSON:-$DATA_DIR/cache-index.json}"
MAX_ITEMS="${AUTOPOIESIS_CACHE_MAX_ITEMS:-50}"
CURL_TIMEOUT="${AUTOPOIESIS_CACHE_CURL_TIMEOUT:-45}"

ARTWORK_DIR="$CACHE_DIR/artworks"
THUMBNAIL_DIR="$CACHE_DIR/thumbnails"
TMP_DIR="$(mktemp -d)"
PLAN_JSONL="$TMP_DIR/plan.jsonl"
RESULTS_JSONL="$TMP_DIR/results.jsonl"
LOG_FILE="$LOG_DIR/cache.log"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$ARTWORK_DIR" "$THUMBNAIL_DIR" "$LOG_DIR" "$(dirname "$INDEX_JSON")"
: >"$RESULTS_JSONL"

log() {
  printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG_FILE"
}

write_empty_index() {
  node - "$INDEX_JSON" "$MANIFEST_JSON" "$1" <<'NODE'
const fs = require("fs");
const [indexPath, manifestPath, reason] = process.argv.slice(2);
let manifest = {};
try {
  manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
} catch {
  manifest = {};
}
fs.writeFileSync(indexPath, JSON.stringify({
  generatedAt: new Date().toISOString(),
  manifestGeneratedAt: manifest.generatedAt || null,
  manifestCount: Number(manifest.count || 0),
  cachedCount: 0,
  failedCount: 0,
  skipped: true,
  reason,
  items: []
}, null, 2) + "\n");
NODE
}

if ! command -v node >/dev/null 2>&1; then
  log "cache skipped: node unavailable"
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  log "cache skipped: curl unavailable"
  write_empty_index "curl unavailable"
  exit 0
fi

if [[ ! -f "$MANIFEST_JSON" ]]; then
  log "cache skipped: manifest not found at $MANIFEST_JSON"
  write_empty_index "manifest not found"
  exit 0
fi

node - "$MANIFEST_JSON" "$ARTWORK_DIR" "$THUMBNAIL_DIR" "$MAX_ITEMS" >"$PLAN_JSONL" <<'NODE'
const fs = require("fs");
const path = require("path");
const [manifestPath, artworkDir, thumbnailDir, maxItemsRaw] = process.argv.slice(2);
const maxItems = Math.max(0, Number(maxItemsRaw || 50) || 50);

function safePart(value, fallback) {
  const cleaned = String(value || fallback || "item")
    .replace(/[^a-zA-Z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 96);
  return cleaned || fallback || "item";
}

function extensionFor(url, fallback = ".bin") {
  try {
    const ext = path.extname(new URL(url).pathname).toLowerCase();
    if (/^\.(jpg|jpeg|png|gif|webp|avif|mp4|webm|mov|mp3|wav|ogg|m4a)$/.test(ext)) {
      return ext;
    }
  } catch {
    // Fall through to fallback.
  }
  return fallback;
}

function plannedPath(dir, item, role, url) {
  if (!url) return null;
  const id = safePart(item.id, "item");
  const type = safePart(item.type || "media", "media");
  return path.join(dir, id + "-" + role + "-" + type + extensionFor(url));
}

let manifest;
try {
  manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
} catch (error) {
  console.error("invalid feed cache manifest: " + error.message);
  process.exit(2);
}

const items = Array.isArray(manifest.items) ? manifest.items.slice(0, maxItems) : [];
for (const item of items) {
  if (!item || !item.id) continue;
  const mediaUrl = item.mediaUrl || item.media_url || null;
  const thumbnailUrl = item.thumbnailUrl || item.thumbnail_url || null;
  process.stdout.write(JSON.stringify({
    id: String(item.id),
    source: item.source || null,
    type: item.type || null,
    priority: item.priority || null,
    expiresAt: item.expiresAt || null,
    mediaUrl,
    thumbnailUrl,
    mediaPath: plannedPath(artworkDir, item, "media", mediaUrl),
    thumbnailPath: plannedPath(thumbnailDir, item, "thumb", thumbnailUrl)
  }) + "\n");
}
NODE

download_asset() {
  local url="$1"
  local destination="$2"

  if [[ -z "$url" || -z "$destination" ]]; then
    printf 'skipped|0'
    return 0
  fi

  if [[ -s "$destination" ]]; then
    printf 'cached|%s' "$(wc -c <"$destination" | tr -d ' ')"
    return 0
  fi

  local tmp_file="$destination.tmp.$$"
  rm -f "$tmp_file"
  if curl -fL --connect-timeout 10 --max-time "$CURL_TIMEOUT" --retry 2 --retry-delay 1 -o "$tmp_file" "$url" >/dev/null 2>&1; then
    chmod 600 "$tmp_file"
    mv "$tmp_file" "$destination"
    printf 'downloaded|%s' "$(wc -c <"$destination" | tr -d ' ')"
    return 0
  fi

  rm -f "$tmp_file"
  printf 'failed|0'
  return 0
}

while IFS= read -r item_json; do
  [[ -n "$item_json" ]] || continue

  id="$(node -e 'const item=JSON.parse(process.argv[1]);process.stdout.write(item.id || "");' "$item_json")"
  media_url="$(node -e 'const item=JSON.parse(process.argv[1]);process.stdout.write(item.mediaUrl || "");' "$item_json")"
  thumbnail_url="$(node -e 'const item=JSON.parse(process.argv[1]);process.stdout.write(item.thumbnailUrl || "");' "$item_json")"
  media_path="$(node -e 'const item=JSON.parse(process.argv[1]);process.stdout.write(item.mediaPath || "");' "$item_json")"
  thumbnail_path="$(node -e 'const item=JSON.parse(process.argv[1]);process.stdout.write(item.thumbnailPath || "");' "$item_json")"

  media_result="$(download_asset "$media_url" "$media_path")"
  thumbnail_result="$(download_asset "$thumbnail_url" "$thumbnail_path")"

  node - "$item_json" "$media_result" "$thumbnail_result" >>"$RESULTS_JSONL" <<'NODE'
const item = JSON.parse(process.argv[2]);
function parse(result) {
  const [status, bytes] = String(result || "skipped|0").split("|");
  return { status, bytes: Number(bytes || 0) || 0 };
}
const media = parse(process.argv[3]);
const thumbnail = parse(process.argv[4]);
process.stdout.write(JSON.stringify({
  id: item.id,
  source: item.source,
  type: item.type,
  priority: item.priority,
  expiresAt: item.expiresAt,
  media: {
    url: item.mediaUrl,
    path: item.mediaPath,
    status: media.status,
    bytes: media.bytes
  },
  thumbnail: {
    url: item.thumbnailUrl,
    path: item.thumbnailPath,
    status: thumbnail.status,
    bytes: thumbnail.bytes
  }
}) + "\n");
NODE

  log "cache item id=$id media=$(printf '%s' "$media_result" | cut -d'|' -f1) thumbnail=$(printf '%s' "$thumbnail_result" | cut -d'|' -f1)"
done <"$PLAN_JSONL"

node - "$INDEX_JSON" "$MANIFEST_JSON" "$RESULTS_JSONL" <<'NODE'
const fs = require("fs");
const [indexPath, manifestPath, resultsPath] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const lines = fs.existsSync(resultsPath)
  ? fs.readFileSync(resultsPath, "utf8").split("\n").filter(Boolean)
  : [];
const items = lines.map(line => JSON.parse(line));
function assetCached(asset) {
  return asset && ["cached", "downloaded"].includes(asset.status);
}
function assetFailed(asset) {
  return asset && asset.status === "failed";
}
const cachedCount = items.filter(item => assetCached(item.media) || assetCached(item.thumbnail)).length;
const failedCount = items.filter(item => assetFailed(item.media) || assetFailed(item.thumbnail)).length;
fs.writeFileSync(indexPath, JSON.stringify({
  generatedAt: new Date().toISOString(),
  manifestGeneratedAt: manifest.generatedAt || null,
  manifestCount: Number(manifest.count || 0),
  cachedCount,
  failedCount,
  items
}, null, 2) + "\n");
NODE

SUMMARY="$(node -e 'const fs=require("fs");const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write("items="+d.items.length+" cached="+d.cachedCount+" failed="+d.failedCount);' "$INDEX_JSON")"
log "cache completed: $SUMMARY"
echo "Autopoiesis cache completed: $SUMMARY"
