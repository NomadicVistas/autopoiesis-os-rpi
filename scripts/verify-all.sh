#!/usr/bin/env bash
# verify-all.sh — Unified offline verification runner for AOS Frames
#
# Runs all self-contained (non-hardware) check scripts in dependency order.
# Produces a unified pass/fail/skip summary.
#
# Usage:
#   scripts/verify-all.sh [--quick] [--verbose] [--fail-fast] [--list]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

QUICK=""
VERBOSE=""
FAIL_FAST=""
LIST=""
for arg in "$@"; do
  case "$arg" in
    --quick|-q)      QUICK=1 ;;
    --verbose|-v)    VERBOSE=1 ;;
    --fail-fast|-x)  FAIL_FAST=1 ;;
    --list|-l)       LIST=1 ;;
    --help|-h)
      echo "Usage: scripts/verify-all.sh [--quick] [--verbose] [--fail-fast] [--list]"
      echo ""
      echo "Runs all self-contained AOS verification gates in dependency order."
      echo ""
      echo "  --quick      Skip heavy integration gates"
      echo "  --verbose    Show full output from each gate"
      echo "  --fail-fast  Stop on first failure"
      echo "  --list       List gates without running"
      exit 0
      ;;
  esac
done

# ── Gate catalog ──────────────────────────────────────────────────────────

SYNTAX_GATES=(
  "node --check local-ui/server.js"
  "node --check hosted-api/server.js"
  "node --check hosted-api/db.js"
  "node --check scripts/mock-hosted-api/server.js"
  "bash -n install.sh"
  "bash -n update.sh"
  "bash -n uninstall-dev-tools.sh"
  "bash -n factory-reset.sh"
)

