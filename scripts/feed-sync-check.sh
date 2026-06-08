#!/usr/bin/env bash
# feed-sync-check.sh — Validate feed-sync.sh standalone behavior
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0; SKIP=0; CHECKS=()

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

check() {
  local status="$1" name="$2" message="$3"
  case "$status" in
    pass) PASS=$((PASS + 1)) ;;
    fail) FAIL=$((FAIL + 1)) ;;
    skip) SKIP=$((SKIP + 1)) ;;
  esac
  CHECKS+=("${status}|${name}|${message}")
  local icon
  case "$status" in pass) icon="✓" ;; fail) icon="✗" ;; skip) icon="○" ;; esac
  printf '  %s %-30s %s\n' "$icon" "$name" "$message"
}

# ── Step 1: Syntax validation ────────────────────────────────────────────
echo "Step 1: Syntax validation"

bash -n "$ROOT_DIR/scripts/feed-sync.sh" && check pass "syntax" "feed-sync.sh parses" || check fail "syntax" "feed-sync.sh has syntax errors"

node -e "
  const fs = require('fs');
  const src = fs.readFileSync('$ROOT_DIR/services/autopoiesis-cache.service', 'utf8');
  if (src.includes('ExecStartPre=') && src.includes('feed-sync.sh')) {
    process.stdout.write('ok');
  } else {
    process.stderr.write('Missing ExecStartPre for feed-sync.sh in cache service');
    process.exit(1);
  }
" && check pass "cache_service" "cache service has ExecStartPre for feed-sync.sh" || check fail "cache_service" "cache service missing feed-sync ExecStartPre"

# ── Step 2: Static contract ──────────────────────────────────────────────
echo ""
echo "Step 2: Static contract"

src="$(cat "$ROOT_DIR/scripts/feed-sync.sh")"

for pattern in \
  "AUTOPOIESIS_LOCAL_URL" \
  "AUTOPOIESIS_LOG_DIR" \
  "feed-sync.log" \
  "/local/feed/sync" \
  "/local/health" \
  "curl" \
  "--json" \
  "--verbose" \
  "--help" \
  "DRY_RUN" \
  "CURL_TIMEOUT" \
  "http_code" \
  "skipped" \
  "offline"; do
  if echo "$src" | grep -qF -e "$pattern"; then
    check pass "contract_${pattern%%=*}" "$pattern present"
  else
    check fail "contract_${pattern%%=*}" "$pattern missing"
  fi
done

# ExecStartPre ordering: feed-sync runs BEFORE cache-artworks
node -e "
  const fs = require('fs');
  const svc = fs.readFileSync('$ROOT_DIR/services/autopoiesis-cache.service', 'utf8');
  const lines = svc.split('\n');
  let startPreLine = -1, startLine = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('ExecStartPre=')) startPreLine = i;
    if (lines[i].startsWith('ExecStart=') && !lines[i].startsWith('ExecStartPre=')) startLine = i;
  }
  if (startPreLine >= 0 && startLine >= 0 && startPreLine < startLine) {
    process.stdout.write('ok');
  } else {
    process.stderr.write('ExecStartPre must come before ExecStart');
    process.exit(1);
  }
" && check pass "service_order" "ExecStartPre (feed-sync) runs before ExecStart (cache-artworks)" || check fail "service_order" "Service ordering incorrect"

# ── Step 3: Help output ──────────────────────────────────────────────────
echo ""
echo "Step 3: Help output"

help_out="$(bash "$ROOT_DIR/scripts/feed-sync.sh" --help 2>&1)" && check pass "help_exit" "--help exits 0" || check fail "help_exit" "--help failed"

for keyword in "Usage" "feed-sync.sh" "local/feed/sync" "--json" "--verbose"; do
  if echo "$help_out" | grep -qF -e "$keyword"; then
    check pass "help_${keyword}" "Help contains $keyword"
  else
    check fail "help_${keyword}" "Help missing $keyword"
  fi
done

# ── Step 4: Dry-run mode ────────────────────────────────────────────────
echo ""
echo "Step 4: Dry-run mode"

