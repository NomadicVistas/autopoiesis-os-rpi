# Backend Issue: Online Admin Device Action Availability

## Summary

`scripts/online-admin-contract-check.sh` now requires every Profile/Admin device row to expose target-specific remote-action availability. The existing global `remoteActions.roleActionMatrix` remains the actor policy source, but UI controls also need a per-device decision for whether each action can be used on this exact frame right now.

## Required Bundle Shape

Add `actionAvailability`, `availableActions`, or `remoteActionAvailability` to each `profileFrames.devices[]` row and each `adminFrames.devices.items[]` row.

The object must include one decision for every supported command:

- `sync_settings`
- `clear_cache`
- `restart_display`
- `enable_device`
- `disable_device`
- `restart_device`
- `update_device`
- `show_broadcast`
- `factory_reset_request`

Allowed decisions should include the same risky-action flags exposed by the global command policy:

```json
{
  "allowed": true,
  "requiresAuthorization": true,
  "requiresAuditId": true,
  "requiresLocalConfirmation": false
}
```

Denied decisions must include a short reason, and may include a stable reason code:

```json
{
  "allowed": false,
  "disabledReason": "Device is offline",
  "reasonCode": "offline"
}
```

Recommended reason codes:

- `offline`
- `remote_disabled`
- `device_disabled`
- `subscription_inactive`
- `role_denied`
- `not_paired`
- `pending_command`
- `local_confirmation_required`

## Acceptance

Generate a staging/CI online-admin bundle and run:

```bash
./scripts/online-admin-contract-check.sh /path/to/online-admin-bundle.json
```

The check should fail if:

- Any Profile/Admin device row is missing action availability.
- Any supported command lacks a target-specific decision.
- A denied target decision lacks a reason.
- An allowed high/critical action does not mirror the global audit-id requirement.
- An allowed critical action does not mirror local-confirmation requirement.

## Open Question

Decide whether Profile-owned device rows should evaluate actions as the current owner role, while Admin fleet rows evaluate actions as the authenticated admin actor role. The contract accepts either as long as each decision is explicit and the denied reason is user-facing enough for disabled controls.
