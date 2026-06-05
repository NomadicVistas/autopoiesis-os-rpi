# Production Cleanup

Production devices must not contain Codex, OpenAI credentials, development tokens, shell history with secrets, or unnecessary remote access.

Current cleanup script:

```bash
sudo /opt/autopoiesis-os/app/scripts/cleanup-production.sh
```

This is currently a checklist script. It must become stricter before production imaging.

Required QA gate before imaging or exposing a device:

```bash
/opt/autopoiesis-os/app/scripts/security-smoke.sh
```

The security smoke test starts the local UI against a temporary data directory containing a fake device API key, then verifies that `/local/status`, `/local/pairing/status`, and `/local/diagnostics` do not expose the key or key field names. It also fails if sensitive-looking files such as `.env`, `.pem`, `.key`, or `secrets/` paths are tracked in Git.

Open work:

- detect Codex install path
- remove Codex only after appliance validation
- remove development package caches
- verify no `.env` files exist outside ignored/local runtime paths
- optionally disable SSH
- preserve runtime services and local pairing/config data