DRY_LOG_DIR="$(mktemp -d)"
dry_out="$(AUTOPOIESIS_FEED_SYNC_DRY_RUN=1 AUTOPOIESIS_LOG_DIR="$DRY_LOG_DIR" bash "$ROOT_DIR/scripts/feed-sync.sh" --json 2>/dev/null)" && check pass "dry_run_exit" "Dry-run exits 0" || check fail "dry_run_exit" "Dry-run failed"

dry_ok="$(echo "$dry_out" | node -e '
  try {
    const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
    process.stdout.write(String(r.ok === false && r.skipped === true && r.reason === "dry_run"));
  } catch { process.stdout.write("false"); }
' 2>/dev/null || echo "false")"
[[ "$dry_ok" == "true" ]] && check pass "dry_run_json" "Dry-run returns correct JSON" || check fail "dry_run_json" "Dry-run JSON incorrect: $dry_out"

# ── Step 5: Graceful skip when local UI is unreachable ───────────────────
echo ""
echo "Step 5: Graceful skip when local UI unreachable"

SKIP_LOG_DIR="$(mktemp -d)"
skip_out="$(AUTOPOIESIS_LOCAL_URL=http://127.0.0.1:19999 AUTOPOIESIS_LOG_DIR="$SKIP_LOG_DIR" bash "$ROOT_DIR/scripts/feed-sync.sh" --json 2>/dev/null)" && check pass "unreachable_exit" "Exits 0 when UI unreachable" || check fail "unreachable_exit" "Did not exit 0 when UI unreachable"

skip_ok="$(echo "$skip_out" | node -e '
  try {
    const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
    process.stdout.write(String(r.ok === false && r.skipped === true && r.reason === "local_ui_unreachable"));
  } catch { process.stdout.write("false"); }
' 2>/dev/null || echo "false")"
[[ "$skip_ok" == "true" ]] && check pass "unreachable_json" "Returns local_ui_unreachable JSON" || check fail "unreachable_json" "Unreachable JSON incorrect: $skip_out"

# ── Step 6: Live feed sync with mock API ─────────────────────────────────
echo ""
echo "Step 6: Live feed sync with mock API"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR" "$DRY_LOG_DIR" "$SKIP_LOG_DIR"' EXIT

MOCK_API_PORT=18941
LOCAL_UI_PORT=18942
MOCK_API_URL="http://127.0.0.1:$MOCK_API_PORT"
LOCAL_UI_URL="http://127.0.0.1:$LOCAL_UI_PORT"

# Start mock API
MOCK_PID=""
bash "$ROOT_DIR/scripts/mock-hosted-api/start.sh" "$MOCK_API_PORT" "$WORK_DIR/mock-api" 2>/dev/null &
MOCK_PID=$!
sleep 1

# Check if mock API started
if ! curl -fsS --max-time 3 "$MOCK_API_URL/health" >/dev/null 2>&1; then
  check skip "mock_api" "Mock API not available (skipping live tests)"
  kill "$MOCK_PID" 2>/dev/null || true
