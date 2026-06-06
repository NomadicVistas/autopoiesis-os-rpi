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

`scripts/online-admin-contract-check.sh` validates the online Profile > Frames surface together with Admin > Frames. The profile portion must expose owned devices, pairing metadata, authoritative settings, active artists, liked artworks, and cache preferences without leaking stored device keys, pairing-code hashes, private tokens, secrets, or local appliance paths. The admin portion must also expose explicit role/action decisions so Profile-owned frame actions and Admin fleet actions use the same authorization vocabulary.
