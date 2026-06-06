# Production Cleanup

Production devices must not contain Codex, OpenAI credentials, development tokens, shell history with secrets, or unnecessary remote access.

Current cleanup script:

```bash
sudo /opt/autopoiesis-os/app/scripts/cleanup-production.sh
```

This is now a read-only production hygiene audit. It does not delete files; it fails or warns so the final image can be fixed deliberately before cloning or exposure.

Strict final-image gate:

```bash
AUTOPOIESIS_PRODUCTION_CLEANUP_STRICT=1 sudo /opt/autopoiesis-os/app/scripts/cleanup-production.sh
```

The audit checks:

- secret-looking files in the installed app tree, including `.env`, key, pem, secret, token, and `secrets/` paths
- Git metadata left in the installed app tree
- tracked secret-looking paths if the app tree is still a Git checkout
- Codex, OpenClaw, and OpenAI credential homes in inspected production users
- shell history files with obvious secret hints, without printing the matching secret line
- common development package caches
- active or enabled SSH/sshd unless `AUTOPOIESIS_PRODUCTION_ALLOW_SSH=1` or `--allow-ssh` is set

Required QA gate before imaging or exposing a device:

```bash
/opt/autopoiesis-os/app/scripts/security-smoke.sh
```

The security smoke test starts the local UI against a temporary data directory containing a fake device API key, then verifies that local support/admin/status endpoints do not expose the key or key field names. It also fails if sensitive-looking files such as `.env`, `.pem`, `.key`, or `secrets/` paths are tracked in Git.

Open work:

- remove Codex only after appliance validation
- remove development package caches
- optionally disable SSH
- preserve runtime services and local pairing/config data