# Add bash -n for every scripts/*.sh
for f in scripts/*.sh; do
  SYNTAX_GATES+=("bash -n $f")
done

STATIC_GATES=(
  # ── Build / installer static gates ──
  "scripts/check-release-update-check.sh"
  "scripts/configure-kiosk-os-check.sh"
  "scripts/frame-crossfade-check.sh"
  "scripts/heartbeat-runner-check.sh"
  "scripts/install-app-tree-check.sh"
  "scripts/release-app-tree-copy-check.sh"
  "scripts/remote-install-check.sh"
  "scripts/run-migrations-check.sh"
  "scripts/setup-launcher-check.sh"
  "scripts/systemd-security-check.sh"
  "scripts/systemd-units-install-check.sh"
  "scripts/touchscreen-check.sh"
  "scripts/watchdog-check.sh"
  # ── Schema / contract static gates ──
  "scripts/aos-schema-contract-check.sh"
  "scripts/broadcast-contract-check.sh"
  "scripts/changelog-check.sh"
  "scripts/feed-model-contract-check.sh"
  "scripts/release-manifest-check.sh"
  "scripts/release-rollout-contract-check.sh"
  "scripts/rollout-acceptance-check.sh"
  "scripts/systemd-timers-check.sh"
)

INTEGRATION_LIGHT_GATES=(
  # ── Broadcast / delivery ──
  "scripts/broadcast-command-check.sh"
  "scripts/broadcast-delivery-status-check.sh"
  "scripts/broadcast-deliveries-heartbeat-check.sh"
  "scripts/broadcast-delivery-ingestion-check.sh"
  # ── Command lifecycle ──
  "scripts/command-ack-contract-check.sh"
  "scripts/command-ack-retry-check.sh"
  "scripts/command-poll-contract-check.sh"
  "scripts/command-state-contract-check.sh"
  # ── Device / auth / pairing ──
  "scripts/device-auth-contract-check.sh"
  "scripts/pairing-contract-check.sh"
  "scripts/profile-ownership-contract-check.sh"
  "scripts/owner-preference-cascade-check.sh"
  # ── Feed / stream ──
  "scripts/feed-cursor-check.sh"
  "scripts/feed-display-dwell-check.sh"
  "scripts/feed-targeting-check.sh"
  "scripts/feed-stream-composition-check.sh"
  "scripts/stream-contract-check.sh"
  "scripts/stream-playback-check.sh"
  # ── Heartbeat / persistence ──
  "scripts/heartbeat-commands-check.sh"
  "scripts/heartbeat-contract-check.sh"
  "scripts/heartbeat-persistence-check.sh"
  # ── Kiosk / display ──
  "scripts/kiosk-check.sh"
  "scripts/kiosk-feed-polling-check.sh"
  "scripts/frame-state-check.sh"
  "scripts/night-mode-check.sh"
  "scripts/night-mode-timer-check.sh"
  # ── Network / Wi-Fi / hardware ──
  "scripts/hardware-profile-check.sh"
  "scripts/hardware-profile-fixture-check.sh"
  "scripts/network-check.sh"
  "scripts/wifi-network-enrichment-check.sh"
  "scripts/wifi-scan-dedup-check.sh"
  # ── Diagnostics / health / readiness ──
  "scripts/diagnostics-check.sh"
  "scripts/health-check.sh"
  "scripts/readiness-check.sh"
  "scripts/support-bundle-check.sh"
  # ── Cache / storage / runtime ──
  "scripts/cache-contract-check.sh"
  "scripts/runtime-storage-check.sh"
  "scripts/events-export-check.sh"
  "scripts/clock-check.sh"
  # ── Settings / admin capabilities ──
  "scripts/settings-contract-check.sh"
  "scripts/admin-capabilities-check.sh"
  "scripts/admin-device-snapshot-check.sh"
  "scripts/prepare-release-check.sh"
  # ── Online admin (mock API based) ──
  "scripts/online-admin-contract-check.sh"
  "scripts/online-admin-entitlements-check.sh"
  "scripts/online-admin-device-state-actions-check.sh"
  "scripts/online-admin-subscription-lifecycle-check.sh"
  # ── Hosted API DB layer (single server) ──
  "scripts/hosted-api-db-check.sh"
  "scripts/hosted-contract-suite-check.sh"
)

INTEGRATION_HEAVY_GATES=(
  # ── Full device lifecycle ──
  "scripts/device-lifecycle-check.sh"
  "scripts/events-ingestion-check.sh"
  "scripts/factory-reset-check.sh"
  "scripts/feed-offline-fallback-check.sh"
  "scripts/settings-sync-check.sh"
  # ── Mock API bridge (multi-server) ──
  "scripts/hosted-mock-bridge-check.sh"
  "scripts/online-admin-mock-bridge-check.sh"
  "scripts/online-admin-fleet-isolation-check.sh"
  # ── Hosted API (real DB, multi-server) ──
  "scripts/hosted-api-server-check.sh"
  "scripts/hosted-api-local-ui-bridge-check.sh"
  "scripts/hosted-api-admin-bundle-check.sh"
  # ── Admin content management (multi-server, heavy CRUD) ──
  "scripts/admin-content-management-check.sh"
  # ── Admin user management (multi-server, user CRUD + preferences) ──
  "scripts/admin-user-management-check.sh"
)

CONTRACT_GATES=(
  "scripts/aos-migration-contract-check.sh|migrations/"
)

SECURITY_GATES=(
  "scripts/security-smoke.sh"
)

# ── List mode ─────────────────────────────────────────────────────────────

if [[ -n "$LIST" ]]; then
  syntax_count=${#SYNTAX_GATES[@]}
  static_count=${#STATIC_GATES[@]}
  light_count=${#INTEGRATION_LIGHT_GATES[@]}
  heavy_count=${#INTEGRATION_HEAVY_GATES[@]}
  contract_count=${#CONTRACT_GATES[@]}
  sec_count=${#SECURITY_GATES[@]}
  echo "AOS Verification Gate Catalog"
  echo "=============================="
  echo ""
  echo "Phase 1: Syntax ($syntax_count)"
  for cmd in "${SYNTAX_GATES[@]}"; do echo "  $cmd"; done
  echo ""
  echo "Phase 2: Static gates ($static_count)"
  for gate in "${STATIC_GATES[@]}"; do echo "  $gate"; done
  echo ""
  echo "Phase 3a: Integration — light ($light_count)"
  for gate in "${INTEGRATION_LIGHT_GATES[@]}"; do echo "  $gate"; done
  echo ""
  echo "Phase 3b: Integration — heavy ($heavy_count)"
  for gate in "${INTEGRATION_HEAVY_GATES[@]}"; do echo "  $gate"; done
  echo ""
  echo "Phase 4: Contract fixtures ($contract_count)"
  for entry in "${CONTRACT_GATES[@]}"; do echo "  $entry"; done
  echo ""
  echo "Phase 5: Security ($sec_count)"
  for gate in "${SECURITY_GATES[@]}"; do echo "  $gate"; done
  exit 0
fi

# ── Runner state ──────────────────────────────────────────────────────────

PASSED=0
FAILED=0
SKIPPED=0
FAILURES=()
STARTED_AT=$(date +%s)

section() {
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo "  $1"
  echo "══════════════════════════════════════════════════════════════"
}

run_gate() {
  local label="$1"
  shift
  local cmd="$*"

  if [[ -n "$VERBOSE" ]]; then
    echo ""
    echo "▶ $label"
    if eval "$cmd" 2>&1; then
      echo "  ✅ $label"
      PASSED=$((PASSED + 1))
      return 0
    else
      echo "  ❌ $label"
      FAILED=$((FAILED + 1))
      FAILURES+=("$label")
      [[ -n "$FAIL_FAST" ]] && exit 1
      return 1
    fi
  else
    local output rc=0
    output=$(eval "$cmd" 2>&1) || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "  ✅ $label"
      PASSED=$((PASSED + 1))
    else
      echo "  ❌ $label"
      FAILED=$((FAILED + 1))
      FAILURES+=("$label")
      echo "$output" | tail -8 | sed 's/^/     /'
      [[ -n "$FAIL_FAST" ]] && exit 1
    fi
  fi
}

skip_gate() {
  local label="$1"
  local reason="${2:-skipped}"
  echo "  ⏭️  $label ($reason)"
  SKIPPED=$((SKIPPED + 1))
}

# ── Header ────────────────────────────────────────────────────────────────

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Autopoiesis OS — Unified Offline Verification             ║"
echo "║  $(date -Is)                                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── Phase 1: Syntax ──────────────────────────────────────────────────────

section "Phase 1: Syntax validation (${#SYNTAX_GATES[@]})"

for cmd in "${SYNTAX_GATES[@]}"; do
  label=$(echo "$cmd" | sed 's/^[a-z]* //' | sed 's/^scripts\///')
  run_gate "$label" "$cmd"
done

# ── Phase 2: Static gates ───────────────────────────────────────────────

section "Phase 2: Static gates (${#STATIC_GATES[@]})"

for gate in "${STATIC_GATES[@]}"; do
  label=$(basename "$gate" .sh)
  if [[ -f "$gate" ]]; then
    run_gate "$label" "bash $gate"
  else
    skip_gate "$label" "file not found"
  fi
done

# ── Phase 3a: Integration light ─────────────────────────────────────────

section "Phase 3a: Integration — light (${#INTEGRATION_LIGHT_GATES[@]})"

for gate in "${INTEGRATION_LIGHT_GATES[@]}"; do
  label=$(basename "$gate" .sh)
  if [[ -f "$gate" ]]; then
    run_gate "$label" "bash $gate"
  else
    skip_gate "$label" "file not found"
  fi
done

# ── Phase 3b: Integration heavy ─────────────────────────────────────────

if [[ -z "$QUICK" ]]; then
  section "Phase 3b: Integration — heavy (${#INTEGRATION_HEAVY_GATES[@]})"
  for gate in "${INTEGRATION_HEAVY_GATES[@]}"; do
    label=$(basename "$gate" .sh)
    if [[ -f "$gate" ]]; then
      run_gate "$label" "bash $gate"
    else
      skip_gate "$label" "file not found"
    fi
  done
else
  section "Phase 3b: Integration — heavy (skipped: --quick)"
  for gate in "${INTEGRATION_HEAVY_GATES[@]}"; do
    skip_gate "$(basename "$gate" .sh)" "--quick"
  done
fi

# ── Phase 4: Contract fixtures ──────────────────────────────────────────

section "Phase 4: Contract fixtures (${#CONTRACT_GATES[@]})"

for entry in "${CONTRACT_GATES[@]}"; do
  gate="${entry%%|*}"
  args="${entry#*|}"
  # Only pass args if the delimiter was found
  if [[ "$entry" == *"|"* ]]; then
    full_cmd="bash $gate $args"
  else
    full_cmd="bash $gate"
  fi
  label=$(basename "$gate" .sh)
  if [[ -f "$gate" ]]; then
    run_gate "$label" "$full_cmd"
  else
    skip_gate "$label" "file not found"
  fi
done

# ── Phase 5: Security ───────────────────────────────────────────────────

section "Phase 5: Security (${#SECURITY_GATES[@]})"

for gate in "${SECURITY_GATES[@]}"; do
  label=$(basename "$gate" .sh)
  if [[ -f "$gate" ]]; then
    run_gate "$label" "bash $gate"
  else
    skip_gate "$label" "file not found"
  fi
done

# ── Phase 6: Git diff ───────────────────────────────────────────────────

section "Phase 6: Working tree"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  run_gate "git-diff-check" "git diff --check"
else
  skip_gate "git-diff-check" "not a git repo"
fi

# ── Summary ─────────────────────────────────────────────────────────────

ENDED_AT=$(date +%s)
DURATION=$((ENDED_AT - STARTED_AT))
TOTAL=$((PASSED + FAILED + SKIPPED))

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Verification Summary                                      ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  ✅ Passed: %-4d  ❌ Failed: %-4d  ⏭  Skipped: %-4d      ║\n" "$PASSED" "$FAILED" "$SKIPPED"
printf "║  Total: %-4d  Duration: %ds                                ║\n" "$TOTAL" "$DURATION"
echo "╚══════════════════════════════════════════════════════════════╝"

if [[ "$FAILED" -gt 0 ]]; then
  echo ""
  echo "Failed gates:"
  for f in "${FAILURES[@]}"; do
    echo "  ❌ $f"
  done
  echo ""
  exit 1
fi

echo ""
echo "All gates passed. 🎉"
exit 0
