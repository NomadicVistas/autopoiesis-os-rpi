# Admin Command Audit Logging + Fleet-Wide Command Queue

**Date:** 2026-06-09
**Workstream:** ONLINE ADMIN
**Milestone:** Command audit trail and fleet-wide command queue visibility

## What Changed

Populated the `aos_admin_command_audits` table for the first time. It existed in the schema since bootstrap but was never written to.

### db.js — 4 new methods

- `logCommandAudit(opts)` — writes audit record on admin command action
- `updateCommandAuditStatus(commandId, status, error)` — updates audit on device ack
- `listAllCommands(opts)` — fleet-wide command listing with filters + pagination
- `listCommandAudits(opts)` — audit trail listing with filters + pagination

### server.js — wiring + endpoints

- `handleAdminDeviceAction` now calls `db.logCommandAudit()` after queueing (try/catch guarded)
- `handleCommandAck` now calls `db.updateCommandAuditStatus()` after ack
- Fixed commandId extraction from `queueCommand()` return (`command.command.commandId`)
- `GET /frames/admin/commands` — fleet-wide command queue (admin-only, filtered, paginated)
- `GET /frames/admin/command-audits` — audit trail (admin-only, filtered, paginated)

### Validation

- `scripts/admin-command-audit-fleet-queue-check.sh` — 10 steps, 75 checks, all green

## Design Decisions

- Audit logging is try/catch guarded: audit failures never break command queue
- CommandId used as the link between `aos_device_commands` and `aos_admin_command_audits`
- `actorId` currently hardcoded to "admin" — will change when multi-admin is supported
- `authorization` field captures the full action availability + deviceState at action time

## Gaps / Next Steps

- No frontend wiring yet (admin dashboard needs Commands + Audit views)
- No audit retention policy
- No bulk action support
- actorId is static "admin" until multi-admin auth is implemented
