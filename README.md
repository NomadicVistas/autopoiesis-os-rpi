# Autopoiesis OS Raspberry Pi Appliance Layer

Autopoiesis OS turns a Raspberry Pi display into a dedicated fullscreen frame for:

https://autopoiesis.art/display?shuffle=1

This repository is not a custom Linux distribution. It is an appliance layer for Raspberry Pi OS:

- Chromium kiosk launcher
- Local setup/settings UI on `http://localhost:3030`
- Persistent local config in `/var/lib/autopoiesis-os`
- Runtime files in `/opt/autopoiesis-os`
- systemd services and timers
- Mock-compatible API integration points

## Current Prototype

Milestone 2 is scaffolded for physical Pi validation. The local UI can:

- create/read device, preference, and state JSON files
- show setup, settings, local frame, offline, disabled, and launch routes
- show network status for LAN and Wi-Fi through nmcli
- verify the local network onboarding API contract used by setup, support, and physical acceptance
- connect Ethernet/LAN through DHCP when available
- scan and connect Wi-Fi through nmcli
- start a mock pairing flow
- redirect `/launch` to setup, disabled, offline fallback, local frame playback, or the live display route depending on local state and remote reachability
- build a local cache index from eligible feed media through the hourly cache timer
- play the local mixed feed queue at `/frame`, preferring cached assets when available
- show cached feed media on `/offline` when the live display is unreachable
- expose a compact `/local/health` probe for support, admin adapters, and hardware acceptance checks
- expose runtime storage writability diagnostics for data, cache, and log directories
- expose system clock/NTP synchronization diagnostics through health/readiness/support surfaces
- expose touchscreen/input diagnostics through health/readiness/support surfaces
- expose systemd timer diagnostics for heartbeat, command executor, cache, updater, and watchdog loops
- expose a phase-level `/local/readiness` probe for setup, clock, input, pairing, sync, content, local playback, cache, commands, and release rollout checks
- expose `/local/rollout/acceptance` as a redacted setup/staged/production rollout gate for QA, Admin > Frames, and physical device handoffs
- generate a GitHub-style rollout issue report from rollout acceptance plus the redacted support bundle
- verify settings sync conflict handling with newest-`updatedAt` semantics across explicit sync, local push, and heartbeat responses
- expose a redacted `/local/support-bundle` for one-step hardware/support handoff collection
- expose `/local/frame-state` so QA, support, and future admin adapters can inspect the browser-safe local playback queue
- expose a metadata-only `/local/commands/audit` trail for recent remote command attempts
- expose `/local/admin/capabilities` so Admin > Frames can discover role-gated remote action policy
- verify the local admin capabilities contract so remote action controls do not drift from device policy
- generate and verify a redacted Admin/Profile device snapshot from the support bundle for hosted fleet adapters
- expose `/local/events/export` so backend/admin adapters can ingest command, delivery, and release lifecycle evidence through one redacted contract
- expose a metadata-only `/local/release/history` trail for local release check/apply outcomes
- verify command-delivered broadcasts for targeting, scheduling, display-time delivery logs, dismissal, expiry, and acknowledgements
- validate release manifests for channel/tag/artifact/checksum/rollback metadata before an update mutates app code
- verify the unified local event export contract for backend/admin ingestion readiness
- verify heartbeat event ingestion cursor acknowledgements, replay overlap, stale ack rejection, and diagnostics/support visibility
- run a local security smoke test that checks device API key redaction and tracked secret hygiene
- validate a hosted pairing/register/claim/status contract before live account pairing is treated as rollout-ready
- run an appliance preflight that checks root install mode, Node.js, rsync, curl, systemd, Chromium, NetworkManager, and whether the appliance user exists
- create the appliance user during install/bootstrap before runtime directories are chowned
- render systemd units during install/update from the configured app, data, log, user, and home paths instead of hard-coding the default appliance layout
- keep rollback metadata and a pre-update app snapshot for release artifact installs
- run a deliberate factory reset that clears identity, pairing, preferences, commands, feed/cache, and rollout state while preserving app code and logs
- run a kiosk check that proves the Chromium launch command uses Pi-safe software rendering flags
- run a local watchdog timer that restarts setup/kiosk services only when liveness checks fail
- reinstall and enable systemd units during install/update so new timers reach existing devices
- verify setup, kiosk, HTTP, Chromium, clock/NTP sync, touchscreen/input, network, and restart behavior on a Pi

## Install

From this repo:

```bash
sudo ./scripts/preflight.sh --install
sudo ./install.sh
sudo systemctl start autopoiesis-setup.service autopoiesis-kiosk.service
sudo /opt/autopoiesis-os/app/scripts/milestone2-verify.sh
sudo /opt/autopoiesis-os/app/scripts/security-smoke.sh
```

During development you can run the local UI without installing:

```bash
cd local-ui
AUTOPOIESIS_DATA_DIR=/tmp/autopoiesis-os node server.js
```

