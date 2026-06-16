#!/usr/bin/env bash
# diagnostics.sh — standalone CLI health check for Autopoiesis Pi appliance
#
# Runs without the local UI server.  Safe to call from SSH when the
# appliance is unresponsive.  Produces a human-readable summary (default)
# or JSON output (--json).
#
# Usage:
#   sudo /opt/autopoiesis-os/app/scripts/diagnostics.sh
#   sudo /opt/autopoiesis-os/app/scripts/diagnostics.sh --json
#   sudo /opt/autopoiesis-os/app/scripts/diagnostics.sh --verbose
#   sudo /opt/autopoiesis-os/app/scripts/diagnostics.sh --quick
#
# Exit codes:
#   0  all checks passed (warnings are OK)
#   1  one or more checks failed
#   2  usage error
set -euo pipefail

APP_DIR="${AUTOPOIESIS_APP_DIR:-/opt/autopoiesis-os/app}"
INSTALL_DIR="${AUTOPOIESIS_INSTALL_DIR:-/opt/autopoiesis-os}"
DATA_DIR="${AUTOPOIESIS_DATA_DIR:-/var/lib/autopoiesis-os}"
LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"
LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"
SYSTEMCTL="${AUTOPOIESIS_SYSTEMCTL_BIN:-systemctl}"
USER_NAME="${AUTOPOIESIS_USER:-frame}"

JSON=0
VERBOSE=0
QUICK=0

for arg in "$@"; do
  case "$arg" in
    --json)       JSON=1 ;;
    --verbose|-v) VERBOSE=1 ;;
    --quick|-q)   QUICK=1 ;;
    -h|--help)
      cat <<'HELP'
Usage: diagnostics.sh [--json] [--verbose] [--quick]

Standalone health check for Autopoiesis Pi appliance.
Safe to run from SSH when the local UI server is down.

Options:
  --json      JSON output for programmatic consumption
  --verbose   Show full details for every check
  --quick     Skip slow checks (log scan, DNS resolution)
  -h, --help  Show this help
HELP
      exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

# ── helpers ──────────────────────────────────────────────────────────────────

PASS=0; WARN=0; FAIL=0; SKIP=0
CHECKS=()   # "status|name|message|detail" lines collected for JSON output

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

jf() {
  local file="$1" field="$2" fallback="${3:-}"
  if [[ -f "$file" ]]; then
    node -e "
      try {
        const v = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))[process.argv[2]];
        process.stdout.write(v === undefined || v === null ? process.argv[3] : String(v));
      } catch(_) { process.stdout.write(process.argv[3]); }
    " "$file" "$field" "$fallback" 2>/dev/null || printf '%s' "$fallback"
  else
    printf '%s' "$fallback"
  fi
}

check() {
  local status="$1" name="$2" message="$3" detail="${4:-}"
  case "$status" in
    pass) PASS=$((PASS + 1)) ;;
    warn) WARN=$((WARN + 1)) ;;
    fail) FAIL=$((FAIL + 1)) ;;
    skip) SKIP=$((SKIP + 1)) ;;
  esac
  CHECKS+=("${status}|${name}|${message}|${detail}")
  if [[ "$JSON" == "0" ]]; then
    local icon
    case "$status" in
      pass) icon="✓" ;;
      warn) icon="⚠" ;;
      fail) icon="✗" ;;
      skip) icon="○" ;;
    esac
    printf '  %s %-24s %s\n' "$icon" "$name" "$message"
    if [[ "$VERBOSE" == "1" && -n "$detail" ]]; then
      printf '    %s\n' "$detail"
    fi
  fi
}

svc_active() {
  local svc="$1"
  if ! command -v "$SYSTEMCTL" >/dev/null 2>&1; then
    printf 'unknown'; return
  fi
  local s
  s="$($SYSTEMCTL is-active "$svc" 2>/dev/null)" || true
  printf '%s' "${s:-not_found}"
}

num_ge() {
  [[ "${1:-0}" =~ ^[0-9]+$ ]] && [[ "${2:-0}" =~ ^[0-9]+$ ]] && (( $1 >= $2 ))
}

