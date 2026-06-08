#!/usr/bin/env bash
# broadcast-feed-delivery-lifecycle-check.sh
# Validates: source attribution in stream items, normalizeFeedItem source passthrough,
# delivery deduplication in getStreamContent, and end-to-end delivery lifecycle.
set -euo pipefail
cd "$(dirname "$0")/.."

PASSED=0; FAILED=0; STEPS=0
port=""
pid=""
tmpdir=""

cleanup() {
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi
  if [ -n "$tmpdir" ] && [ -d "$tmpdir" ]; then rm -rf "$tmpdir"; fi
}
trap cleanup EXIT

ok() { PASSED=$((PASSED+1)); }
fail() { FAILED=$((FAILED+1)); echo "  FAIL: $1"; }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok; else fail "$label: expected=$expected got=$actual"; fi
}
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then ok; else fail "$label: $needle not found"; fi
}
assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then fail "$label: $needle should not be present"; else ok; fi
}
assert_gt() {
  local label="$1" a="$2" b="$3"
  if [ "$a" -gt "$b" ] 2>/dev/null; then ok; else fail "$label: $a not > $b"; fi
}

api() {
  local method="$1" endpoint="$2"
  local body="${3:-}"
  local url="http://127.0.0.1:${port}${endpoint}"
  if [ "$method" = "GET" ]; then
    curl -sf -H "x-admin-token: test-admin-token" "$url" 2>/dev/null || echo '{"error":"req_fail"}'
  else
    curl -sf -X "$method" -H "Content-Type: application/json" -H "x-admin-token: test-admin-token" \
      -d "$body" "$url" 2>/dev/null || echo '{"error":"req_fail"}'
  fi
}

api_device() {
  local method="$1" endpoint="$2"
  local body="${3:-}"
  local url="http://127.0.0.1:${port}${endpoint}"
  local key="${device_key:-unset}"
  if [ "$method" = "GET" ]; then
    curl -sf -H "x-frame-device-key: $key" "$url" 2>/dev/null || echo '{"error":"req_fail"}'
  else
    curl -sf -X "$method" -H "Content-Type: application/json" -H "x-frame-device-key: $key" \
      -d "$body" "$url" 2>/dev/null || echo '{"error":"req_fail"}'
  fi
}

jqv() {
  echo "$1" | node -pe "
    try { const j=JSON.parse(require('fs').readFileSync(0,'utf8'));
      const p='$2'.split('.'); let v=j;
      for (const k of p){if(v==null)break;v=v[k]}
      JSON.stringify(v) } catch{JSON.stringify(null)}" 2>/dev/null | tr -d '"'
}
jlen() {
  echo "$1" | node -pe "
    try { const j=JSON.parse(require('fs').readFileSync(0,'utf8'));
      const p='$2'.split('.'); let v=j;
      for (const k of p){if(v==null)break;v=v[k]}
      Array.isArray(v)?v.length:0 } catch{0}" 2>/dev/null
}
jmap() {
  echo "$1" | node -pe "
    try { const j=JSON.parse(require('fs').readFileSync(0,'utf8'));
      const items=j.items||[];
      process.stdout.write(items.map(i=>String(i[$2])).join(',')) } catch{''}" 2>/dev/null
}

echo "=== Broadcast Feed Delivery Lifecycle Check ==="

# ── Step 1: Syntax ──────────────────────────────────────────────────────────
STEPS=$((STEPS+1))
echo "Step $STEPS: Syntax validation"
node --check hosted-api/db.js && ok || fail "db.js syntax"
node --check hosted-api/server.js && ok || fail "server.js syntax"
node --check local-ui/server.js && ok || fail "local-ui syntax"

# ── Step 2: Static contract ────────────────────────────────────────────────
STEPS=$((STEPS+1))
echo "Step $STEPS: Static contract"
db_src=$(cat hosted-api/db.js)
assert_contains "getStreamContent source field" "$db_src" "source: category"
assert_contains "delivery dedup query" "$db_src" "aos_broadcast_deliveries"
assert_contains "displayedSet" "$db_src" "displayedSet"

# Check local-ui directly with grep
grep -qF 'raw.source || source' local-ui/server.js && ok || fail "effectiveSource from raw.source"
grep -qF 'source: effectiveSource' local-ui/server.js && ok || fail "effectiveSource in output"

