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
)

INTEGRATION_LIGHT_GATES=(
  "scripts/broadcast-command-check.sh"
  "scripts/broadcast-delivery-status-check.sh"
  "scripts/command-ack-retry-check.sh"
  "scripts/feed-cursor-check.sh"
  "scripts/feed-display-dwell-check.sh"
  "scripts/feed-targeting-check.sh"
  "scripts/hardware-profile-fixture-check.sh"
  "scripts/heartbeat-commands-check.sh"
  "scripts/night-mode-check.sh"
  "scripts/night-mode-timer-check.sh"
)

INTEGRATION_HEAVY_GATES=(
  "scripts/device-lifecycle-check.sh"
  "scripts/hosted-mock-bridge-check.sh"
  "scripts/events-ingestion-check.sh"
  "scripts/factory-reset-check.sh"
  "scripts/feed-offline-fallback-check.sh"
  "scripts/online-admin-mock-bridge-check.sh"
  "scripts/online-admin-fleet-isolation-check.sh"
  "scripts/settings-sync-check.sh"
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
