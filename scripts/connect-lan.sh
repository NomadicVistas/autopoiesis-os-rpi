#!/usr/bin/env bash
set -euo pipefail

if ! command -v nmcli >/dev/null 2>&1; then
  echo "NetworkManager/nmcli is not installed." >&2
  exit 1
fi

DEVICE="${1:-}"
if [[ -z "$DEVICE" ]]; then
  DEVICE="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2 == "ethernet" { print $1; exit }')"
fi

if [[ -z "$DEVICE" ]]; then
  echo "No Ethernet/LAN device found." >&2
  exit 2
fi

nmcli device connect "$DEVICE"

