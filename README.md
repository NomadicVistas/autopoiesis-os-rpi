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
- refresh the local stream from the heartbeat loop when hosted polling cadence marks it due or stale
- play the local mixed feed queue at `/frame`, preferring cached assets when available
- show cached feed media on `/offline` when the live display is unreachable
- expose a compact `/local/health` probe for support, admin adapters, and hardware acceptance checks
- expose runtime storage writability diagnostics for data, cache, and log directories
- expose a hardware profile that marks Raspberry Pi 5 as recommended, Raspberry Pi 4 as the supported baseline, and Pi 3/older as underpowered for Chromium kiosk rollout
- expose system clock/NTP synchronization diagnostics through health/readiness/support surfaces
- expose touchscreen/input diagnostics through health/readiness/support surfaces
- expose systemd timer diagnostics for heartbeat, command executor, cache, updater, and watchdog loops
- verify the heartbeat timer wrapper logs local state, reaches the local heartbeat route, records local UI failures, and survives missing or malformed pre-pairing state
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
- run the hosted contract suite for migration, schema, pairing, device-auth, settings conflict, profile ownership, heartbeat, command polling, command acknowledgement, command state, stream, cache, online-admin, broadcast, release, and rollout readiness before physical Pi testing
- verify the unified local event export contract for backend/admin ingestion readiness
- verify heartbeat event ingestion cursor acknowledgements, replay overlap, stale ack rejection, and diagnostics/support visibility
- run a local security smoke test that checks device API key redaction and tracked secret hygiene
- run a production cleanup audit that fails on app-tree secrets, Git metadata, Codex/OpenClaw/OpenAI homes, shell-history secret hints, development caches, and SSH exposure
- run an isolated factory reset contract check that proves identity, pairing, runtime, cache, support-history, dry-run, and service-restart behavior before a real reset touches device state
- validate a hosted pairing/register/claim/status contract before live account pairing is treated as rollout-ready
- run an appliance preflight that checks app-tree completeness, local UI syntax, root install mode, Node.js, rsync, curl, systemd, target volume free space, Chromium, NetworkManager, and whether the appliance user exists
- create the appliance user during install/bootstrap before runtime directories are chowned
- render systemd units during install/update from the configured app, data, log, user, and home paths instead of hard-coding the default appliance layout
- launch the setup/local UI from the configured or installed app path instead of assuming the default `/opt/autopoiesis-os` layout
- keep rollback metadata and a pre-update app snapshot for release artifact installs
- run a deliberate factory reset that clears identity, pairing, preferences, commands, feed/cache, and rollout state while preserving app code and logs
- run a kiosk check that proves the Chromium launch command uses Pi-safe software rendering flags
- run a hardware profile check that fails physical acceptance on underpowered Pi hardware while allowing x86_64 development hosts
- run a fixture-backed hardware profile gate that proves Pi 5, Pi 4, Pi 3, and throttling classifications without physical hardware
- run a local watchdog timer plus isolated acceptance gate that restarts setup/kiosk services only when liveness checks fail
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

The install preflight fails if the appliance checkout is missing required
config, local UI, script, service, timer, or version files, or if
`local-ui/server.js` does not parse. It also fails when the selected install,
data, or log volumes have less than 1024 MB free. Override the app tree with
`AUTOPOIESIS_PREFLIGHT_APP_ROOT` for isolated fixtures. Override the disk
threshold with `AUTOPOIESIS_PREFLIGHT_MIN_FREE_MB` when building constrained
test images, or set it to `0` to disable the disk-space gate deliberately.
Hardware preflight treats Raspberry Pi 5 as the recommended target and
Raspberry Pi 4 4GB as the supported baseline. Raspberry Pi 3 and older boards
are reported as underpowered for the Chromium kiosk appliance.

During development you can run the local UI without installing:

```bash
cd local-ui
AUTOPOIESIS_DATA_DIR=/tmp/autopoiesis-os node server.js
```

Run the local security smoke test before shipping an image or exposing the local UI beyond localhost:

```bash
./scripts/security-smoke.sh
```