# ── Step 3: Server bootstrap ───────────────────────────────────────────────
PORT=3187
STEPS=$((STEPS+1))
echo "Step $STEPS: Server bootstrap"
tmpdir=$(mktemp -d)
export AOS_DB="$tmpdir/test.db"
export AOS_PORT="$PORT"
export AUTOPOIESIS_DATA_DIR="$tmpdir"
export AUTOPOIESIS_FRAMES_ADMIN_TOKEN="test-admin-token"

fuser -k "$PORT/tcp" 2>/dev/null || true
sleep 0.3

node hosted-api/server.js &
pid=$!

for i in $(seq 1 15); do
  if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then break; fi
  sleep 0.5
done
port="$PORT"
ok
echo "  Server on port $port"

# ── Step 4: Device registration + pairing ──────────────────────────────────
STEPS=$((STEPS+1))
echo "Step $STEPS: Device registration + pairing"

reg=$(api POST /frames/device/register '{"deviceName":"lf-test-1"}')
device_id=$(jqv "$reg" "device.deviceId")
device_key=$(jqv "$reg" "device.deviceApiKey")
pair_code=$(jqv "$reg" "pairingCode")
if [ -z "$device_id" ]; then fail "no deviceId"; exit 1; fi
ok

# Claim pairing code directly in DB
DB_FILE="$tmpdir/test.db"
HOSTED_DB="$(pwd)/hosted-api/db.js"
node -e "
const AosDb = require('$HOSTED_DB');
const db = new AosDb('$DB_FILE');
db.claimPairingCode('$pair_code', 'user-alice');
db.close();
" 2>/dev/null && ok || fail "pairing claim"
echo "  device=$device_id"

# ── Step 5: Seed content ───────────────────────────────────────────────────
STEPS=$((STEPS+1))
echo "Step $STEPS: Seed content items"

a1=$(api POST /frames/admin/broadcasts '{"title":"Sunset","type":"artwork","mediaUrl":"https://example.com/s.jpg","artist":"Vessel","artistId":"v1","targetType":"all","priority":"normal","cacheAllowed":true,"status":"published","createdBy":"pulse"}')
a1_id=$(jqv "$a1" "broadcast.id")
[ -n "$a1_id" ] && ok || fail "artwork create"

b1=$(api POST /frames/admin/broadcasts '{"title":"New Exhibition","type":"broadcast_message","body":"Join us Friday","priority":"high","targetType":"all","dismissible":true,"status":"published","createdBy":"pulse"}')
b1_id=$(jqv "$b1" "broadcast.id")
[ -n "$b1_id" ] && ok || fail "broadcast create"

c1=$(api POST /frames/admin/broadcasts '{"title":"Behind the Canvas","type":"blog","body":"Generative art deep dive","priority":"normal","targetType":"all","cacheAllowed":true,"status":"published","createdBy":"pulse"}')
c1_id=$(jqv "$c1" "broadcast.id")
[ -n "$c1_id" ] && ok || fail "blog create"

e1=$(api POST /frames/admin/broadcasts '{"title":"URGENT Maintenance","type":"system_notice","body":"Restarting in 10 min","priority":"emergency","targetType":"all","dismissible":false,"status":"published","createdBy":"pulse"}')
e1_id=$(jqv "$e1" "broadcast.id")
[ -n "$e1_id" ] && ok || fail "emergency create"

echo "  a=$a1_id b=$b1_id c=$c1_id e=$e1_id"

# ── Step 6: Stream source attribution ──────────────────────────────────────
STEPS=$((STEPS+1))
echo "Step $STEPS: Stream source attribution"

stream=$(api_device GET "/frames/device/${device_id}/stream")
stream_count=$(jlen "$stream" "items")
assert_gt "stream has items" "$stream_count" 0

