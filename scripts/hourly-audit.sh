#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${AUTOPOIESIS_AUDIT_LOG_DIR:-$ROOT_DIR/logs}"
mkdir -p "$LOG_DIR"
OUT="$LOG_DIR/hourly-audit-$(date +%Y%m%dT%H%M%S).log"

{
  echo "Autopoiesis OS hourly audit"
  echo "Date: $(date -Is)"
  echo
  echo "Brief priority: boot -> setup -> lan/wifi -> config -> kiosk -> pairing -> sync -> cache -> updates -> disable -> cleanup"
  echo
  echo "Disk:"
  df -h / /boot/firmware 2>/dev/null || df -h /
  echo
  echo "Memory:"
  free -h
  echo
  echo "Autopoiesis services:"
  systemctl --no-pager --type=service --state=running list-units 'autopoiesis-*' 2>/dev/null || true
  echo
  echo "Network:"
  nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null || true
  echo
  echo "Recent Autopoiesis logs:"
  find /var/log/autopoiesis-os "$ROOT_DIR/logs" -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort | tail -20 || true
  echo
  echo "Recommended next big improvement:"
  echo "Run scripts/milestone2-verify.sh on the target Pi, then continue pairing/API integration."
} > "$OUT"

ln -sfn "$(basename "$OUT")" "$LOG_DIR/hourly-audit-latest.log"
echo "$OUT"
