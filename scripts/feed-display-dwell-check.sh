#!/usr/bin/env bash
# feed-display-dwell-check.sh — Content-type-aware display dwell time gate
# Verifies per-category display durations, preference overrides, and broadcast max cap.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR=""
PORT=""
BASE=""
PID=""
STEP=0
PASS=0
FAIL=0

notice()  { printf "\033[1;36m→ %s\033[0m\n" "$*"; }
pass()    { PASS=$((PASS+1)); printf "\033[0;32m✓ Step %d: %s\033[0m\n" "$STEP" "$*"; }
fail()    { FAIL=$((FAIL+1)); printf "\033[0;31m✗ Step %d: %s\033[0m\n" "$STEP" "$*"; }
step()    { STEP=$((STEP+1)); }

cleanup() {
  if [ -n "$PID" ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  if [ -n "$TMPDIR" ]; then
    rm -rf "$TMPDIR"
  fi
}
trap cleanup EXIT

pick_port() {
  node -e 'const net=require("net"),s=net.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}

# ── Setup ──────────────────────────────────────────────────────────────────
TMPDIR="$(mktemp -d)"
DATA_DIR="$TMPDIR/data"
mkdir -p "$DATA_DIR" "$TMPDIR/log" "$TMPDIR/cache"

PORT=$(pick_port)
BASE="http://127.0.0.1:$PORT"

# Seed device as paired
cat > "$DATA_DIR/device.json" <<JSON
{
  "deviceId": "dwell-test-device",
  "deviceName": "Dwell Test Frame",
  "paired": true,
  "firstRunComplete": true,
  "onboardingComplete": true,
  "apiBaseUrl": "http://127.0.0.1:1/api"
}
JSON

# Seed preferences
cat > "$DATA_DIR/preferences.json" <<JSON
{
  "displayMode": "local-feed",
  "streamCategories": ["artwork", "broadcast", "curatorial", "blog", "news"],
  "imageDuration": 60,
  "allowImages": true,
  "allowVideos": true
}
JSON

# Start local UI
export AUTOPOIESIS_PORT="$PORT"
export AUTOPOIESIS_DATA_DIR="$DATA_DIR"
export AUTOPOIESIS_LOG_DIR="$TMPDIR/log"
export AUTOPOIESIS_CACHE_DIR="$TMPDIR/cache"
export AUTOPOIESIS_HOSTED_API_URL="http://127.0.0.1:1"

node "$ROOT/local-ui/server.js" &
PID=$!

for i in $(seq 1 20); do
  if curl -sf "$BASE/local/health" > /dev/null 2>&1; then break; fi
  sleep 0.5
done

# Helper: write feed.json directly
write_feed() {
  local json="$1"
  echo "$json" > "$DATA_DIR/feed.json"
}

# Helper: write preferences directly
write_prefs() {
  local json="$1"
  echo "$json" > "$DATA_DIR/preferences.json"
}

# ── Step 1: Category display defaults in frame-state ──────────────────────
step
# Write empty feed so frame-state has data
write_feed '{"syncedAt":"2026-06-08T00:00:00Z","items":[]}'

FRAME=$(curl -sf "$BASE/local/frame-state")
if echo "$FRAME" | python3 -c "
import json,sys
d=json.load(sys.stdin)
cd=d.get('categoryDisplay',{})
defs=cd.get('defaults',{})
assert defs.get('artwork')==60, f'artwork default should be 60, got {defs.get(\"artwork\")}'
assert defs.get('broadcast')==0, f'broadcast default should be 0 (until dismissed), got {defs.get(\"broadcast\")}'
assert defs.get('blog')==30, f'blog default should be 30, got {defs.get(\"blog\")}'
assert defs.get('news')==20, f'news default should be 20, got {defs.get(\"news\")}'
assert defs.get('curatorial')==45, f'curatorial default should be 45, got {defs.get(\"curatorial\")}'
assert defs.get('content')==60, f'content default should be 60, got {defs.get(\"content\")}'
print('OK')
" 2>/dev/null; then
  pass "Category display defaults present in frame-state"
else
  fail "Category display defaults missing or wrong in frame-state"
fi

# ── Step 2: Category display defaults in diagnostics ─────────────────────
step
DIAG=$(curl -sf "$BASE/local/diagnostics")
if echo "$DIAG" | python3 -c "
import json,sys
d=json.load(sys.stdin)
diag=d.get('diagnostics',d)
feed=diag.get('feed',{})
cd=feed.get('categoryDisplay',{})
defs=cd.get('defaults',{})
assert defs.get('artwork')==60, f'diagnostics artwork default wrong: {defs.get(\"artwork\")}'
assert defs.get('broadcast')==0, f'diagnostics broadcast default wrong: {defs.get(\"broadcast\")}'
assert defs.get('blog')==30, f'diagnostics blog default wrong: {defs.get(\"blog\")}'
assert defs.get('news')==20, f'diagnostics news default wrong: {defs.get(\"news\")}'
print('OK')
" 2>/dev/null; then
  pass "Category display defaults present in diagnostics"
else
  fail "Category display defaults missing in diagnostics"
fi

# ── Step 3: Artwork item gets 60000ms display ────────────────────────────
step
write_feed '{"syncedAt":"2026-06-08T00:01:00Z","items":[{"id":"art1","source":"feed","type":"artwork_image","title":"Test Art","mediaUrl":"https://example.com/art1.jpg"}]}'

FRAME=$(curl -sf "$BASE/local/frame-state")
ART_MS=$(echo "$FRAME" | python3 -c "
import json,sys
d=json.load(sys.stdin)
items=[i for i in d.get('items',[]) if i.get('id')=='art1']
assert items, 'artwork item not in frame'
print(items[0].get('displayMs',0))
" 2>/dev/null)
if [ "$ART_MS" = "60000" ]; then
  pass "Artwork item displays for 60000ms (60s default)"
else
  fail "Artwork item displayMs should be 60000, got ${ART_MS:-none}"
fi

# ── Step 4: Broadcast item gets broadcast max cap (300s default) ─────────
step
write_feed '{"syncedAt":"2026-06-08T00:02:00Z","items":[{"id":"art1","source":"feed","type":"artwork_image","title":"Art","mediaUrl":"https://example.com/art1.jpg"},{"id":"bcast1","source":"broadcast","type":"broadcast_message","title":"Admin Notice","body":"Test broadcast"}]}'

FRAME=$(curl -sf "$BASE/local/frame-state")
BCAST_MS=$(echo "$FRAME" | python3 -c "
import json,sys
d=json.load(sys.stdin)
items=[i for i in d.get('items',[]) if i.get('id')=='bcast1']
assert items, 'broadcast item not in frame'
print(items[0].get('displayMs',0))
" 2>/dev/null)
if [ "$BCAST_MS" = "300000" ]; then
  pass "Broadcast item displays for 300000ms (300s max cap)"
else
  fail "Broadcast item displayMs should be 300000, got ${BCAST_MS:-none}"
fi

# ── Step 5: Blog item gets 30000ms display ────────────────────────────────
step
write_feed '{"syncedAt":"2026-06-08T00:03:00Z","items":[{"id":"blog1","source":"feed","type":"blog_post","title":"A Blog Post","body":"Some text"}]}'

FRAME=$(curl -sf "$BASE/local/frame-state")
BLOG_MS=$(echo "$FRAME" | python3 -c "
import json,sys
d=json.load(sys.stdin)
items=[i for i in d.get('items',[]) if i.get('id')=='blog1']
assert items, 'blog item not in frame'
print(items[0].get('displayMs',0))
" 2>/dev/null)
if [ "$BLOG_MS" = "30000" ]; then
  pass "Blog item displays for 30000ms (30s default)"
else
  fail "Blog item displayMs should be 30000, got ${BLOG_MS:-none}"
fi

# ── Step 6: News item gets 20000ms display ────────────────────────────────
step
write_feed '{"syncedAt":"2026-06-08T00:04:00Z","items":[{"id":"news1","source":"feed","type":"news_update","title":"Breaking","body":"News text"}]}'

FRAME=$(curl -sf "$BASE/local/frame-state")
NEWS_MS=$(echo "$FRAME" | python3 -c "
import json,sys
d=json.load(sys.stdin)
items=[i for i in d.get('items',[]) if i.get('id')=='news1']
assert items, 'news item not in frame'
print(items[0].get('displayMs',0))
" 2>/dev/null)
if [ "$NEWS_MS" = "20000" ]; then
  pass "News item displays for 20000ms (20s default)"
else
  fail "News item displayMs should be 20000, got ${NEWS_MS:-none}"
fi

# ── Step 7: Curatorial item gets 45000ms display ─────────────────────────
step
write_feed '{"syncedAt":"2026-06-08T00:05:00Z","items":[{"id":"cur1","source":"feed","type":"curatorial_note","title":"Curatorial","body":"A note"}]}'

FRAME=$(curl -sf "$BASE/local/frame-state")
CUR_MS=$(echo "$FRAME" | python3 -c "
import json,sys
d=json.load(sys.stdin)
items=[i for i in d.get('items',[]) if i.get('id')=='cur1']
assert items, 'curatorial item not in frame'
print(items[0].get('displayMs',0))
" 2>/dev/null)
if [ "$CUR_MS" = "45000" ]; then
  pass "Curatorial item displays for 45000ms (45s default)"
else
  fail "Curatorial item displayMs should be 45000, got ${CUR_MS:-none}"
fi

# ── Step 8: Category override in preferences changes dwell time ──────────
step
write_prefs '{"displayMode":"local-feed","streamCategories":["artwork","broadcast","curatorial","blog","news"],"allowImages":true,"allowVideos":true,"imageDuration":90,"categoryDurations":{"artwork":120,"blog":45,"news":15}}'
write_feed '{"syncedAt":"2026-06-08T00:06:00Z","items":[{"id":"art2","source":"feed","type":"artwork_image","title":"Art Override","mediaUrl":"https://example.com/art2.jpg"},{"id":"blog2","source":"feed","type":"blog_post","title":"Blog Override","body":"text"},{"id":"news2","source":"feed","type":"news_update","title":"News Override","body":"text"}]}'

FRAME=$(curl -sf "$BASE/local/frame-state")
OVERRIDE_OK=$(echo "$FRAME" | python3 -c "
import json,sys
d=json.load(sys.stdin)
byid={i['id']:i for i in d.get('items',[])}
errors=[]
a=byid.get('art2',{}).get('displayMs',0)
if a!=120000: errors.append(f'artwork override should be 120000, got {a}')
b=byid.get('blog2',{}).get('displayMs',0)
if b!=45000: errors.append(f'blog override should be 45000, got {b}')
n=byid.get('news2',{}).get('displayMs',0)
if n!=15000: errors.append(f'news override should be 15000, got {n}')
if errors:
  for e in errors: print(e,file=sys.stderr)
  sys.exit(1)
print('OK')
" 2>/dev/null)
if [ "$OVERRIDE_OK" = "OK" ]; then
  pass "Category duration overrides apply correctly (artwork=120s, blog=45s, news=15s)"
else
  fail "Category duration overrides not applied correctly"
fi

# ── Step 9: Overrides reflected in categoryDisplay ────────────────────────
step
FRAME=$(curl -sf "$BASE/local/frame-state")
OVERRIDES_VISIBLE=$(echo "$FRAME" | python3 -c "
import json,sys
d=json.load(sys.stdin)
cd=d.get('categoryDisplay',{})
ov=cd.get('overrides',{})
assert ov.get('artwork')==120, f'artwork override not in categoryDisplay: {ov}'
assert ov.get('blog')==45, f'blog override not in categoryDisplay: {ov}'
assert ov.get('news')==15, f'news override not in categoryDisplay: {ov}'
print('OK')
" 2>/dev/null)
if [ "$OVERRIDES_VISIBLE" = "OK" ]; then
  pass "Category overrides visible in frame-state categoryDisplay"
else
  fail "Category overrides not visible in frame-state categoryDisplay"
fi

# ── Step 10: broadcastMaxDuration preference changes broadcast cap ────────
step
write_prefs '{"displayMode":"local-feed","streamCategories":["artwork","broadcast","curatorial","blog","news"],"allowImages":true,"allowVideos":true,"categoryDurations":{"artwork":60},"broadcastMaxDuration":120}'
write_feed '{"syncedAt":"2026-06-08T00:07:00Z","items":[{"id":"art1","source":"feed","type":"artwork_image","title":"Art","mediaUrl":"https://example.com/art1.jpg"},{"id":"bcast2","source":"broadcast","type":"broadcast_message","title":"Short Broadcast","body":"Test"}]}'

FRAME=$(curl -sf "$BASE/local/frame-state")
BCAST_CAP=$(echo "$FRAME" | python3 -c "
import json,sys
d=json.load(sys.stdin)
items=[i for i in d.get('items',[]) if i.get('id')=='bcast2']
assert items, 'broadcast bcast2 not in frame'
print(items[0].get('displayMs',0))
" 2>/dev/null)
BCAST_MAX_VISIBLE=$(echo "$FRAME" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('categoryDisplay',{}).get('broadcastMaxSeconds',0))
" 2>/dev/null)
if [ "$BCAST_CAP" = "120000" ] && [ "$BCAST_MAX_VISIBLE" = "120" ]; then
  pass "broadcastMaxDuration preference caps broadcast at 120s"
else
  fail "broadcastMaxDuration should cap at 120s (displayMs=${BCAST_CAP:-none}, max=${BCAST_MAX_VISIBLE:-none})"
fi

# ── Step 11: Video item duration still overrides category dwell ───────────
step
write_prefs '{"displayMode":"local-feed","streamCategories":["artwork","broadcast","curatorial","blog","news"],"allowImages":true,"allowVideos":true}'
write_feed '{"syncedAt":"2026-06-08T00:08:00Z","items":[{"id":"vid1","source":"feed","type":"artwork_video","title":"Video Art","mediaUrl":"https://example.com/vid1.mp4","duration":45}]}'

FRAME=$(curl -sf "$BASE/local/frame-state")
VID_MS=$(echo "$FRAME" | python3 -c "
import json,sys
d=json.load(sys.stdin)
items=[i for i in d.get('items',[]) if i.get('id')=='vid1']
assert items, 'video item not in frame'
print(items[0].get('displayMs',0))
" 2>/dev/null)
if [ "$VID_MS" = "45000" ]; then
  pass "Video item uses own duration (45s) overriding category default"
else
  fail "Video item should use duration 45000ms, got ${VID_MS:-none}"
fi

# ── Step 12: Mixed content queue preserves per-item dwell times ──────────
step
write_prefs '{"displayMode":"local-feed","streamCategories":["artwork","broadcast","curatorial","blog","news"],"allowImages":true,"allowVideos":true}'
write_feed '{"syncedAt":"2026-06-08T00:09:00Z","items":[{"id":"art_m1","source":"feed","type":"artwork_image","title":"Art","mediaUrl":"https://example.com/art.jpg"},{"id":"blog_m1","source":"feed","type":"blog_post","title":"Blog","body":"text"},{"id":"news_m1","source":"feed","type":"news_update","title":"News","body":"text"},{"id":"cur_m1","source":"feed","type":"curatorial_note","title":"Curatorial","body":"text"},{"id":"bcast_m1","source":"broadcast","type":"broadcast_message","title":"Broadcast","body":"text"}]}'

FRAME=$(curl -sf "$BASE/local/frame-state")
MIXED_OK=$(echo "$FRAME" | python3 -c "
import json,sys
d=json.load(sys.stdin)
byid={i['id']:i for i in d.get('items',[])}
errors=[]
a=byid.get('art_m1',{}).get('displayMs',0)
if a!=60000: errors.append(f'art should be 60000, got {a}')
b=byid.get('blog_m1',{}).get('displayMs',0)
if b!=30000: errors.append(f'blog should be 30000, got {b}')
n=byid.get('news_m1',{}).get('displayMs',0)
if n!=20000: errors.append(f'news should be 20000, got {n}')
c=byid.get('cur_m1',{}).get('displayMs',0)
if c!=45000: errors.append(f'curatorial should be 45000, got {c}')
bc=byid.get('bcast_m1',{}).get('displayMs',0)
if bc!=300000: errors.append(f'broadcast should be 300000, got {bc}')
if errors:
  for e in errors: print(e,file=sys.stderr)
  sys.exit(1)
print('OK')
" 2>/dev/null)
if [ "$MIXED_OK" = "OK" ]; then
  pass "Mixed content queue: each item type gets its own dwell time"
else
  fail "Mixed content queue dwell time mismatch"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
printf "\033[1;37m═══ feed-display-dwell-check ═══\033[0m\n"
printf "  Passed: \033[0;32m%d\033[0m  Failed: \033[0;31m%d\033[0m  Total: %d\n" "$PASS" "$FAIL" "$STEP"
if [ "$FAIL" -gt 0 ]; then
  echo "  STATUS: FAIL"
  exit 1
fi
echo "  STATUS: PASS"
exit 0
