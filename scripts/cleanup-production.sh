#!/usr/bin/env bash
set -euo pipefail

echo "Production cleanup checklist"
echo "- Remove Codex and OpenAI credentials manually after final validation."
echo "- Verify no .env files or secrets are present:"
find /opt/autopoiesis-os/app -name '.env' -o -name '*secret*' -o -name '*token*'
echo "- Disable SSH if production policy requires it."
echo "- Keep autopoiesis services enabled."
