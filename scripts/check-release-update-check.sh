#!/usr/bin/env bash
set -euo pipefail

# Isolated acceptance gate for scripts/check-release-update.sh.
# Uses the real node binary (for JSON parsing) and a mock curl that
# returns scripted responses from the local UI release endpoints.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE_NAME="check-release-update"

WORK_DIR=""
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

WORK_DIR="$(mktemp -d)"
DATA_DIR="$WORK_DIR/data"
LOG_DIR="$WORK_DIR/logs"
BIN_DIR="$WORK_DIR/bin"
mkdir -p "$DATA_DIR" "$LOG_DIR" "$BIN_DIR"

MOCK_CURL="$BIN_DIR/curl"
CURL_CALLS="$WORK_DIR/curl-calls.log"

# ── Mock curl ──
cat > "$MOCK_CURL" <<'CURL_EOF'
#!/usr/bin/env bash
RESP_DIR="${AUTOPOIESIS_MOCK_CURL_RESPONSES:-}"
CALLS_LOG="${AUTOPOIESIS_MOCK_CURL_LOG:-/dev/null}"

# Collect the last argument that looks like a URL
URL=""
for arg in "$@"; do
  case "$arg" in
    http://*|https://*) URL="$arg" ;;
  esac
done

echo "$(date -Is) $URL" >> "$CALLS_LOG"

if [[ "$URL" == */local/health ]]; then
  echo '{"ok":true,"status":"healthy"}'
  exit 0
fi

if [[ "$URL" == */local/release/check ]]; then
  if [[ -f "$RESP_DIR/check.json" ]]; then
    cat "$RESP_DIR/check.json"
    exit 0
  fi
  echo '{"ok":true,"release":null,"currentVersion":"0.1.0"}'
  exit 0
fi

if [[ "$URL" == */local/release/apply ]]; then
  if [[ -f "$RESP_DIR/apply.json" ]]; then
    cat "$RESP_DIR/apply.json"
    exit 0
  fi
  echo '{"ok":true,"version":"0.2.0"}'
  exit 0
fi

echo '{"ok":false}' >&2
exit 1
CURL_EOF
chmod +x "$MOCK_CURL"

run_subject() {
  local responses_dir="$1"
  shift
  rm -f "$LOG_DIR/update.log"
  AUTOPOIESIS_LOCAL_URL="http://127.0.0.1:3030" \
  AUTOPOIESIS_DATA_DIR="$DATA_DIR" \
  AUTOPOIESIS_LOG_DIR="$LOG_DIR" \
  AUTOPOIESIS_RELEASE_CURL_TIMEOUT=5 \
  AUTOPOIESIS_MOCK_CURL_LOG="$CURL_CALLS" \
  AUTOPOIESIS_MOCK_CURL_RESPONSES="$responses_dir" \
  PATH="$BIN_DIR:$PATH" \
  "$ROOT_DIR/scripts/check-release-update.sh" "$@"
}

log_has() {
  grep -q "$1" "$LOG_DIR/update.log" 2>/dev/null
}

echo "$GATE_NAME gate"

# ── Test 1: No curl available ──
echo "1. Skips when curl is unavailable"
rm -f "$LOG_DIR/update.log"
NO_CURL_DIR="$WORK_DIR/no-curl-bin"; mkdir -p "$NO_CURL_DIR"
# Provide a fake PATH with ls/bash/date but no curl
for cmd in bash date ls mkdir cat grep; do
  real="$(command -v "$cmd" 2>/dev/null || true)"
  [[ -n "$real" ]] && ln -sf "$real" "$NO_CURL_DIR/$cmd" 2>/dev/null || true
done
AUTOPOIESIS_DATA_DIR="$DATA_DIR" \
AUTOPOIESIS_LOG_DIR="$LOG_DIR" \
PATH="$NO_CURL_DIR" \
"$ROOT_DIR/scripts/check-release-update.sh" 2>/dev/null || true
if log_has 'skipped: curl unavailable'; then
  echo "  PASS: logged curl unavailable skip"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "  FAIL: expected curl unavailable log"
  cat "$LOG_DIR/update.log" 2>/dev/null || echo "  (no log)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ── Test 2: Auto-update disabled ──
echo "2. Skips when auto-update is disabled in device preferences"
cat > "$DATA_DIR/device.json" <<'EOF'
{"deviceId":"test-001","paired":true,"autoUpdate":false}
EOF
RESP_DIR="$WORK_DIR/responses/disabled"; mkdir -p "$RESP_DIR"
run_subject "$RESP_DIR"
if log_has 'auto-update disabled'; then
  echo "  PASS: logged auto-update disabled skip"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "  FAIL: expected auto-update disabled log"
  cat "$LOG_DIR/update.log" 2>/dev/null || echo "  (no log)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ── Test 3: No release available ──
