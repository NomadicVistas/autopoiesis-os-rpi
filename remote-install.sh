#!/usr/bin/env bash
# remote-install.sh — One-command Autopoiesis Frame installer for Raspberry Pi
#
# Usage:
#   curl -fsSL <url>/remote-install.sh | sudo bash
#   wget -qO- <url>/remote-install.sh | sudo bash
#   sudo ./remote-install.sh
#
# Downloads the latest (or specified) GitHub release and runs the full
# appliance installer, including system dependency installation and kiosk
# OS configuration.
#
# Environment:
#   AUTOPOIESIS_GITHUB_REPO       GitHub owner/repo (default: NomadicVistas/autopoiesis-os-rpi)
#   AUTOPOIESIS_RELEASE_TAG       Specific release tag (default: latest)
#   AUTOPOIESIS_INSTALL_DIR       Install directory (default: /opt/autopoiesis-os)
#   AUTOPOIESIS_USER              Appliance user (default: frame)
#   AUTOPOIESIS_SKIP_DEPS         Set to 1 to skip system dependency installation
#   AUTOPOIESIS_SKIP_KIOSK_CONFIG Set to 1 to skip kiosk OS configuration (auto-login etc.)
#   AUTOPOIESIS_REMOTE_VERBOSE    Set to 1 for verbose output
set -euo pipefail

GITHUB_REPO="${AUTOPOIESIS_GITHUB_REPO:-NomadicVistas/autopoiesis-os-rpi}"
RELEASE_TAG="${AUTOPOIESIS_RELEASE_TAG:-}"
INSTALL_DIR="${AUTOPOIESIS_INSTALL_DIR:-/opt/autopoiesis-os}"
USER_NAME="${AUTOPOIESIS_USER:-frame}"
SKIP_DEPS="${AUTOPOIESIS_SKIP_DEPS:-0}"
SKIP_KIOSK_CONFIG="${AUTOPOIESIS_SKIP_KIOSK_CONFIG:-0}"
VERBOSE="${AUTOPOIESIS_REMOTE_VERBOSE:-0}"
GITHUB_API="https://api.github.com"

TMP_DIR=""
STAGE="init"

# ── Logging ──────────────────────────────────────────────────────────────

log() {
  printf '\033[1m[AUTOPOIESIS]\033[0m %s\n' "$*"
}

verbose() {
  [[ "$VERBOSE" == "1" ]] && printf '  %s\n' "$*" || true
}

fail() {
  printf '\033[31m[AUTOPOIESIS] FAILED at stage "%s": %s\033[0m\n' "$STAGE" "$*" >&2
  exit 1
}

# ── Cleanup ──────────────────────────────────────────────────────────────

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    verbose "cleaning up $TMP_DIR"
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

# ── Guards ───────────────────────────────────────────────────────────────

STAGE="guard"
log "Autopoiesis Frame — one-command installer"

if [[ "$(id -u)" -ne 0 ]]; then
  fail "This script must be run as root. Use: curl ... | sudo bash"
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  fail "This installer targets Linux (Raspberry Pi OS). Detected: $(uname -s)"
fi

ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|armv7l|armv6l)
    log "Architecture: $ARCH (Raspberry Pi compatible)"
    ;;
  x86_64|amd64)
    log "Architecture: $ARCH (development host — Pi 5 is the primary target)"
    ;;
  *)
    log "Architecture: $ARCH (untested)"
    ;;
esac

command -v curl >/dev/null 2>&1 || fail "curl is required. Install it first: sudo apt install -y curl"
command -v tar >/dev/null 2>&1 || fail "tar is required. Install it first: sudo apt install -y tar"

# ── Detect model ─────────────────────────────────────────────────────────

MODEL=""
TOTAL_RAM_MB=0
if [[ -r /proc/device-tree/model ]]; then
  MODEL="$(tr -d '\0' </proc/device-tree/model | sed 's/[[:space:]]*$//')"
fi
TOTAL_RAM_MB="$(awk '/MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo 2>/dev/null || echo 0)"

if [[ -n "$MODEL" ]]; then
  log "Hardware: $MODEL ($TOTAL_RAM_MB MB RAM)"
else
  log "Hardware: generic ($ARCH, $TOTAL_RAM_MB MB RAM)"
fi

# ── Install system dependencies ──────────────────────────────────────────

STAGE="deps"

apt_get_install() {
  if command -v apt-get >/dev/null 2>&1; then
    verbose "apt-get install: $*"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" >/dev/null 2>&1
    return $?
  fi
  return 1
}

