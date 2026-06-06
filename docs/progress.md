# Progress

## 2026-06-06 - Production cleanup audit gate

Date: 2026-06-06

Milestone: QA / SECURITY - final image hygiene

Changed files:

- `scripts/cleanup-production.sh`
- `README.md`
- `docs/production-cleanup.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Reworked `scripts/cleanup-production.sh` from a checklist into a read-only production hygiene audit.
- Added strict-mode support for final imaging through `--strict` or `AUTOPOIESIS_PRODUCTION_CLEANUP_STRICT=1`.
- The audit now checks installed app-tree secret-like paths, leftover Git metadata, tracked secret-like paths when the app is still a checkout, Codex/OpenClaw/OpenAI credential homes, shell-history secret hints without printing matching lines, common development caches, and SSH/sshd exposure.
- Added `--allow-ssh`, `--app-dir=...`, `--home-dir=...`, `AUTOPOIESIS_PRODUCTION_HOME_DIRS`, and `AUTOPOIESIS_SYSTEMCTL_BIN` so the same gate works on physical Pi images and isolated CI fixtures.

Verification:

- `bash -n scripts/cleanup-production.sh` passed.
- Strict cleanup audit passed against an isolated temporary app/home tree.
- Strict cleanup audit rejected a temporary app tree containing `.env`.
- Strict cleanup audit rejected a temporary production home containing `.codex`.
- Strict cleanup audit rejected a temporary shell history with an `OPENAI_API_KEY` hint without printing the secret line.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Run `AUTOPOIESIS_PRODUCTION_CLEANUP_STRICT=1 sudo /opt/autopoiesis-os/app/scripts/cleanup-production.sh` on the physical Pi after final appliance validation and before cloning a production image; document any intentional SSH exception.

## 2026-06-06 - Hosted device auth contract gate

Date: 2026-06-06

Milestone: LEAD / INTEGRATION - device credential boundary

Changed files:

- `scripts/device-auth-contract-check.sh`
- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/agent-notes/backend-device-auth-contract-issue.md`
- `docs/agent-notes/hosted-contract-suite-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/device-auth-contract-check.sh`, a saved-bundle or live-URL verifier for hosted device-only route authentication evidence.
- The checker requires correct per-device credentials to succeed while missing, wrong, and cross-device credentials are rejected for pairing status, settings read/write, heartbeat, stream, command polling, command acknowledgement, and release routes.
- The checker validates route device-id consistency on authorized responses and rejects raw device API keys, API-key field names, pairing-code hashes, bearer tokens, private/admin tokens, secrets, passwords, and local appliance paths.
- Wired the device-auth gate into `scripts/hosted-contract-suite-check.sh`; strict hosted readiness now requires migration, schema, pairing, device-auth, heartbeat, stream, online-admin, and release sources.
- Added a backend handoff issue note defining the optional staging/CI device-auth bundle.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/device-auth-contract-check.sh` passed against a representative all-route auth bundle fixture.
- `scripts/device-auth-contract-check.sh` rejected a route missing cross-device rejection evidence.
- `scripts/hosted-contract-suite-check.sh` passed with a required device-auth source.
- `scripts/hosted-contract-suite-check.sh` rejected a missing required device-auth source.
- `scripts/security-smoke.sh` passed.

Next step:

Generate the device-auth bundle from hosted route integration tests or a staging-only admin adapter, then run the expanded hosted suite before trusting heartbeat, stream, command, release, or physical Pi validation results.

## 2026-06-06 - Support bundle acceptance gate

Date: 2026-06-06

Milestone: RPI APPLIANCE - support handoff contract

Changed files:

- `scripts/support-bundle-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/support-bundle-check.sh`, a read-only verifier for `GET /local/support-bundle`.
- The checker validates the support-bundle schema marker, redaction flag, generated timestamp, device identity, health/readiness summaries, runtime storage booleans, input summary, playback state, command policy matrix, event export shape, and required support sections.
- The checker rejects stored device-key field names, raw command payloads, release checksums, and release artifact URLs in the support bundle.
- Wired the support-bundle gate into Milestone 2 verification before the derived Admin/Profile device snapshot check.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/support-bundle-check.sh` passed against an isolated local UI in setup mode.
- `scripts/security-smoke.sh` passed.

Next step:

Run `scripts/support-bundle-check.sh` on the physical Pi after live pairing, feed/cache sync, and at least one command/broadcast attempt; attach the validated bundle to hardware rollout blockers or Admin/Profile support adapter work.

## 2026-06-06 - Hosted heartbeat contract gate

Date: 2026-06-06

Milestone: LEAD / INTEGRATION - heartbeat sync readiness

Changed files:

- `scripts/heartbeat-contract-check.sh`
- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/agent-notes/backend-heartbeat-contract-issue.md`
- `docs/agent-notes/hosted-contract-suite-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/heartbeat-contract-check.sh`, a saved-response, saved request/response bundle, or live-URL verifier for `POST /api/frames/device/{deviceId}/heartbeat`.
- The checker validates safe heartbeat request diagnostics, unified event export shape, event ingestion acknowledgements, optional settings, remote command authorization metadata, optional mixed-stream items, and sensitive/local-only field redaction.
- Wired the heartbeat gate into `scripts/hosted-contract-suite-check.sh`; strict hosted readiness now requires migration, schema, pairing, heartbeat, stream, online-admin, and release sources.
- Added a backend handoff issue note for generating the heartbeat contract fixture from a paired staged device or durable seeded `aos_` rows.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/heartbeat-contract-check.sh` passed against a representative heartbeat request/response fixture.
- `scripts/heartbeat-contract-check.sh` rejected a heartbeat response without an event acknowledgement.
- `scripts/hosted-contract-suite-check.sh` passed with a required heartbeat source.
- `scripts/hosted-contract-suite-check.sh` rejected a missing required heartbeat source.
- `scripts/security-smoke.sh` passed.

Next step:

Generate the heartbeat bundle from hosted staging after pairing, then run the expanded hosted suite with real migration/schema/pairing/heartbeat/stream/admin/release fixtures before physical Pi Milestone 2 validation.

## 2026-06-06 - Hosted contract suite gate

Date: 2026-06-06

Milestone: LEAD / INTEGRATION - backend staging readiness

Changed files:

- `scripts/hosted-contract-suite-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/agent-notes/hosted-contract-suite-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/hosted-contract-suite-check.sh`, an umbrella staging/CI runner for the hosted Frames contract gates.
- The suite runs migration, final schema, pairing lifecycle, stream response, online Profile/Admin, and release manifest checks in dependency order.
- `--strict` requires all six sources before physical Pi acceptance; `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE` allows partial CI jobs to require only their owned gates while still running every provided source.
- Added a backend handoff issue note describing how to wire the suite into hosted staging readiness.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/hosted-contract-suite-check.sh` passed against a temporary release-manifest fixture.
- `scripts/hosted-contract-suite-check.sh` rejected a missing required stream source.
- `scripts/security-smoke.sh` passed.

Next step:

Wire the suite into the hosted backend CI/staging path with real migration/schema/pairing/stream/admin/release fixtures, then run it before physical Pi Milestone 2 validation.

## 2026-06-06 - Online admin role matrix contract

Date: 2026-06-06

Milestone: ONLINE ADMIN - role-gated fleet controls

Changed files:

- `scripts/online-admin-contract-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/admin-system.md`
- `docs/online-frames-profile.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Extended the hosted online-admin bundle gate to require `show_broadcast` command policy coverage.
- Added a required role/action authorization matrix to the online-admin contract.
- The matrix accepts `roleActionMatrix`, `roleMatrix`, or `permissions`, with one explicit allow/deny decision per accepted actor role and remote command type.
- Allowed risky commands must expose authorization, audit-id, and local-confirmation requirements so Admin > Frames controls can render prompts from contract data.
- Denied commands must include a UI-facing reason, and the matrix must include at least one denied action plus one denied critical action before destructive fleet actions are considered staging-ready.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/online-admin-contract-check.sh` passed against a representative Profile/Admin bundle fixture with admin/support role decisions.
- `scripts/online-admin-contract-check.sh` rejected a bundle without a role/action matrix.
- `scripts/online-admin-contract-check.sh` rejected a denied critical action without a UI-facing reason.
- `scripts/online-admin-contract-check.sh` rejected a bundle leaking a local appliance path.
- `scripts/security-smoke.sh` passed.

Next step:

Assemble the hosted role/action matrix from real backend authorization checks, then drive Admin > Frames action disabled states and confirmation copy from the same bundle before enabling destructive remote actions in staging.

## 2026-06-06 - AOS migration contract gate

Date: 2026-06-06

Milestone: API / DATABASE / SYNC - migration safety foundation

Changed files:

- `scripts/aos-migration-contract-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/agent-notes/backend-migration-contract-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/aos-migration-contract-check.sh`, an executable pre-apply gate for hosted Frames database migrations.
- The checker accepts either a migrations directory of sorted `.sql` files or a saved migration manifest from a backend migration tool.
- It validates deterministic migration ids, `aos_` table/index namespacing, transaction boundaries, required MVP table coverage, hashed pairing-code storage, secret-literal red flags, and destructive SQL opt-in.
- Added a backend handoff note defining how to wire the gate before schema verification in migration CI.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/aos-migration-contract-check.sh` passed against a representative manifest fixture.
- `scripts/aos-migration-contract-check.sh` rejected a non-`aos_` migration fixture.
- `scripts/aos-migration-contract-check.sh` rejected a destructive migration fixture without explicit opt-in.
- `scripts/security-smoke.sh` passed.

Next step:

Wire the migration gate into the hosted app's migration CI/export path, then run `scripts/aos-schema-contract-check.sh` against the migrated staging database or exported schema before enabling hosted stream/admin/heartbeat checks.

## 2026-06-06 - Systemd unit rendering gate

Date: 2026-06-06

Milestone: RPI APPLIANCE - installer/systemd path fidelity

Changed files:

