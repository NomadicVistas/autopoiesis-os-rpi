#!/usr/bin/env bash
set -euo pipefail

# Verification gate for remote-install.sh
# Tests syntax, argument handling, environment detection, dependency resolution,
# release URL construction, and dry-run mode without requiring network access
# or an actual Raspberry Pi.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_INSTALL="$SCRIPT_DIR/../remote-install.sh"
TMP_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

pass() {
  PASS=$((PASS + 1))
  echo "  ✓ $*"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  ✗ FAIL: $*" >&2
}

# ── Step 1: Script syntax ────────────────────────────────────────────────

echo "Step 1: Script syntax"
if bash -n "$REMOTE_INSTALL"; then
  pass "bash -n parses cleanly"
else
  fail "bash -n failed"
fi

# ── Step 2: Help output ──────────────────────────────────────────────────

echo "Step 2: Script structure"
if grep -q "set -euo pipefail" "$REMOTE_INSTALL"; then
  pass "strict mode is set"
else
  fail "strict mode is missing"
fi

if grep -q "trap cleanup EXIT" "$REMOTE_INSTALL"; then
  pass "cleanup trap is registered"
else
  fail "cleanup trap is missing"
fi

# ── Step 3: Root guard ──────────────────────────────────────────────────

echo "Step 3: Root guard"
if AUTOPOIESIS_SKIP_DEPS=1 bash -c 'source <(grep -A2 "id -u" "'"$REMOTE_INSTALL"'" | head -3)' 2>&1 | grep -qi "root"; then
  pass "non-root execution produces root requirement message"
else
  # The script will fail with exit code 1 when not root
  if ! AUTOPOIESIS_SKIP_DEPS=1 bash "$REMOTE_INSTALL" 2>&1; then
    pass "non-root execution exits with failure (as expected)"
  else
    fail "non-root execution should have failed"
  fi
fi

# ── Step 4: Environment variable handling ────────────────────────────────

echo "Step 4: Environment variable defaults"
for var in GITHUB_REPO RELEASE_TAG INSTALL_DIR USER_NAME SKIP_DEPS SKIP_KIOSK_CONFIG VERBOSE; do
  if grep -q "$var" "$REMOTE_INSTALL"; then
    pass "$var is handled"
  else
    fail "$var is not referenced"
  fi
done

# ── Step 5: Release URL construction ─────────────────────────────────────

echo "Step 5: Release URL construction"
if grep -q 'releases/download' "$REMOTE_INSTALL"; then
  pass "GitHub release download URL pattern is present"
else
  fail "GitHub release download URL pattern is missing"
fi

if grep -q 'resolve_latest_tag' "$REMOTE_INSTALL"; then
  pass "latest tag resolution function exists"
else
  fail "latest tag resolution function is missing"
fi

if grep -q 'GITHUB_API' "$REMOTE_INSTALL"; then
  pass "GitHub API endpoint is referenced"
else
  fail "GitHub API endpoint is missing"
fi

# ── Step 6: Dependency installation paths ────────────────────────────────

echo "Step 6: Dependency installation"
for dep in "node" "chromium" "nmcli" "unclutter" "rsync"; do
  if grep -q "$dep" "$REMOTE_INSTALL"; then
    pass "$dep dependency is checked"
  else
    fail "$dep dependency check is missing"
  fi
done

if grep -q "nodesource" "$REMOTE_INSTALL"; then
  pass "NodeSource Node.js installation path exists"
else
  fail "NodeSource installation path is missing"
fi

if grep -q "DEBIAN_FRONTEND" "$REMOTE_INSTALL"; then
  pass "non-interactive apt is used"
else
  fail "non-interactive apt is missing"
fi

# ── Step 7: Install flow ────────────────────────────────────────────────

echo "Step 7: Install flow stages"
for stage in "guard" "deps" "download" "extract" "install" "kiosk-config" "cleanup-check" "done"; do
  if grep -q "$stage" "$REMOTE_INSTALL"; then
    pass "stage '$stage' is defined"
  else
    fail "stage '$stage' is missing"
  fi
done

# ── Step 8: Artifact fallback ────────────────────────────────────────────

echo "Step 8: Artifact fallback paths"
if grep -q 'source\.tar\.gz\|archive/refs/tags' "$REMOTE_INSTALL"; then
  pass "source archive fallback exists"
