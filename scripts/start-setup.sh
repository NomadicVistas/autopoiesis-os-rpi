#!/usr/bin/env bash
set -euo pipefail

cd /opt/autopoiesis-os/app/local-ui
exec node server.js
