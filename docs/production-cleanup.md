# Production Cleanup

Production devices must not contain Codex, OpenAI credentials, development tokens, shell history with secrets, or unnecessary remote access.

Current cleanup script:

```bash
sudo /opt/autopoiesis-os/app/scripts/cleanup-production.sh
```

This is currently a checklist script. It must become stricter before production imaging.

Open work:

- detect Codex install path
- remove Codex only after appliance validation
- remove development package caches
- verify no `.env` files exist
- optionally disable SSH
- preserve runtime services and local pairing/config data
