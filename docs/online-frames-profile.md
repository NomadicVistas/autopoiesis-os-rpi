# Online Frames Profile

The online app is the source of truth for user settings and paired Frames devices.

## Navigation

Profile

- Account
- Subscription
- Frames
- Billing

Frames

- My Frames
- Pair New Frame
- Stream Preferences
- Artist Preferences
- Sound Preferences
- Liked Artworks
- Offline Cache
- Broadcast History

## My Frames

Show:

- device name
- online/offline
- current mode
- current artwork
- software version
- last heartbeat
- storage status
- remote enabled or disabled
- update status
- action availability and disabled-action reasons

Actions:

- rename
- edit settings
- restart display
- update device
- disable device
- remove device
- factory reset request

## Pair New Frame

- User enters pairing code shown on device.
- Server validates code.
- Device becomes owned by user.
- Device receives profile settings.
- Device appears in My Frames.

`scripts/pairing-contract-check.sh` is the staging/CI gate for this lifecycle. It validates device registration evidence, authenticated user claim evidence, and final device pairing-status evidence before physical Pi/account testing depends on the hosted flow. Profile-facing pairing responses must not expose stored device API keys or pairing-code hashes; the raw active pairing code is only for the registering device while the code is still valid.

## Stream Preferences

- living stream
- calm mode
- active mode
- experimental mode
- liked works only
- artist rotation
- news/blog/art blend
- content filters

## Artist Preferences

Initial artist examples:

- Spool
- Kinema
- Future artists

## Sound Preferences

- sound on/off
- default volume
- autoplay sound
- fade in/out
- night mute
- sound works only during active hours

## Offline Cache

- cache liked artworks
- cache recent artworks
- cache selected artists
- clear device cache
- set cache size limit

## Contract Gate

`scripts/online-admin-contract-check.sh` validates the online Profile > Frames surface together with Admin > Frames. The profile portion must expose owned devices, pairing metadata, authoritative settings, active artists, liked artworks, explicit cache preferences, and per-device action availability without leaking stored device keys, pairing-code hashes, private tokens, secrets, or local appliance paths. Each profile device row must include ownerUserId matching profileFrames.userId, so Profile > Frames never has to infer ownership from the enclosing response alone. Cache preferences must include the enabled state, liked/recent/selected-artist cache toggles, and size limit, and they must agree with mirrored cache fields in preferences when both are present. Active artist ids and liked artwork ids must be unique; active artist rows must also agree with any `preferences.activeArtists` selection list. Paged liked-artwork rows must still expose stable artwork ids and totals that cover the returned rows. Device action availability must include one explicit allow/deny decision for each remote command, with disabled reasons when a button should not be active. The admin portion must expose internally consistent user, subscriber, subscription, and fleet-owner references plus explicit role/action decisions so Profile-owned frame actions and Admin fleet actions use the same authorization vocabulary.

`scripts/profile-ownership-contract-check.sh` is the account/session scoping gate for Profile > Frames. It requires staging evidence that a signed-in owner can list/read/write only their own frame, that another owner cannot read, write settings for, or queue commands against that frame, that anonymous profile requests are rejected, and that Admin fleet reads happen through the admin boundary rather than ordinary Profile routes. Run it before wiring destructive owner actions or treating Profile settings sync as account-safe.
