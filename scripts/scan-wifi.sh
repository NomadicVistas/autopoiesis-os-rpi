#!/usr/bin/env bash
set -euo pipefail

nmcli -t -f SSID,SIGNAL,SECURITY device wifi list