- `install.sh`
- `services/autopoiesis-cache.service`
- `services/autopoiesis-command-executor.service`
- `services/autopoiesis-heartbeat.service`
- `services/autopoiesis-kiosk.service`
- `services/autopoiesis-setup.service`
- `services/autopoiesis-updater.service`
- `scripts/install-systemd-units.sh`
- `scripts/systemd-units-install-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/installation.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- `scripts/install-systemd-units.sh` now renders service units into the target systemd directory using the configured app, install, data, log, appliance user, and user-home paths.
- `install.sh` now passes its chosen install/data/log/user values into the systemd installer, so custom install roots do not leave services pointing at the default `/opt`, `/var/lib`, or `frame` layout.
- Timer units are still copied directly, while service units have default path/user placeholders replaced at install/update time.
- Service units now carry explicit runtime environment for data/log/cache/app paths where their scripts depend on those defaults.
- Added `scripts/systemd-units-install-check.sh`, an isolated fake-systemd acceptance gate that renders units with custom paths/user and fails if default hard-coded paths or `frame` ownership survive.
- Wired the gate into Milestone 2 verification after baseline service status checks.

Verification:

- `scripts/systemd-units-install-check.sh` passed.

Next step:

Run `sudo ./install.sh` or `sudo ./update.sh` on a physical Pi using the default layout, then inspect `/etc/systemd/system/autopoiesis-*.service` and run full Milestone 2 verification to confirm rendered units start the healthy installed services.

## 2026-06-06 - Broadcast command display gate

Date: 2026-06-06

Milestone: BROADCAST / FEED - command-delivered broadcast behavior

Changed files:

- `local-ui/server.js`
- `scripts/broadcast-command-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/broadcast-system.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Hardened `show_broadcast` command handling so command-delivered broadcasts use defensive targeting and expiry checks before writing `current-broadcast.json`.
- Scheduled command broadcasts are accepted without interrupting playback before `startsAt`; `/launch` now routes to any active stored broadcast once it is eligible.
- `broadcast_shown` is recorded when `/broadcast` actually renders, not when the command is merely accepted.
- Dismissed broadcasts stay inactive; stored broadcasts that are no longer target-eligible emit one `broadcast_skipped` delivery event.
- Added `scripts/broadcast-command-check.sh`, an isolated local UI + mock Frames API gate for wrong-target rejection, scheduled delay, active launch routing, display-time delivery logging, dismissal, expired-command rejection, and command acknowledgements.
- Wired the new gate into Milestone 2 after stream playback and feed targeting.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/broadcast-command-check.sh` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Run the broadcast command gate on physical Pi hardware after Admin > Frames can enqueue a real targeted broadcast command, then confirm durable `aos_broadcast_deliveries` receives the displayed/dismissed event projection.

## 2026-06-06 - Release manifest safety gate

Date: 2026-06-06

Milestone: RELEASE / ROLLOUT - safe update foundation

Changed files:

- `scripts/release-manifest-check.sh`
- `scripts/update-from-release.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/release-manifest-check.sh`, a saved-manifest or live-URL gate for release metadata before a frame accepts an update.
- The checker validates semantic target versions, optional release channels, GitHub-style tags, HTTPS artifact URLs, SHA-256 checksums, rollout percentages, release-note URLs, optional rollback notes, and redaction of device keys, pairing hashes, private/admin tokens, secrets, passwords, and local appliance paths.
- `scripts/update-from-release.sh` now runs the manifest gate before writing rollback metadata, downloading artifacts, or applying a git fallback update.
- The updater now accepts `artifactUrl`/`sha256` style fields as aliases for the existing `artifact_url`/`checksum` contract so backend and GitHub release adapters can share one manifest shape.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/release-manifest-check.sh` passed against a strict representative stable release fixture.
- `scripts/release-manifest-check.sh` rejected an artifact release without a checksum.
- `scripts/update-from-release.sh` rejected an invalid manifest before mutating an isolated fake install.
- `scripts/security-smoke.sh` passed.

Next step:

Make the hosted release endpoint emit channel, tag, checksum, changelog URL, rollout percentage, and rollback notes, then run strict manifest validation before cutting the first GitHub-tagged production artifact.

## 2026-06-06 - Hosted pairing contract gate

Date: 2026-06-06

Milestone: LEAD / INTEGRATION - pairing foundation

Changed files:

- `scripts/pairing-contract-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/online-frames-profile.md`
- `docs/agent-notes/backend-pairing-contract-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/pairing-contract-check.sh`, a saved-response or live-URL verifier for the hosted Frames pairing lifecycle.
- The checker validates read-only evidence for device registration, authenticated user claim, and final device pairing status.
- It requires a bounded pairing-code TTL, an unpaired registration response, a durable device credential at registration, consistent claimed owner/device identity, optional settings handoff shape, final paired status, and redaction of pairing-code hashes, user tokens, secrets, and local appliance paths.
- Added a backend issue note defining the optional staging/CI pairing contract bundle and the durable `aos_` ownership/security expectations.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/pairing-contract-check.sh` passed against a representative pairing lifecycle fixture.
- `scripts/security-smoke.sh` passed.

Next step:

Assemble the optional `GET /api/admin/frames/pairing-contract-bundle` staging adapter from durable `aos_frame_devices` and `aos_frame_pairing_codes` evidence, then run `scripts/pairing-contract-check.sh` before live physical Pi pairing acceptance.

## 2026-06-06 - Runtime storage diagnostics gate

Date: 2026-06-06

Milestone: RPI APPLIANCE - runtime filesystem acceptance

Changed files:

- `local-ui/server.js`
- `scripts/runtime-storage-check.sh`
- `scripts/milestone2-verify.sh`
- `scripts/security-smoke.sh`
- `scripts/support-bundle.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/installation.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added runtime storage diagnostics for `DATA_DIR`, `CACHE_DIR`, and `LOG_DIR`.
- Diagnostics now verify each runtime path exists or can be created, is a directory, is readable/writable, and accepts a short write probe from the local UI process.
- Health emits `runtime_storage_unavailable` when any required runtime path is blocked.
- Readiness and support bundles now include a storage phase/summary so physical Pi handoffs can distinguish ownership/mount failures from pairing, heartbeat, cache, or support-bundle bugs.
- `scripts/support-bundle.sh` now prints the runtime storage status in its one-line support summary.
- Added `scripts/runtime-storage-check.sh` and wired it into Milestone 2 physical verification.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/runtime-storage-check.sh` passed against an isolated local UI with writable data/cache/log directories.
- `scripts/support-bundle.sh` summary output reported `storage=ready` against the same isolated writable local UI.
- `scripts/runtime-storage-check.sh` passed with `AUTOPOIESIS_ALLOW_RUNTIME_STORAGE_UNREADY=1` against an isolated blocked-cache-path fixture, proving `runtime_storage_unavailable` health/readiness/support reporting.
- `scripts/security-smoke.sh` passed.

Next step:

Run the strict runtime storage gate on the physical Pi after install/update; if it fails, fix ownership or mounts for `/var/lib/autopoiesis-os`, the cache directory, and `/var/log/autopoiesis-os` before testing higher-level appliance flows.

## 2026-06-06 - Durable AOS schema contract gate

Date: 2026-06-06

Milestone: LEAD / INTEGRATION - database foundation

Changed files:

- `scripts/aos-schema-contract-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/agent-notes/aos-schema-contract-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/aos-schema-contract-check.sh`, a schema-level verifier for the durable `aos_` Frames database contract.
- The checker accepts either a SQLite database file, when `sqlite3` is available, or a saved schema JSON fixture for CI/staging adapters.
- It validates required tables, columns, and primary/unique keys for frame devices, pairing, settings, user preferences, heartbeats, commands, admin command audits, device events, artwork likes, broadcasts, releases, subscriptions, broadcast deliveries, and release rollouts.
- Added a backend issue note so database/migration work has a concrete acceptance target before stream, admin, event ingestion, command, broadcast, or rollout gates are trusted.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/aos-schema-contract-check.sh` passed against a representative durable `aos_` schema fixture.
- `scripts/security-smoke.sh` passed.

Next step:

Run `scripts/aos-schema-contract-check.sh` against a staging backend database or exported migration schema before relying on hosted stream/admin/event/broadcast/release acceptance checks; migrate `aos_frame_pairing_codes` from plaintext `pairing_code` to `pairing_code_hash` before production hardening.

## 2026-06-06 - Online admin contract gate

Date: 2026-06-06

Milestone: ONLINE ADMIN - Profile/Admin Frames contract

Changed files:

- `scripts/online-admin-contract-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/admin-system.md`
- `docs/online-frames-profile.md`
- `docs/database-schema.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/online-admin-contract-check.sh`, a saved-response or live-URL validator for the hosted Profile > Frames and Admin > Frames bundle.
- The checker validates user devices, pairing metadata, settings, active artists, liked artworks, cache preferences, users, subscribers, subscriptions, fleet devices, accepted admin roles, remote action policy rows, authorization/audit requirements, and redaction of local-only or sensitive fields.
- Documented the expected bundle as an optional staging/CI adapter assembled from existing Profile/Admin endpoints, so UI, backend authorization, and Pi command policy can be checked before real fleet actions are enabled.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/online-admin-contract-check.sh` passed against a representative Profile/Admin bundle fixture.
- `scripts/security-smoke.sh` passed.

Next step:

Expose or assemble the online admin bundle from durable `aos_` and canonical account/subscription rows, then run `scripts/online-admin-contract-check.sh` against staging auth data before enabling destructive remote actions.

## 2026-06-06 - Hosted stream contract verifier

Date: 2026-06-06

Milestone: LEAD / INTEGRATION - backend stream handoff

Changed files:

- `scripts/stream-contract-check.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/agent-notes/backend-stream-contract-issue.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/stream-contract-check.sh`, a reusable saved-response or live-URL verifier for `GET /api/frames/device/{deviceId}/stream`.
- The verifier checks schema version, generated timestamp, stream metadata, optional settings/preferences shape, unique item ids, item identity/media/cache/priority/schedule/targeting fields, displayability, and redaction of local-only or sensitive fields.
- Added `docs/agent-notes/backend-stream-contract-issue.md`, a GitHub-style backend issue note specifying the durable `aos_` tables, response shape, acceptance checks, and open ownership/subscription/cursor questions for the hosted stream endpoint.
- Documented the checker in the README, API contract, database schema notes, and Pulse handoff notes.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/stream-contract-check.sh` passed against a representative fixture.
- `scripts/security-smoke.sh` passed.

Next step:

Implement the hosted `/api/frames/device/{deviceId}/stream` query from durable `aos_` device, settings, preference, subscription, content, and broadcast rows, then run this contract check before stream playback and feed targeting gates.

## 2026-06-06 - Command acknowledgement retry gate

Date: 2026-06-06

Milestone: API / DATABASE / SYNC - command acknowledgement idempotency

Changed files:

- `local-ui/server.js`
- `scripts/command-ack-retry-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Tightened command audit status for successful local executions whose final `completed` acknowledgement cannot be delivered; those now surface immediately as `ack_failed` instead of looking cleanly completed.
- Added `scripts/command-ack-retry-check.sh`, an isolated local UI + mock Frames API gate for command acknowledgement retry behavior.
- The gate verifies initial acknowledgement failures retain commands before execution, successful initial ack retry then executes once, final acknowledgement failures retain final-only retry metadata and count as audit errors, final ack retry success does not re-execute the command, and repeated final ack retry failure records `ack_retry_failed`.
- Wired the gate into Milestone 2 verification before settings sync and event ingestion checks.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/command-ack-retry-check.sh` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Mirror this idempotency contract in durable backend `aos_` command rows: repeated `completed`/`error` acknowledgements should be harmless, and last ack failure/timestamp should be visible in Admin > Frames support data.

## 2026-06-06 - System clock diagnostics gate

Date: 2026-06-06

Milestone: RPI APPLIANCE - time sync diagnostics and staged hardware acceptance

Changed files:

- `local-ui/server.js`
- `scripts/clock-check.sh`
- `scripts/milestone2-verify.sh`
- `scripts/security-smoke.sh`
- `scripts/support-bundle.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `timedatectl show` backed system clock diagnostics to the local UI diagnostics snapshot.
- Compact health now emits stable `clock_unsynchronized`, `clock_unknown`, and `clock_ntp_disabled` issue codes when system time sync is unhealthy or unavailable.
- Readiness, rollout acceptance, and support bundles now include a clock phase/summary so staged hardware can distinguish bad Pi time from generic network, feed, heartbeat, or release failures.
- Added `scripts/clock-check.sh`, validating diagnostics, health, readiness, and support-bundle clock surfaces with strict `AUTOPOIESIS_REQUIRE_CLOCK_SYNC=1` mode.
- Wired strict clock sync into `scripts/milestone2-verify.sh` after timer diagnostics and extended security/support summaries to cover the new redacted clock contract.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted fake-`timedatectl` clock smoke passed for synchronized strict mode, unsynchronized health issue plus strict failure, and unavailable `clock_unknown` reporting.

Next step:

Run strict `scripts/clock-check.sh` on the physical Pi after network onboarding; if it fails, capture `timedatectl status` before debugging higher-level feed, heartbeat, pairing, or release behavior.

## 2026-06-06 - Defensive feed targeting gate

Date: 2026-06-06

Milestone: BROADCAST / FEED - mixed stream targeting and cache eligibility

Changed files:

- `local-ui/server.js`
- `scripts/feed-targeting-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/broadcast-system.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added defensive local feed targeting for recognized device, owner/user, subscriber status, subscription tier, region/country, test-device, and explicit exclusion target shapes.
- Preserved backend targeting as the authoritative source, while making the Pi refuse obviously non-matching feed items or broadcasts before they enter `/local/feed`, `/local/frame-state`, cache manifests, or kiosk playback.
- Redacted normalized targeting metadata from public `/local/feed` responses after eligibility evaluation, closing a small local privacy leak for target lists.
- Added `scripts/feed-targeting-check.sh`, an isolated local UI + mock Frames API gate for targeting, expiry/start-time filtering, priority order, public redaction, delivery evidence, and cache eligibility.
- Wired the targeting gate into `scripts/milestone2-verify.sh` after the stream playback integration gate.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- `scripts/feed-targeting-check.sh` passed.
- `scripts/stream-playback-check.sh` passed.

Next step:

Implement the hosted `GET /api/frames/device/{deviceId}/stream` path so durable `aos_` rows emit the same targeting/cache/priority fields this device-side gate now validates, then run the gate on physical paired hardware after a live stream sync.

## 2026-06-06 - Stream playback gate hardening

Date: 2026-06-06

Milestone: LEAD / integration - local stream player contract

Changed files:

- `scripts/stream-playback-check.sh`
- `README.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Adopted the pending local stream/dashboard/player integration set as the active LEAD handoff instead of leaving it as ambiguous dirty work.
- Hardened `scripts/stream-playback-check.sh` to choose per-run loopback ports by default, while preserving `AUTOPOIESIS_STREAM_PLAYBACK_CHECK_PORT` and `AUTOPOIESIS_STREAM_PLAYBACK_CHECK_API_PORT` overrides for focused debugging.
- This brings the stream playback gate in line with the event-ingestion acceptance gate and avoids false failures when hourly cron checks or local development runs overlap.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- `scripts/stream-playback-check.sh` passed.

Next step:

Implement the hosted `GET /api/frames/device/{deviceId}/stream` path against durable `aos_` preference/content rows, then run this checker plus strict frame-state validation on physical Pi hardware after live feed/cache sync.

## 2026-06-06 - Stream playback integration gate

Date: 2026-06-06

Milestone: LEAD / integration - local stream player contract

Changed files:

- `scripts/stream-playback-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/stream-playback-check.sh`, an isolated local UI acceptance gate for the current stream/dashboard/player contract.
- The check runs a temporary local UI against a mock Frames API and verifies preferred `GET /stream` sync, fallback to legacy `GET /feed`, artist/category preference filtering, `/dashboard` rendering, frame item `displayMs` timing, local like persistence, remote like forwarding, and `feed_item_liked` delivery evidence.
- Wired the gate into Milestone 2 verification immediately after the local frame route check so physical acceptance catches drift between backend stream shape, device preferences, and local kiosk playback.
- Documented the standalone gate for focused debugging before a full physical Pi validation pass.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- `scripts/stream-playback-check.sh` passed.

Next step:

Mirror the same stream contract in the hosted Frames backend with durable `aos_` stream preference defaults, then run this gate plus strict frame-state validation after a real feed/cache cycle on physical Pi hardware. A clean commit for this pass is unsafe until the pre-existing uncommitted stream/dashboard/player edits in `config/defaults.json`, `docs/api-contract.md`, and `local-ui/server.js` are either adopted into the same change set or separated.

## 2026-06-06 - Admin device snapshot acceptance gate

Date: 2026-06-06

Milestone: ONLINE ADMIN - hosted device detail contract

Changed files:

- `scripts/admin-device-snapshot-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/admin-device-snapshot-check.sh`, a read-only acceptance gate that derives a compact redacted Admin/Profile device snapshot from `/local/support-bundle`.
- The snapshot validates and summarizes identity, health/readiness, pairing and stored-key flags, remote-enabled state, playback/cache counts, role-gated command policies, command/delivery/release evidence, and device event export cursor state.
- Added strict `AUTOPOIESIS_REQUIRE_DEVICE_ADMIN_READY=1` mode for paired staged devices where Admin > Frames should be able to offer role-gated remote actions.
- Wired the check into Milestone 2 verification immediately after the admin-capabilities contract so hardware validation covers both the raw policy matrix and the hosted fleet row shape.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Isolated temporary local UI smoke passed for snapshot JSON generation, strict paired/keyed remote-admin readiness, command policy summarization, event-count summarization, and stored device-key redaction.

Next step:

Mirror this snapshot shape into the online Admin > Frames and Profile > Frames device detail APIs so UI cards can consume one stable row instead of stitching together raw heartbeat/support fields.

## 2026-06-06 - Network onboarding acceptance gate

Date: 2026-06-06

Milestone: RPI APPLIANCE - LAN/Wi-Fi setup contract

Changed files:

- `scripts/network-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/network-check.sh`, a local acceptance gate for the `/local/network/status` contract used by touchscreen setup, support handoff, and physical Pi validation.
- The check validates LAN/Wi-Fi availability shape, primary-link consistency, optional online requirement, device visibility, and sensitive-key redaction.
- Wired the gate into Milestone 2 verification immediately after the raw `nmcli` printout so the physical Pi pass proves both NetworkManager state and the local onboarding API are usable.
- Documented normal and strict online modes for staged hardware validation.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted temporary local UI smoke passed for connected LAN, offline Wi-Fi-only, strict online rejection, and unavailable-network reporting.

Next step:

Run `AUTOPOIESIS_REQUIRE_NETWORK_ONLINE=1 /opt/autopoiesis-os/app/scripts/network-check.sh` on the physical Pi after LAN/Wi-Fi onboarding; if it fails, capture `/local/network/status`, `nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status`, and the setup UI state before changing connection scripts.

## 2026-06-06 - Event ingestion cursor acceptance gate

Date: 2026-06-06

Milestone: LEAD / integration - heartbeat event ingestion cursor

Changed files:

- `scripts/events-ingestion-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/events-ingestion-check.sh`, an isolated heartbeat ingestion acceptance gate for the RPi event cursor contract.
- The check starts a temporary local UI plus mock Frames API, seeds command-audit, display-delivery, and release-history events, and confirms the first heartbeat exports all three sources.
- It verifies accepted backend acks persist a redacted `event-cursor.json`, diagnostics/support surfaces expose the accepted cursor, and the next heartbeat sends `eventIngestionCursor` plus a bounded replay window.
- It also verifies stale backend event acknowledgements are rejected without moving the retained cursor backward, while recording `stale_event_ingestion_ack` for support visibility.
- Wired the gate into `scripts/milestone2-verify.sh` so physical Pi acceptance validates backend/device event-ingestion drift alongside export shape.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- `scripts/events-ingestion-check.sh` passed.

Next step:

Run the full Milestone 2 verification on the physical Pi after the backend `aos_device_events` ingestion path is deployed; if event replay loops or missing Admin evidence appear, start with this check plus `/local/support-bundle` before inspecting raw logs.

## 2026-06-06 - Rollout issue report handoff

Date: 2026-06-06

Milestone: LEAD / integration - rollout support handoff

Changed files:

- `scripts/rollout-issue-report.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/rollout-issue-report.sh`, a read-only handoff tool that collects `/local/rollout/acceptance` and `/local/support-bundle` from a device and formats a GitHub-style Markdown issue report.
- The report includes device/version/profile, acceptance status, health/readiness status, blockers, warnings, support evidence counts, and reproduction commands.
- The script validates that both source payloads are redacted contract shapes and rejects inputs that expose device API key field names.
- Added profile/content/service/event-limit environment switches so setup, staged, and production rollout reports use the same acceptance parameters as the rollout gate.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted temporary local UI smoke passed for Markdown report generation, redaction validation, blocker/warning formatting, and output-file mode.

Next step:

Run `AUTOPOIESIS_ROLLOUT_PROFILE=staged /opt/autopoiesis-os/app/scripts/rollout-issue-report.sh ./rollout-issue.md` on the physical Pi when rollout acceptance blocks or warns, then attach the generated note plus support bundle to the hardware validation issue.

## 2026-06-06 - Settings sync acceptance gate

Date: 2026-06-06

Milestone: API / DATABASE / SYNC - settings conflict contract

Changed files:

- `scripts/settings-sync-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/settings-sync-check.sh`, an isolated acceptance gate for device settings conflict behavior.
- The check starts a temporary local UI and mock Frames API, then verifies stale explicit sync responses are rejected, newer remote settings apply, local settings pushes include `updatedAt`, and stale heartbeat settings preserve newer local preferences.
- The check also confirms diagnostics exposes `settingsSync.status = local_newer` and compact health emits `settings_conflict` while the conflict is active.
- Wired the settings sync check into Milestone 2 verification so physical Pi acceptance catches drift in the API/database sync contract.
- Documented the backend requirement to return authoritative `updatedAt` values from settings GET, settings POST, and heartbeat responses and to mirror newest-wins semantics in durable `aos_` settings rows.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- `scripts/settings-sync-check.sh` passed.

Next step:

Mirror this acceptance behavior in the online Frames backend by making `aos_` settings writes reject or explicitly flag stale `updatedAt` payloads, then return the authoritative row timestamp in settings and heartbeat responses.

## 2026-06-06 - Appliance timer diagnostics

Date: 2026-06-06

Milestone: RPI APPLIANCE - systemd maintenance loop acceptance

Changed files:

- `local-ui/server.js`
- `scripts/systemd-timers-check.sh`
- `scripts/milestone2-verify.sh`
- `scripts/security-smoke.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added systemd timer diagnostics for heartbeat, command executor, cache, updater, and watchdog timers alongside existing service diagnostics.
- Health now emits stable `timer_failed` and `timer_disabled` issue codes when timer-driven appliance loops are broken.
- Readiness now includes a `timers` phase so support, rollout checks, and Admin adapters can distinguish unavailable local systemd state from failed or disabled maintenance loops.
- Added `scripts/systemd-timers-check.sh` and wired it into Milestone 2 physical Pi verification.
- Extended the security smoke test so diagnostics, health, readiness, and support bundle responses must expose timer state without leaking device keys.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted fake-systemctl smoke passed for ready timers, disabled timer health/readiness signaling, and `scripts/systemd-timers-check.sh` failure on a disabled timer.