# ── collect system data ─────────────────────────────────────────────────────

PI_MODEL="unknown"
[[ -f /proc/device-tree/model ]] && PI_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"

TEMP="unknown"
[[ -r /sys/class/thermal/thermal_zone0/temp ]] && TEMP="$(awk '{ printf "%.1f", $1/1000 }' /sys/class/thermal/thermal_zone0/temp)"

DISK_PCT_NUM=0; DISK_AVAIL_HUMAN=""
DISK_TOTAL=""; DISK_USED=""; DISK_AVAIL=""; DISK_PCT=""
if df -Pm / >/dev/null 2>&1; then
  read -r DISK_USED DISK_TOTAL DISK_AVAIL DISK_PCT <<< "$(df -Pm / | awk 'NR==2{print $3,$2,$4,$5}')"
  DISK_AVAIL_HUMAN="${DISK_AVAIL}MB"
  DISK_PCT_NUM="$(echo "$DISK_PCT" | tr -d '%')"
  DISK_HUMAN="${DISK_USED}MB / ${DISK_TOTAL}MB (${DISK_PCT} used, ${DISK_AVAIL}MB free)"
else
  DISK_HUMAN="unknown"
fi

MEM_AVAIL="unknown" MEM_TOTAL="unknown"
[[ -r /proc/meminfo ]] && {
  MEM_AVAIL="$(awk '/MemAvailable/ {printf "%.0fMB", $2/1024}' /proc/meminfo)"
  MEM_TOTAL="$(awk '/MemTotal/ {printf "%.0fMB", $2/1024}' /proc/meminfo)"
}

UPTIME="unknown"
[[ -r /proc/uptime ]] && UPTIME="$(awk '{printf "%.0f min", $1/60}' /proc/uptime)"

CPU_LOAD="unknown"
[[ -r /proc/loadavg ]] && CPU_LOAD="$(awk '{print $1, $2, $3}' /proc/loadavg)"

VERSION="unknown"
[[ -f "$APP_DIR/VERSION" ]] && VERSION="$(tr -d '\n' < "$APP_DIR/VERSION")"

# ── human output header ─────────────────────────────────────────────────────

if [[ "$JSON" == "0" ]]; then
  echo "Autopoiesis Frame Diagnostics"
  echo "=============================="
  echo "Time: $(ts)"
  echo ""
  echo "System"
  echo "------"
  echo "  Model:    $PI_MODEL"
  echo "  Version:  $VERSION"
  echo "  Temp:     ${TEMP}°C"
  echo "  Disk:     $DISK_HUMAN"
  echo "  Memory:   $MEM_AVAIL available / $MEM_TOTAL total"
  echo "  CPU load: $CPU_LOAD"
  echo "  Uptime:   $UPTIME"
  echo ""
fi

# ── system checks ───────────────────────────────────────────────────────────

if num_ge "$DISK_PCT_NUM" 90; then
  check fail "disk_space" "Disk is ${DISK_PCT}% full" "$DISK_AVAIL_HUMAN available"
elif num_ge "$DISK_PCT_NUM" 75; then
  check warn "disk_space" "Disk is ${DISK_PCT}% full" "$DISK_AVAIL_HUMAN available"
elif num_ge "$DISK_PCT_NUM" 1; then
  check pass "disk_space" "Disk usage ${DISK_PCT}" "$DISK_AVAIL_HUMAN available"
else
  check skip "disk_space" "Disk info unavailable"
fi

TEMP_NUM=""
[[ "$TEMP" != "unknown" ]] && TEMP_NUM="$(echo "$TEMP" | grep -oP '[\d.]+' || true)"
if [[ -n "$TEMP_NUM" ]]; then
  TEMP_INT="$(printf '%.0f' "$TEMP_NUM")"
  if num_ge "$TEMP_INT" 80; then
    check fail "cpu_temp" "CPU temperature ${TEMP}°C" "Throttling likely"
  elif num_ge "$TEMP_INT" 70; then
    check warn "cpu_temp" "CPU temperature ${TEMP}°C" "Approaching throttle threshold"
  else
    check pass "cpu_temp" "CPU temperature ${TEMP}°C"
  fi
