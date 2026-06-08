#!/usr/bin/env bash
# release-state-heartbeat-check.sh — Wrapper that runs the Node.js validation gate
set -uo pipefail
cd "$(dirname "$0")/.."
node scripts/release-state-heartbeat-check.mjs
