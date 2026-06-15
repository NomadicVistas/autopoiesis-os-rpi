#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${AUTOPOIESIS_APP_DIR:-/opt/autopoiesis-os/app}"
INSTALL_DIR="${AUTOPOIESIS_INSTALL_DIR:-/opt/autopoiesis-os}"
DATA_DIR="${AUTOPOIESIS_DATA_DIR:-/var/lib/autopoiesis-os}"
LOG_DIR="${AUTOPOIESIS_LOG_DIR:-/var/log/autopoiesis-os}"
USER_NAME="${AUTOPOIESIS_USER:-frame}"

# For installed appliances, use the hosted release check path.
# For git checkouts during development, use the git-based updater.
if [[ -d "$APP_DIR/.git" ]]; then
  "$SCRIPT_DIR/scripts/update-from-github.sh"
else
  "$SCRIPT_DIR/scripts/check-release-update.sh"
fi

# Post-update verification
run_post_update_check() {
  echo ""
  echo "Running post-update verification..."
  if [[ -x "$INSTALL_DIR/app/scripts/diagnostics.sh" ]]; then
    "$INSTALL_DIR/app/scripts/diagnostics.sh" --quick 2>&1 | tee -a "$LOG_DIR/update-verification.log" || true
    echo "Verification log written to $LOG_DIR/update-verification.log"
    # Extract summary line
    if tail -5 "$LOG_DIR/update-verification.log" | grep -q "Summary:"; then
      tail -5 "$LOG_DIR/update-verification.log" | grep "Summary:"
    else
      echo "Verification completed (see log for details)."
    fi
  else
    echo "Verification script not found; skipping."
  fi
}
run_post_update_check
