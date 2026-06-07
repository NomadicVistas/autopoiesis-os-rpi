# GitHub Updates

Phase 1 uses a stable branch pull:

```txt
main = stable production
develop = experimental
```

The placeholder updater checks whether `/opt/autopoiesis-os/app` is a Git checkout. If it is not, it logs and exits.

Production target:

- install releases under `/opt/autopoiesis-os/releases/vX.Y.Z`
- point `/opt/autopoiesis-os/current` to the active release
- preserve `/var/lib/autopoiesis-os`
- rollback when health checks fail
- restart services after successful update

Current rollback foundation:

- `scripts/update-from-release.sh` writes `/var/lib/autopoiesis-os/release-rollback.json` before applying an update.
- Release apply infers the expected channel from `/var/lib/autopoiesis-os/device.json` `updateChannel` when no explicit environment channel is set, then rejects manifests that omit or mismatch that channel before mutating app code.
- Git-checkout updates record the previous revision and can roll back with `git reset --hard` to that revision.
- Artifact updates snapshot the current app into `/opt/autopoiesis-os/releases/rollback/app` before replacing app files.
- Rollback metadata records release channel, tag, and release id so support can tie a rollback to the Admin rollout row without storing artifact URLs or checksums.
- `scripts/rollback-release.sh` restores the previous git revision or snapshot, reruns bootstrap/systemd unit installation, restarts setup/kiosk services, writes `release-state.json`, and appends metadata-only rollback events to `release-log.json`.
- Device-local data in `/var/lib/autopoiesis-os` is not restored or deleted by rollback, so pairing, device API keys, preferences, cache state, and logs survive an app-code revert.