if [[ "$SKIP_DEPS" != "1" ]]; then
  log "Installing system dependencies..."

  # Update package index (quietly, tolerate failure)
  if command -v apt-get >/dev/null 2>&1; then
    verbose "updating apt package index"
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
  fi

  # Essential tools
  DEPS_NEEDED=()
  for cmd in curl tar bash; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      DEPS_NEEDED+=("$cmd")
    fi
  done

  # Node.js
  NODE_MAJOR=""
  if command -v node >/dev/null 2>&1; then
    NODE_MAJOR="$(node -p "Number(process.versions.node.split('.')[0])" 2>/dev/null || echo 0)"
  fi

  if [[ -z "$NODE_MAJOR" || "$NODE_MAJOR" -lt 20 ]]; then
    if [[ "$SKIP_DEPS" != "1" ]]; then
      log "Installing Node.js 20..."
      # Try NodeSource setup first, fall back to distro package
      if command -v apt-get >/dev/null 2>&1; then
        if curl -fsSL https://deb.nodesource.com/setup_20.x 2>/dev/null | bash -s -- >/dev/null 2>&1; then
          DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs >/dev/null 2>&1 || true
        else
          # Fallback: try distro package (may be older)
          DEPS_NEEDED+=(nodejs)
        fi
      fi
    fi
  fi

  # Chromium
  if ! command -v chromium-browser >/dev/null 2>&1 && ! command -v chromium >/dev/null 2>&1; then
    DEPS_NEEDED+=(chromium-browser)
  fi

  # NetworkManager
  if ! command -v nmcli >/dev/null 2>&1; then
    DEPS_NEEDED+=(network-manager)
  fi

  # Cursor hiding
  if ! command -v unclutter >/dev/null 2>&1; then
    DEPS_NEEDED+=(unclutter)
  fi

  # rsync (preferred for app tree copy)
  if ! command -v rsync >/dev/null 2>&1; then
    DEPS_NEEDED+=(rsync)
  fi

  # Install all needed deps at once
  if [[ ${#DEPS_NEEDED[@]} -gt 0 ]]; then
    log "Installing: ${DEPS_NEEDED[*]}"
    apt_get_install "${DEPS_NEEDED[@]}" || log "Warning: some dependencies may not have installed cleanly"
  fi

  # Verify critical deps after installation
  command -v node >/dev/null 2>&1 || fail "Node.js is required but not installed"
  NODE_MAJOR="$(node -p "Number(process.versions.node.split('.')[0])" 2>/dev/null || echo 0)"
  if [[ "$NODE_MAJOR" -lt 20 ]]; then
    log "Warning: Node.js is version $(node -v). Version 20+ is recommended."
  fi

  command -v curl >/dev/null 2>&1 || fail "curl is required but not installed"
  command -v systemctl >/dev/null 2>&1 || fail "systemctl is required (systemd-based OS expected)"
fi

log "Dependencies ready."

# ── Download release ─────────────────────────────────────────────────────

STAGE="download"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/autopoiesis-install.XXXXXX")"
verbose "temp directory: $TMP_DIR"

resolve_latest_tag() {
  local tag
  tag="$(curl -fsSL -o /dev/null -w '%{url_effective}' "$GITHUB_API/repos/$GITHUB_REPO/releases/latest" 2>/dev/null | sed 's|.*/tag/||' || true)"
  if [[ -z "$tag" ]]; then
    # Fallback: query the API directly
    tag="$(curl -fsSL "$GITHUB_API/repos/$GITHUB_REPO/releases/latest" 2>/dev/null | grep -m1 '"tag_name"' | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)"
  fi
  printf '%s' "$tag"
}

if [[ -n "$RELEASE_TAG" ]]; then
  log "Installing release: $RELEASE_TAG"
  TAG="$RELEASE_TAG"
else
  TAG="$(resolve_latest_tag)"
  if [[ -z "$TAG" ]]; then
    fail "Could not determine latest release tag from $GITHUB_REPO. Set AUTOPOIESIS_RELEASE_TAG explicitly."
  fi
  log "Latest release: $TAG"
fi

RELEASE_URL="https://github.com/$GITHUB_REPO/releases/download/$TAG"

# Try common artifact names
TARBALL=""
for name in "autopoiesis-os.tar.gz" "autopoiesis-os-$TAG.tar.gz" "release.tar.gz" "autopoiesis-frame.tar.gz"; do
  verbose "checking $RELEASE_URL/$name"
  if curl -fsSL -o /dev/null "$RELEASE_URL/$name" 2>/dev/null; then
    TARBALL="$name"
    break
  fi
done

if [[ -z "$TARBALL" ]]; then
  # Fallback: list assets from the release API
  verbose "querying release assets from API"
  ASSET_URL="$(curl -fsSL "$GITHUB_API/repos/$GITHUB_REPO/releases/tags/$TAG" 2>/dev/null | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*\.tar\.gz"' | head -1 | sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)"
  if [[ -n "$ASSET_URL" ]]; then
    TARBALL="$(basename "$ASSET_URL")"
  fi
fi

if [[ -z "$TARBALL" ]]; then
  # Final fallback: try to download the repo archive (source tarball)
  log "No release artifact found. Trying source archive..."
  ARCHIVE_URL="https://github.com/$GITHUB_REPO/archive/refs/tags/$TAG.tar.gz"
  if curl -fsSL -o "$TMP_DIR/source.tar.gz" "$ARCHIVE_URL" 2>/dev/null; then
    TARBALL="source.tar.gz"
    log "Downloaded source archive for $TAG"
  else
    fail "No release artifact or source archive found for tag $TAG at $GITHUB_REPO"
  fi
else
  log "Downloading $TARBALL..."
  curl -fsSL -o "$TMP_DIR/release.tar.gz" "$RELEASE_URL/$TARBALL" || fail "Failed to download $TARBALL"
fi

# ── Extract ──────────────────────────────────────────────────────────────

STAGE="extract"

verbose "extracting to $TMP_DIR/staging"
mkdir -p "$TMP_DIR/staging"

# Detect top-level directory in tarball (GitHub archives wrap in a directory)
tar -xzf "$TMP_DIR/${TARBALL}" -C "$TMP_DIR/staging"

# Find the extracted root (may be wrapped in a subdirectory)
EXTRACT_ROOT="$TMP_DIR/staging"
WRAPPED_DIR="$(find "$TMP_DIR/staging" -maxdepth 1 -mindepth 1 -type d | head -1)"
if [[ -n "$WRAPPED_DIR" && -f "$WRAPPED_DIR/install.sh" ]]; then
  EXTRACT_ROOT="$WRAPPED_DIR"
  verbose "detected wrapped directory: $WRAPPED_DIR"
fi

if [[ ! -f "$EXTRACT_ROOT/install.sh" ]]; then
  fail "Extracted archive does not contain install.sh. Not a valid Autopoiesis OS release."
fi

if [[ ! -f "$EXTRACT_ROOT/VERSION" ]]; then
  fail "Extracted archive does not contain VERSION. Not a valid Autopoiesis OS release."
fi

VERSION="$(tr -d '\n' < "$EXTRACT_ROOT/VERSION")"
log "Installing Autopoiesis OS v${VERSION} (tag: $TAG)"

# ── Run installer ────────────────────────────────────────────────────────

STAGE="install"

log "Running appliance installer..."

cd "$EXTRACT_ROOT"

AUTOPOIESIS_INSTALL_DIR="$INSTALL_DIR" \
AUTOPOIESIS_USER="$USER_NAME" \
  ./install.sh || fail "Appliance installer failed"

log "Appliance installer completed."

# ── Kiosk OS configuration ───────────────────────────────────────────────

STAGE="kiosk-config"

if [[ "$SKIP_KIOSK_CONFIG" != "1" ]]; then
  if [[ -x "$INSTALL_DIR/app/scripts/configure-kiosk-os.sh" ]]; then
    log "Configuring kiosk OS mode (auto-login, screen blanking, cursor hiding)..."

    AUTOPOIESIS_USER="$USER_NAME" \
      "$INSTALL_DIR/app/scripts/configure-kiosk-os.sh" || {
      log "Warning: kiosk OS configuration failed. You can run it manually later:"
      log "  sudo $INSTALL_DIR/app/scripts/configure-kiosk-os.sh"
    }
  else
    verbose "configure-kiosk-os.sh not found, skipping"
  fi
else
  log "Skipping kiosk OS configuration (AUTOPOIESIS_SKIP_KIOSK_CONFIG=1)"
fi

# ── Production cleanup check ─────────────────────────────────────────────

STAGE="cleanup-check"

if [[ -x "$INSTALL_DIR/app/scripts/cleanup-production.sh" ]]; then
  log "Running production cleanup audit..."
  if AUTOPOIESIS_APP_DIR="$INSTALL_DIR/app" \
     AUTOPOIESIS_USER="$USER_NAME" \
     "$INSTALL_DIR/app/scripts/cleanup-production.sh"; then
    log "Production cleanup audit passed."
  else
    log "Warning: production cleanup audit reported issues. Review above."
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────

STAGE="done"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log "✓ Autopoiesis Frame v${VERSION} installed successfully!"
echo ""
echo "  Install directory:  $INSTALL_DIR"
echo "  Data directory:     /var/lib/autopoiesis-os"
echo "  Log directory:      /var/log/autopoiesis-os"
echo "  Appliance user:     $USER_NAME"
echo ""
echo "Next steps:"
echo ""
echo "  1. Reboot to start the kiosk:"
echo "       sudo reboot"
echo ""
echo "  2. After reboot, the touchscreen will show the setup wizard."
echo "     Connect Wi-Fi and pair your frame at:"
echo "       https://autopoiesis.art/profile/frames"
echo ""
echo "  3. To start services without rebooting:"
echo "       sudo systemctl start autopoiesis.target"
echo ""
echo "  Useful commands:"
echo "    Check status:    sudo systemctl status autopoiesis.target"
echo "    View logs:       sudo journalctl -u autopoiesis-setup.service -f"
echo "    Factory reset:   sudo $INSTALL_DIR/app/factory-reset.sh"
echo "    Update:          sudo $INSTALL_DIR/app/update.sh"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