src_ok=$(echo "$stream" | node -pe "
  try{const j=JSON.parse(require('fs').readFileSync(0,'utf8'));
    const items=j.items||[];
    items.every(i=>i.source==='admin')?'yes':'no'}catch{'err'}" 2>/dev/null)
assert_eq "all items source=admin" "yes" "$src_ok"

cats=$(echo "$stream" | node -pe "
  try{const j=JSON.parse(require('fs').readFileSync(0,'utf8'));
    const items=j.items||[];
    [...new Set(items.map(i=>i.category))].sort().join(',')}catch{''}" 2>/dev/null)
assert_contains "has broadcast category" "$cats" "broadcast"
assert_contains "has artwork category" "$cats" "artwork"
echo "  categories: $cats"

# ── Step 7: Delivery via heartbeat ─────────────────────────────────────────
STEPS=$((STEPS+1))
echo "Step $STEPS: Simulate delivery via heartbeat"

now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
hb_body=$(cat <<HBEOF
{"softwareVersion":"0.1.0","currentMode":"frame","networkOnline":true,"events":[],
 "broadcastDeliveries":{"deliveries":[
   {"broadcastId":"$b1_id","status":"displayed","receivedAt":"$now_iso","shownAt":"$now_iso"},
   {"broadcastId":"$a1_id","status":"displayed","receivedAt":"$now_iso","shownAt":"$now_iso"}
 ]}}
HBEOF
)
hb1=$(api_device POST "/frames/device/${device_id}/heartbeat" "$hb_body")
assert_contains "heartbeat accepted" "$hb1" "ok"
ok

# ── Step 8: Deliveries persisted ───────────────────────────────────────────
STEPS=$((STEPS+1))
echo "Step $STEPS: Verify deliveries persisted"

del=$(api GET "/frames/admin/broadcast-deliveries?broadcastId=$b1_id")
del_n=$(jlen "$del" "deliveries")
assert_gt "broadcast delivery persisted" "$del_n" 0

adel=$(api GET "/frames/admin/broadcast-deliveries?broadcastId=$a1_id")
adel_n=$(jlen "$adel" "deliveries")
assert_gt "artwork delivery persisted" "$adel_n" 0
echo "  bcast_del=$del_n art_del=$adel_n"

# ── Step 9: Dedup - displayed items excluded except emergency ──────────────
STEPS=$((STEPS+1))
echo "Step $STEPS: Dedup - displayed items excluded"

stream2=$(api_device GET "/frames/device/${device_id}/stream")
ids2=$(echo "$stream2" | node -pe "
  try{const j=JSON.parse(require('fs').readFileSync(0,'utf8'));
    (j.items||[]).map(i=>i.id).join(',')}catch{''}" 2>/dev/null)

assert_not_contains "broadcast excluded" "$ids2" "$b1_id"
assert_not_contains "artwork excluded" "$ids2" "$a1_id"
assert_contains "emergency kept - bypasses dedup" "$ids2" "$e1_id"
assert_contains "blog kept - not yet displayed" "$ids2" "$c1_id"
echo "  remaining: $ids2"

# ── Step 10: Fresh device sees all items ───────────────────────────────────
STEPS=$((STEPS+1))
echo "Step $STEPS: Fresh device - no dedup"

reg2=$(api POST /frames/device/register '{"deviceName":"lf-test-2"}')
device_id2=$(jqv "$reg2" "device.deviceId")
device_key2=$(jqv "$reg2" "device.deviceApiKey")
pair_code2=$(jqv "$reg2" "pairingCode")
node -e "
const AosDb = require('$(pwd)/hosted-api/db.js');
const db = new AosDb('$tmpdir/test.db');
db.claimPairingCode('$pair_code2', 'user-bob');
db.close();
" 2>/dev/null || true

# Override device_key for api_device
old_key="$device_key"
device_key="$device_key2"
stream3=$(api_device GET "/frames/device/${device_id2}/stream")
device_key="$old_key"

stream3_count=$(jlen "$stream3" "items")
assert_gt "fresh device sees all items" "$stream3_count" 3

ids3=$(echo "$stream3" | node -pe "
  try{const j=JSON.parse(require('fs').readFileSync(0,'utf8'));
    (j.items||[]).map(i=>i.id).join(',')}catch{''}" 2>/dev/null)
assert_contains "fresh sees artwork" "$ids3" "$a1_id"
assert_contains "fresh sees broadcast" "$ids3" "$b1_id"
assert_contains "fresh sees emergency" "$ids3" "$e1_id"
assert_contains "fresh sees blog" "$ids3" "$c1_id"
echo "  fresh sees $stream3_count items"

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASSED passed, $FAILED failed, $STEPS steps ==="
if [ "$FAILED" -gt 0 ]; then
  echo "SOME CHECKS FAILED"
  exit 1
fi
echo "ALL CHECKS PASSED"
