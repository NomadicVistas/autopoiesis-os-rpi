# Backend Issue: Add AOS Migration Contract Gate

## Summary

Add `scripts/aos-migration-contract-check.sh` to backend migration CI before Frames database migrations are applied to staging or production.

## Context

The final schema gate already validates the durable `aos_` table contract after migrations have run. This new gate checks the migration plan before mutation, so unsafe database changes fail before they can damage paired devices, command queues, heartbeat/event ingestion, broadcast delivery, or release rollout evidence.

## Acceptance

- Run the gate against either the backend migrations directory or a migration manifest exported by the migration tool.
- Migration ids are deterministic and sortable, such as `202606061845_create_aos_frames.sql`.
- SQL migrations are wrapped in `BEGIN`/`COMMIT`, unless a manifest marks a migration `nonTransactional`.
- DDL/DML table and index names touched by Frames migrations use the `aos_` namespace.
- The plan covers the MVP durable tables required by `scripts/aos-schema-contract-check.sh`.
- Persistent pairing storage uses `pairing_code_hash`, not plaintext `pairing_code`.
- DROP, TRUNCATE, unconditional DELETE, and broad UPDATE statements fail unless `AUTOPOIESIS_ALLOW_DESTRUCTIVE_MIGRATIONS=1` is explicitly set for a reviewed repair/rollback migration.
- The gate is followed by `scripts/aos-schema-contract-check.sh` against the migrated staging database or exported final schema.

## Commands

```bash
scripts/aos-migration-contract-check.sh /path/to/migrations
scripts/aos-schema-contract-check.sh /path/to/schema-introspection.json
```

## Open Questions

- Which migration tool will be canonical for the hosted app, and can it export a manifest with `migrations` and `finalSchema.tables`?
- Should destructive repair migrations require a linked release/audit id in CI metadata?
- Where should pre-migration backup evidence be stored for the first production Frames rollout?
