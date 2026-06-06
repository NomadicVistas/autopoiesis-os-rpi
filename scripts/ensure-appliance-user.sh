#!/usr/bin/env bash
set -euo pipefail

USER_NAME="${AUTOPOIESIS_USER:-frame}"
HOME_DIR="${AUTOPOIESIS_USER_HOME:-/home/$USER_NAME}"
SHELL_PATH="${AUTOPOIESIS_USER_SHELL:-/bin/bash}"

if id -u "$USER_NAME" >/dev/null 2>&1; then
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Appliance user '$USER_NAME' does not exist. Re-run as root so it can be created." >&2
  exit 1
fi

if ! command -v useradd >/dev/null 2>&1; then
  echo "Cannot create appliance user '$USER_NAME': useradd is unavailable." >&2
  exit 1
fi

EXTRA_GROUPS=()
for group in audio video input render netdev gpio spi i2c; do
  if getent group "$group" >/dev/null 2>&1; then
    EXTRA_GROUPS+=("$group")
  fi
done

USERADD_ARGS=(--create-home --home-dir "$HOME_DIR" --shell "$SHELL_PATH")
if [[ "${#EXTRA_GROUPS[@]}" -gt 0 ]]; then
  IFS=,
  USERADD_ARGS+=(--groups "${EXTRA_GROUPS[*]}")
  unset IFS
fi

useradd "${USERADD_ARGS[@]}" "$USER_NAME"
echo "Created appliance user '$USER_NAME'."