else
  check skip "cpu_temp" "Temperature not available"
fi

# ── appliance target ────────────────────────────────────────────────────────

TARGET_STATUS="unknown"
if [[ "$JSON" == "0" ]]; then echo ""; echo "Appliance"; echo "--------"; fi

ts="$(svc_active autopoiesis.target)"
TARGET_STATUS="$ts"
case "$ts" in
  active) check pass "appliance_target" "Autopoiesis appliance: active" "All services and timers under autopoiesis.target are running" ;;
  inactive)
    check fail "appliance_target" "Autopoiesis appliance: inactive" \
      "Target unit stopped. Run: sudo systemctl start autopoiesis.target" ;;
  failed)
    check fail "appliance_target" "Autopoiesis appliance: failed" \
      "One or more units in the target failed. Run: systemctl --failed" ;;
  not_found)
    check warn "appliance_target" "Autopoiesis appliance: target not installed" \
      "autopoiesis.target may not be deployed yet on this device" ;;
  *)
    check warn "appliance_target" "Autopoiesis appliance: $ts" ;;
esac

# ── services ────────────────────────────────────────────────────────────────

if [[ "$JSON" == "0" ]]; then echo ""; echo "Services"; echo "--------"; fi

SERVICE_LIST=(
  "autopoiesis-setup.service|Setup UI"
  "autopoiesis-kiosk.service|Kiosk"
  "autopoiesis-heartbeat.timer|Heartbeat"
  "autopoiesis-command-executor.timer|Command executor"
  "autopoiesis-updater.timer|Updater"
  "autopoiesis-cache.timer|Cache"
  "autopoiesis-watchdog.timer|Watchdog"
  "autopoiesis-night-mode.timer|Night mode"
)

for entry in "${SERVICE_LIST[@]}"; do
  IFS='|' read -r svc label <<< "$entry"
  s="$(svc_active "$svc")"
  case "$s" in
    active) check pass "svc_${svc}" "${label}: active" ;;
    inactive)
      if [[ "$svc" == *.timer ]]; then
        check warn "svc_${svc}" "${label}: inactive" "Timer may be between runs or stopped"
      else
        check fail "svc_${svc}" "${label}: inactive"
      fi ;;
    failed) check fail "svc_${svc}" "${label}: failed" "Run: journalctl -u $svc -n 30" ;;
    not_found) check warn "svc_${svc}" "${label}: not installed" ;;
    *)      check warn "svc_${svc}" "${label}: $s" ;;
  esac
done

# ── enhanced service checks for kiosk and local UI ──────────────────────────

if [[ "$JSON" == "0" ]]; then echo ""; echo "Service Health"; echo "--------------"; fi

# Check if kiosk service is actually running the local UI
KIOSK_STATUS="$(svc_active autopoiesis-kiosk.service)"
if [[ "$KIOSK_STATUS" == "active" ]]; then
  # Check if the process is actually running
  if pgrep -f "local-ui/server.js" >/dev/null 2>&1; then
    check pass "kiosk_process" "Kiosk process running" "local-ui/server.js is active"
  else
    check warn "kiosk_process" "Kiosk service active but UI process not found" "Check logs for startup errors"
  fi
else
  check warn "kiosk_process" "Kiosk service not active" "Kiosk will not start UI"
fi

# Check if local UI port is listening
if command -v netstat >/dev/null 2>&1 || command -v ss >/dev/null 2>&1; then
  if command -v ss >/dev/null 2>&1; then
    if ss -tlnp | grep -q ":3030 "; then
      check pass "local_ui_port" "Local UI port 3030 listening" "Ready to serve kiosk interface"
    else
      check warn "local_ui_port" "Local UI port 3030 not listening" "Kiosk service may have failed to start UI"
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if netstat -tlnp | grep -q ":3030 "; then
      check pass "local_ui_port" "Local UI port 3030 listening" "Ready to serve kiosk interface"
    else
      check warn "local_ui_port" "Local UI port 3030 not listening" "Kiosk service may have failed to start UI"
    fi
  fi
