# Mock Hosted API

## Overview

`scripts/mock-hosted-api/server.js` provides a minimal in-memory mock of the hosted Frames API that the device-side local UI calls. It is used by `scripts/device-lifecycle-check.sh` to prove the full device lifecycle without the real backend.

## API Endpoints

| Endpoint | Method | Purpose |
|---|---|---|
| `/frames/device/register` | POST | Register device, return pairing code + API key |
| `/frames/device/:id/pairing-status` | GET | Check pairing state |
| `/frames/device/:id/settings` | GET | Read device settings |
| `/frames/device/:id/settings` | POST | Push device settings (newest-wins) |
| `/frames/device/:id/heartbeat` | POST | Heartbeat + event ingestion + command delivery |
| `/frames/device/:id/stream` | GET | Content stream with mock artwork + broadcast |
| `/frames/device/:id/feed` | GET | Feed alias for stream |
| `/frames/device/:id/commands/:cmdId/ack` | POST | Acknowledge command |
| `/frames/device/:id/release` | GET | Check for release update |
| `/frames/artworks/:id/like` | POST | Like artwork |

## Test Helpers

| Endpoint | Method | Purpose |
|---|---|---|
| `/mock/pair-device/:id` | POST | Force-pair a registered device |
| `/mock/queue-command/:id` | POST | Queue a command for a device |
| `/mock/set-release/:id` | POST | Set a mock release for a device |
| `/mock/state` | GET | Dump all device state |

## Limitations

- No request schema validation (the hosted contract checkers handle that).
- No persistent storage; state is in-memory only.
- No authentication enforcement on all routes (test helpers skip auth).
- Content stream returns static mock items, not personalized content.
- Event ingestion is basic; no cursor replay or deduplication.

## Usage

```bash
# Start mock API on default port 3131
node scripts/mock-hosted-api/server.js

# Start with custom port
MOCK_API_PORT=4030 node scripts/mock-hosted-api/server.js

# Run full lifecycle test
./scripts/device-lifecycle-check.sh
```
