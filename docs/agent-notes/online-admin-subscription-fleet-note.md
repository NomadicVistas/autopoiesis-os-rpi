# Online Admin Subscription & Fleet Action Endpoints

**Date:** 2026-06-08
**Workstream:** ONLINE ADMIN
**Status:** Implemented

## What

Added subscription CRUD admin endpoints and device fleet action endpoints to the hosted API. These are the missing **write** operations for the online admin platform — the admin dashboard could view data (via admin bundle) but couldn't manage subscriptions, device states, or queue remote actions.

## New Endpoints

### Subscription Management (4 endpoints)

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/frames/admin/subscriptions` | Create subscription (validates plan/status, 409 on duplicate) |
| GET | `/frames/admin/subscriptions/:userId` | Get subscription + computed entitlements |
| PATCH | `/frames/admin/subscriptions/:userId` | Update plan/status/provider |
| POST | `/frames/admin/subscriptions/:userId/cancel` | Cancel subscription (409 on already cancelled) |

### Device Fleet Management (2 endpoints)

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/frames/admin/devices/:id/actions` | Queue remote action (role-action matrix + device-state gated) |
| PATCH | `/frames/admin/devices/:id` | Update device properties (disabled, remoteEnabled, deviceName, updateChannel) |

## Key Design Decisions

1. **Plan validation**: All 4 PLAN_LIMITS tiers are validated (`frames_trial`, `frames_basic`, `frames_premium`, `frames_enterprise`). Invalid plans return 400 with valid options listed.

2. **Status validation**: 6 valid statuses (`trial`, `active`, `expired`, `cancelled`, `past_due`, `inactive`). Invalid status returns 400.

3. **Idempotent cancel**: Cancelling an already-cancelled subscription returns 400 with "already cancelled" — not a silent success.

4. **Double-create protection**: Creating a subscription for a user who already has one returns 409 with the existing subscription.

5. **Action validation through full matrix**: `handleAdminDeviceAction()` validates against the full 5-layer gating (subscription → role → paired → disabled/remote → online). Blocked actions return 409 with `reasonCode` and `deviceState`.

6. **Disabled column migration**: Added `disabled INTEGER NOT NULL DEFAULT 0` to `aos_frame_devices` via migration `20260608000002_add_device_disabled_column.sql`.

7. **Risk mapping**: Each action maps to a risk level (low/medium/high/critical) stored on the queued command. Factory reset is `critical`.

## Validation

- `scripts/online-admin-subscription-fleet-check.sh` — 15-step 100-check gate covering all CRUD, cancel, device actions, auth gates, error cases, and regression.
- All existing check suites pass (heartbeat-persistence 33/33, admin-auth 38/38, security-smoke).

## Next Steps

- Wire these endpoints into the admin dashboard frontend.
- Add user preferences admin endpoint (GET/PATCH `/frames/admin/users/:id/preferences`).
- Add subscription reactivation endpoint (POST `/frames/admin/subscriptions/:userId/reactivate`).
- Add device fleet bulk actions (batch enable/disable/update).
- Add audit trail logging for subscription changes and device state changes.
