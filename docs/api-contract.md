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
GET  /local/wifi/scan
POST /local/wifi/connect
POST /local/settings
POST /local/pairing/start
GET  /local/pairing/status
POST /local/system/restart
POST /local/system/factory-reset
POST /local/system/update-now
```
