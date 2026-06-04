#!/usr/bin/env bash
set -euo pipefail

if [[ -r /etc/machine-id ]]; then
  printf 'rpi-%s\n' "$(tr -d '\n' < /etc/machine-id)"
elif command -v uuidgen >/dev/null 2>&1; then
  printf 'rpi-%s\n' "$(uuidgen)"
else
  printf 'rpi-%s-%s\n' "$(hostname)" "$(date +%s)"
fi
