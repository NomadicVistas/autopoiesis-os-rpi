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

# ── services ─────────────────────────────────────────────────────────────────

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

# ── offline state ────────────────────────────────────────────────────────────

STATE_JSON="$DATA_DIR/state.json"
STATE_OFFLINE="unknown"
if [[ -f "$STATE_JSON" ]]; then
  STATE_OFFLINE="$(node -e "
    try {
      const s = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
      process.stdout.write((s.offline && s.offline.active) ? 'active' : 'inactive');
    } catch(_) { process.stdout.write('unknown'); }
  " "$STATE_JSON" 2>/dev/null || echo "unknown")"
fi

if [[ "$STATE_OFFLINE" == "active" ]]; then
  check warn "offline_mode" "Device is in offline mode" "Check network connectivity"
elif [[ "$STATE_OFFLINE" == "inactive" ]]; then
  check pass "offline_mode" "Online mode"
else
  check skip "offline_mode" "State unknown"
fi

# ── recent errors ────────────────────────────────────────────────────────────

if [[ "$JSON" == "0" ]]; then echo ""; echo "Logs"; echo "----"; fi

if [[ "$QUICK" == "0" && -d "$LOG_DIR" ]]; then
  ERROR_COUNT=0
  for logfile in "$LOG_DIR"/*.log; do
    [[ -f "$logfile" ]] || continue
    local_errors="$(grep -ci 'error\|fail\|crash' "$logfile" 2>/dev/null || echo 0)"
    ERROR_COUNT=$((ERROR_COUNT + local_errors))
    if [[ "$VERBOSE" == "1" && "$local_errors" -gt 0 ]]; then
      echo "    $(basename "$logfile"): $local_errors lines"
    fi
  done
  if [[ "$ERROR_COUNT" -eq 0 ]]; then
    check pass "logs" "No recent errors in $LOG_DIR"
  elif [[ "$ERROR_COUNT" -lt 10 ]]; then
    check warn "logs" "$ERROR_COUNT error-indicating lines in logs"
  else
    check fail "logs" "$ERROR_COUNT error-indicating lines in logs" "Check: tail -50 $LOG_DIR/*.log"
  fi
else
  check skip "logs" "Skipped (--quick or no log directory)"
fi

# ── kiosk process ────────────────────────────────────────────────────────────

if [[ "$JSON" == "0" ]]; then echo ""; echo "Kiosk"; echo "-----"; fi

KIOSK_PROC="$(pgrep -af 'chromium.*--kiosk' 2>/dev/null || true)"
if [[ -n "$KIOSK_PROC" ]]; then
  if echo "$KIOSK_PROC" | grep -qF -- "--disable-gpu"; then
    check pass "kiosk_process" "Chromium kiosk running with Pi-safe flags"
  else
    check warn "kiosk_process" "Chromium kiosk running but may lack Pi-safe flags" \
      "Expected --disable-gpu"
  fi
else
  check fail "kiosk_process" "No Chromium kiosk process found" \
    "Check: systemctl status autopoiesis-kiosk.service"
fi

# ── summary ──────────────────────────────────────────────────────────────────

TOTAL=$((PASS + WARN + FAIL + SKIP))

if [[ "$JSON" == "0" ]]; then
  echo ""
  echo "==========================================="
  echo "Summary: $PASS pass, $WARN warn, $FAIL fail, $SKIP skip ($TOTAL total)"
  if [[ "$FAIL" -gt 0 ]]; then
    echo "Status:  ISSUES DETECTED"
  elif [[ "$WARN" -gt 0 ]]; then
    echo "Status:  HEALTHY WITH WARNINGS"
  else
    echo "Status:  ALL CHECKS PASSED"
  fi
  echo "==========================================="
fi

# ── JSON output (single node process) ────────────────────────────────────────

if [[ "$JSON" == "1" ]]; then
  # Write all collected data to a temp file; one node process builds the JSON.
  DATA_TMP="$(mktemp)"
  {
    # Scalar variables
    echo "VERSION=$VERSION"
    echo "PI_MODEL=$PI_MODEL"
    echo "TEMP=$TEMP"
    echo "DISK_TOTAL=${DISK_TOTAL:-unknown}"
    echo "DISK_USED=${DISK_USED:-unknown}"
    echo "DISK_AVAIL=${DISK_AVAIL_HUMAN:-unknown}"
    echo "DISK_PCT=${DISK_PCT:-unknown}"
    echo "MEM_AVAIL=${MEM_AVAIL:-unknown}"
    echo "MEM_TOTAL=${MEM_TOTAL:-unknown}"
    echo "CPU_LOAD=${CPU_LOAD:-unknown}"
    echo "UPTIME=${UPTIME:-unknown}"
    echo "NET_ONLINE=$NET_ONLINE"
    echo "NET_PRIMARY=${NET_PRIMARY:-none}"
    echo "DEVICE_ID=${DEVICE_ID:-unknown}"
    echo "PAIRED=${PAIRED:-false}"
    echo "LAST_HB=${LAST_HB:-never}"
    echo "CACHE_COUNT=${CACHE_COUNT}"
    echo "CACHE_SIZE=${CACHE_SIZE:-0}"
    echo "STATE_OFFLINE=${STATE_OFFLINE:-unknown}"
    echo "PASS=$PASS"
    echo "WARN=$WARN"
    echo "FAIL=$FAIL"
    echo "SKIP=$SKIP"
    echo "TOTAL=$TOTAL"
    echo "---CHECKS---"
    for entry in "${CHECKS[@]}"; do
      echo "$entry"
    done
  } > "$DATA_TMP"

  node - "$DATA_TMP" <<'NODEJS'
const fs = require('fs');
const lines = fs.readFileSync(process.argv[2], 'utf8').split('\n');
const vars = {};
const checks = [];
let inChecks = false;
for (const line of lines) {
  if (line === '---CHECKS---') { inChecks = true; continue; }
  if (inChecks) {
    const parts = line.split('|');
    if (parts.length >= 3) {
      checks.push({ status: parts[0], name: parts[1], message: parts[2], detail: parts[3] || '' });
    }
  } else {
    const eq = line.indexOf('=');
    if (eq > 0) vars[line.slice(0, eq)] = line.slice(eq + 1);
  }
}
const str = v => typeof v === 'string' ? v : String(v);
const bool = v => str(v) === 'true';
const num = (v, fb = 0) => { const n = Number(v); return Number.isFinite(n) ? n : fb; };
const r = {
  timestamp: new Date().toISOString().replace(/\.\d+Z$/, 'Z'),
  version: vars.VERSION || 'unknown',
  system: {
    model: vars.PI_MODEL || 'unknown',
    temperature: str(vars.TEMP || 'unknown') + '\u00B0C',
    disk: {
      total: str(vars.DISK_TOTAL || 'unknown'),
      used: str(vars.DISK_USED || 'unknown'),
      available: str(vars.DISK_AVAIL || 'unknown'),
      percent: str(vars.DISK_PCT || 'unknown')
    },
    memory: { available: str(vars.MEM_AVAIL || 'unknown'), total: str(vars.MEM_TOTAL || 'unknown') },
    cpuLoad: str(vars.CPU_LOAD || 'unknown'),
    uptime: str(vars.UPTIME || 'unknown')
  },
  network: { online: bool(vars.NET_ONLINE), primary: vars.NET_PRIMARY || 'none' },
  device: {
    id: vars.DEVICE_ID || 'unknown',
    paired: bool(vars.PAIRED),
    lastHeartbeat: vars.LAST_HB || 'never'
  },
  cache: { count: num(vars.CACHE_COUNT, 0), size: str(vars.CACHE_SIZE || '0') },
  offline: vars.STATE_OFFLINE || 'unknown',
  checks: {
    total: num(vars.TOTAL),
    pass: num(vars.PASS),
    warn: num(vars.WARN),
    fail: num(vars.FAIL),
    skip: num(vars.SKIP)
  },
  results: checks,
  healthy: num(vars.FAIL) === 0
};
process.stdout.write(JSON.stringify(r, null, 2) + '\n');
NODEJS
  rm -f "$DATA_TMP"
fi

# Exit code
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
