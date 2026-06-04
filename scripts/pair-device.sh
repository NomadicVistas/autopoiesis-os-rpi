#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${AUTOPOIESIS_DATA_DIR:-/var/lib/autopoiesis-os}"
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
