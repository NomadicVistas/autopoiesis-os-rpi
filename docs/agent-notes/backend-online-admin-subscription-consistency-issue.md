# Backend Issue: Online Admin Subscription Consistency

Generate the online-admin bundle so Admin > Frames account, subscriber, subscription, and fleet ownership rows are join-consistent before subscription-gated frame controls are considered staging-ready.

## Why

`scripts/online-admin-contract-check.sh` already validates the broad Profile/Admin Frames response shape, cache preferences, role/action policy, and per-device action availability. The remaining risk was that the bundle could pass with disconnected admin pages: subscriber rows for unknown users, active subscriptions without subscriber evidence, device owners absent from the user page, or device subscription summaries pointing at ids the admin subscription page does not expose.

That would make Admin > Frames look usable while subscription-gated actions, fleet filters, and support views were assembled from inconsistent data.

## Required Evidence

The bundle should be assembled from durable `aos_` rows plus the canonical account/subscription model and include:

- `adminFrames.users.items[].userId`
- `adminFrames.subscribers.items[].userId`
- `adminFrames.subscribers.items[].subscriptionId` when a canonical subscription id is available
- `adminFrames.subscriptions.items[].subscriptionId`
- `adminFrames.subscriptions.items[].userId`
- `adminFrames.devices.items[].ownerUserId`
- `adminFrames.devices.items[].subscription.subscriptionId` when the device row exposes subscription state

The checker now rejects:

- duplicate user, subscriber, subscription, or fleet device ids
- subscriber rows whose user is absent from `adminFrames.users`
- subscription rows whose user is absent from `adminFrames.users`
- entitled subscriptions (`active`, `trialing`, `past_due`, `comped`) without a matching subscriber row
- subscriber `subscriptionId` values absent from `adminFrames.subscriptions`
- fleet device owners absent from `adminFrames.users`
- device subscription ids absent from `adminFrames.subscriptions`
- page `total` values smaller than `items.length`

## Acceptance

```bash
./scripts/online-admin-contract-check.sh /path/to/online-admin-bundle.json
AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE=online-admin \
  AUTOPOIESIS_ONLINE_ADMIN_CONTRACT_SOURCE=/path/to/online-admin-bundle.json \
  ./scripts/hosted-contract-suite-check.sh
```

## Open Question

Which billing/subscription provider is canonical for production entitlement status? The contract accepts common normalized statuses, but the adapter should perform that normalization in one place before UI and fleet-action logic consume it.
