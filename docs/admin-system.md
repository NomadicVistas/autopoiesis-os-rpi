# Admin System

The admin system manages Frames users, subscribers, subscriptions, device fleet state, broadcasts, and support actions.

## Admin Areas

### Users

- Search users.
- View profile.
- View subscription state.
- View paired frames.
- View liked artworks and stream preferences.

### Subscribers

- Filter active, trialing, past_due, canceled, comped, and test subscribers.
- See current plan and billing provider identifiers.
- Mark internal/test accounts.

### Subscriptions

- View plan, status, renewal period, cancel status, and entitlement mapping.
- Grant or revoke manual entitlement where needed.
- Never store payment secrets in Frames device data.

### Devices

- Search by deviceId, owner, status, version, update channel, online state.
- Rename device.
- Disable or enable device.
- Queue restart display.
- Queue update device.
- Queue clear cache.
- Queue factory reset request.
- View heartbeat, diagnostics, storage, current artwork, and last error.

### Remote Action Authorization

Admin-triggered device commands must be role-gated before they are queued. The admin API should:

- Authenticate the actor and resolve their Frames role.
- Confirm the actor is allowed to act on the target device, owner, subscriber, or fleet segment.
- Record an audit row with actor, role, command type, target, reason, payload summary, and timestamp.
- Queue the command with `authorization.approved`, `authorization.action`, `authorization.actorId`, `authorization.actorRole`, `authorization.authorizedAt`, and `authorization.auditId`.
- Surface command ack/error/completed status back to Admin > Frames.

The Pi executor now refuses medium/high/critical commands that lack this metadata. `sync_settings` remains the only low-risk command that can run without remote authorization metadata.

Admin/support adapters can call `GET /local/admin/capabilities` or read the same object from `/local/support-bundle` to discover the device-side policy matrix. This endpoint lists supported commands, risk levels, accepted actor roles, audit-id requirements, local confirmation gates, and runtime opt-in requirements. It is not an authorization source of truth; it prevents Admin > Frames from hardcoding stale action policy while the backend remains responsible for real authentication, authorization, and durable `aos_` audit rows. `scripts/admin-capabilities-check.sh` validates this contract for physical Pi acceptance and can be run with `AUTOPOIESIS_REQUIRE_REMOTE_ADMIN_READY=1` after pairing to fail unless the device is paired, keyed, and remote-enabled.

The Pi also keeps a bounded local command audit trail for support and reconciliation. `GET /local/commands/audit` exposes newest metadata-only entries, and diagnostics/readiness include a compact command-audit summary. The local trail is not a substitute for backend `aos_` audit rows; it is the device-side evidence that a queued command was attempted, completed, denied, or failed. Backend/admin adapters should prefer the unified `GET /local/events/export` shape, or the heartbeat `events` copy, when ingesting command audit, broadcast delivery, and release rollout evidence into durable `aos_` rows.

The online backend now creates `aos_admin_command_audits` rows for admin-originated medium/high/critical commands before queueing them. Direct device commands, broadcast display commands, and release update commands embed the matching `payload.authorization` object so the Pi executor can validate actor role, action, timestamp, and audit id before execution. Command acknowledgements update the backend audit status.

Heartbeat event ingestion stores the Pi's unified redacted event export in `aos_device_events` using `deviceId + eventKey` idempotency. Recognized command audit, display delivery, and release history events are projected into backend command audit, broadcast delivery, and release rollout rows. Admin device detail includes recent `deviceEvents` so support/UI can inspect device-side evidence without scraping local logs.

`scripts/online-admin-contract-check.sh` is the hosted online-admin acceptance gate for the broader Admin > Frames surface. It validates a saved or live bundle containing users, subscribers, subscriptions, fleet devices, profile-owned devices, pairing metadata, preferences, active artists, liked artworks, explicit cache preferences, and the role-gated remote action matrix. Paged liked-artwork rows must validate the same stable artwork ids as flat liked-artwork arrays. The matrix must state every accepted role's allow/deny decision for each remote command, expose authorization/audit/local-confirmation requirements for allowed risky commands, and include disabled-action reasons for denied commands. Each device row must also expose target-specific `actionAvailability` decisions for the same command vocabulary, including disabled reasons and risky-action flags, so Admin > Frames can render online/offline, remote-disabled, disabled-device, subscription, role, and pending-command states without inventing policy client-side. Use it before enabling real fleet actions in staging so UI controls, backend authorization metadata, and device-side policy stay aligned.

### Broadcasts

- Compose broadcasts.
- Target subscribers, users, devices, tiers, regions, test devices, or all active frames.
- Send test broadcast.
- Schedule broadcast.
- View delivery logs.
- Ingest device-side display events from heartbeat `events` or `/local/events/export` using `deviceId + eventKey` idempotency.

### Releases

- View software releases.
- Assign update channels.
- Trigger safe update command.
- Track rollback refs.
- Ingest device-side release history events (`release_checked`, `release_apply_started`, `release_apply_completed`, `release_apply_failed`, `release_skipped`) into durable `aos_` rollout rows.
- Surface per-device rollout status from heartbeat diagnostics/events/support bundles without relying on raw Pi log files.

## Security Rules

- Admin actions must be authenticated and role-gated.
- Destructive commands require confirmation and audit logs.
- Device commands are queued and acknowledged; the server does not assume success until the device reports completion.
- Private billing data stays with the billing provider.