else
  check skip "local_ui_port" "Port check tools not available"
fi

# ── network ──────────────────────────────────────────────────────────────────

if [[ "$JSON" == "0" ]]; then echo ""; echo "Network"; echo "-------"; fi

NET_ONLINE=false
NET_PRIMARY="none"
if command -v nmcli >/dev/null 2>&1; then
  NET_STATE="$(nmcli -t -f STATE general status 2>/dev/null || echo "unknown")"
  if [[ "$NET_STATE" == *"connected"* ]]; then
    NET_ONLINE=true
    NET_PRIMARY="$(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null \
      | awk -F: '$3=="connected"{print $1; exit}' || echo "unknown")"
    check pass "network" "Online via $NET_PRIMARY"
  else
    check fail "network" "Offline ($NET_STATE)" "Run: nmcli device wifi list"
  fi
else
  if curl -fsS --max-time 3 http://connectivity-check.ubuntu.com >/dev/null 2>&1; then
    NET_ONLINE=true
    check pass "network" "Online (connectivity check passed)"
  else
    check fail "network" "Offline or no connectivity check"
  fi
fi

if [[ "$QUICK" == "0" ]]; then
  if host autopoiesis.art >/dev/null 2>&1; then
    check pass "dns" "autopoiesis.art resolves"
  else
    check warn "dns" "autopoiesis.art does not resolve" "Check DNS settings"
  fi
else
  check skip "dns" "Skipped (--quick)"
fi

# ── local UI server ──────────────────────────────────────────────────────────

if [[ "$JSON" == "0" ]]; then echo ""; echo "Local UI"; echo "--------"; fi

if curl -fsS --max-time 4 "$LOCAL_URL/local/health" >/dev/null 2>&1; then
  check pass "local_ui" "Server responding on $LOCAL_URL"
  if [[ "$VERBOSE" == "1" ]]; then
    curl -fsS --max-time 4 "$LOCAL_URL/local/health?services=1" 2>/dev/null \
      | node -e "
        try {
          const h = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
          if (h.health && h.health.items) {
            h.health.items.forEach(i => {
              const icon = i.status==='healthy'?'  ✓':i.status==='warning'?'  ⚠':'  ✗';
              console.log(icon+' '+i.id+': '+(i.message||i.status));
            });
          }
        } catch(_) {}
      " 2>/dev/null || true
  fi
else
  check fail "local_ui" "Server not responding on $LOCAL_URL" \
    "Check: systemctl status autopoiesis-setup.service"
fi

# ── enhanced local UI checks ────────────────────────────────────────────────

if [[ "$JSON" == "0" ]]; then echo ""; echo "Local UI Content"; echo "----------------"; fi

# Check if the local UI serves the actual kiosk interface
if curl -fsS --max-time 4 "$LOCAL_URL/" >/dev/null 2>&1; then
  # Check if it returns HTML (basic check)
  if curl -fsS --max-time 4 "$LOCAL_URL/" 2>/dev/null | grep -q "<!DOCTYPE html\|<html\|<body"; then
    check pass "local_ui_content" "Serves HTML content" "Kiosk interface likely available"
  else
    check warn "local_ui_content" "Server responding but not HTML" "May be serving API only or error"
  fi
else
  check fail "local_ui_content" "Cannot retrieve kiosk interface" "Check local UI server logs"
fi

# Check for common UI errors in logs (if not quick)
if [[ "$QUICK" == "0" ]]; then
  UI_LOG="$LOG_DIR/local-ui.service.log"
  if [[ -f "$UI_LOG" ]]; then
    if grep -i "error\|fail\|panic" "$UI_LOG" | tail -5 | grep -v "npm info" >/dev/null 2>&1; then
      check warn "local_ui_errors" "Recent errors in local UI log" "Check $UI_LOG for details"
    else
      check pass "local_ui_errors" "No recent errors in local UI log" ""
    fi
  else
    check skip "local_ui_errors" "Local UI log not found"
  fi
