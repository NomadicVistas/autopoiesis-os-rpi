#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${AUTOPOIESIS_DATA_DIR:-/var/lib/autopoiesis-os}"
LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"

if command -v curl >/dev/null 2>&1; then
  RESPONSE="$(curl -fsS -X POST "$LOCAL_URL/local/pairing/start" || true)"
  if [[ -n "$RESPONSE" ]]; then
    node -e "const r=JSON.parse(process.argv[1]); process.stdout.write((r.pairingCode || '') + '\n')" "$RESPONSE"
    exit 0
  fi
fi

PAIRING_CODE="$(tr -dc A-Z0-9 </dev/urandom | head -c 4)-$(tr -dc 0-9 </dev/urandom | head -c 4)"

node -e "
const fs=require('fs');
const dataDir='$DATA_DIR';
const devicePath=dataDir+'/device.json';
const device=JSON.parse(fs.readFileSync(devicePath,'utf8'));
device.pairingCode='$PAIRING_CODE';
device.paired=false;
fs.writeFileSync(devicePath, JSON.stringify(device,null,2)+'\n');
fs.writeFileSync(dataDir+'/pairing.json', JSON.stringify({pairingCode:'$PAIRING_CODE',mock:true,expiresAt:new Date(Date.now()+900000).toISOString()},null,2)+'\n');
"

echo "$PAIRING_CODE"