Next step:

Run `sudo /opt/autopoiesis-os/app/scripts/milestone2-verify.sh` on the physical Pi after updating units; if it fails at the timer step, capture `systemctl list-timers 'autopoiesis-*'` and `journalctl -u <timer-owned service> -n 120 --no-pager`.

## 2026-06-06 - Frame item delivery acknowledgement

Date: 2026-06-06

Milestone: BROADCAST / FEED - mixed stream display evidence

Changed files:

- `local-ui/server.js`
- `docs/api-contract.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `POST /local/frame/display`, a defensive local acknowledgement endpoint for regular mixed-stream frame items.
- The endpoint only records ids that are currently playable in `GET /local/frame-state`, preventing arbitrary browser/client payloads from inventing delivery rows.
- The local kiosk `/frame` surface now posts an acknowledgement each time it renders an item.
- Display acknowledgement appends metadata-only `feed_item_shown` events into the existing bounded delivery log and updates local state with current feed/artwork item pointers.
- Documented the endpoint and `feed_item_shown` event as part of the delivery-log contract for future backend `aos_` delivery ingestion.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted temporary local UI smoke passed for valid frame display acknowledgement, invalid id rejection, delivery-log/event-export inclusion, state update, and device-key redaction.

Next step:

Ingest `feed_item_shown` events into durable backend `aos_` delivery rows alongside broadcast delivery events, then let Admin > Frames show whether personalized feed items are actually reaching device playback.

## 2026-06-06 - Rollout acceptance contract

Date: 2026-06-06

Milestone: LEAD / integration - managed rollout gate

Changed files:

- `local-ui/server.js`
- `scripts/rollout-acceptance-check.sh`
- `scripts/security-smoke.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `GET /local/rollout/acceptance`, a redacted fleet rollout gate derived from health, readiness, Admin capabilities, and unified event export.
- Added setup, staged, and production profiles so fresh setup validation, managed staged devices, and strict production candidates can use the same contract with different required checks.
- Added `strictContent=1` for staged devices that must prove synced content, local playback, and cache state before rollout.
- Added `scripts/rollout-acceptance-check.sh` as the CLI gate for Pi validation, Admin adapter smoke tests, and rollout handoff reports.
- Extended the security smoke test to cover rollout acceptance redaction and remote-admin readiness evaluation.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted temporary local UI smoke passed for staged rollout warning mode, strict staged cache blocking, production cache blocking, event export presence, remote-admin readiness, and device-key redaction.

Next step:

Run `AUTOPOIESIS_ROLLOUT_PROFILE=staged /opt/autopoiesis-os/app/scripts/rollout-acceptance-check.sh` on the paired physical Pi after heartbeat/feed/cache cycles; use `AUTOPOIESIS_ROLLOUT_STRICT_CONTENT=1` when promoting a device from staged to production.

## 2026-06-06 - Admin capabilities acceptance check

Date: 2026-06-06

Milestone: ONLINE ADMIN - remote action policy acceptance

Changed files:

- `scripts/admin-capabilities-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/admin-system.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `scripts/admin-capabilities-check.sh` to validate the redacted `GET /local/admin/capabilities` contract for Admin > Frames remote-action controls.
- The check verifies accepted actor roles, command risk levels, authorization requirements, high/critical audit-id requirements, restart runtime opt-in state, factory-reset local-confirmation blocking, pending-command count shape, and device API key redaction.
- Added optional `AUTOPOIESIS_REQUIRE_REMOTE_ADMIN_READY=1` mode for staged paired devices, requiring paired state, stored device key, and `remoteEnabled=true`.
- Wired the check into `scripts/milestone2-verify.sh` so physical Pi acceptance catches drift between device policy and online admin controls.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted temporary local UI smoke passed for `scripts/admin-capabilities-check.sh` normal mode and strict `AUTOPOIESIS_REQUIRE_REMOTE_ADMIN_READY=1` rejection before pairing.

Next step:

After pairing a physical Pi to an online Frames profile, run `AUTOPOIESIS_REQUIRE_REMOTE_ADMIN_READY=1 /opt/autopoiesis-os/app/scripts/admin-capabilities-check.sh` and confirm Admin > Frames maps disabled/confirm/audit-required buttons from the same capability payload.

## 2026-06-06 - Frame playback readiness signal

Date: 2026-06-06

Milestone: LEAD / integration - rollout playback observability

Changed files:

- `local-ui/server.js`
- `scripts/frame-state-check.sh`
- `scripts/milestone2-verify.sh`
- `scripts/security-smoke.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added a compact `playback` summary to `GET /local/frame-state`, distinguishing `waiting_for_feed`, `empty_queue`, `no_playable_items`, `ready_remote`, and `ready_with_cache`.
- Mirrored that summary as `framePlayback` in diagnostics, compact health, readiness, and support bundles so admin/support consumers can tell whether a synced feed is actually renderable by the kiosk.
- Added stable health issue codes `frame_no_playable_items` and `frame_queue_empty` for feed/playback mismatch cases.
- Added `scripts/frame-state-check.sh` to validate the local playback contract and optionally fail when no playable frame items exist with `AUTOPOIESIS_REQUIRE_FRAME_ITEMS=1`.
- Wired the frame-state check into Milestone 2 validation without requiring items by default, preserving fresh setup validation while giving staged rollout a stricter switch.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted temporary-state local playback smoke passed for `AUTOPOIESIS_REQUIRE_FRAME_ITEMS=1 scripts/frame-state-check.sh`, `ready_with_cache`, diagnostics/health/readiness/support `framePlayback` visibility, support-bundle `frameState`, and device-key redaction.

Next step:

After a live backend feed sync and cache pass on the physical Pi, run `AUTOPOIESIS_REQUIRE_FRAME_ITEMS=1 /opt/autopoiesis-os/app/scripts/frame-state-check.sh` and then `sudo /opt/autopoiesis-os/app/scripts/milestone2-verify.sh` to confirm the local queue is renderable under Chromium.


## 2026-06-06 - Touchscreen input diagnostics

Date: 2026-06-06

Milestone: RPI APPLIANCE - physical input acceptance

Changed files:

- `local-ui/server.js`
- `scripts/touchscreen-check.sh`
- `scripts/milestone2-verify.sh`
- `scripts/security-smoke.sh`
- `scripts/support-bundle.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/installation.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added Linux input-device diagnostics derived from `/proc/bus/input/devices`, reporting touchscreen, pointer, keyboard, and bounded device metadata without reading live input events.
- Health now warns with stable `input_unknown`, `input_missing`, and `touchscreen_missing` issue codes; readiness includes a dedicated input phase.
- Support bundles and the support-bundle CLI summary now include compact input status.
- Added `scripts/touchscreen-check.sh` with an optional `AUTOPOIESIS_REQUIRE_TOUCHSCREEN=1` hard gate, and wired that hard gate into physical Pi Milestone 2 verification.
- Extended the local security smoke test to confirm input diagnostics are present on diagnostics, health, and readiness endpoints.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- `scripts/touchscreen-check.sh` passed in this container as pointer-only input.
- Targeted temporary-state touchscreen smoke passed for `scripts/touchscreen-check.sh`, `AUTOPOIESIS_REQUIRE_TOUCHSCREEN=1`, `/local/diagnostics`, `/local/health`, `/local/readiness?services=0`, and `/local/support-bundle?services=0` using a fake Goodix input device file.

Next step:

Run `sudo /opt/autopoiesis-os/app/scripts/milestone2-verify.sh` on the physical Pi and confirm the touchscreen check reports `touchscreen_ready`; if it reports `pointer_only` or fails, capture `/proc/bus/input/devices` plus the touchscreen HAT/driver model for the hardware issue note.

## 2026-06-06 - Local frame playback surface

Date: 2026-06-06

Milestone: LEAD / integration - local-first kiosk playback

Changed files:

- `local-ui/server.js`
- `scripts/milestone2-verify.sh`
- `scripts/security-smoke.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `GET /local/frame-state`, a browser-safe playback contract derived from the mixed `displayQueue` plus local cache index state.
- Added `/frame`, a local kiosk playback surface that rotates through the balanced queue, supports image/video/audio/text items, and prefers cached asset URLs when available.
- Added explicit local launch routing through `/launch?local=1` and `preferences.displayMode=local-feed` while preserving the hosted-display-first default launch path.
- Added local frame route and frame-state checks to Milestone 2 validation and security-smoke redaction coverage.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted temporary-state local frame smoke passed for `/local/frame-state`, cached media preference, `/frame`, cached asset serving, and `/launch?local=1` redirect.

Next step:

Point a staged kiosk at `/launch?local=1` or set `displayMode=local-feed` after a real backend feed sync, then verify on physical Pi hardware that Chromium rotates cached and remote items correctly across image/video/text content.