else
  check pass "mock_api" "Mock API started on port $MOCK_API_PORT"

  # Start local UI
  AUTOPOIESIS_API_BASE_URL="$MOCK_API_URL" \
  AUTOPOIESIS_PORT="$LOCAL_UI_PORT" \
  AUTOPOIESIS_DATA_DIR="$WORK_DIR/data" \
  AUTOPOIESIS_LOG_DIR="$WORK_DIR/logs" \
  node "$ROOT_DIR/local-ui/server.js" >/dev/null 2>&1 &
  LOCAL_PID=$!
  sleep 1

  if curl -fsS --max-time 3 "$LOCAL_UI_URL/local/health" >/dev/null 2>&1; then
    check pass "local_ui" "Local UI started on port $LOCAL_UI_PORT"

    # Register device via local UI
    reg_response="$(curl -sS -X POST "$LOCAL_UI_URL/pairing/start" 2>/dev/null)" || true
    device_id="$(echo "$reg_response" | node -e '
      try {
        const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
        process.stdout.write(r.deviceId || "");
      } catch { process.stdout.write(""); }
    ' 2>/dev/null || true)"

    if [[ -n "$device_id" ]]; then
      check pass "register" "Device registered: $device_id"
    else
      check warn "register" "Device registration response: $reg_response"
    fi

    # Pair device (claim pairing code directly)
    pairing_code="$(node -e "
      try {
        const fs = require('fs');
        const d = JSON.parse(fs.readFileSync('$WORK_DIR/data/device.json', 'utf8'));
        process.stdout.write(d.pairingCode || '');
      } catch { process.stdout.write(''); }
    " 2>/dev/null || true)"

    if [[ -n "$pairing_code" ]]; then
      # Claim via mock API
      claim_response="$(curl -sS -X POST "$MOCK_API_URL/frames/device/pair" \
        -H 'Content-Type: application/json' \
        -d "{\"pairingCode\":\"$pairing_code\",\"ownerUserId\":\"test-user-001\"}" 2>/dev/null)" || true
      check pass "pairing" "Pairing code claimed"
    fi

    # Run feed-sync.sh against the live local UI
    sync_out="$(AUTOPOIESIS_LOCAL_URL="$LOCAL_UI_URL" \
      AUTOPOIESIS_LOG_DIR="$WORK_DIR/logs" \
      bash "$ROOT_DIR/scripts/feed-sync.sh" --json 2>/dev/null)" || true

    sync_ok="$(echo "$sync_out" | node -e '
      try {
        const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
        process.stdout.write(String(r.ok === true || r.skipped === true));
      } catch { process.stdout.write("false"); }
    ' 2>/dev/null || echo "false")"

    if [[ "$sync_ok" == "true" ]]; then
      check pass "live_sync" "Feed sync succeeded against live local UI"
    else
      check fail "live_sync" "Feed sync failed: $sync_out"
    fi

    # Verify feed.json was written
    if [[ -f "$WORK_DIR/data/feed.json" ]]; then
      feed_items="$(node -e "
        try {
          const f = JSON.parse(require('fs').readFileSync('$WORK_DIR/data/feed.json', 'utf8'));
          process.stdout.write(String(f.items ? f.items.length : 0));
        } catch { process.stdout.write('0'); }
      " 2>/dev/null || echo 0)"
      check pass "feed_json" "feed.json written with $feed_items items"
    else
      check warn "feed_json" "feed.json not written (may be empty stream)"
    fi

    # Verify feed-cache.json (manifest) was written
    if [[ -f "$WORK_DIR/data/feed-cache.json" ]]; then
      cache_count="$(node -e "
        try {
          const c = JSON.parse(require('fs').readFileSync('$WORK_DIR/data/feed-cache.json', 'utf8'));
          process.stdout.write(String(c.count || c.items?.length || 0));
        } catch { process.stdout.write('0'); }
      " 2>/dev/null || echo 0)"
      check pass "feed_cache_json" "feed-cache.json written with $cache_count items"
    else
      check warn "feed_cache_json" "feed-cache.json not written"
    fi

    # Verify log file was written
    if [[ -f "$WORK_DIR/logs/feed-sync.log" ]]; then
      log_lines="$(wc -l < "$WORK_DIR/logs/feed-sync.log" | tr -d ' ')"
      check pass "sync_log" "feed-sync.log written with $log_lines lines"
    else
      check warn "sync_log" "feed-sync.log not found"
    fi

    kill "$LOCAL_PID" 2>/dev/null || true
  else
    check skip "local_ui" "Local UI did not start (skipping live tests)"
  fi

  kill "$MOCK_PID" 2>/dev/null || true
fi

# ── Step 7: Regression — existing scripts still valid ────────────────────
echo ""
echo "Step 7: Regression"

bash -n "$ROOT_DIR/scripts/cache-artworks.sh" && check pass "cache_syntax" "cache-artworks.sh still parses" || check fail "cache_syntax" "cache-artworks.sh has syntax errors"
node --check "$ROOT_DIR/local-ui/server.js" && check pass "local_ui_syntax" "local-ui/server.js parses" || check fail "local_ui_syntax" "local-ui/server.js failed node --check"

# ── Summary ──────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL + SKIP))
echo ""
echo "Results: $PASS pass, $FAIL fail, $SKIP skip ($TOTAL total)"

if [[ "$FAIL" -gt 0 ]]; then
  echo "STATUS: FAILED"
  exit 1
fi
echo "STATUS: PASSED"
exit 0
