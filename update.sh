#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${AUTOPOIESIS_APP_DIR:-/opt/autopoiesis-os/app}"

# For installed appliances, use the hosted release check path.
# For git checkouts during development, use the git-based updater.
if [[ -d "$APP_DIR/.git" ]]; then
  "$SCRIPT_DIR/scripts/update-from-github.sh"
else
  "$SCRIPT_DIR/scripts/check-release-update.sh"
fi