Run the local security smoke test before shipping an image or exposing the local UI beyond localhost:

```bash
./scripts/security-smoke.sh
```

Check the compact local health summary:

```bash
./scripts/health-check.sh
```

Check the kiosk launch command and any running kiosk process:

```bash
./scripts/kiosk-check.sh
```

Check whether Linux sees the touchscreen/input devices:

```bash
./scripts/touchscreen-check.sh
AUTOPOIESIS_REQUIRE_TOUCHSCREEN=1 ./scripts/touchscreen-check.sh
```

Check the local LAN/Wi-Fi onboarding contract:

```bash
./scripts/network-check.sh
AUTOPOIESIS_REQUIRE_NETWORK_ONLINE=1 ./scripts/network-check.sh
```

Check appliance timer wiring for sync, command, cache, update, and watchdog loops:

```bash
./scripts/systemd-timers-check.sh
```

Check that systemd unit installation honors custom appliance paths and users:

```bash
./scripts/systemd-units-install-check.sh
```

Check system clock/NTP synchronization:

```bash
./scripts/clock-check.sh
AUTOPOIESIS_REQUIRE_CLOCK_SYNC=1 ./scripts/clock-check.sh
```

Check that the local UI can write its runtime data, cache, and log paths:

```bash
./scripts/runtime-storage-check.sh
AUTOPOIESIS_REQUIRE_RUNTIME_STORAGE=1 ./scripts/runtime-storage-check.sh
```

Run the same liveness checks used by the systemd watchdog:

```bash
sudo /opt/autopoiesis-os/app/scripts/watchdog.sh
```

Check rollout readiness across the local integration phases:

```bash
./scripts/readiness-check.sh
```

Check whether a managed device is acceptable for rollout:

```bash
./scripts/rollout-acceptance-check.sh
AUTOPOIESIS_ROLLOUT_PROFILE=setup ./scripts/rollout-acceptance-check.sh
AUTOPOIESIS_ROLLOUT_PROFILE=production AUTOPOIESIS_ROLLOUT_STRICT_CONTENT=1 ./scripts/rollout-acceptance-check.sh
```

Generate a redacted rollout issue note for hardware/support handoff:

```bash
./scripts/rollout-issue-report.sh ./rollout-issue.md
AUTOPOIESIS_ROLLOUT_PROFILE=production AUTOPOIESIS_ROLLOUT_STRICT_CONTENT=1 ./scripts/rollout-issue-report.sh
```

Check the role-gated Admin > Frames remote-action policy contract:

```bash
./scripts/admin-capabilities-check.sh
AUTOPOIESIS_REQUIRE_REMOTE_ADMIN_READY=1 ./scripts/admin-capabilities-check.sh
```

Generate and validate the redacted Admin/Profile device snapshot shape:

```bash
./scripts/admin-device-snapshot-check.sh ./admin-device-snapshot.json
AUTOPOIESIS_REQUIRE_DEVICE_ADMIN_READY=1 ./scripts/admin-device-snapshot-check.sh
```

Check command acknowledgement retry behavior against a mock Frames API:

```bash
./scripts/command-ack-retry-check.sh
```

Check the unified command/delivery/release event export contract:

```bash
./scripts/events-export-check.sh
```

Check heartbeat event ingestion cursor acknowledgement behavior:

```bash
./scripts/events-ingestion-check.sh
```

Inspect the local frame playback queue:

```bash
curl -fsS http://127.0.0.1:3030/local/frame-state
./scripts/frame-state-check.sh
AUTOPOIESIS_REQUIRE_FRAME_ITEMS=1 ./scripts/frame-state-check.sh
```

Run the local stream/playback integration gate:

```bash
./scripts/stream-playback-check.sh
```

This isolated check launches a temporary local UI against a mock Frames API on per-run loopback ports and validates preferred `/stream` sync, legacy `/feed` fallback, artist/category filtering, dashboard rendering, item timing, local like persistence, remote like forwarding, and delivery-log evidence.

Validate a hosted stream response before physical Pi testing:

```bash
./scripts/stream-contract-check.sh /path/to/stream-response.json
AUTOPOIESIS_STREAM_CONTRACT_TOKEN="$TOKEN" ./scripts/stream-contract-check.sh "https://autopoiesis.art/api/frames/device/$DEVICE_ID/stream"
```

The stream contract check validates the hosted `GET /api/frames/device/{deviceId}/stream` response before physical Pi testing. It checks schema version, generated timestamps, settings shape, item identity/media/cache/priority/schedule/targeting fields, duplicate ids, and redaction of local-only or sensitive fields.

Validate the hosted Profile/Admin Frames contract before wiring UI or physical fleet actions:

```bash
./scripts/online-admin-contract-check.sh /path/to/online-admin-bundle.json
AUTOPOIESIS_ONLINE_ADMIN_CONTRACT_TOKEN="$TOKEN" ./scripts/online-admin-contract-check.sh "https://autopoiesis.art/api/admin/frames/online-admin-bundle"
```

