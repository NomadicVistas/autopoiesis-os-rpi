# API Contract

Base:

```txt
https://autopoiesis.art/api
```

The local prototype does not assume these endpoints exist yet.

## Register Device

```txt
POST /api/frames/device/register
```

## Pairing Status

```txt
GET /api/frames/device/{deviceId}/pairing-status
```

## Settings

```txt
GET /api/frames/device/{deviceId}/settings
POST /api/frames/device/{deviceId}/settings
```

## Heartbeat

```txt
POST /api/frames/device/{deviceId}/heartbeat
```

## Artwork Feed

```txt
GET /api/frames/device/{deviceId}/artwork-feed
```

## Local Internal API

```txt
GET  /local/status
GET  /local/network/status
POST /local/lan/connect
GET  /local/wifi/scan
GET  /local/wifi/scan.json
POST /local/wifi/connect
POST /local/settings
POST /local/pairing/start
GET  /local/pairing/status
POST /local/system/restart
POST /local/system/factory-reset
POST /local/system/update-now
```

## Minimum Frames API

Device lifecycle:

- POST /api/frames/device/register
- GET /api/frames/device/{deviceId}/pairing-status
- POST /api/frames/device/{deviceId}/pair
- POST /api/frames/device/{deviceId}/heartbeat

Settings sync:

- GET /api/frames/device/{deviceId}/settings
- POST /api/frames/device/{deviceId}/settings
- GET /api/frames/user/preferences
- POST /api/frames/user/preferences
- GET /api/frames/user/devices
- POST /api/frames/user/devices/pair

Content stream:

- GET /api/frames/device/{deviceId}/feed
- GET /api/frames/device/{deviceId}/broadcasts
- POST /api/frames/artworks/{artworkId}/like
- DELETE /api/frames/artworks/{artworkId}/like

Commands:

- GET /api/frames/device/{deviceId}/commands
- POST /api/frames/device/{deviceId}/commands/{commandId}/ack

## Admin API

Users and subscribers:

- GET /api/admin/frames/users
- GET /api/admin/frames/users/{userId}
- GET /api/admin/frames/subscribers
- GET /api/admin/frames/subscriptions

Devices:

- GET /api/admin/frames/devices
- GET /api/admin/frames/devices/{deviceId}
- POST /api/admin/frames/devices/{deviceId}/disable
- POST /api/admin/frames/devices/{deviceId}/enable
- POST /api/admin/frames/devices/{deviceId}/commands
- GET /api/admin/frames/devices/{deviceId}/logs
- GET /api/admin/frames/devices/{deviceId}/heartbeats

Broadcasts:

- GET /api/admin/frames/broadcasts
- POST /api/admin/frames/broadcasts
- GET /api/admin/frames/broadcasts/{broadcastId}
- POST /api/admin/frames/broadcasts/{broadcastId}/send-test
- POST /api/admin/frames/broadcasts/{broadcastId}/cancel
- GET /api/admin/frames/broadcasts/{broadcastId}/deliveries

Releases:

- GET /api/admin/frames/releases
- POST /api/admin/frames/releases
- POST /api/admin/frames/releases/{releaseId}/promote
- POST /api/admin/frames/releases/{releaseId}/rollback

## Content Feed Item

Fields:

- id
- type
- title
- artist
- body
- url
- mediaUrl
- thumbnailUrl
- duration
- soundRequired
- cacheAllowed
- priority
- visibility
- createdAt
- expiresAt

Supported types:

- artwork_image
- artwork_video
- artwork_audio
- artwork_web
- artwork_generative
- news
- blog
- artist_update
- curatorial_note
- broadcast_message
- broadcast_media
- system_notice

## Command Types

- restart_display
- restart_device
- update_device
- clear_cache
- sync_settings
- disable_device
- enable_device
- show_broadcast
- factory_reset_request
