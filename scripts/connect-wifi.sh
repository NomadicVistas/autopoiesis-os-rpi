#!/usr/bin/env bash
set -euo pipefail

SSID="${1:-}"
PASSWORD="${2:-}"

if [[ -z "$SSID" ]]; then
  echo "Usage: connect-wifi.sh SSID [PASSWORD]" >&2
  exit 2
fi

if [[ -n "$PASSWORD" ]]; then
  nmcli device wifi connect "$SSID" password "$PASSWORD"
else
  nmcli device wifi connect "$SSID"
fi