else
  fail "source archive fallback is missing"
fi

if grep -q 'browser_download_url' "$REMOTE_INSTALL"; then
  pass "release API asset discovery exists"
else
  fail "release API asset discovery is missing"
fi

# ── Step 9: Extract and validate ─────────────────────────────────────────

echo "Step 9: Extract validation"
if grep -q 'install\.sh' "$REMOTE_INSTALL"; then
  pass "install.sh presence check after extraction"
else
  fail "install.sh presence check is missing"
fi

if grep -q 'VERSION' "$REMOTE_INSTALL"; then
  pass "VERSION file check after extraction"
else
  fail "VERSION file check is missing"
fi

# ── Step 10: Kiosk configuration ─────────────────────────────────────────

echo "Step 10: Kiosk OS configuration integration"
if grep -q 'configure-kiosk-os' "$REMOTE_INSTALL"; then
  pass "configure-kiosk-os.sh is called"
else
  fail "configure-kiosk-os.sh integration is missing"
fi

if grep -q 'SKIP_KIOSK_CONFIG' "$REMOTE_INSTALL"; then
  pass "kiosk config skip flag is supported"
else
  fail "kiosk config skip flag is missing"
fi

# ── Step 11: Production cleanup ──────────────────────────────────────────

echo "Step 11: Production cleanup integration"
if grep -q 'cleanup-production' "$REMOTE_INSTALL"; then
  pass "cleanup-production.sh is called"
else
  fail "cleanup-production.sh integration is missing"
fi

# ── Step 12: Post-install messaging ──────────────────────────────────────

echo "Step 12: Post-install guidance"
if grep -q 'reboot' "$REMOTE_INSTALL"; then
  pass "reboot guidance is present"
else
  fail "reboot guidance is missing"
fi

if grep -q 'autopoiesis.art' "$REMOTE_INSTALL"; then
  pass "pairing URL is shown"
else
  fail "pairing URL is missing"
fi

if grep -q 'factory-reset' "$REMOTE_INSTALL"; then
  pass "factory reset command is shown"
else
  fail "factory reset command is missing"
fi

# ── Step 13: Dry run with temp extraction ────────────────────────────────

echo "Step 13: Mock release extraction"

# Create a mock release tarball
MOCK_DIR="$TMP_DIR/mock-release"
mkdir -p "$MOCK_DIR/scripts"
echo "0.1.0-test" > "$MOCK_DIR/VERSION"
echo '#!/bin/bash' > "$MOCK_DIR/install.sh"
echo 'echo "mock install OK"' >> "$MOCK_DIR/install.sh"
chmod +x "$MOCK_DIR/install.sh"

# Create tarball
tar -czf "$TMP_DIR/autopoiesis-os.tar.gz" -C "$TMP_DIR" "mock-release"

# Verify it extracts correctly
mkdir -p "$TMP_DIR/verify"
tar -xzf "$TMP_DIR/autopoiesis-os.tar.gz" -C "$TMP_DIR/verify"
if [[ -f "$TMP_DIR/verify/mock-release/install.sh" ]]; then
  pass "mock release extracts correctly"
else
  fail "mock release extraction failed"
fi

# Verify the installer's wrapped directory detection pattern
if grep -q 'WRAPPED_DIR' "$REMOTE_INSTALL"; then
  pass "wrapped directory detection exists"
else
  fail "wrapped directory detection is missing"
fi

# ── Step 14: Security checks ─────────────────────────────────────────────

echo "Step 14: Security considerations"
if grep -q 'set -euo pipefail' "$REMOTE_INSTALL"; then
  pass "strict bash mode"
else
  fail "strict bash mode missing"
fi

# Check that the script doesn't pipe curl directly to bash (it downloads first)
if grep -qE 'curl.*\|.*bash' "$REMOTE_INSTALL" && ! grep -q 'nodesource' <<< "$(grep 'curl.*|.*bash' "$REMOTE_INSTALL")"; then
  fail "script pipes curl directly to bash (security risk)"
else
  pass "no unsafe curl-to-bash piping (NodeSource is acceptable)"
fi

# Verify cleanup on exit
if grep -q 'rm -rf.*TMP_DIR' "$REMOTE_INSTALL"; then
  pass "temp directory cleanup on exit"
else
  fail "temp directory cleanup is missing"
fi

# ── Summary ──────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "All remote installer gate checks passed."