Run the production hygiene audit before imaging a final device:

```bash
AUTOPOIESIS_PRODUCTION_CLEANUP_STRICT=1 sudo /opt/autopoiesis-os/app/scripts/cleanup-production.sh
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

Check the heartbeat timer wrapper without touching a real Frames API:

```bash
./scripts/heartbeat-runner-check.sh
```

Check that systemd unit installation honors custom appliance paths and users:

```bash
./scripts/systemd-units-install-check.sh
```

Check that the setup/local UI launcher honors custom appliance paths:

~~~bash
./scripts/setup-launcher-check.sh
~~~

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
./scripts/watchdog-check.sh
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

Validate hosted command polling before treating remote commands as staging-ready:

    ./scripts/command-poll-contract-check.sh /path/to/command-poll-contract-bundle.json
    AUTOPOIESIS_COMMAND_POLL_CONTRACT_TOKEN="$TOKEN" ./scripts/command-poll-contract-check.sh "https://autopoiesis.art/api/admin/frames/command-poll-contract-bundle"

The command poll contract check validates read-only staging/CI evidence that durable aos_device_commands rows become exactly the redacted command set returned to one authorized device. It proves queued rows for the device are returned once, other-device and ineligible rows are excluded, denied/blocked polls return no commands, risky commands carry approved authorization metadata, high/critical commands carry audit ids, and sensitive/local-only fields are redacted.

Validate hosted command acknowledgement persistence before treating remote commands as staging-ready:

```bash
./scripts/command-ack-contract-check.sh /path/to/command-ack-contract-bundle.json
AUTOPOIESIS_COMMAND_ACK_CONTRACT_TOKEN="$TOKEN" ./scripts/command-ack-contract-check.sh "https://autopoiesis.art/api/admin/frames/command-ack-contract-bundle"
```

The command ack contract check validates read-only staging/CI evidence that `POST /api/frames/device/{deviceId}/commands/{commandId}/ack` updates durable `aos_device_commands`, mirrors status into `aos_admin_command_audits`, ingests `command_audit` events idempotently by `deviceId + eventKey`, and handles duplicate final acknowledgements without creating duplicate effects. It rejects raw command payloads, credentials, tokens, release artifact details, checksums, stdout/stderr, and local appliance paths.

Validate hosted command state transitions before treating remote commands as staging-ready:

```bash
./scripts/command-state-contract-check.sh /path/to/command-state-contract-bundle.json
AUTOPOIESIS_COMMAND_STATE_CONTRACT_TOKEN="$TOKEN" ./scripts/command-state-contract-check.sh "https://autopoiesis.art/api/admin/frames/command-state-contract-bundle"
```

The command state contract check validates read-only staging/CI evidence that a durable `aos_device_commands` row moves from queued before poll, to delivered/sent after poll, to terminal after acknowledgement, mirrors terminal status into `aos_admin_command_audits`, and is not returned by the next device poll. It rejects raw command payloads, credentials, tokens, release artifact details, checksums, stdout/stderr, and local appliance paths.

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

The stream contract check validates the hosted `GET /api/frames/device/{deviceId}/stream` response before physical Pi testing. It checks schema version, generated timestamps, settings shape, optional polling/refresh cadence metadata, unique displayable item identity, supported mixed-content type/category mapping, cache/priority/targeting fields, active schedule windows relative to `generatedAt`, duplicate ids, and redaction of local-only or sensitive fields. Set `AUTOPOIESIS_REQUIRE_STREAM_POLLING=1` when staging must prove backend-provided poll cadence before device rollout.

Validate the hosted cache/offline contract before enabling cache-management UI or production offline fallback:

```bash
./scripts/cache-contract-check.sh /path/to/cache-contract-bundle.json
AUTOPOIESIS_CACHE_CONTRACT_TOKEN="$TOKEN" ./scripts/cache-contract-check.sh "https://autopoiesis.art/api/admin/frames/cache-contract-bundle"
```

The cache contract check validates read-only staging/CI evidence that hosted Profile > Frames cache preferences, stream cache candidates, and device cache/offline summaries line up. It requires explicit cache policy booleans and size limits, HTTP(S) cache candidate URLs, cache status counts, duplicate-id rejection, and redaction of credentials plus local appliance/cache paths.

Validate the hosted Profile/Admin Frames contract before wiring UI or physical fleet actions:

```bash
./scripts/online-admin-contract-check.sh /path/to/online-admin-bundle.json
AUTOPOIESIS_ONLINE_ADMIN_CONTRACT_TOKEN="$TOKEN" ./scripts/online-admin-contract-check.sh "https://autopoiesis.art/api/admin/frames/online-admin-bundle"
```

The online admin contract check validates a saved or live bundle assembled from Profile > Frames and Admin > Frames endpoints. It checks user devices, pairing metadata, settings, active artists, liked artworks, explicit cache preferences, users, subscribers, subscriptions, fleet devices, role-gated remote actions, an explicit role/action matrix with denied-action reasons, per-device action availability with disabled-action reasons, and redaction of device keys, pairing hashes, private tokens, secrets, and local appliance paths. Profile cache preferences must agree with any mirrored cache settings, active artist ids must be unique and agree with preference selections, and liked artwork ids must be unique. Profile device rows must expose ownerUserId matching the profile user. Admin users, subscribers, subscriptions, and fleet devices must cross-reference cleanly so staged UI cannot show orphaned owners, subscriber rows, subscription ids, or device ownership; subscriber and fleet-device subscription summaries must also belong to the same owner and match referenced subscription status/plan/tier when those fields are present.

Validate the hosted pairing lifecycle before physical Pi/account testing:

```bash
./scripts/pairing-contract-check.sh /path/to/pairing-contract-bundle.json
AUTOPOIESIS_PAIRING_CONTRACT_TOKEN="$TOKEN" ./scripts/pairing-contract-check.sh "https://autopoiesis.art/api/admin/frames/pairing-contract-bundle"
```

The pairing contract check validates read-only staging evidence for `POST /api/frames/device/register`, `POST /api/frames/user/devices/pair`, and `GET /api/frames/device/{deviceId}/pairing-status`. It requires a bounded pairing-code TTL, a durable device credential in the registration response, a claimed owner/device relationship after user pairing, settings handoff shape, final paired status, and redaction of pairing hashes, user tokens, secrets, and local appliance paths. The optional adapter endpoint is for CI/staging evidence; it should not run a destructive live pairing flow.

Validate hosted device-route authentication before treating pairing/API sync as staging-ready:

```bash
./scripts/device-auth-contract-check.sh /path/to/device-auth-contract-bundle.json
AUTOPOIESIS_DEVICE_AUTH_CONTRACT_TOKEN="$TOKEN" ./scripts/device-auth-contract-check.sh "https://autopoiesis.art/api/admin/frames/device-auth-contract-bundle"
```

The device auth contract check validates read-only staging evidence for the keyed device-only routes: pairing status, settings read/write, heartbeat, stream, command polling, command acknowledgement, and release manifest checks. For each route, the bundle must prove that the correct per-device credential succeeds, while missing, wrong, and cross-device credentials are rejected with 401/403/404-style failures. The bundle must not expose raw device API keys, pairing hashes, private tokens, secrets, or local appliance paths.

Validate hosted settings conflict handling before treating sync as staging-ready:

```bash
./scripts/settings-contract-check.sh /path/to/settings-contract-bundle.json
AUTOPOIESIS_SETTINGS_CONTRACT_TOKEN="$TOKEN" ./scripts/settings-contract-check.sh "https://autopoiesis.art/api/admin/frames/settings-contract-bundle"
```

The settings contract check validates read-only staging evidence for `GET /api/frames/device/{deviceId}/settings`, `POST /api/frames/device/{deviceId}/settings`, and heartbeat settings handoff. It requires an initial authoritative read, a newer write that preserves or advances the submitted `updatedAt`, a stale write rejection or explicit conflict, a final read proving the stale write did not overwrite the newer row, and a heartbeat response that returns settings at least as current as the accepted write. The bundle must not expose device API keys, pairing codes/hashes, private tokens, secrets, or local appliance paths.

Validate hosted Profile account ownership before exposing Profile > Frames account routes:

```bash
./scripts/profile-ownership-contract-check.sh /path/to/profile-ownership-contract-bundle.json
AUTOPOIESIS_PROFILE_OWNERSHIP_CONTRACT_TOKEN="$TOKEN" ./scripts/profile-ownership-contract-check.sh "https://autopoiesis.art/api/admin/frames/profile-ownership-contract-bundle"
```

The profile ownership contract check validates read-only staging/CI evidence that authenticated Profile > Frames routes are scoped to the current account/session. It requires owner list/read/settings-write success, cross-owner read/settings-write/command rejection, anonymous profile rejection, admin fleet read separation, and redaction of device keys, pairing codes/hashes, private tokens, secrets, and local appliance paths. This gate sits between settings conflict behavior and heartbeat/admin evidence because owner scoping has to be correct before Profile controls can safely mutate device settings or queue owner actions.

Validate the hosted heartbeat response before backend sync/admin evidence is treated as staging-ready:

```bash
./scripts/heartbeat-contract-check.sh /path/to/heartbeat-contract-bundle.json
AUTOPOIESIS_HEARTBEAT_CONTRACT_REQUEST=/path/to/heartbeat-request.json AUTOPOIESIS_HEARTBEAT_CONTRACT_TOKEN="$TOKEN" ./scripts/heartbeat-contract-check.sh "https://autopoiesis.art/api/frames/device/frame-id/heartbeat"
```

The heartbeat contract check validates a saved response or a bundle with `request` and `response` sections for `POST /api/frames/device/{deviceId}/heartbeat`. It checks safe diagnostics, unified event export shape, event ingestion acknowledgements, optional authoritative settings, command authorization metadata, mixed-stream item hints, and redaction of device keys, pairing hashes, private tokens, secrets, and local appliance paths.

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

Run the hosted staging contract suite before handing backend work to physical Pi validation:

```bash
AUTOPOIESIS_AOS_MIGRATION_CONTRACT_SOURCE=/path/to/migrations \
AUTOPOIESIS_AOS_SCHEMA_CONTRACT_SOURCE=/path/to/schema-introspection.json \
AUTOPOIESIS_PAIRING_CONTRACT_SOURCE=/path/to/pairing-contract-bundle.json \
AUTOPOIESIS_DEVICE_AUTH_CONTRACT_SOURCE=/path/to/device-auth-contract-bundle.json \
AUTOPOIESIS_SETTINGS_CONTRACT_SOURCE=/path/to/settings-contract-bundle.json \
AUTOPOIESIS_PROFILE_OWNERSHIP_CONTRACT_SOURCE=/path/to/profile-ownership-contract-bundle.json \
AUTOPOIESIS_HEARTBEAT_CONTRACT_SOURCE=/path/to/heartbeat-contract-bundle.json \
AUTOPOIESIS_COMMAND_POLL_CONTRACT_SOURCE=/path/to/command-poll-contract-bundle.json \
AUTOPOIESIS_COMMAND_ACK_CONTRACT_SOURCE=/path/to/command-ack-contract-bundle.json \
AUTOPOIESIS_COMMAND_STATE_CONTRACT_SOURCE=/path/to/command-state-contract-bundle.json \
AUTOPOIESIS_STREAM_CONTRACT_SOURCE=/path/to/stream-response.json \
AUTOPOIESIS_CACHE_CONTRACT_SOURCE=/path/to/cache-contract-bundle.json \
AUTOPOIESIS_ONLINE_ADMIN_CONTRACT_SOURCE=/path/to/online-admin-bundle.json \
AUTOPOIESIS_BROADCAST_CONTRACT_SOURCE=/path/to/broadcast-contract-bundle.json \
AUTOPOIESIS_RELEASE_MANIFEST_SOURCE=/path/to/release.json \
AUTOPOIESIS_RELEASE_ROLLOUT_CONTRACT_SOURCE=/path/to/release-rollout-contract-bundle.json \
AUTOPOIESIS_HOSTED_CONTRACT_REPORT=/path/to/hosted-contract-report.json \
./scripts/hosted-contract-suite-check.sh --strict
```

CI can also hand the suite a single manifest instead of exporting every source:

```json
{
  "require": [
    "migrations",
    "schema",
    "pairing",
    "device-auth",
    "settings",
    "profile-ownership",
    "heartbeat",
    "command-poll",
    "command-ack",
    "command-state",
    "stream",
    "cache",
    "online-admin",
    "broadcast",
    "release",
    "release-rollout"
  ],
  "sources": {
    "migrations": "./migrations",
    "schema": "./schema-introspection.json",
    "pairing": "./pairing-contract-bundle.json",
    "device-auth": "./device-auth-contract-bundle.json",
    "settings": "./settings-contract-bundle.json",
    "profile-ownership": "./profile-ownership-contract-bundle.json",
    "heartbeat": "./heartbeat-contract-bundle.json",
    "command-poll": "./command-poll-contract-bundle.json",
    "command-ack": "./command-ack-contract-bundle.json",
    "command-state": "./command-state-contract-bundle.json",
    "stream": "./stream-response.json",
    "cache": "./cache-contract-bundle.json",
    "online-admin": "./online-admin-bundle.json",
    "broadcast": "./broadcast-contract-bundle.json",
    "release": "./release.json",
    "release-rollout": "./release-rollout-contract-bundle.json"
  }
}
```

```bash
AUTOPOIESIS_HOSTED_CONTRACT_MANIFEST=/path/to/hosted-contract-manifest.json \
AUTOPOIESIS_HOSTED_CONTRACT_REPORT=/path/to/hosted-contract-report.json \
./scripts/hosted-contract-suite-check.sh
```

The suite runs the existing hosted gates in dependency order: migrations, final schema, pairing, device auth, settings conflict, profile ownership, heartbeat, command polling, command acknowledgement, command state, stream, cache/offline, online admin, broadcast lifecycle, release manifest, then hosted release rollout evidence. Run `./scripts/hosted-contract-suite-check.sh --list-gates` for the machine-readable gate catalog with each gate name, order, source environment variable, checker script, and label. Run `./scripts/hosted-contract-suite-check.sh --manifest-template` to generate a disabled JSON manifest skeleton from that same catalog, then let CI fill and enable the sources it owns before plan/full execution. Manifest paths are resolved relative to the manifest file, and per-gate `AUTOPOIESIS_*_SOURCE` variables override manifest entries. A manifest can declare required gates with `require`, `required`, `requireGates`, `requiredGates`, or `required_gates`; set `strict` or `requireAll` to `true` when the manifest must provide every hosted source. In non-strict mode it runs every provided source and fails only if a gate named in the manifest or `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE` is missing. Required-gate names are normalized and typo-checked before any gate runs. Manifest source containers (`sources`, `contracts`, `gates`, and `contractSources`) are also linted as gate-keyed objects: unknown gate names and enabled entries without `source`, `path`, `file`, or `url` fail during plan/setup instead of being silently skipped. Use `false` or `{ "enabled": false }` for intentionally disabled source entries. Individual token and strictness variables are passed through to the underlying checkers unchanged.

Use `--plan` or `--dry-run` to validate manifest and required-gate configuration, then print a redacted source matrix without running the individual checkers. Required gates still fail when missing, so CI can use plan mode for rollout annotations before fetching live fixtures or running the full suite.

When `AUTOPOIESIS_HOSTED_CONTRACT_REPORT` is set, the suite writes a redacted JSON report on pass, fail, and plan mode with `status`, `mode`, `exitCode`, `requiredGates`, summary counts, and per-gate planned/pass/skip/missing-required status. The report records only source-presence booleans and source environment names, not fixture paths, URLs, bearer tokens, or local appliance paths.

Validate the hosted broadcast lifecycle before treating Admin > Frames broadcasts as rollout-ready:

```bash
./scripts/broadcast-contract-check.sh /path/to/broadcast-contract-bundle.json
AUTOPOIESIS_BROADCAST_CONTRACT_TOKEN="$TOKEN" ./scripts/broadcast-contract-check.sh "https://autopoiesis.art/api/admin/frames/broadcast-contract-bundle"
```

The broadcast contract bundle is read-only staging/CI evidence for durable broadcast rows, queued `show_broadcast` commands, and delivery rows. The checker validates explicit targeting or audience, scheduling/priority fields, command authorization and audit metadata, display/delivery evidence, and redaction of device keys, pairing hashes, private tokens, secrets, and local appliance paths.

Validate a release manifest before a device applies it:

```bash
./scripts/release-manifest-check.sh /path/to/release.json
AUTOPOIESIS_RELEASE_CHANNEL=stable AUTOPOIESIS_RELEASE_REQUIRE_CHANNEL=1 AUTOPOIESIS_RELEASE_REQUIRE_TAG=1 AUTOPOIESIS_RELEASE_REQUIRE_ROLLBACK_NOTES=1 ./scripts/release-manifest-check.sh /path/to/release.json
```

The updater runs this check automatically before applying `/local/release/apply` or an `update_device` command. When a frame has `updateChannel` in local `device.json`, release apply infers that channel, requires the manifest to declare a matching `channel`/`updateChannel`, and rejects mismatches before rollback metadata, downloads, git fallback, or app-code mutation. Artifact releases must use HTTPS and include a SHA-256 checksum unless explicitly overridden for local testing. Strict rollout can also require GitHub tag, artifact, and rollback notes before a production device accepts an update.

Validate hosted release rollout evidence before treating Admin > Frames updates as rollout-ready:

```bash
./scripts/release-rollout-contract-check.sh /path/to/release-rollout-contract-bundle.json
AUTOPOIESIS_RELEASE_ROLLOUT_CONTRACT_TOKEN="$TOKEN" ./scripts/release-rollout-contract-check.sh "https://autopoiesis.art/api/admin/frames/release-rollout-contract-bundle"
```

The release rollout contract bundle is read-only staging/CI evidence for durable software release rows, per-device rollout rows, queued `update_device` commands, admin audit metadata, and heartbeat-ingested `release_history` events. The checker validates version/channel/status consistency, command authorization and audit ids, rollout progress or failure rows, release-history event idempotency, unknown references, and redaction of device keys, tokens, artifact URLs, checksums, command payloads, and local appliance paths.

Check defensive feed targeting and cache eligibility:

```bash
./scripts/feed-targeting-check.sh
```

This isolated check validates heartbeat-triggered stream polling, local stream targeting for device, owner, subscriber status, tier, and region shapes; expiry/start-time filtering; priority order; public targeting redaction; mixed-stream broadcast display evidence; and feed cache manifest eligibility.

Check command-delivered broadcast behavior:

```bash
./scripts/broadcast-command-check.sh
```

This isolated check runs the local command processor against a mock Frames API and validates wrong-target rejection, scheduled broadcasts waiting until `startsAt`, `/launch` routing for active broadcasts, `broadcast_shown` only when `/broadcast` renders, dismissal, expired-command rejection, and command acknowledgements.

Collect a redacted local support bundle:

```bash
./scripts/support-bundle.sh ./support-bundle.json
```

Validate the support bundle contract used by hardware reports and Admin/Profile support adapters:

```bash
./scripts/support-bundle-check.sh
```

Rollback the last release update on a device after a bad rollout:

    sudo /opt/autopoiesis-os/app/scripts/rollback-release.sh

Preview and run a local factory reset on a device:

    sudo /opt/autopoiesis-os/app/factory-reset.sh --dry-run
    sudo /opt/autopoiesis-os/app/factory-reset.sh

Validate the factory reset contract without mutating installed device state:

```bash
./scripts/factory-reset-check.sh
```

The check runs the real reset script against temporary app/data/cache/log
directories with a stubbed `systemctl`. It proves default reset clears local
identity, pairing, runtime, cache, rollout, and support-history state;
`--keep-support-history` preserves support JSON while still clearing paired
runtime state; and `--dry-run` leaves seeded files untouched.

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
