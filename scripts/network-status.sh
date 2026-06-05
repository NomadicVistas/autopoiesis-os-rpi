#!/usr/bin/env bash
set -euo pipefail

if ! command -v nmcli >/dev/null 2>&1; then
  echo "NetworkManager/nmcli is not installed." >&2
  exit 1
fi

nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status