The online admin contract check validates a saved or live bundle assembled from Profile > Frames and Admin > Frames endpoints. It checks user devices, pairing metadata, settings, active artists, liked artworks, cache preferences, users, subscribers, subscriptions, fleet devices, role-gated remote actions, an explicit role/action matrix with denied-action reasons, and redaction of device keys, pairing hashes, private tokens, secrets, and local appliance paths.

Validate the hosted pairing lifecycle before physical Pi/account testing:

```bash
./scripts/pairing-contract-check.sh /path/to/pairing-contract-bundle.json
AUTOPOIESIS_PAIRING_CONTRACT_TOKEN="$TOKEN" ./scripts/pairing-contract-check.sh "https://autopoiesis.art/api/admin/frames/pairing-contract-bundle"
```

The pairing contract check validates read-only staging evidence for `POST /api/frames/device/register`, `POST /api/frames/user/devices/pair`, and `GET /api/frames/device/{deviceId}/pairing-status`. It requires a bounded pairing-code TTL, a durable device credential in the registration response, a claimed owner/device relationship after user pairing, settings handoff shape, final paired status, and redaction of pairing hashes, user tokens, secrets, and local appliance paths. The optional adapter endpoint is for CI/staging evidence; it should not run a destructive live pairing flow.

Validate the durable `aos_` database schema before backend/admin/device integration work assumes rows exist:

```bash
./scripts/aos-schema-contract-check.sh /path/to/schema-introspection.json
./scripts/aos-schema-contract-check.sh /path/to/database.sqlite
```

The schema contract check validates the required Frames tables, columns, and primary/unique keys for devices, pairing, settings, preferences, heartbeats, commands, admin audits, events, likes, broadcasts, releases, subscriptions, delivery logs, and rollout records. SQLite database checks require the `sqlite3` CLI; CI can also pass a saved schema JSON fixture.

Validate the hosted `aos_` migration plan before applying it to staging or production:

```bash
./scripts/aos-migration-contract-check.sh /path/to/migrations
./scripts/aos-migration-contract-check.sh /path/to/migration-manifest.json
```

The migration contract check validates deterministic migration ids, `aos_` table/index namespacing, transaction boundaries, MVP table coverage, hashed pairing-code storage, and absence of accidental destructive SQL. Destructive repair or rollback migrations must be explicitly reviewed and run with `AUTOPOIESIS_ALLOW_DESTRUCTIVE_MIGRATIONS=1`.

Validate a release manifest before a device applies it:

```bash
./scripts/release-manifest-check.sh /path/to/release.json
AUTOPOIESIS_RELEASE_CHANNEL=stable AUTOPOIESIS_RELEASE_REQUIRE_CHANNEL=1 AUTOPOIESIS_RELEASE_REQUIRE_TAG=1 AUTOPOIESIS_RELEASE_REQUIRE_ROLLBACK_NOTES=1 ./scripts/release-manifest-check.sh /path/to/release.json
```

The updater runs this check automatically before applying `/local/release/apply` or an `update_device` command. Artifact releases must use HTTPS and include a SHA-256 checksum unless explicitly overridden for local testing. Strict rollout can require channel, GitHub tag, and rollback notes before a production device accepts an update.

Check defensive feed targeting and cache eligibility:

```bash
./scripts/feed-targeting-check.sh
```

This isolated check validates local stream targeting for device, owner, subscriber status, tier, and region shapes; expiry/start-time filtering; priority order; public targeting redaction; delivery evidence; and feed cache manifest eligibility.

Check command-delivered broadcast behavior:

```bash
./scripts/broadcast-command-check.sh
```

This isolated check runs the local command processor against a mock Frames API and validates wrong-target rejection, scheduled broadcasts waiting until `startsAt`, `/launch` routing for active broadcasts, `broadcast_shown` only when `/broadcast` renders, dismissal, expired-command rejection, and command acknowledgements.

Collect a redacted local support bundle:

```bash
./scripts/support-bundle.sh ./support-bundle.json
```

Rollback the last release update on a device after a bad rollout:

    sudo /opt/autopoiesis-os/app/scripts/rollback-release.sh

Preview and run a local factory reset on a device:

    sudo /opt/autopoiesis-os/app/factory-reset.sh --dry-run
    sudo /opt/autopoiesis-os/app/factory-reset.sh

Run one local cache refresh after a feed sync:

```bash
./scripts/cache-artworks.sh
```

Open:

```txt
http://localhost:3030/setup
```

Network setup is available at:

```txt
http://localhost:3030/network
```

## Cron / Hourly Audit

This repo includes `scripts/hourly-audit.sh`. It is intentionally read-only and writes reports under `logs/`.

It does not run Codex unattended and does not modify the system. Automated code changes on an appliance are reserved for explicit, versioned updates.

## Priority

```txt
boot -> setup -> lan/wifi -> config -> kiosk -> pairing -> sync -> cache -> updates -> disable -> cleanup
```

with love pulse
