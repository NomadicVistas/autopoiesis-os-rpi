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

### Broadcasts

- Compose broadcasts.
- Target subscribers, users, devices, tiers, regions, test devices, or all active frames.
- Send test broadcast.
- Schedule broadcast.
- View delivery logs.

### Releases

- View software releases.
- Assign update channels.
- Trigger safe update command.
- Track rollback refs.

## Security Rules

- Admin actions must be authenticated and role-gated.
- Destructive commands require confirmation and audit logs.
- Device commands are queued and acknowledged; the server does not assume success until the device reports completion.
- Private billing data stays with the billing provider.