else
  check skip "local_ui_errors" "Skipped (--quick)"
fi

# ── device state ─────────────────────────────────────────────────────────────

if [[ "$JSON" == "0" ]]; then echo ""; echo "Device"; echo "------"; fi

DEVICE_JSON="$DATA_DIR/device.json"
if [[ -f "$DEVICE_JSON" ]]; then
  DEVICE_ID="$(jf "$DEVICE_JSON" deviceId unknown)"
  PAIRED="$(jf "$DEVICE_JSON" paired false)"
  LAST_HB="$(jf "$DEVICE_JSON" lastHeartbeatAt never)"
  check pass "device_id" "Device registered ($DEVICE_ID)"
  if [[ "$PAIRED" == "true" ]]; then
    check pass "pairing" "Device is paired"
  else
    check warn "pairing" "Device is not paired" "Visit /setup on the touchscreen"
  fi
  if [[ "$LAST_HB" != "never" && -n "$LAST_HB" ]]; then
    check pass "last_heartbeat" "Last heartbeat: $LAST_HB"
  else
    check warn "last_heartbeat" "No heartbeat recorded"
  fi
else
  check fail "device_id" "device.json not found" "Run: bootstrap.sh"
  DEVICE_ID="unknown"; PAIRED="false"; LAST_HB="never"
fi

# ── cache state ──────────────────────────────────────────────────────────────

if [[ "$JSON" == "0" ]]; then echo ""; echo "Cache"; echo "-----"; fi

CACHE_INDEX="$DATA_DIR/cache-index.json"
CACHE_DIR="$INSTALL_DIR/cache/artworks"
CACHE_COUNT=0
CACHE_SIZE="0"

if [[ -f "$CACHE_INDEX" ]]; then
  CACHE_COUNT="$(node -e "
    try {
      const idx = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
      const items = Array.isArray(idx) ? idx : (idx.items || []);
      process.stdout.write(String(items.length));
    } catch(_) { process.stdout.write('0'); }
  " "$CACHE_INDEX" 2>/dev/null || echo 0)"
fi
[[ -d "$CACHE_DIR" ]] && CACHE_SIZE="$(du -sh "$CACHE_DIR" 2>/dev/null | awk '{print $1}' || echo "unknown")"

if [[ "$CACHE_COUNT" -gt 0 ]]; then
  check pass "cache" "$CACHE_COUNT artworks cached (${CACHE_SIZE})"
else
  check warn "cache" "No artworks cached" "Art will not display during offline mode"
fi

# ── enhanced system checks ──────────────────────────────────────────────────

if [[ "$JSON" == "0" ]]; then echo ""; echo "System Checks"; echo "-------------"; fi

# Check if factory reset script exists and is executable
if [[ -x "$INSTALL_DIR/factory-reset.sh" ]]; then
  check pass "factory_reset_script" "Factory reset script available" "Ready for emergency recovery"
else
  check fail "factory_reset_script" "Factory reset script missing or not executable" "System recovery compromised"
fi

# Check if update script exists and is executable
if [[ -x "$INSTALL_DIR/update.sh" ]]; then
  check pass "update_script" "Update script available" "Ready for OTA updates"
else
  check fail "update_script" "Update script missing or not executable" "OTA updates disabled"
fi

# Check if install.sh exists and is executable
if [[ -x "$INSTALL_DIR/install.sh" ]]; then
  check pass "install_script" "Install script available" "Ready for reinstallation"
else
  check warn "install_script" "Install script missing or not executable" "Reinstallation may be difficult"
fi