## 2026-06-06 - Backend heartbeat event ingestion

Date: 2026-06-06

Milestone: LEAD / integration - durable event ingestion

Changed files:

- `/data/.openclaw/workspace/autopoiesis/app/backend/production.py`
- `docs/api-contract.md`
- `docs/database-schema.md`
- `docs/admin-system.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added backend `aos_device_events` persistence for redacted heartbeat event exports, keyed idempotently by `device_id + event_key`.
- Heartbeat responses now return `eventsAck` with accepted event pointers, source cursors, and ingestion counts so Pi devices can advance their local replay cursor safely.
- Backend ingestion projects recognized events into existing durable rows: command audit events update command/audit status, broadcast display lifecycle events update delivery rows, and release history events update rollout rows.
- Admin device detail now returns recent ingested `deviceEvents` for support/UI consumption.

Verification:

- `python3 -m py_compile app/backend/production.py` passed in the main gallery repo.
- Focused Flask test-client smoke with a temporary SQLite DB passed for event insertion, device-key redaction, `eventsAck`, command audit projection, broadcast delivery projection, release rollout projection, and Admin device detail `deviceEvents`.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed in the RPi repo.
- `scripts/security-smoke.sh` passed.

Next step:

Wire Admin > Frames to render ingested `deviceEvents` and the projected delivery/release state, then decide whether production deploy should include this backend patch after the main `autopoiesis` worktree is cleaned enough for a scoped commit.

## 2026-06-06 - Heartbeat event ingestion cursor

Date: 2026-06-06

Milestone: API / database / sync ingestion readiness

Changed files:

- `local-ui/server.js`
- `factory-reset.sh`
- `docs/api-contract.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added a redacted local `event-cursor.json` contract for backend heartbeat event ingestion acknowledgements.
- Heartbeats now send the previous `eventIngestionCursor` when present, replay events from the accepted timestamp with a small overlap window, and persist compatible backend acknowledgements from `eventsAck`, `eventAck`, `deviceEventsAck`, or `eventIngestionCursor`.
- Diagnostics, `/local/events/export`, and support bundles now expose a compact event-ingestion summary so Admin/support can see what event pointer the API last accepted.
- Factory reset clears the event cursor with other local runtime/sync state.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted heartbeat mock passed for initial event export, backend `eventsAck` persistence, follow-up heartbeat replay using the stored cursor, diagnostics/support-bundle visibility, and device API key redaction.

Next step:

Implement backend heartbeat ingestion into durable `aos_` event tables and return `eventsAck` with the accepted event pointer so Pi devices can advance this cursor without losing idempotent replay safety.

## 2026-06-06 - Factory reset state hygiene

Date: 2026-06-06

Milestone: MVP 1.0 - Production installer foundation

Changed files:

- `factory-reset.sh`
- `README.md`
- `docs/installation.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Reworked `factory-reset.sh` into a deliberate appliance reset path with `--dry-run`, `--no-restart`, and `--keep-support-history`.
- Reset now clears local identity, pairing, preferences, network state, pending commands, active broadcasts, feed/cache manifests, release state, rollback metadata, support-history JSON, and runtime cache directories.
- App code and `/var/log/autopoiesis-os` are preserved; the script bootstraps a fresh unpaired device afterward and re-chowns runtime state/cache directories for the appliance user.
- When restarting is enabled, the script stops local timers during reset, reinstalls systemd units, and restarts setup/kiosk services.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted factory-reset smoke passed against temporary data/cache/install/log directories, confirming stale identity, pairing, command, feed, release, support-history, and cache files are removed while fresh bootstrap files are regenerated.

Next step:

Run `sudo /opt/autopoiesis-os/app/factory-reset.sh --dry-run` and then the real reset on physical Pi hardware, confirm the setup screen returns with a new unpaired device id, and then re-run Milestone 2 verification.

## 2026-06-06 - Mixed feed display queue

Date: 2026-06-06

Milestone: MVP 0.2 - Personal Stream / MVP 0.4 - Broadcast System

Changed files:

- `local-ui/server.js`
- `docs/api-contract.md`
- `docs/broadcast-system.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added a derived local `displayQueue` to `GET /local/feed` for personalized mixed stream playback.
- The queue preserves priority bands first, then round-robins broadcast, curatorial, artwork, blog, news, and general content categories within each band.
- Added feed category counts and `displayQueueItems` to local feed output and diagnostics so Admin > Frames/support tooling can see whether a device has a balanced displayable stream.
- Wrote display category/position into the feed cache manifest so cache workers follow the same display order instead of only raw recency.
- Feed sync delivery events now include category counts for backend delivery-log ingestion.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- Direct local feed smoke confirmed that `/local/feed` exposes `displayQueue`, `displayQueueItems`, and category counts. Broader syntax/security gates passed; full physical feed/cache validation still belongs on the Pi after live feed sync.

Next step:

Have the backend `/api/frames/device/{deviceId}/feed` return real mixed artwork/blog/news/curatorial/broadcast items, then point the kiosk/display surface at `displayQueue` for local-first playback behavior.

## 2026-06-06 - Event export source cursors

Date: 2026-06-06

Milestone: Lead/integration ingestion readiness

Changed files:

- `local-ui/server.js`
- `scripts/events-export-check.sh`
- `docs/api-contract.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Extended the unified `/local/events/export` and heartbeat `events` payload with per-source cursors for command audit, display delivery, and release history.
- Each source cursor now reports total entries, exported entries, per-source limit, `hasMore`, latest event pointer, and oldest exported event pointer.
- The global cursor also exposes oldest exported event pointers and a mixed-stream `hasMore` flag.
- Hardened `scripts/events-export-check.sh` so physical Pi validation checks the new cursor shape instead of only the mixed latest cursor.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted event cursor smoke passed for seeded command, display delivery, and release events with per-source truncation and device-key redaction.

Next step:

Use `sourceCursors` in backend heartbeat event ingestion so Admin > Frames can detect truncated device event exports per source and request/support replay without guessing from the mixed event order.

## 2026-06-06 - Local release rollback script

Date: 2026-06-06

Milestone: MVP 1.0 - Release rollout safety

Changed files:

- `scripts/update-from-release.sh`
- `scripts/rollback-release.sh`
- `README.md`
- `docs/github-updates.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added a device-local rollback script for the last release update.
- Git-checkout updates now record rollback metadata before fast-forwarding; artifact updates also snapshot the current app into `/opt/autopoiesis-os/releases/rollback/app` before replacing app files.
- Rollback restores either the previous git revision or the pre-update app snapshot, reruns bootstrap/systemd unit installation, restarts setup/kiosk services, writes `release-state.json`, and appends metadata-only rollback events to `release-log.json`.
- Rollback is intentionally app-code only: `/var/lib/autopoiesis-os` is preserved so pairing, device API keys, preferences, cache metadata, and support logs survive.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Targeted rollback smoke passed for snapshot restore, release-state/log updates, and preserving device data under `/var/lib/autopoiesis-os`.

Next step:

Run rollback on physical Pi hardware after a staged release update and confirm the frame returns to the previous app version while staying paired.

## 2026-06-06 - Event export acceptance gate

Date: 2026-06-06

Milestone: Lead/integration ingestion readiness

Changed files:

- `scripts/events-export-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added a local event export verification script for the unified command, display delivery, and release history feed exposed at `/local/events/export`.
- The check validates the redacted contract kind/schema, device id, exported counts, allowed sources, parseable timestamps, newest-first ordering, unique event keys, and cursor consistency when events exist.
- Wired the check into Milestone 2 verification so physical Pi validation proves the event stream is ready for backend `aos_` ingestion alongside health/readiness/kiosk checks.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `scripts/security-smoke.sh` passed.
- `git diff --check` passed.
- Targeted local smoke passed for seeded command/delivery/release events and for `since` filtering.

Next step:

Implement backend heartbeat event ingestion using `deviceId + eventKey` as the idempotency key, then surface durable command audit, broadcast delivery, and release rollout rows in Admin > Frames.

## 2026-06-06 - Installer preflight and appliance user bootstrap

Date: 2026-06-06

Milestone: MVP 1.0 - Production installer foundation

Changed files:

- `install.sh`
- `scripts/bootstrap.sh`
- `scripts/ensure-appliance-user.sh`
- `scripts/preflight.sh`
- `README.md`
- `docs/installation.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added a reusable appliance user bootstrap helper so fresh installs and later bootstrap/update paths create the configured frame user before any runtime directory chown.
- Added `scripts/preflight.sh --install` to report hard installer blockers for root mode, rsync, curl, systemd, and Node.js 20+, plus warnings for non-Pi development hosts, missing Chromium, missing NetworkManager, and user creation.
- Wired the preflight and user helper into `install.sh`, and the user helper into `scripts/bootstrap.sh`.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- Local preflight smoke correctly failed on this development host because `rsync` is missing.
- PATH-stubbed local preflight smoke passed and reported only expected non-Pi/missing-NetworkManager warnings.

Next step:

Run `sudo ./install.sh` on a clean Raspberry Pi OS image where the `frame` user does not yet exist, then confirm the user is created with display/input groups and Milestone 2 verification still passes.

## 2026-06-04

Date: 2026-06-04

Milestone: 1 - Repo and installer skeleton

Changed files:

- `README.md`
- `install.sh`
- `update.sh`
- `uninstall-dev-tools.sh`
- `factory-reset.sh`
- `VERSION`
- `config/defaults.json`
- `config/device.example.json`
- `local-ui/package.json`
- `local-ui/server.js`
- `scripts/*.sh`
- `services/*.service`
- `timers/*.timer`
- `docs/*.md`
- `logs/.gitkeep`

Test result:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Local smoke test passed outside sandbox: `GET /local/status`, `GET /setup`, and `HEAD /launch` redirect to `/setup`.

Known issues:

- Wi-Fi connect endpoint is present but needs touchscreen UI and real-device validation.
- Pairing is mock/local only.
- Updater only supports a Git checkout and does not yet implement release rollback.
- Kiosk service assumes the active graphical session exposes `DISPLAY=:0` and `/home/frame/.Xauthority`.
- Hourly audit is read-only by design; it does not run Codex unattended.

Next step:

Implement Milestone 2: install locally, start setup service, launch Chromium kiosk at `/launch`, and verify restart behavior.

## 2026-06-05

Date: 2026-06-05

Milestone: 1 - Repo and installer skeleton (continued)

Changed files:

- `local-ui/server.js` (optimized version caching)

Test result:

