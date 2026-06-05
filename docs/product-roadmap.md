# Product Roadmap

## MVP 0.1 - Pairable Frames Device

Goal: a real device can be installed, connected, paired, seen online, and launched into the Frames stream.

Acceptance:

- Pi boots into setup.
- User connects LAN or Wi-Fi through local setup.
- Device registers with online Frames API.
- Device displays a pairing code.
- User enters code under Profile > Frames.
- Settings sync from online profile to device.
- Local setting changes sync back online.
- Kiosk opens /frames fullscreen.
- Heartbeat works.
- Device appears in online profile.

## MVP 0.2 - Personal Stream

- Active artist preferences.
- Liked artworks.
- Stream mode selection.
- Content type filters for image, video, audio, web, generative, blog, news, and curatorial notes.
- Sound preferences.
- Personalized feed endpoint.

## MVP 0.3 - Offline Living Frame

- Cache liked artworks.
- Cache recent artworks.
- Cache selected artists.
- Bundled fallback works.
- Offline playback without technical error screens.
- Cache management UI.

## MVP 0.4 - Broadcast System

- Admin broadcast composer.
- Targeting by all devices, subscriber status, user, device, tier, artist followers, region, and test devices.
- Device polling endpoint.
- Delivery logs.
- Expiry, priority, repeat count, dismissible flags, and media support.

## MVP 0.5 - Managed Device Fleet

- Remote disable and enable.
- Restart display command.
- Update device command.
- Clear cache command.
- Diagnostics, storage, software version, update channel, and release tracking.

## MVP 1.0 - Production Installer

- One-command install from GitHub.
- Stable main branch or tagged release channel.
- Safe updater with rollback.
- Production cleanup and no development secrets.
- Tested on physical Raspberry Pi hardware.