# Check for port conflicts on 3030
if command -v lsof >/dev/null 2>&1 || command -v fuser >/dev/null 2>&1; then
  if command -v lsof >/dev/null 2>&1; then
    if lsof -i:3030 >/dev/null 2>&1; then
      # Check if it's our process
      if lsof -i:3030 | grep -q "node\|local-ui"; then
        check pass "port_3030" "Port 3030 in use by Autopoiesis" "Correct process listening"
      else
          check warn "port_3030" "Port 3030 in use by another process" "Possible conflict with local UI"
      fi
    else
        check pass "port_3030" "Port 3030 available" "Ready for local UI"
    fi
  elif command -v fuser >/dev/null 2>&1; then
    if fuser 3030/tcp >/dev/null 2>&1; then
        check warn "port_3030" "Port 3030 in use" "Check if it's the local UI server"
    else
        check pass "port_3030" "Port 3030 available" "Ready for local UI"
    fi
  fi
else
    check skip "port_3030" "Port check tools not available"
fi

# ── feed sync health ────────────────────────────────────────────────────────

if [[ "$JSON" == "0" ]]; then echo ""; echo "Feed Sync"; echo "---------"; fi

FEED_JSON="$DATA_DIR/feed.json"
if [[ -f "$FEED_JSON" ]]; then
  SYNCED_AT="$(jf "$FEED_JSON" syncedAt never)"
  ITEM_COUNT="$(jf "$FEED_JSON" items 0 | wc -l)"
  # Adjust item count if it's an array
  if [[ "$ITEM_COUNT" == "0" ]]; then
    ITEM_COUNT="$(node -e "
      try {
        const feed = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
        const items = Array.isArray(feed.items) ? feed.items : [];
        process.stdout.write(String(items.length));
      } catch(_) { process.stdout.write('0'); }
    " "$FEED_JSON" 2>/dev/null || echo 0)"
  fi
  
  if [[ "$SYNCED_AT" != "never" && -n "$SYNCED_AT" ]]; then
    check pass "feed_sync" "Feed synced: $SYNCED_AT ($ITEM_COUNT items)" ""
  else
      check warn "feed_sync" "Feed not synced" "Device may show stale or no content"
  fi
else
    check warn "feed_sync" "feed.json not found" "Run bootstrap.sh or check network"
fi

# ── offline fallback ────────────────────────────────────────────────────────

if [[ "$JSON" == "0" ]]; then echo ""; echo "Offline Fallback"; echo "----------------"; fi

STATE_JSON="$DATA_DIR/state.json"
if [[ -f "$STATE_JSON" ]]; then
  OFFLINE_ACTIVE="$(jf "$STATE_JSON" offline.active false)"
  if [[ "$OFFLINE_ACTIVE" == "true" ]]; then
    OFFLINE_SINCE="$(jf "$STATE_JSON" offline.since unknown)"
    check warn "offline_mode" "Running in offline mode since $OFFLINE_SINCE" "Content from cache only"
  else
      check pass "offline_mode" "Online mode active" ""
  fi
else
    check skip "offline_mode" "state.json not found"
fi

# ── summary ──────────────────────────────────────────────────────────────────

if [[ "$JSON" == "1" ]]; then
  # JSON output
  printf '{"timestamp":"%s","summary":{"pass":%d,"warn":%d,"fail":%d,"skip":%d},"checks":[', "$(ts)" "$PASS" "$WARN" "$FAIL" "$SKIP"
  for i in "${!CHECKS[@]}"; do
    IFS='|' read -r status name message detail <<< "${CHECKS[$i]}"
    printf '{"status":"%s","name":"%s","message":"%s","detail":"%s"}' "$status" "$name" "$message" "$detail"
    if [[ $i -lt $(( ${#CHECKS[@]} - 1 )) ]]; then
      printf ','
    fi
  done
  printf ']}\n'
else
  # Human readable output
  echo ""
  echo "Summary"
  echo "-------"
  if [[ $FAIL -eq 0 ]]; then
    if [[ $WARN -eq 0 ]]; then
      echo "All checks passed ($PASS checks)"
    else
      echo "$PASS passed, $WARN warnings ($((PASS+WARN)) checks total)"
    fi
  else
    echo "$PASS passed, $WARN warnings, $FAIL failures ($((PASS+WARN+FAIL)) checks total)"
  fi
fi

exit $FAIL