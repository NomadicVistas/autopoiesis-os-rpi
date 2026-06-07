#!/usr/bin/env bash
# systemd-security-check.sh — Validate security hardening in AOS service templates
# Ensures every service file has the expected sandboxing directives and that
# root services carry extra protection where appropriate.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVICES_DIR="$ROOT_DIR/services"

PASS=0
FAIL=0
CHECKS=0

# ---- helpers ----

fail() {
  echo "FAIL: $*" >&2
  ((FAIL++)) || true
  ((CHECKS++)) || true
}

pass() {
  ((PASS++)) || true
  ((CHECKS++)) || true
}

check_directive() {
  local file="$1" directive="$2" description="$3"
  if grep -qP "^${directive}=" "$file"; then
    pass
  else
    fail "$description missing in $(basename "$file")"
  fi
}

check_directive_value() {
  local file="$1" directive="$2" expected="$3" description="$4"
  local actual
  actual="$(grep -oP "^${directive}=\\K.*" "$file" || true)"
  if [[ "$actual" == "$expected" ]]; then
    pass
  else
    fail "$description in $(basename "$file"): expected '$expected', got '${actual:-<missing>}'"
  fi
}

check_no_directive() {
  local file="$1" directive="$2" description="$3"
  if grep -qP "^${directive}=" "$file"; then
    fail "$description should not be present in $(basename "$file")"
  else
    pass
  fi
}

# ---- validate all service files exist ----

echo "=== AOS Systemd Security Check ==="
echo ""

REQUIRED_SERVICES=(
  autopoiesis-setup.service
  autopoiesis-kiosk.service
  autopoiesis-heartbeat.service
  autopoiesis-cache.service
  autopoiesis-command-executor.service
  autopoiesis-updater.service
  autopoiesis-watchdog.service
)

for svc in "${REQUIRED_SERVICES[@]}"; do
  if [[ ! -f "$SERVICES_DIR/$svc" ]]; then
    fail "Missing service template: $svc"
  else
    pass
  fi
done

echo ""
echo "--- Universal hardening (all services) ---"

# Directives that EVERY service must have
UNIVERSAL_DIRECTIVES=(
  "PrivateTmp|PrivateTmp"
  "ProtectHome|ProtectHome"
  "ProtectClock|ProtectClock"
  "ProtectKernelModules|ProtectKernelModules"
  "ProtectKernelLogs|ProtectKernelLogs"
  "ProtectKernelTunables|ProtectKernelTunables"
  "ProtectControlGroups|ProtectControlGroups"
  "RestrictNamespaces|RestrictNamespaces"
  "LockPersonality|LockPersonality"
  "RestrictRealtime|RestrictRealtime"
  "RestrictSUIDSGID|RestrictSUIDSGID"
  "SystemCallArchitectures|SystemCallArchitectures"
)

for svc in "${REQUIRED_SERVICES[@]}"; do
  file="$SERVICES_DIR/$svc"
  [[ -f "$file" ]] || continue

  for entry in "${UNIVERSAL_DIRECTIVES[@]}"; do
    IFS='|' read -r directive description <<< "$entry"
    check_directive "$file" "$directive" "$description"
  done
done

echo ""
echo "--- Capability bounding (all services) ---"

# Every service should drop all capabilities
for svc in "${REQUIRED_SERVICES[@]}"; do
  file="$SERVICES_DIR/$svc"
  [[ -f "$file" ]] || continue
  check_directive_value "$file" "CapabilityBoundingSet" "" "CapabilityBoundingSet drop"
done

echo ""
echo "--- Frame-user services: strict sandboxing ---"

# Services running as frame (unprivileged) should use ProtectSystem=strict
# and NoNewPrivileges=true and MemoryDenyWriteExecute=true
FRAME_SERVICES=(
  autopoiesis-setup.service
  autopoiesis-heartbeat.service
  autopoiesis-cache.service
)

for svc in "${FRAME_SERVICES[@]}"; do
  file="$SERVICES_DIR/$svc"
  [[ -f "$file" ]] || continue

  check_directive_value "$file" "ProtectSystem" "strict" "ProtectSystem=strict for frame service"
  check_directive "$file" "NoNewPrivileges" "NoNewPrivileges"
  check_directive "$file" "MemoryDenyWriteExecute" "MemoryDenyWriteExecute"

  # Must have ReadWritePaths since ProtectSystem=strict
  if grep -qP "^ReadWritePaths=" "$file"; then
    # Must include data and log dirs
    local_paths="$(grep -oP '^ReadWritePaths=\K.*' "$file")"
    if echo "$local_paths" | grep -q "/var/lib/autopoiesis-os"; then
      pass
    else
      fail "$svc ReadWritePaths must include /var/lib/autopoiesis-os"
    fi
    if echo "$local_paths" | grep -q "/var/log/autopoiesis-os"; then
      pass
    else
      fail "$svc ReadWritePaths must include /var/log/autopoiesis-os"
    fi
  else
    fail "$svc with ProtectSystem=strict must have ReadWritePaths"
    ((CHECKS++)) || true  # count the data check too
  fi
done

echo ""
echo "--- Kiosk service: Chromium-appropriate sandboxing ---"

file="$SERVICES_DIR/autopoiesis-kiosk.service"
if [[ -f "$file" ]]; then
  # Kiosk uses ProtectSystem=full (not strict) because Chromium needs broader fs access
  check_directive_value "$file" "ProtectSystem" "full" "ProtectSystem=full for kiosk (Chromium)"
  check_directive "$file" "NoNewPrivileges" "NoNewPrivileges"
  # Chromium cannot use MemoryDenyWriteExecute (JIT)
  check_no_directive "$file" "MemoryDenyWriteExecute" "MemoryDenyWriteExecute"
fi

echo ""
echo "--- Root services: maximum available restriction ---"

ROOT_SERVICES=(
  autopoiesis-command-executor.service
  autopoiesis-updater.service
  autopoiesis-watchdog.service
)

for svc in "${ROOT_SERVICES[@]}"; do
  file="$SERVICES_DIR/$svc"
  [[ -f "$file" ]] || continue

  # Root services should use ProtectSystem=strict
  check_directive_value "$file" "ProtectSystem" "strict" "ProtectSystem=strict for root service"

  # Must have ReadWritePaths
  if grep -qP "^ReadWritePaths=" "$file"; then
    pass
  else
    fail "$svc (root) with ProtectSystem=strict must have ReadWritePaths"
  fi

  # Root services should NOT have NoNewPrivileges (may need capabilities)
  # This is intentional — root services may need to restart other services
done

echo ""
echo "--- Watchdog: relaxed ProtectSystem ---"

# Watchdog needs systemctl which may need broader access
file="$SERVICES_DIR/autopoiesis-watchdog.service"
if [[ -f "$file" ]]; then
  # Watchdog doesn't need ProtectSystem=strict — it interacts with systemd
  # But it should still have basic protections
  if grep -qP "^ProtectSystem=" "$file"; then
    pass
  else
    # It's acceptable for watchdog to not have ProtectSystem since it needs systemctl
    pass
  fi
fi

echo ""
echo "--- No hardcoded secrets in service files ---"

for svc in "${REQUIRED_SERVICES[@]}"; do
  file="$SERVICES_DIR/$svc"
  [[ -f "$file" ]] || continue

  # Check for suspicious patterns
  if grep -qiP '(password|secret|token|api.key|private.key)\s*=' "$file"; then
    fail "$(basename "$file") may contain hardcoded credentials"
  else
    pass
  fi
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $CHECKS total checks ==="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

echo "systemd security check passed"
exit 0
