#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="${1:-}"
TARGET_DIR="${2:-}"
USER_NAME="${3:-${AUTOPOIESIS_USER:-frame}}"
GROUP_NAME="${4:-$USER_NAME}"
COPY_METHOD="${AUTOPOIESIS_INSTALL_COPY_METHOD:-auto}"
SKIP_CHOWN="${AUTOPOIESIS_INSTALL_COPY_SKIP_CHOWN:-0}"

fail() {
  echo "install app-tree copy failed: $*" >&2
  exit 2
}

trim_trailing_slash() {
  local value="$1"
  value="${value%/}"
  printf '%s' "${value:-/}"
}

if [[ -z "$SOURCE_DIR" || -z "$TARGET_DIR" ]]; then
  echo "Usage: install-app-tree.sh SOURCE_DIR TARGET_DIR [USER] [GROUP]" >&2
  exit 2
fi

SOURCE_DIR="$(trim_trailing_slash "$SOURCE_DIR")"
TARGET_DIR="$(trim_trailing_slash "$TARGET_DIR")"

[[ -d "$SOURCE_DIR" ]] || fail "source directory does not exist: $SOURCE_DIR"
[[ "$TARGET_DIR" != "/" ]] || fail "target directory cannot be /"

case "$COPY_METHOD" in
  auto|rsync|tar)
    ;;
  *)
    fail "AUTOPOIESIS_INSTALL_COPY_METHOD must be auto, rsync, or tar"
    ;;
esac

chown_tree() {
  local path="$1"
  if [[ "$SKIP_CHOWN" != "1" ]]; then
    chown -R "$USER_NAME:$GROUP_NAME" "$path"
  fi
}

copy_with_rsync() {
  command -v rsync >/dev/null 2>&1 || fail "rsync requested but not installed"
  install -d "$TARGET_DIR"
  rsync -a --delete \
    --exclude '.git' \
    --exclude 'logs/*' \
    --exclude 'node_modules' \
    "$SOURCE_DIR/" "$TARGET_DIR/"
  chown_tree "$TARGET_DIR"
}

copy_with_tar() {
  command -v tar >/dev/null 2>&1 || fail "tar fallback requested but not installed"

  local parent
  parent="$(dirname "$TARGET_DIR")"
  install -d "$parent"

  local staging_dir old_dir
  staging_dir="$(mktemp -d "$parent/.current.new.XXXXXX")"
  old_dir="$parent/.current.old.$$"

  cleanup_staging() {
    rm -rf "$staging_dir"
  }
  trap cleanup_staging RETURN

  tar -C "$SOURCE_DIR" \
    --exclude='./.git' \
    --exclude='./logs/*' \
    --exclude='./node_modules' \
    -cf - . | tar -C "$staging_dir" -xf -

  chown_tree "$staging_dir"

  rm -rf "$old_dir"
  if [[ -e "$TARGET_DIR" || -L "$TARGET_DIR" ]]; then
    mv "$TARGET_DIR" "$old_dir"
  fi
  mv "$staging_dir" "$TARGET_DIR"
  trap - RETURN
  rm -rf "$old_dir"
}

if [[ "$COPY_METHOD" == "rsync" ]]; then
  copy_with_rsync
elif [[ "$COPY_METHOD" == "tar" ]]; then
  copy_with_tar
elif command -v rsync >/dev/null 2>&1; then
  copy_with_rsync
else
  echo "rsync not found; using tar fallback for appliance app-tree copy." >&2
  copy_with_tar
fi