echo "3. Completes when no update is available"
cat > "$DATA_DIR/device.json" <<'EOF'
{"deviceId":"test-001","paired":true,"autoUpdate":true}
EOF
RESP_DIR="$WORK_DIR/responses/no-update"; mkdir -p "$RESP_DIR"
cat > "$RESP_DIR/check.json" <<'EOF'
{"ok":true,"release":null,"currentVersion":"0.1.0"}
EOF
run_subject "$RESP_DIR"
if log_has 'no update available'; then
  echo "  PASS: logged no update available"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "  FAIL: expected no update available log"
  cat "$LOG_DIR/update.log" 2>/dev/null || echo "  (no log)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ── Test 4: Release available and applied ──
echo "4. Applies release when update is available"
cat > "$DATA_DIR/device.json" <<'EOF'
{"deviceId":"test-001","paired":true,"autoUpdate":true}
EOF
RESP_DIR="$WORK_DIR/responses/update-available"; mkdir -p "$RESP_DIR"
cat > "$RESP_DIR/check.json" <<'EOF'
{"ok":true,"release":{"version":"0.2.0","channel":"stable"}}
EOF
cat > "$RESP_DIR/apply.json" <<'EOF'
{"ok":true,"version":"0.2.0"}
EOF
run_subject "$RESP_DIR"
if log_has 'applied release 0.2.0'; then
  echo "  PASS: logged successful apply"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "  FAIL: expected applied release log"
  cat "$LOG_DIR/update.log" 2>/dev/null || echo "  (no log)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ── Test 5: Apply failure ──
echo "5. Reports failure when apply fails"
RESP_DIR="$WORK_DIR/responses/apply-fail"; mkdir -p "$RESP_DIR"
cat > "$RESP_DIR/check.json" <<'EOF'
{"ok":true,"release":{"version":"0.3.0","channel":"stable"}}
EOF
cat > "$RESP_DIR/apply.json" <<'EOF'
{"ok":false,"error":"checksum mismatch"}
EOF
if run_subject "$RESP_DIR" 2>/dev/null; then
  echo "  FAIL: expected non-zero exit from apply failure"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "  PASS: returned non-zero on apply failure"
  PASS_COUNT=$((PASS_COUNT + 1))
fi
if log_has 'release apply failed'; then
  echo "  PASS: logged apply failure"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "  FAIL: expected apply failure log"
  cat "$LOG_DIR/update.log" 2>/dev/null || echo "  (no log)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ── Test 6: Dry run ──
echo "6. Dry run reports but does not apply"
RESP_DIR="$WORK_DIR/responses/dry-run"; mkdir -p "$RESP_DIR"
cat > "$RESP_DIR/check.json" <<'EOF'
{"ok":true,"release":{"version":"0.4.0","channel":"stable"}}
EOF
cat > "$RESP_DIR/apply.json" <<'EOF'
{"ok":true,"version":"0.4.0"}
EOF
AUTOPOIESIS_RELEASE_CHECK_DRY_RUN=1 run_subject "$RESP_DIR"
if log_has 'dry-run: would apply release 0.4.0'; then
  echo "  PASS: logged dry-run would apply"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "  FAIL: expected dry-run log"
  cat "$LOG_DIR/update.log" 2>/dev/null || echo "  (no log)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ── Test 7: update.sh dispatches to check-release-update for non-git install ──
echo "7. update.sh dispatches to check-release-update for installed appliances"
MOCK_APP_DIR="$WORK_DIR/installed-app"
mkdir -p "$MOCK_APP_DIR"
cat > "$DATA_DIR/device.json" <<'EOF'
{"deviceId":"test-001","paired":true,"autoUpdate":true}
EOF
RESP_DIR="$WORK_DIR/responses/dispatch"; mkdir -p "$RESP_DIR"
cat > "$RESP_DIR/check.json" <<'EOF'
{"ok":true,"release":null,"currentVersion":"0.1.0"}
EOF
AUTOPOIESIS_APP_DIR="$MOCK_APP_DIR" \
AUTOPOIESIS_LOCAL_URL="http://127.0.0.1:3030" \
AUTOPOIESIS_DATA_DIR="$DATA_DIR" \
AUTOPOIESIS_LOG_DIR="$LOG_DIR" \
AUTOPOIESIS_RELEASE_CURL_TIMEOUT=5 \
AUTOPOIESIS_MOCK_CURL_LOG="$CURL_CALLS" \
AUTOPOIESIS_MOCK_CURL_RESPONSES="$RESP_DIR" \
PATH="$BIN_DIR:$PATH" \
"$ROOT_DIR/update.sh" 2>/dev/null
if log_has 'no update available'; then
  echo "  PASS: update.sh dispatched to check-release-update"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "  FAIL: expected check-release-update dispatch"
  cat "$LOG_DIR/update.log" 2>/dev/null || echo "  (no log)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

echo
echo "$GATE_NAME gate: $PASS_COUNT passed, $FAIL_COUNT failed"
if [[ $FAIL_COUNT -gt 0 ]]; then
  exit 1
fi