- Version caching implemented to avoid reading VERSION file on every request.
- `node --check local-ui/server.js` still passes.
- All existing functionality preserved.

Next step:

Continue with Milestone 2: install locally, start setup service, launch Chromium kiosk at `/launch`, and verify restart behavior.

## 2026-06-05 - Milestone 2 scaffold

Date: 2026-06-05

Milestone: 2 - Physical Pi kiosk validation and LAN support

Changed files:

- `local-ui/server.js`
- `config/defaults.json`
- `config/device.example.json`
- `scripts/start-kiosk.sh`
- `scripts/network-status.sh`
- `scripts/connect-lan.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/*.md`

Implemented:

- Local network status API and UI for LAN and Wi-Fi.
- LAN activation through NetworkManager DHCP.
- Wi-Fi scan UI separated from the JSON API.
- Kiosk startup wait for the local `/launch` route.
- Repeatable Milestone 2 verification script for setup, kiosk, HTTP, Chromium, network state, and restart behavior.

Known issues:

- Physical Pi validation still has to be run on the target device.
- Pairing remains mock/local only.
- Production cloud API integration is still pending.

## 2026-06-05 - Brief-led program setup

Date: 2026-06-05

Milestone: Program foundation for Autopoiesis OS + Frames

Changed files:

- docs/pulse-brief.md
- docs/product-roadmap.md
- docs/database-schema.md
- docs/broadcast-system.md
- docs/admin-system.md
- docs/online-frames-profile.md
- docs/agent-notes/*.md
- docs/api-contract.md
- /data/.openclaw/workspace/autopoiesis-os-program/*

Implemented:

- Created the Pulse lead brief and roadmap from Ewoud's attached PDF.
- Added database schema proposal with program tag autopoiesis_os_frames, namespace aos, and table prefix aos_.
- Added admin system requirements for users, subscribers, subscriptions, devices, broadcasts, releases, and device commands.
- Added Profile > Frames product definition and broadcast system spec.
- Added agent notes for Pulse/RPi coordination.
- Created a separate program-management directory for logs, cron registry, and MVP management.

Next step:

Continue MVP 0.1 implementation through the active aos-* cron system.

## 2026-06-05 - Cron system

Date: 2026-06-05

Milestone: Major build automation

Implemented:

- Removed the earlier single daily autopoiesis-os-iterate cron to avoid duplicate OS automation.
- Created seven active aos-* OpenClaw cron jobs using gpt-5.4 with high thinking.
- Configured Telegram delivery to the Pulse channel for concise cliffnotes reports.
- Workstreams: lead integration, RPi appliance, online admin, API/database/sync, broadcast/feed, release/rollout, QA/security.
- Recorded cron IDs under program/CRON-REGISTRY.md.

Verification:

- Confirmed all seven cron jobs are enabled, scheduled, and set to gpt-5.4/high.
- Ran node and shell syntax checks after repo changes.

## 2026-06-05 - Device API wiring

Date: 2026-06-05

Milestone: MVP 0.1 - Pairable Frames Device

Changed files:

- local-ui/server.js
- scripts/heartbeat.sh
- scripts/sync-settings.sh
- scripts/pair-device.sh
- scripts/check-remote-status.sh
- docs/api-contract.md
- docs/agent-notes/pulse.md
- program/ROLLING-LOG.md

Implemented:

- Local UI now registers the device with the Frames API when starting pairing.
- Server pairing codes are stored locally and displayed in setup.
- Pairing status can be checked from the local UI.
- Remote settings can sync down to local preferences.
- Local settings push to the Frames API when paired.
- Heartbeat posts to the Frames API and stores queued commands locally.
- Scripts now call the local UI endpoints instead of placeholder-only behavior.

Verification:

- node --check local-ui/server.js passed.
- bash -n install/update/reset/scripts passed.
- Mock Frames API smoke test passed for register, pairing check, settings sync, heartbeat, and command storage.

Next step:

Build Profile > Frames UI and admin UI around the new backend APIs.
## Pi Command and Release Executor

- Added local `/local/commands/process` endpoint to fetch queued commands from heartbeat, acknowledge them, execute local actions, and report completed/error status.
- Added `/local/release/check` and `/local/release/apply` endpoints for release-channel lookup and local update execution.
- Added `scripts/process-commands.sh` plus `autopoiesis-command-executor.service/.timer` to process commands every 2 minutes.
- Added `scripts/update-from-release.sh` with artifact tarball support, checksum validation, git fallback, rollback metadata, and kiosk restart.
- Command support: `sync_settings`, `clear_cache`, `restart_display`, `restart_device` with explicit reboot opt-in, `update_device`, `disable_device`, `enable_device`, `show_broadcast`, and guarded `factory_reset_request`.

## 2026-06-05 - Device diagnostics contract

Date: 2026-06-05

Milestone: Lead/integration observability for QA, admin, and hardware validation

Changed files:

- `local-ui/server.js`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`

Implemented:

- Added `GET /local/diagnostics` for a compact device support snapshot.
- Heartbeat now sends the same diagnostics object to the Frames API.
- Diagnostics includes version, hostname, uptime, load, memory, temperature, cached network/pairing state, data/cache storage, release state, pending command count, current broadcast, and local systemd service states when requested locally.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Mock local UI/API smoke test passed for `GET /local/diagnostics` and heartbeat diagnostics upload.

Next step:

Teach the online Admin > Frames device detail view to surface the latest diagnostics payload from heartbeats once this Pi payload is deployed.

## 2026-06-05 - Kiosk offline launch fallback

Date: 2026-06-05

Milestone: RPi appliance runtime hardening

Changed files:

- `local-ui/server.js`
- `README.md`
- `docs/agent-notes/rpi-agent.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- `/launch` now probes the configured Frames URL before redirecting kiosk Chromium to the remote app.
- If the remote frame is unreachable, the launcher records offline mode and redirects to the local `/offline` fallback instead of a Chromium network error page.
- The offline page records the last fallback check and retries `/launch` automatically so network recovery can self-heal.

Verification:

- `node --check local-ui/server.js` passed.
- Local smoke test passed for unreachable remote -> `/offline` and reachable remote -> configured Frames URL.

Next step:

Validate on physical Raspberry Pi hardware by disconnecting LAN/Wi-Fi after pairing, confirming kiosk lands on `/offline`, reconnecting the network, and confirming the retry returns to the remote Frames app.

## 2026-06-05 - Diagnostics health summary

Date: 2026-06-05

Milestone: Lead/integration observability for support and admin surfaces

Changed files:

- `local-ui/server.js`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`

- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `diagnostics.health` to the local diagnostics payload and heartbeat diagnostics.
- Health status is derived as `ok`, `warning`, or `error`.
- Stable issue codes now cover pairing, missing device API key, network/offline fallback, storage pressure, low memory, high temperature, release/update state, pending commands, and failed systemd services when local service checks are included.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Local diagnostics smoke test passed: temporary local UI returned `diagnostics.health.status` plus expected setup issue codes.

Next step:

Use `diagnostics.health` in Admin > Frames and hardware validation reports so support does not have to infer device condition from raw telemetry.

## 2026-06-05 - QA/security smoke gate

Date: 2026-06-05

Milestone: QA/security production hygiene

Changed files:

- `scripts/security-smoke.sh`
- `README.md`
- `docs/production-cleanup.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`

Implemented:

- Added a repeatable local security smoke test that starts the local UI against temporary device state containing a fake device API key.
- The test verifies that `/local/status`, `/local/pairing/status`, and `/local/diagnostics` do not leak the key or device key field names.
- The test confirms safe key-presence flags remain visible for support and fails if sensitive-looking files are tracked in Git.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `scripts/security-smoke.sh` passed.

Next step:

Run this smoke gate on physical Raspberry Pi hardware after install, then add it to the final production-image acceptance checklist.

## 2026-06-05 - Raspberry Pi hardware validation

Date: 2026-06-05

Milestone: Physical Pi setup and endpoint validation

Hardware:

- Raspberry Pi 3 Model B Rev 1.2.
- Debian GNU/Linux 13 (trixie), 13.4.

Install:

- Removed the previous `/home/frame/autopoiesis-os-rpi` checkout.
- Recloned `dev/pulse-initial-improvements` at `34c656f`.
- Ran `sudo ./install.sh`.
- Restarted `autopoiesis-setup.service` and `autopoiesis-kiosk.service`.
- `sudo /opt/autopoiesis-os/app/scripts/milestone2-verify.sh` passed.

Network:

- LAN connected on `eth0` via `netplan-eth0`.
- Wi-Fi hardware present as `wlan0`, disconnected during this run.

Pairing:

- Live Frames API registration succeeded with non-mock pairing.
- Device remains unclaimed, so no local device API key is stored yet.
- `device.json` contains a stable `rpi-` device ID and is `0600 frame frame`.

Backend-dependent checks:

- Heartbeat, settings sync, command polling, and release check endpoints are reachable but skip until the device is claimed.
- These must be rerun after live pairing is completed from a Frames account.

Pi fix:

- Added compatibility aliases for `GET /local/status.json` and `GET /local/network/status.json`.
- Confirmed `GET /local/diagnostics` is available for the handoff checks.
- Did not change command allowlists or unattended update behavior.

Journal notes:

- Setup service reports `Autopoiesis local UI listening on http://127.0.0.1:3030`.
- Kiosk service stays active.
- Chromium logs Pi 3 GPU initialization errors including `GLES3 is unsupported` and `CollectGraphicsInfo failed`; kiosk remains running.

Source:

- Origin commit `72f41fb Validate Pi setup endpoints`.
- Full local report on the validated Pi: `logs/2026-06-05-rpi-hardware-validation.md`. The `logs/*` path is gitignored, so this tracked summary is the portable report.

## 2026-06-06 - Guided onboarding setup

Date: 2026-06-06

Milestone: Appliance first-run UX

Changed files:

- `local-ui/server.js`
- `docs/progress.md`

Implemented:

- Replaced the generic `/setup` utility panel with a guided onboarding sequence.
- The sequence now leads users through four steps: connect internet, pair account, choose basic display settings, and launch stream.
- Kept the existing network, Wi-Fi, pairing, settings, and launch endpoints underneath the flow.
- Launch remains disabled until local state has both network and pairing readiness.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh factory-reset.sh uninstall-dev-tools.sh scripts/*.sh` passed.
- `git diff --check` passed.
- Temporary local UI smoke confirmed `/setup` renders the onboarding steps and `/launch` redirects to `/setup` when unready.

Next step:

Validate the sequence on the physical touchscreen and confirm the copy/buttons fit without scrolling friction.

## 2026-06-06 - Onboarding launch gate

Date: 2026-06-06

Milestone: Appliance first-run UX

Changed files:

- `local-ui/server.js`
- `docs/progress.md`

Implemented:

- Added explicit `device.onboardingComplete` gating to `/launch`.
- Already-paired frames no longer skip the setup sequence after installing a new onboarding build.
- The final Launch Stream button calls `/launch?completeOnboarding=1`, records onboarding completion, then proceeds to the display/offline decision.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh factory-reset.sh uninstall-dev-tools.sh scripts/*.sh` passed.
- `git diff --check` passed.
- Temporary local UI smoke confirmed `/launch` redirects to `/setup` before onboarding completion, and `/launch?completeOnboarding=1` records `onboardingComplete: true`.

## 2026-06-06 - Online admin diagnostics health readout

Date: 2026-06-06

Milestone: MVP 0.5 - Managed Device Fleet

Changed files:

- `/data/.openclaw/workspace/autopoiesis/app/frontend/src/pages/AdminFrames.jsx`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Admin > Frames device detail now extracts the newest heartbeat carrying `payload.diagnostics`.
- The selected device panel shows `diagnostics.health.status`, stable issue-code chips, and the timestamp of the heartbeat that supplied diagnostics.
- The panel handles older devices that have not yet sent diagnostics by showing a clear waiting state.

Verification:

- `npm run build` passed in `/data/.openclaw/workspace/autopoiesis/app/frontend`.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.

Commit note:

- The main `autopoiesis` repo change was not committed because that checkout already contains a large unrelated dirty backlog.
- The OS repo documentation/log update can be committed safely from the clean RPi checkout.

Next step:

Extend the admin fleet list endpoint/UI to include latest health status per device, so operators can scan the whole fleet without opening each frame.

## 2026-06-06 - Compact local health probe

Date: 2026-06-06

Milestone: Lead/integration observability for support, admin adapters, and hardware validation

Changed files:

- `local-ui/server.js`
- `scripts/health-check.sh`
- `scripts/security-smoke.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `GET /local/health`, a compact redacted summary derived from the existing diagnostics health object.
- Added optional `?services=1` support so systemd service state can be included before deriving health.
- Added `scripts/health-check.sh` for Pi acceptance checks and folded it into the Milestone 2 verification flow.
- Extended the security smoke gate to prove the new health endpoint does not leak stored device API keys.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `scripts/security-smoke.sh` passed, including `/local/health` redaction coverage.
- Local smoke test passed for `scripts/health-check.sh` against `/local/health` and for service-aware `/local/health?services=1`.

Next step:

Use the same compact health shape when the online admin fleet list API grows latest-health summaries per device.

## 2026-06-06 - Local feed and broadcast display foundation

Date: 2026-06-06

Milestone: MVP 0.2/MVP 0.4 - Personal Stream and Broadcast System

Changed files:

- `local-ui/server.js`
- `docs/api-contract.md`
- `docs/broadcast-system.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added local feed state at `/local/feed` plus `POST /local/feed/sync` for the remote device feed endpoint.
- Heartbeat responses carrying `feed`, `items`, `artworks`, or `broadcasts` are normalized into the same local feed model.
- Feed eligibility now filters expired items, future scheduled items, and media types disabled by local preferences.
- Added a metadata-only cache eligibility manifest for media/thumbnail items with `cacheAllowed` enabled.
- `show_broadcast` commands now normalize payloads, reject expired broadcasts, preserve priority/expiry/duration, and route active broadcasts through a local `/broadcast` display page.
- Diagnostics and `/local/health` now include compact feed/cache and richer broadcast summary fields.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Local mock API smoke passed for feed sync, preference/expiry filtering, cache eligibility, command ack/completion, `/launch` broadcast routing, and `/broadcast` rendering.

Next step:

Connect the backend feed endpoint to the real artwork/blog/news/curatorial content model and have the cache service download the cache manifest entries for offline playback.

## 2026-06-06 - Local cache worker foundation

Date: 2026-06-06

Milestone: MVP 0.3 - Offline Living Frame

Changed files:

- `scripts/cache-artworks.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Replaced the cache placeholder with a real feed-cache worker.
- The worker reads `feed-cache.json`, downloads eligible media and thumbnails into the runtime cache directory, and writes `cache-index.json`.
- Each cached item records media/thumbnail URL, local path, status, and byte count.
- Missing manifests, offline downloads, and partial failures are handled conservatively so the hourly timer leaves support-visible state instead of silently doing nothing.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Local cache smoke passed against a temporary HTTP file server: manifest item downloaded, `cache-index.json` reported one cached item and zero failed items.

Next step:

Use `cache-index.json` from the local offline fallback route so a disconnected paired frame can display cached artwork instead of only the static offline screen.

## 2026-06-06 - Settings sync conflict handling

Date: 2026-06-06

Milestone: MVP 0.1 - Pairable Frames Device

Changed files:

- `local-ui/server.js`
- `docs/api-contract.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added device-side settings sync metadata with local/remote `updatedAt` tracking.
- Local settings saves now stamp preferences before writing or pushing to the Frames API.
- Remote settings from explicit sync, push responses, and heartbeat responses now pass through one resolver.
- Stale remote settings are rejected when their `updatedAt` is older than the local settings timestamp.
- Settings conflicts are exposed through heartbeat diagnostics as `settingsSync` plus a `settings_conflict` health warning.
- Untimestamped remote payloads remain accepted for legacy compatibility and are marked as `remote_applied_untimestamped`.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Mock Frames API smoke passed for stale remote settings rejection, `settings_conflict` health reporting, and newer remote settings application.

Next step:

Mirror the same latest-`updatedAt` rule in the online Frames backend so POST/GET settings responses always return authoritative timestamps and can report conflicts explicitly.

## 2026-06-06 - Readiness contract

Date: 2026-06-06

Milestone: Lead/integration rollout readiness

Changed files:

- `local-ui/server.js`
- `scripts/readiness-check.sh`
- `scripts/security-smoke.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `GET /local/readiness`, a redacted phase-level rollout snapshot derived from diagnostics.
- Readiness phases cover local UI, network, pairing/device key, settings sync, content/feed, cache, commands, and release state.
- Added cache index fields to diagnostics and health issue codes for cache failures or empty completed cache runs.
- Added `scripts/readiness-check.sh` and included it in Milestone 2 verification.
- Extended the security smoke gate to verify readiness output does not leak stored device API keys.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Local readiness smoke passed for an unpaired device, a paired/cache-ready device, and a cache-failure blocked device.

Next step:

Run `scripts/readiness-check.sh` on physical Raspberry Pi hardware after live pairing, then use the blocker list as the acceptance checklist for rollout.

## 2026-06-06 - Offline cache playback

Date: 2026-06-06

Milestone: MVP 0.3 - Offline Living Frame

Changed files:

- `local-ui/server.js`
- `README.md`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `GET /local/offline-cache`, a redacted playable cache inventory built from `cache-index.json` and the active feed metadata.
- Added safe cached asset serving at `/local/cache/assets/{itemId}/media` and `/local/cache/assets/{itemId}/thumbnail`, constrained to files under the configured cache directory.
- Updated `/offline` so disconnected frames rotate cached playable feed media when available, while keeping the static offline fallback for empty caches.
- Diagnostics feed summary now includes `offlinePlayableItems` for support/readiness consumers.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh factory-reset.sh uninstall-dev-tools.sh scripts/*.sh` passed.
- `scripts/security-smoke.sh` passed with `/local/offline-cache` included in redaction coverage.
- Local offline-cache smoke passed for cache inventory, cached asset serving, `/offline` cached view rendering, and unreachable `/launch -> /offline` fallback.

Next step:

Run the offline cache path on physical Raspberry Pi hardware after a real feed/cache cycle, then add cache eviction and storage pressure policy.

## 2026-06-06 - Raspberry Pi Chromium software rendering

Date: 2026-06-06

Milestone: Physical Pi kiosk hardening

Changed files:

- `scripts/start-kiosk.sh`
- `docs/troubleshooting.md`
- `docs/progress.md`

Implemented:

- Added conservative Chromium kiosk flags for Pi 3 class devices where GLES3 initialization fails.
- Default flags now disable GPU compositing/accelerated canvas and use SwiftShader software GL.
- Added `AUTOPOIESIS_CHROMIUM_FLAGS` escape hatch for future hardware-specific overrides.

Verification:

- `bash -n scripts/start-kiosk.sh` passed.

## 2026-06-06 - Kiosk launch verification

Date: 2026-06-06

Milestone: Physical Pi kiosk hardening

Changed files:

- `scripts/start-kiosk.sh`
- `scripts/kiosk-check.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/troubleshooting.md`
- `docs/progress.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added a dry-run mode to the kiosk launcher so support checks can validate the exact Chromium command without starting a browser.
- Added `scripts/kiosk-check.sh` to assert the launch route is reachable, the launcher includes Pi-safe software rendering flags, and an installed running kiosk process has picked up those flags when required.
- Wired the kiosk check into `scripts/milestone2-verify.sh` so physical Pi acceptance fails if the kiosk process is still using stale Chromium flags after a restart.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `scripts/kiosk-check.sh` passed in dry-run mode without a local server.
- Local kiosk smoke passed against a temporary local UI server for `/launch` reachability and required Chromium software-rendering flags.
- Required-process kiosk smoke passed with a simulated Chromium command line carrying the expected Pi-safe flags.
- `git diff --check` passed.

## 2026-06-06 - Remote action authorization guard

Date: 2026-06-06

Milestone: Online admin remote-action foundation

Changed files:

- `local-ui/server.js`
- `docs/api-contract.md`
- `docs/admin-system.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added command risk policy for remote device actions.
- `sync_settings` remains low-risk and can run without remote authorization metadata.
- Medium/high/critical commands now require approved authorization metadata with actor, role, and timestamp.
- High/critical commands also require an admin audit id.
- Denied commands are reported through the existing command ack error path with policy context.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Mock API/local UI smoke passed for missing-authorization rejection and authorized `disable_device` completion.

Next step:

Update the online Frames backend command queueing path to create real audit rows and include authorization metadata before sending non-`sync_settings` commands.

## 2026-06-06 - Local command audit trail

Date: 2026-06-06

Milestone: Lead/integration admin-command reconciliation

Changed files:

- `local-ui/server.js`
- `scripts/security-smoke.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/admin-system.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added bounded local `command-audit.json` persistence for completed, denied, and failed remote command attempts.
- Added redacted `GET /local/commands/audit` for support/admin adapters.
- Heartbeat diagnostics, `/local/health`, and `/local/readiness` now include a compact `commandAudit` summary.
- Extended the security smoke gate so the command audit endpoint is included in device API key redaction coverage.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed with `/local/commands/audit` included in redaction coverage.
- Mock Frames API/local UI command audit smoke passed for missing-authorization denial, authorized `disable_device` completion, audit endpoint output, diagnostics/readiness summaries, and device-key redaction.

Next step:

Mirror this device-side command audit trail with durable backend `aos_` admin audit rows and include real authorization metadata when queueing non-`sync_settings` commands.

## 2026-06-06 - Redacted local support bundle

Date: 2026-06-06

Milestone: Lead/integration rollout evidence

Changed files:

- `local-ui/server.js`
- `scripts/support-bundle.sh`
- `scripts/security-smoke.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added `GET /local/support-bundle`, a redacted one-shot support payload for hardware validation, admin adapters, and handoff reports.
- The bundle aggregates existing redacted diagnostics, compact health, rollout readiness, active feed, offline-cache inventory, and recent command audit entries.
- Added `scripts/support-bundle.sh` to collect the bundle from a running local UI, print a concise summary, and optionally write the JSON to a specified path.
- Extended the local security smoke gate so the support bundle is covered by device API key redaction checks.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `scripts/security-smoke.sh` passed with `/local/support-bundle` included in device-key redaction coverage.
- Targeted support-bundle smoke passed for `?services=0&auditLimit=1`, script file output, summary generation, audit limiting, and device-key redaction.
- `git diff --check` passed.

Next step:

Run the support bundle collector on physical Raspberry Pi hardware after live pairing, real feed/cache sync, and at least one remote command attempt; then mirror the shape into Admin > Frames fleet support exports.

## 2026-06-06 - Device delivery log foundation

Date: 2026-06-06

Milestone: MVP 0.4 - Broadcast delivery evidence

Changed files:

- `local-ui/server.js`
- `scripts/security-smoke.sh`
- `docs/api-contract.md`
- `docs/broadcast-system.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added bounded local `delivery-log.json` persistence for display/feed lifecycle events.
- Feed sync now records `feed_synced` events with total, eligible, and cache-eligible counts.
- Broadcast display now records `broadcast_shown`, `broadcast_dismissed`, and one-time `broadcast_expired` events.
- Added redacted `GET /local/delivery-log` for support/admin adapters.
- Diagnostics, `/local/health`, and `/local/support-bundle` now include compact display-delivery summaries.
- Extended the security smoke gate so the delivery log endpoint is covered by device API key redaction checks.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed with `/local/delivery-log` included in device-key redaction coverage.
- Targeted delivery-log smoke passed for feed sync, authorized broadcast show, dismiss, one-time expiry logging, support-bundle `deliveryLimit`, and device-key redaction.

Next step:

Mirror these device-side delivery events into durable backend `aos_` delivery rows from heartbeat diagnostics/support-bundle ingestion, then surface broadcast delivery state in Admin > Frames.

## 2026-06-06 - Appliance watchdog timer

Date: 2026-06-06

Milestone: RPi appliance runtime self-healing

Changed files:

- `scripts/watchdog.sh`
- `scripts/install-systemd-units.sh`
- `services/autopoiesis-watchdog.service`
- `timers/autopoiesis-watchdog.timer`
- `install.sh`
- `scripts/update-from-github.sh`
- `scripts/update-from-release.sh`
- `scripts/milestone2-verify.sh`
- `README.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Replaced the placeholder kiosk restart service with a real appliance watchdog script.
- Added a systemd watchdog timer enabled by install.
- Added a shared systemd unit installer used by fresh install and both update paths so changed services/timers are copied to `/etc/systemd/system` and newly added timers are enabled on upgraded devices.
- Watchdog checks local health HTTP, local launch HTTP, and the kiosk process/flags through the existing kiosk check.
- Setup restarts only when local routes are unreachable; kiosk restarts only when the kiosk check fails.
- Milestone 2 verification now confirms the watchdog timer is enabled and runs the watchdog script.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed.
- Local watchdog smoke passed with a temporary local UI, fake systemctl, and simulated Chromium kiosk process.
- Systemd unit installer dry-run smoke passed against a temporary systemd directory with a fake systemctl.

Next step:

Run the updated `scripts/milestone2-verify.sh` on physical Pi hardware after install/update to confirm the watchdog timer can restart real systemd services without disrupting a healthy kiosk session.

## 2026-06-06 - Command acknowledgement retry safety

Date: 2026-06-06

Milestone: MVP 0.1 - Pairable Frames Device command sync

Changed files:

- `local-ui/server.js`
- `docs/api-contract.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Local command queues now retain commands when the initial `acknowledged` POST fails, without executing the command.
- Commands that execute successfully but fail to deliver the final `completed` or `error` acknowledgement are retained with local final-ack retry metadata.
- Final-ack retries do not execute the command again, preventing duplicate side effects for commands like broadcast display, disable, update, restart, or cache clear.
- Command audit summaries now count acknowledgement delivery failures as recent errors.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- Targeted mock Frames API smoke passed for initial ack failure retention, final ack failure retention without re-execution, and final ack retry removal.

Next step:

Mirror this expectation in backend `aos_` command rows: command status transitions should be idempotent, preserve last ack error, and tolerate devices retrying the same final acknowledgement after local execution.

## 2026-06-06 - Local release history contract

Date: 2026-06-06

Milestone: MVP 0.5 - Managed Device Fleet rollout evidence

Changed files:

- `local-ui/server.js`
- `scripts/support-bundle.sh`
- `scripts/security-smoke.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/admin-system.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added bounded local `release-log.json` persistence for release check/apply lifecycle events.
- `/local/release/check` records `release_checked`; release apply paths record `release_apply_started`, `release_apply_completed`, `release_apply_failed`, or `release_skipped`.
- Added redacted `GET /local/release/history` for support, hardware validation, and admin rollout adapters.
- Diagnostics, `/local/health`, `/local/readiness`, and `/local/support-bundle` now include compact release-history summaries.
- Extended the support-bundle CLI summary and security smoke gate to cover release history.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed with `/local/release/history` included in device-key redaction coverage.
- Targeted release-history smoke passed for mock API release check, already-current release apply skip, history events, support-bundle summary, and artifact/checksum/key redaction.

Next step:

Mirror these device-side release events into durable backend `aos_` rollout rows and make Admin > Frames show per-device release progress from heartbeat/support-bundle ingestion.

## 2026-06-06 - Local admin capabilities contract

Date: 2026-06-06

Milestone: MVP 0.5 - Managed Device Fleet role-gated actions

Changed files:

- `local-ui/server.js`
- `scripts/security-smoke.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/admin-system.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added redacted `GET /local/admin/capabilities` for Admin > Frames, support tools, and backend adapters.
- The endpoint reports pairing/key presence, remote-enabled state, accepted actor roles, authorization window, supported command types, risk levels, audit-id requirements, local confirmation gates, runtime opt-in requirements, pending command count, and compact command-audit summary.
- Included the same admin capability object in `/local/support-bundle` so support exports carry the current remote action policy matrix.
- Extended the security smoke gate so admin capabilities are checked for device API key redaction and high-risk audit requirements.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed with `/local/admin/capabilities` included in device-key redaction coverage.
- Targeted admin-capabilities smoke passed for command policy shape, support-bundle inclusion, restart-device runtime opt-in, and no device-key leakage.

Next step:

Use `/local/admin/capabilities` or its support-bundle copy when building Admin > Frames action buttons, and persist real backend `aos_` audit rows before queueing non-`sync_settings` commands.

## 2026-06-06 - Unified device event export

Date: 2026-06-06

Milestone: Lead/integration backend ingestion contract

Changed files:

- `local-ui/server.js`
- `scripts/security-smoke.sh`
- `scripts/support-bundle.sh`
- `README.md`
- `docs/api-contract.md`
- `docs/admin-system.md`
- `docs/troubleshooting.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added redacted `GET /local/events/export`, a unified newest-first event stream built from local command audit, display delivery, and release history evidence.
- Heartbeats now include the same bounded event export under `events`, giving the backend one ingestion shape for durable `aos_` command audit, broadcast delivery, and release rollout rows.
- Support bundles now include `deviceEvents`, and the support-bundle CLI summary reports exported event count.
- Event exports include stable `source`, `eventKey`, and `observedAt` fields so backend ingestion can use `deviceId + eventKey` idempotency.
- Extended the local security smoke gate so `/local/events/export` is covered by device-key redaction checks.

Verification:

- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed.
- `scripts/security-smoke.sh` passed with `/local/events/export` included in device-key redaction coverage.
- Targeted event export smoke passed for event aggregation, `since` filtering, support-bundle inclusion, heartbeat inclusion, and device-key redaction.

Next step:

Implement backend heartbeat event ingestion into durable `aos_` command audit, broadcast delivery, and release rollout rows, treating repeated `deviceId + eventKey` reports as idempotent.

## 2026-06-06 - Backend admin command authorization audit

Date: 2026-06-06

Milestone: MVP 0.5 - Managed Device Fleet role-gated actions

Changed files:

- `/data/.openclaw/workspace/autopoiesis/app/backend/production.py`
- `docs/api-contract.md`
- `docs/admin-system.md`
- `docs/agent-notes/pulse.md`
- `docs/progress.md`
- `/data/.openclaw/workspace/autopoiesis-os-program/ROLLING-LOG.md`

Implemented:

- Added backend `aos_admin_command_audits` persistence for admin-originated remote frame commands.
- Direct Admin > Frames device commands now create an audit row before queueing medium/high/critical commands and embed approved `payload.authorization` metadata for the Pi executor.
- Admin broadcast and release enqueue paths now use the same authorization/audit path for `show_broadcast` and `update_device` commands.
- Device command acknowledgements now update the matching backend audit row status.
- Admin device detail responses now include recent command audit rows for UI/support consumption.

Verification:

- `python3 -m py_compile app/backend/production.py` passed in the main `autopoiesis` repo.
- Focused Flask test-client smoke passed against a temporary SQLite database for high-risk command authorization payloads, audit status updates, and disallowed actor-role rejection.
- `node --check local-ui/server.js` passed.
- `bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed.
- `git diff --check` passed in both touched repos.

Commit status:

- RPi documentation was committed locally.
- The main `autopoiesis` backend code was not committed because that checkout already contains a very large unrelated dirty backlog, including pre-existing modifications in `app/backend/production.py`.

Next step:

Ingest heartbeat `events` into durable backend broadcast delivery, release rollout, and device event rows using `deviceId + eventKey` idempotency, then show those rows in Admin > Frames.
