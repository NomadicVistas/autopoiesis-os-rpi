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
