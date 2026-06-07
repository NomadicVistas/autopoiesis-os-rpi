# Backend Online Admin Profile Coherence Issue

## Context

`scripts/online-admin-contract-check.sh` already validates the broad Profile/Admin Frames bundle, account/subscription joins, remote action policy, and target-specific action availability. The remaining profile risk was contradictory state inside Profile > Frames itself: cache toggles could disagree between `preferences` and `cachePreferences`, active artist selections could drift from active artist rows, and duplicate liked artwork ids could render as repeated or unstable UI rows.

## Required Evidence

Generate the online-admin bundle from the same hosted sources the UI uses:

- `profileFrames.preferences` from durable user/device preference rows.
- `profileFrames.cachePreferences` from the canonical cache policy projection.
- `profileFrames.activeArtists` from canonical artist rows plus the user's selected artists.
- `profileFrames.likedArtworks` from canonical likes or an `aos_` mirror with stable artwork ids.

The bundle must now prove:

- Cache fields mirrored in `preferences` match `cachePreferences.enabled`, `likedArtworks`, `recentArtworks`, `selectedArtists`, and `sizeLimitMb`.
- `activeArtists` contains no duplicate artist ids.
- Any `preferences.activeArtists` id exists in `activeArtists` and is not explicitly disabled.
- If `activeArtists` includes enabled rows while `preferences.activeArtists` is present, each enabled id appears in preferences.
- Liked artwork ids are unique in both flat and paged forms.
- Paged liked artwork totals are at least the number of returned rows.

## Acceptance

```bash
./scripts/online-admin-contract-check.sh /path/to/online-admin-bundle.json
AUTOPOIESIS_ONLINE_ADMIN_CONTRACT_SOURCE=/path/to/online-admin-bundle.json \
  AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE=online-admin \
  ./scripts/hosted-contract-suite-check.sh
```

Do not enable Profile > Frames cache controls, active artist toggles, or liked artwork pagination against staging data until this gate passes against real hosted evidence.
