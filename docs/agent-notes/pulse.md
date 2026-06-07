# Pulse Agent Notes

## 2026-06-07 - Hosted suite gate catalog

Date/time: 2026-06-07 09:15 UTC / 2026-06-07 11:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The hosted suite had accumulated a long ordered gate list used by strict mode, execution, docs, and backend manifest generation. That made CI jobs likely to drift as new hosted gates were added.
What changed: Added `--list-gates` to `scripts/hosted-contract-suite-check.sh`, returning a JSON catalog with gate name, order, source environment variable, checker script, and label. The shell runner now uses one `for_each_gate` table for both `--strict` all-gate generation and execution order, so those two paths cannot diverge.
What needs review: The embedded manifest alias validation still has duplicated gate/alias metadata; a later cleanup should move alias normalization into one generated helper if the suite keeps growing.
Next recommended action: Have hosted CI generate manifest templates and rollout annotations from `scripts/hosted-contract-suite-check.sh --list-gates`, then run `--plan` and the full suite from the generated manifest.

## 2026-06-07 - Watchdog restart policy gate

Date/time: 2026-06-07 08:35 UTC / 2026-06-07 10:35 Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE cron pass. The appliance watchdog already restarted setup or kiosk during live Milestone 2 checks, but there was no isolated way to prove its restart policy before touching real services.
What changed: Added `scripts/watchdog-check.sh`, which stubs local HTTP probes, kiosk process lookup, `systemctl`, and `sleep` around the real `scripts/watchdog.sh`. It verifies healthy no-op behavior, setup restart on `/local/health` failure, setup restart on `/launch` failure, and kiosk restart when Chromium is missing once. Milestone 2 now runs this gate before the live watchdog.
What needs review: Physical Pi validation should still force one real setup failure and one real kiosk failure, then compare service journals against this isolated policy.
Next recommended action: Run full Milestone 2 on hardware after install/update and capture `journalctl -u autopoiesis-watchdog.service -n 120 --no-pager` if either recovery path differs.

## 2026-06-07 - Hosted manifest source validation

Date/time: 2026-06-07 08:15 UTC / 2026-06-07 10:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The hosted suite could consume a manifest and produce a plan report, but typoed source keys or enabled source entries without values could still degrade into skipped gates unless the same gate was also marked required.
What changed: Added early source-container validation to `scripts/hosted-contract-suite-check.sh`. `sources`, `contracts`, `gates`, and `contractSources` must be objects keyed by normalized gate names; unknown keys and enabled entries without `source`, `path`, `file`, or `url` now fail before plan or execution.
What needs review: Hosted artifact generation should emit `false` or `{ "enabled": false }` for deliberately disabled sources, rather than empty strings or placeholder objects.
Next recommended action: Run suite `--plan` against every generated staging manifest and archive the redacted report before the full strict run.

## 2026-06-07 - Hosted command state contract

Date/time: 2026-06-07 06:45 UTC / 2026-06-07 08:45 Europe/Berlin
Agent: Pulse
Context: API / DATABASE / SYNC cron pass. Command polling and acknowledgement gates existed, but the hosted suite still lacked one direct proof that the durable command outbox moves through queued, delivered, terminal, and post-terminal non-delivery states.
What changed: Added `scripts/command-state-contract-check.sh` and wired `command-state` into the hosted contract suite after command acknowledgement. Added backend handoff docs for a read-only bundle covering `beforePollCommands`, `postPollCommands`, `postAckCommands`, mirrored admin audits, next-poll exclusion, and redaction boundaries.
What needs review: Hosted staging should generate this bundle from seeded `aos_device_commands` rows plus the same poll serializer and ack route used by real devices. Decide whether poll itself marks rows `sent` immediately or whether the first acknowledgement is the canonical delivered transition.
Next recommended action: Run the strict hosted suite with `AUTOPOIESIS_COMMAND_STATE_CONTRACT_SOURCE` before enabling broad Profile/Admin remote command controls.

## 2026-06-07 - Hosted suite JSON readiness report

Date/time: 2026-06-07 06:15 UTC / 2026-06-07 08:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The hosted suite could run manifest-driven gates, but CI and rollout handoffs still had to interpret terminal output to know which gates passed, skipped, or blocked.
What changed: Added optional `AUTOPOIESIS_HOSTED_CONTRACT_REPORT` output to `scripts/hosted-contract-suite-check.sh`. The report is written on pass and fail, names the failed gate when available, summarizes required/passed/skipped gates, and records only source-presence booleans rather than raw paths or URLs.
What needs review: Hosted CI should archive the report beside the contract manifest and use it as the backend readiness artifact for release and physical-Pi handoff decisions.
Next recommended action: Generate one staging report from the strict hosted suite, then wire the report fields into deployment annotations or GitHub issue comments.


## 2026-06-07 - Device update channel enforcement

Date/time: 2026-06-07 06:00 UTC / 2026-06-07 08:00 Europe/Berlin
Agent: Pulse
Context: RELEASE / ROLLOUT cron pass. The manifest checker could enforce channels, but release apply still depended on callers or services remembering to set `AUTOPOIESIS_RELEASE_CHANNEL` and `AUTOPOIESIS_RELEASE_REQUIRE_CHANNEL`.
What changed: `scripts/update-from-release.sh` now infers the expected channel from device-local `device.json` when no explicit env channel is provided, requires a manifest channel when a device channel exists, and rejects mismatches before rollback metadata, artifact download, git fallback, or app-code mutation. Manifest validation failures are recorded in `update.log`. Rollback metadata now records release channel, tag, and id. Local release state/history also carries tag/channel context.
What needs review: Hosted release generation should always emit channel and tag metadata. Physical Pi validation still needs one staged artifact apply plus rollback inspection to prove the runtime service environment and local device channel behave the same as the isolated smoke.
Next recommended action: Cut a staging artifact on the `stable` channel, apply it to a stable-channel Pi, inspect release history and rollback metadata, then repeat only the manifest check with a mismatched beta manifest to confirm the device refuses it.


## 2026-06-07 - Hosted suite manifest requirements

Date/time: 2026-06-07 05:15 UTC / 2026-06-07 07:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The hosted suite could consume one manifest of contract sources, but the pass/fail intent still lived outside the artifact in `--strict` or `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE`, which made partial backend handoffs easy to mis-run.
What changed: Extended `scripts/hosted-contract-suite-check.sh` so manifests can declare required gates with `require`, `required`, `requireGates`, or `requiredGates`, and can require every gate with `strict: true` or `requireAll: true`. The suite still honors per-gate source environment overrides and external `--strict`/`AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE`.
What needs review: Hosted CI should emit `require` for partial jobs and `strict: true` for full staging artifacts so the manifest itself proves which evidence set is expected.
Next recommended action: Generate the staging artifact manifest with self-declared requirements and run the suite without extra env flags as the backend-to-Pi handoff gate.

## 2026-06-07 - Heartbeat runner resilience gate

Date/time: 2026-06-07 04:35 UTC / 2026-06-07 06:35 Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE cron pass. The heartbeat service was timer-managed, and local heartbeat/event-ingestion behavior had deeper mock API checks, but the shell wrapper itself could still exit before logging if pre-pairing JSON state was missing or malformed.
What changed: Hardened `scripts/heartbeat.sh` to create its log directory, normalize `AUTOPOIESIS_LOCAL_URL`, and fall back to `unknown` device/mode values on unreadable or invalid JSON. Added `scripts/heartbeat-runner-check.sh` to prove success logging, local UI failure logging, URL normalization, and damaged-state resilience with a fake `curl`. Wired it into Milestone 2 before the event-ingestion cursor check.
What needs review: Run this on the physical Pi after boot and after pairing. The isolated gate proves wrapper behavior, but hardware still needs confirmation that the real systemd timer writes logs under the installed appliance user and that local UI outages produce useful `heartbeat-error.log` entries.
Next recommended action: During physical Milestone 2, force one local UI restart/outage and confirm the next timer tick records the failure without disabling the heartbeat loop.

## 2026-06-07 - Hosted suite manifest integration

Date/time: 2026-06-07 04:15 UTC / 2026-06-07 06:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The hosted suite now covers the full chain of migration, schema, pairing, auth, settings, ownership, heartbeat, commands, stream, cache, admin, broadcast, release, and rollout gates, but CI still had to export a long list of individual source variables.
What changed: Added `AUTOPOIESIS_HOSTED_CONTRACT_MANIFEST` and the `AUTOPOIESIS_HOSTED_CONTRACT_BUNDLE` alias to `scripts/hosted-contract-suite-check.sh`. The manifest can provide a `sources` object keyed by normalized gate names, resolves relative fixture paths from the manifest directory, supports URL manifests with an optional bearer token, and still lets per-gate source variables override manifest entries for targeted reruns.
What needs review: Hosted CI should generate one manifest alongside the saved contract fixtures, then run the strict suite from that manifest before physical Pi validation.
Next recommended action: Build the staging artifact/index that emits the manifest, then keep individual source env vars only for override/debug jobs.

## 2026-06-07 - Online admin subscription consistency

Date/time: 2026-06-07 04:05 UTC / 2026-06-07 06:05 Europe/Berlin
Agent: Pulse
Context: ONLINE ADMIN cron pass. The online-admin bundle checked users, subscribers, subscriptions, fleet devices, cache preferences, and action availability, but it still allowed those admin pages to pass as disconnected lists.
What changed: Tightened `scripts/online-admin-contract-check.sh` so Admin > Frames users, subscribers, subscriptions, and fleet devices must cross-reference cleanly. The gate now rejects duplicate ids, page totals smaller than returned items, subscribers without listed users, subscription rows without listed users, entitled subscriptions without subscriber rows, subscriber/device subscription ids missing from the subscription page, and fleet device owners missing from the user page. Added `docs/agent-notes/backend-online-admin-subscription-consistency-issue.md`.
What needs review: Hosted staging should generate the online-admin bundle from the canonical account/subscription provider plus durable `aos_` device rows, normalizing billing statuses once before Admin/Profile controls consume them.
Next recommended action: Run the strict hosted suite with the updated online-admin bundle before enabling subscription-gated remote actions or fleet subscription filters.

## 2026-06-07 - Hosted command polling contract

Date/time: 2026-06-07 03:15 UTC / 2026-06-07 05:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. Device auth proved the command route is keyed and command acknowledgement proved ack persistence, but hosted readiness still lacked a direct proof that durable queued command rows become exactly the redacted command set a device is allowed to poll.
What changed: Added `scripts/command-poll-contract-check.sh` and wired `command-poll` into the hosted contract suite between heartbeat and command acknowledgement. Added backend handoff docs for a read-only bundle covering durable `aos_device_commands`, authorized poll response shape, ineligible command exclusion, denied poll evidence, authorization metadata, audit ids, and redaction boundaries.
What needs review: Hosted staging should generate this bundle from real command queue rows plus the same serializer used by heartbeat command responses or `GET /api/frames/device/{deviceId}/commands`. Decide whether polling marks rows as sent immediately or waits for the initial acknowledged ack.
Next recommended action: Run the strict hosted suite with `AUTOPOIESIS_COMMAND_POLL_CONTRACT_SOURCE` before enabling broad Admin/Profile remote command actions.

## 2026-06-07 - Hosted command acknowledgement contract

Date/time: 2026-06-07 02:45 UTC / 2026-06-07 04:45 Europe/Berlin
Agent: Pulse
Context: API / DATABASE / SYNC cron pass. Device ack retry behavior and route authentication were covered, but hosted readiness still lacked one durable proof that `POST /commands/{commandId}/ack` updates command rows, mirrors admin audit status, and handles duplicate final acknowledgements harmlessly.
What changed: Added `scripts/command-ack-contract-check.sh` and wired `command-ack` into `scripts/hosted-contract-suite-check.sh` immediately after heartbeat. Added backend handoff docs for a read-only bundle covering durable `aos_device_commands`, ack attempts, `aos_admin_command_audits`, heartbeat-ingested `command_audit` events, duplicate final-ack idempotency, and redaction boundaries.
What needs review: Hosted staging should generate this bundle from route-level ack integration tests plus durable `aos_` projections. Decide whether duplicate final acks return 200/204 with idempotent metadata or 409 with the unchanged terminal row.
Next recommended action: Run the strict hosted suite with `AUTOPOIESIS_COMMAND_ACK_CONTRACT_SOURCE` before enabling broad Profile/Admin remote command controls.

## 2026-06-07 - Factory reset contract gate

Date/time: 2026-06-07 02:35 UTC / 2026-06-07 04:35 Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE cron pass. Factory reset is deliberately destructive on real device state, but until now the appliance only documented the behavior instead of proving it in an isolated acceptance gate.
What changed: Added `scripts/factory-reset-check.sh` and wired it into Milestone 2 verification. The checker seeds paired identity/runtime/support/cache state in temporary directories, runs the real reset script with a stubbed `systemctl`, verifies regenerated unpaired identity, cleared runtime/cache/support state, restored install-cache directories, setup/kiosk restart intent, support-history preservation mode, and dry-run non-mutation.
What needs review: Run the full Milestone 2 script on the physical Pi, then perform one real reset after collecting a support bundle so the screen, pairing flow, and new device identity are confirmed on hardware.
Next recommended action: Treat this script as the pre-reset sanity gate in support workflows; if it fails, fix reset behavior before asking anyone to run `factory-reset.sh` against real appliance state.

## 2026-06-07 - Feed polling metadata contract

Date/time: 2026-06-07 02:25 UTC / 2026-06-07 04:25 Europe/Berlin
Agent: Pulse
Context: BROADCAST / FEED cron pass. Local mixed-stream targeting, priority, expiry, cache eligibility, and broadcast display evidence were already gated, but hosted stream polling cadence was still implicit.
What changed: Added device-side normalization for redacted stream polling/freshness hints such as `pollAfterSeconds`, `minPollSeconds`, `maxPollSeconds`, `nextPollAt`, and `staleAfter`. The hints now surface through `POST /local/feed/sync`, `GET /local/feed`, local diagnostics/support, and `feed_synced` delivery evidence. Tightened `scripts/stream-contract-check.sh` with optional `AUTOPOIESIS_REQUIRE_STREAM_POLLING=1`, and extended `scripts/feed-targeting-check.sh` to prove cadence preservation.
What needs review: Hosted staging should decide the canonical cadence field location, preferably `stream.polling`, and include it in stream fixtures before strict device rollout.
Next recommended action: Generate a live stream response with `stream.polling`, run `AUTOPOIESIS_REQUIRE_STREAM_POLLING=1 ./scripts/stream-contract-check.sh`, then use local diagnostics to confirm the Pi reports the same freshness policy after sync.

## 2026-06-07 - Hosted profile ownership contract gate

Date/time: 2026-06-07 02:15 UTC / 2026-06-07 04:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. Device-key auth and Profile/Admin bundle gates were in place, but ordinary Profile > Frames account routes still needed one executable proof that users cannot see or mutate another owner's frame.
What changed: Added `scripts/profile-ownership-contract-check.sh` and wired `profile-ownership` into `scripts/hosted-contract-suite-check.sh` after settings conflict handling. Added backend handoff docs for a read-only ownership bundle covering owner list/read/write success, cross-owner read/settings/command rejection, anonymous profile rejection, and separate Admin fleet read evidence.
What needs review: Hosted staging should generate this bundle from real account/session authorization tests or a staging-only adapter backed by canonical users plus `aos_frame_devices.owner_user_id`. Decide whether cross-owner misses normalize to 403 or 404.
Next recommended action: Run the strict hosted suite with `AUTOPOIESIS_PROFILE_OWNERSHIP_CONTRACT_SOURCE` before exposing destructive Profile > Frames owner actions.

## 2026-06-07 - Install preflight app-tree gate

Date/time: 2026-06-07 00:35 UTC / 2026-06-07 02:35 Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE cron pass. The installer preflight caught OS dependencies and disk pressure, but a damaged or partial checkout could still reach the copy/bootstrap step and fail later as a kiosk, service, or heartbeat symptom.
What changed: Added an app-tree completeness gate to `scripts/preflight.sh`. It validates required config, local UI, service, timer, version, and executable runtime script files, then runs `node --check` on `local-ui/server.js` when Node is available. `AUTOPOIESIS_PREFLIGHT_APP_ROOT` lets support point the same check at an installed app tree or isolated fixture.
What needs review: Run the preflight from both a clean release checkout and the installed `/opt/autopoiesis-os/app` tree on physical Pi hardware. If a release artifact intentionally omits a file this gate names, update the gate and install docs in the same release.
Next recommended action: Pair this with the disk-space preflight and production cleanup audit before cloning the first production image.

## 2026-06-07 - Hosted cache/offline contract

Date/time: 2026-06-07 00:15 UTC / 2026-06-07 02:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. Stream and Profile/Admin contracts already name cache eligibility and cache preferences, but the strict hosted suite still lacked one bridge proving cache candidates, explicit cache policy, and ingested device offline summaries line up before physical Pi cache validation.
What changed: Added `scripts/cache-contract-check.sh` and wired `cache` into `scripts/hosted-contract-suite-check.sh` between stream and online-admin. The gate validates explicit cache policy booleans and size limits, HTTP(S) cache candidate URLs, duplicate ids, cache status/category vocabulary, device cache evidence, optional cache-relevant commands, and redaction of credentials plus local cache paths.
What needs review: Hosted staging should generate the bundle from durable `aos_` settings/preferences, stream/content/broadcast rows, and heartbeat/support-ingested cache summaries. Decide whether support-bundle uploads can backfill cache state or whether heartbeat is the only source.
Next recommended action: Run the expanded hosted suite with a real cache bundle before enabling Profile > Frames cache-management controls or treating offline fallback as production-ready.

## 2026-06-07 - Hosted settings conflict contract

Date/time: 2026-06-06 22:45 UTC / 2026-06-07 00:45 Europe/Berlin
Agent: Pulse
Context: API / DATABASE / SYNC cron pass. Device-side settings sync already proves newest-`updatedAt` conflict handling locally, but the strict hosted suite still lacked direct evidence that durable backend settings rows reject stale writes and keep heartbeat settings current.
What changed: Added `scripts/settings-contract-check.sh` and wired it into `scripts/hosted-contract-suite-check.sh` between device auth and heartbeat. The gate validates initial read, newer write, stale write conflict/rejection, final read preservation, heartbeat settings freshness, device-id consistency, and redaction.
What needs review: Hosted staging should generate the bundle from real `aos_frame_device_settings` / `aos_frame_user_preferences` rows and the same heartbeat response assembler used by devices. The stale-write response shape still needs a product/API decision.
Next recommended action: Run the expanded hosted suite with a settings bundle before trusting heartbeat/Profile/Admin fixtures, then settle whether stale writes return `409 Conflict`, `ok=false`, or `applied: false`.

## 2026-06-07 - Install preflight disk-space gate

Date/time: 2026-06-06 22:35 UTC / 2026-06-07 00:35 Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE cron pass. The one-command install preflight checked commands and runtime shape, but it could still proceed on a nearly full SD card and fail later during copy/cache/bootstrap work.
What changed: Added a configurable free-space gate to `scripts/preflight.sh --install` for the selected install, data, and log volumes. It follows `AUTOPOIESIS_INSTALL_DIR`, `AUTOPOIESIS_DATA_DIR`, and `AUTOPOIESIS_LOG_DIR`, defaults to 1024 MB minimum free space, and can be tuned with `AUTOPOIESIS_PREFLIGHT_MIN_FREE_MB`.
What needs review: Run the updated preflight on the clean Raspberry Pi OS image before install. If a production image intentionally has less than 1 GB free, document the override in the rollout note instead of silently bypassing it.
Next recommended action: Pair this with strict production cleanup before imaging so storage exhaustion and leftover development state are caught before cloning devices.

## 2026-06-07 - Hosted broadcast lifecycle contract

Date/time: 2026-06-06 22:15 UTC / 2026-06-07 00:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The strict hosted suite covered pairing, auth, heartbeat, stream, Profile/Admin, and release readiness, but broadcast rollout still relied on local Pi checks without a hosted lifecycle contract.
What changed: Added `scripts/broadcast-contract-check.sh` and wired it into `scripts/hosted-contract-suite-check.sh`. The gate validates durable broadcast rows, explicit targeting/audience, queued `show_broadcast` commands with approved authorization/audit metadata, delivery/display evidence, and redaction boundaries.
What needs review: Hosted staging should generate the bundle from durable `aos_` broadcast, admin command/audit, and delivery rows. Decide whether global broadcasts normalize as `audience: "all"` or a structured targeting object before CI fixtures settle.
Next recommended action: Run the expanded strict hosted suite with a real broadcast lifecycle fixture before enabling Admin > Frames broadcast rollout controls in staging.

## 2026-06-07 - Online admin profile cache contract

Date/time: 2026-06-06 22:05 UTC / 2026-06-07 00:05 Europe/Berlin
Agent: Pulse
Context: ONLINE ADMIN cron pass. The Profile > Frames contract named cache preferences and liked artworks as required surface data, but the checker still allowed missing cache preference policy and did not validate paged liked-artwork item rows.
What changed: Tightened `scripts/online-admin-contract-check.sh` so `profileFrames.cachePreferences` is required with explicit cache enabled/liked/recent/selected-artist toggles and a size limit. Paged `likedArtworks.items` now validate stable artwork ids like the flat array form.
What needs review: Hosted staging fixtures or adapters should build cache preferences from durable user/device settings, not frontend defaults. Empty liked-artwork pages are fine, but any returned item must identify the artwork.
Next recommended action: Run the hosted contract suite with the updated online-admin bundle before enabling Profile > Frames cache-management controls in staging.

## 2026-06-06 - Production cleanup audit gate

Date/time: 2026-06-06 21:56 UTC / 2026-06-06 23:56 Europe/Berlin
Agent: Pulse
Context: QA / SECURITY cron pass. The production cleanup doc still called `scripts/cleanup-production.sh` a loose checklist, leaving final image hygiene dependent on manual interpretation.
What changed: Reworked `scripts/cleanup-production.sh` into a read-only audit with strict mode. It checks the installed app tree for secret-like files and Git metadata, verifies tracked secret paths when the app is still a checkout, inspects production home dirs for Codex/OpenClaw/OpenAI credential homes, scans shell histories for obvious secret hints without printing matching lines, reports development caches, and flags SSH exposure unless explicitly allowed.
What needs review: Run the strict audit on the physical Pi after appliance validation and before cloning a production image. If SSH is intentionally kept for support, set the allow flag and document that policy in the rollout note.
Next recommended action: Pair this gate with `scripts/security-smoke.sh` and strict rollout acceptance as the final production-image QA bundle.

## 2026-06-06 - Hosted device auth contract gate

Date/time: 2026-06-06 21:15 UTC / 2026-06-06 23:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. Pairing and heartbeat contracts were in place, but the hosted suite still did not prove that device-only routes reject absent credentials, invalid credentials, or credentials belonging to another frame.
What changed: Added `scripts/device-auth-contract-check.sh`, a read-only staging/CI bundle gate for pairing status, settings read/write, heartbeat, stream, command polling, command acknowledgement, and release route authentication. Wired it into `scripts/hosted-contract-suite-check.sh` between pairing and heartbeat.
What needs review: Backend CI should generate the device-auth bundle from real route-level authorization tests or a staging-only admin adapter. The bundle must never include raw device keys or stored credential field names.
Next recommended action: Run the expanded hosted suite with real migration/schema/pairing/device-auth/heartbeat/stream/admin/release fixtures before physical Pi validation.

## 2026-06-06 - Support bundle acceptance gate

Date/time: 2026-06-06 20:35 UTC / 2026-06-06 22:35 Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE cron pass. The device already had a rich redacted support bundle, but physical Pi reports and Admin/Profile support adapters needed a direct contract gate instead of relying on partial storage, security, and admin snapshot checks.
What changed: Added `scripts/support-bundle-check.sh` to validate the support bundle schema, redaction marker, timestamps, health/readiness summaries, runtime storage, input, playback, command policies, event export, and required evidence sections. Wired it into Milestone 2 before the derived admin device snapshot check.
What needs review: Run the checker on physical paired hardware after real feed/cache sync and at least one command or broadcast attempt so the bundle proves useful under non-empty evidence.
Next recommended action: Use the validated support bundle as the attachment/source payload for hardware rollout issue reports and future Admin/Profile downloadable support exports.

## 2026-06-06 - Hosted heartbeat contract gate

Date/time: 2026-06-06 20:15 UTC / 2026-06-06 22:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The hosted suite covered migration/schema/pairing/stream/admin/release, but heartbeat is the sync path where settings, commands, event ingestion, broadcast delivery, and rollout evidence converge.
What changed: Added `scripts/heartbeat-contract-check.sh` for saved heartbeat responses, saved request/response bundles, or live POST checks with a request fixture. Wired the checker into `scripts/hosted-contract-suite-check.sh` so strict hosted readiness now requires heartbeat/event-ingestion evidence.
What needs review: Hosted CI should generate a heartbeat contract bundle from a paired staged device or a seeded fixture that includes exported events and an `eventsAck` response.
Next recommended action: Run the expanded hosted suite against real migration/schema/pairing/heartbeat/stream/admin/release fixtures before physical Pi Milestone 2 validation.

## 2026-06-06 - Hosted contract suite gate

Date/time: 2026-06-06 19:15 UTC / 2026-06-06 21:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The backend contract work had good individual gates, but no single staging command that proved migration/schema/pairing/stream/admin/release readiness before handing the build to physical Pi validation.
What changed: Added `scripts/hosted-contract-suite-check.sh`, an ordered runner for hosted migration, schema, pairing, stream, online-admin, and release manifest checks. It supports `--strict` for full staging acceptance and `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE` for partial CI jobs.
What needs review: Hosted CI still needs to generate or expose the saved contract fixtures/URLs; the suite deliberately does not invent live endpoints or credentials.
Next recommended action: Wire the suite into the hosted backend staging job and require it before Milestone 2 physical Pi acceptance.

## 2026-06-06 - Online admin role matrix contract

Date/time: 2026-06-06 19:05 UTC / 2026-06-06 21:05 Europe/Berlin
Agent: Pulse
Context: ONLINE ADMIN cron pass. The earlier online-admin bundle gate checked command policy rows, but Admin > Frames still needed explicit per-role allow/deny evidence so disabled controls and destructive-action prompts do not drift from backend authorization.
What changed: Extended `scripts/online-admin-contract-check.sh` to require `show_broadcast` policy coverage and a `roleActionMatrix`/`roleMatrix`/`permissions` section with one explicit decision per accepted actor role and remote command. Allowed risky commands must expose authorization, audit-id, and local-confirmation requirements; denied commands must include a reason.
What needs review: The hosted staging adapter should assemble this matrix from backend role/ownership/subscription authorization code, not from frontend constants.
Next recommended action: Wire Admin > Frames action buttons and confirmation copy from the same role matrix used by the bundle, then run the checker against staging before enabling real fleet actions.

## 2026-06-06 - AOS migration contract gate

Date/time: 2026-06-06 18:45 UTC / 2026-06-06 20:45 Europe/Berlin
Agent: Pulse
Context: API / DATABASE / SYNC cron pass. The schema gate proves final table shape, but backend migration work still needed a pre-apply check so risky or mis-namespaced migrations do not reach staging before the schema verifier runs.
What changed: Added `scripts/aos-migration-contract-check.sh`, accepting either a migrations directory or saved migration manifest. It checks deterministic ids, `aos_` table/index namespacing, transaction boundaries, required MVP table coverage, hashed pairing-code storage, secret-literal red flags, and destructive SQL opt-in.
What needs review: Wire this into backend migration CI before applying Frames migrations, then run `scripts/aos-schema-contract-check.sh` against the migrated database/export.
Next recommended action: Build the hosted migration manifest/export adapter from the main app migration tool and include backup/rollback notes for any migration that needs `AUTOPOIESIS_ALLOW_DESTRUCTIVE_MIGRATIONS=1`.

## 2026-06-06 - Broadcast command display contract

Date/time: 2026-06-06 18:25 UTC / 2026-06-06 20:25 Europe/Berlin
Agent: Pulse
Context: BROADCAST / FEED cron pass. Mixed-stream targeting had a gate, but command-delivered broadcasts still needed their own acceptance path because they arrive through heartbeat command polling and `current-broadcast.json`.
What changed: Hardened `show_broadcast` command handling so command broadcasts use defensive targeting and expiry checks, scheduled broadcasts wait until `startsAt`, `/launch` routes to any active stored broadcast, dismissed broadcasts stay inactive, and `broadcast_shown` is recorded only when `/broadcast` renders. Added `scripts/broadcast-command-check.sh` and wired it into Milestone 2.
What needs review: Physical Pi validation should confirm Chromium reaches `/broadcast` during a real admin broadcast and that heartbeat event ingestion projects `broadcast_shown` and `broadcast_dismissed` into durable `aos_broadcast_deliveries`.
Next recommended action: Add the same command-delivered broadcast cases to hosted backend/admin tests once the durable broadcast command rows are isolated in staging.

## 2026-06-06 - Release manifest safety gate

Date/time: 2026-06-06 18:00 UTC / 2026-06-06 20:00 Europe/Berlin
Agent: Pulse
Context: RELEASE / ROLLOUT cron pass. The device updater already preserved local runtime state and had rollback support, but malformed release metadata could still reach the mutation point before being rejected.
What changed: Added `scripts/release-manifest-check.sh` and wired it into `scripts/update-from-release.sh` before rollback metadata, artifact download, or git fallback. The gate validates version, optional channel/tag, HTTPS artifact URL, SHA-256 checksum, rollout percentage, release-note URL, optional rollback notes, and sensitive/local-only field redaction. It also accepts camelCase GitHub/backend aliases such as `artifactUrl` and `sha256`.
What needs review: The hosted release endpoint should start emitting channel, tag, checksum, changelog URL, rollout percentage, and rollback notes. Production devices can then set strict `AUTOPOIESIS_RELEASE_REQUIRE_*` flags before broad rollout.
Next recommended action: Cut a staged GitHub release fixture, run the strict manifest gate, then test artifact update plus rollback on the physical Pi.

## 2026-06-06 - Runtime storage diagnostics gate

Date/time: 2026-06-06 16:35 UTC / 2026-06-06 18:35 Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE cron pass. Installer/bootstrap creates the appliance data and log paths, and cache/support/heartbeat flows depend on those paths being writable by the runtime process, but diagnostics did not directly prove writable ownership before higher-level checks ran.
What changed: Added runtime storage diagnostics for `DATA_DIR`, `CACHE_DIR`, and `LOG_DIR`, including directory creation, read/write access, and short write probes. Health now emits `runtime_storage_unavailable`; readiness and support bundles include storage summaries; `scripts/runtime-storage-check.sh` is wired into Milestone 2 physical verification.
What needs review: Run the strict check on a physical Pi after fresh install and after update. If it fails, inspect ownership and mount state before investigating cache, heartbeat, or support-bundle symptoms.
Next recommended action: Add Admin > Frames display of the storage phase once support-bundle ingestion is rendered in the hosted UI.

## 2026-06-06 - Durable AOS schema contract gate

Date/time: 2026-06-06 16:15 UTC / 2026-06-06 18:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. Stream, online admin, event ingestion, command acknowledgement, targeting, and rollout gates now depend on the same durable `aos_` backend tables, but there was no direct schema acceptance gate to catch missing columns or idempotency keys before those higher-level checks ran.
What changed: Added `scripts/aos-schema-contract-check.sh`, accepting either a SQLite database file or saved schema JSON fixture. It validates the MVP Frames tables, required columns, and primary/unique keys for devices, pairing, settings, preferences, heartbeats, commands, admin audits, device events, likes, broadcasts, releases, subscriptions, deliveries, and rollouts. Added `docs/agent-notes/aos-schema-contract-issue.md` as the backend handoff note.
What needs review: Run the gate against a staging database or exported migration schema from the hosted app. The script allows current MVP `pairing_code` storage but warns that `pairing_code_hash` should replace it before production hardening.
Next recommended action: Add this gate to backend migration/CI before running hosted stream, online admin bundle, heartbeat event ingestion, broadcast delivery, or release rollout acceptance checks.

## 2026-06-06 - Online admin contract gate

Date/time: 2026-06-06 16:05 UTC / 2026-06-06 18:05 Europe/Berlin
Agent: Pulse
Context: ONLINE ADMIN cron pass. Profile > Frames and Admin > Frames now have several partial contracts, but the online surface needed one staging gate spanning owner devices, pairing, preferences, cache, subscription/admin data, fleet devices, and role-gated actions.
What changed: Added `scripts/online-admin-contract-check.sh`, a saved-response or live-URL validator for an `autopoiesis_frames_online_admin_bundle` assembled from Profile/Admin Frames endpoints. Documented the bundle in README, API contract, admin/profile docs, and database notes.
What needs review: Once the hosted app exposes the relevant endpoints or a staging-only adapter, run the checker against real auth/session data before enabling destructive remote actions.
Next recommended action: Implement the optional `GET /api/admin/frames/online-admin-bundle` staging adapter or generate the same fixture in CI from the individual Profile/Admin endpoints, then use this gate with backend auth tests.

## 2026-06-06 - Hosted stream contract verifier

Date/time: 2026-06-06 15:15 UTC / 2026-06-06 17:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. Device-side stream playback and targeting gates are now stable, but backend implementation still needed one sharp response validator before physical Pi testing.
What changed: Added `scripts/stream-contract-check.sh` to validate saved or live `GET /api/frames/device/{deviceId}/stream` responses for schema, timestamps, stream/settings shape, item identity/media/cache/priority/schedule/targeting fields, duplicate ids, and sensitive/local-only field redaction. Added `docs/agent-notes/backend-stream-contract-issue.md` as the GitHub-style backend issue note for implementing the durable `aos_` stream endpoint.
What needs review: Run the contract check against the hosted endpoint once backend `/stream` is implemented from durable `aos_` content, broadcast, preference, subscription, and device rows.
Next recommended action: Implement the hosted stream query, then run `scripts/stream-contract-check.sh`, `scripts/stream-playback-check.sh`, and `scripts/feed-targeting-check.sh` before physical paired-device validation.

## 2026-06-06 - System clock diagnostics gate

Date/time: 2026-06-06 14:38 UTC / 2026-06-06 16:38 Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE cron pass. A Pi with bad system time can break HTTPS, pairing/heartbeat cursors, feed expiry windows, and release checks while presenting as a generic network or sync failure.
What changed: Added timedatectl-backed clock diagnostics to local diagnostics, compact health, readiness, rollout acceptance, and support bundles. Added `scripts/clock-check.sh` and wired strict `AUTOPOIESIS_REQUIRE_CLOCK_SYNC=1` into Milestone 2 physical verification.
What needs review: Run the strict clock check on the target Pi after network onboarding; if it fails, capture `timedatectl status` and verify NTP reachability before debugging higher-level feed or release issues.
Next recommended action: Add Admin > Frames display of the clock phase once support-bundle/device snapshot ingestion is shown in the hosted UI.

## 2026-06-06 - Defensive feed targeting gate

Date/time: 2026-06-06 14:25 UTC / 2026-06-06 16:25 Europe/Berlin
Agent: Pulse
Context: BROADCAST / FEED cron pass. The local mixed stream already handled preferences, expiry, priority, cache eligibility, and playback, but normalized feed items only preserved targeting metadata; they did not defensively reject non-matching device/user/subscriber/tier/region targets if the hosted API ever returned them.
What changed: Added recognized targeting filters in `local-ui/server.js`, redacted targeting metadata from public `/local/feed`, and added `scripts/feed-targeting-check.sh`. The check runs an isolated local UI against a mock Frames API and proves targeted broadcasts/items enter playback, wrong-device/wrong-user/wrong-subscriber/excluded/expired/future items stay out, priority is preserved, cache eligibility stays scoped to displayable items, and delivery evidence is recorded.
What needs review: Backend stream targeting remains authoritative. The hosted `aos_` stream query should still avoid sending non-targeted content; the Pi guard is a last-mile safety net and regression check.
Next recommended action: Build the hosted `/api/frames/device/{deviceId}/stream` query from durable content, broadcast, preference, subscriber, and device rows, then run this gate plus stream playback validation on physical paired hardware after a real sync.

## 2026-06-06 - Stream playback gate hardening

Date/time: 2026-06-06 14:15 UTC / 2026-06-06 16:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The previous stream playback pass left a coherent but ambiguous dirty set around local stream preferences, dashboard/player behavior, likes, and the new acceptance gate.
What changed: Adopted that integration set as the active stream-player handoff and hardened `scripts/stream-playback-check.sh` to allocate per-run loopback ports by default. Environment overrides still work for debugging, but overlapping cron/local runs should no longer collide on fixed ports.
What needs review: The hosted backend still needs to serve the preferred `GET /api/frames/device/{deviceId}/stream` contract from durable `aos_` preference/content rows. The RPi gate now gives backend/API work a stable device-side target.
Next recommended action: After backend stream implementation, run `scripts/stream-playback-check.sh` and `AUTOPOIESIS_REQUIRE_FRAME_ITEMS=1 scripts/frame-state-check.sh` on physical paired hardware following a live feed/cache cycle.

## 2026-06-06 - Stream playback integration gate

Date/time: 2026-06-06 13:15 UTC / 2026-06-06 15:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The local frame stream surface now spans backend stream sync, local preferences, dashboard, `/frame`, likes, and delivery evidence, but that cross-system behavior had no single regression gate.
What changed: Added `scripts/stream-playback-check.sh` and wired it into Milestone 2 verification after the local frame route check. The script launches a temporary local UI with a mock Frames API, proves `/stream` is preferred before legacy `/feed`, validates artist/category filtering, checks dashboard/player timing fields, confirms local like persistence plus remote like forwarding, and verifies `feed_item_liked` delivery evidence.
What needs review: The checkout still contains pre-existing uncommitted stream/dashboard/player changes in `config/defaults.json`, `docs/api-contract.md`, and `local-ui/server.js`. This gate validates those changes in the current worktree, but a clean commit of only this pass is unsafe until that dirty work is either adopted or separated.
Next recommended action: Implement the hosted `GET /api/frames/device/{deviceId}/stream` contract against durable `aos_` preferences/content rows, then run this check and strict frame-state validation on physical Pi hardware after a real feed/cache cycle.

## 2026-06-06 - Admin device snapshot acceptance gate

Date/time: 2026-06-06 13:05 UTC / 2026-06-06 15:05 Europe/Berlin
Agent: Pulse
Context: ONLINE ADMIN cron pass. The Pi exposes support, health, readiness, admin capabilities, frame state, and event export contracts, but the hosted Profile > Frames/Admin > Frames surfaces still need one stable device-row shape instead of reconstructing status from many raw payloads.
What changed: Added `scripts/admin-device-snapshot-check.sh` and wired it into Milestone 2 verification. The check fetches `/local/support-bundle`, validates redaction, and derives an `autopoiesis_frame_admin_device_snapshot` with identity, health/readiness, pairing/key/remote flags, playback/cache counts, role-gated command policy, command/delivery/release evidence, and device event cursor state. Strict mode requires paired, stored-key, remote-enabled state for staged devices.
What needs review: When the hosted backend/API layer is ready for the next Admin/Profile pass, mirror this compact snapshot shape into durable `aos_` device detail rows or responses rather than duplicating local parsing logic in the frontend.
Next recommended action: Use this check during physical Pi validation after pairing; if strict mode fails, capture the generated snapshot plus `/local/admin/capabilities` and `/local/support-bundle`.

## 2026-06-06 - Network onboarding acceptance gate

Date/time: 2026-06-06 12:35 UTC / 2026-06-06 14:35 Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE cron pass. Milestone 2 printed raw `nmcli` state, but it did not prove the local `/local/network/status` contract that the touchscreen setup UI and support flow actually consume.
What changed: Added `scripts/network-check.sh` and wired it into Milestone 2 verification. The gate validates LAN/Wi-Fi shape, visible NetworkManager devices, primary connected-link consistency, optional strict online mode, and redaction of sensitive key material.
What needs review: On the physical Pi, run strict mode after LAN or Wi-Fi onboarding. If NetworkManager shows a connection but this script fails, inspect the local UI network parser before adjusting setup-page behavior.
Next recommended action: Use this network check in hardware reports alongside touchscreen and timer checks so setup failures can be separated from kiosk/feed/cache failures.

## 2026-06-06 - Event ingestion cursor acceptance gate

Date/time: 2026-06-06 12:15 UTC / 2026-06-06 14:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The backend event ingestion path now exists, and the Pi can persist acknowledgements, but physical acceptance still needed a dedicated guard for cursor replay and stale ack safety.
What changed: Added `scripts/events-ingestion-check.sh` and wired it into Milestone 2 verification. The check runs a temporary local UI against a mock Frames API, seeds command-audit, display-delivery, and release-history events, proves the first heartbeat exports all sources, persists a redacted accepted cursor, uses replay overlap on the next heartbeat, exposes the cursor in diagnostics/support, and rejects stale backend acks without moving the cursor backward.
What needs review: Run this on the physical Pi after backend deployment if Admin > Frames shows missing or repeated event evidence. A stale ack should leave `acceptedThroughObservedAt` unchanged and set `lastEventIngestionAckStatus=stale_event_ingestion_ack` for support visibility.
Next recommended action: Add Admin > Frames rendering for ingested `deviceEvents` and projected delivery/release state; use this check as the device-side regression gate before changing backend ack semantics.

## 2026-06-06 - Settings sync acceptance gate

Date/time: 2026-06-06 10:45 UTC / 2026-06-06 12:45 Europe/Berlin
Agent: Pulse
Context: API / DATABASE / SYNC cron pass. Device-side newest-`updatedAt` settings resolution existed, but backend and hardware validation still needed a direct contract test instead of relying on incidental diagnostics checks.
What changed: Added `scripts/settings-sync-check.sh`, which runs an isolated local UI against a mock Frames API and proves stale explicit sync rejection, newer remote apply, local push `updatedAt` propagation, stale heartbeat rejection, diagnostics conflict visibility, and the `settings_conflict` health issue. Wired it into Milestone 2 verification and documented the backend `aos_` timestamp requirement.
What needs review: Backend settings rows should now mirror this exactly: every settings GET/POST/heartbeat response needs an authoritative `updatedAt`, and stale writes should be rejected or surfaced as conflicts rather than silently winning.
Next recommended action: Add backend-side tests around `aos_` device/user settings writes using the same newest-wins cases, then expose explicit conflict status to Profile > Frames/Admin > Frames.

## 2026-06-06 - Appliance timer diagnostics

Date/time: 2026-06-06 10:35 UTC / 2026-06-06 12:35 Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE cron pass. The device had service diagnostics and a watchdog, but the maintenance loops that actually drive heartbeat, command execution, cache refresh, update checks, and watchdog recovery are timer units. A disabled timer could make local HTTP look healthy while the appliance stopped syncing.
What changed: Added systemd timer diagnostics to diagnostics/health/readiness/support surfaces, stable `timer_failed` and `timer_disabled` health issue codes, a readiness `timers` phase, and `scripts/systemd-timers-check.sh` wired into Milestone 2 physical Pi verification. Security smoke now asserts timer diagnostics stay redacted.
What needs review: Physical Pi validation should run the milestone script after update/install and confirm all five timers are active and enabled. If one fails, capture `systemctl list-timers 'autopoiesis-*'` plus the journal for the owned service before adjusting timer cadence or install wiring.
Next recommended action: Mirror timer health in Admin > Frames support detail from heartbeat diagnostics so remote support can see stalled maintenance loops without shell access.

## 2026-06-06 - Rollout acceptance contract

Date/time: 2026-06-06 10:15 UTC / 2026-06-06 12:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The Pi now exposes many correct local signals, but rollout/admin still needed one redacted pass/fail contract that explains whether a device is acceptable for setup, staged, or production use.
What changed: Added `GET /local/rollout/acceptance` and `scripts/rollout-acceptance-check.sh`. The contract derives checks from health, readiness phases, Admin capabilities, and unified event export, with stricter gates for staged/production profiles and optional strict content playback validation.
What needs review: Run the staged profile on physical paired hardware. If it blocks, use the reported check ids and summaries as the rollout issue note instead of manually stitching together health/readiness/admin outputs.
Next recommended action: Let Admin > Frames consume this endpoint or its backend-stored equivalent for rollout badges, promotion gating, and support handoff summaries.

## 2026-06-06 - Admin capabilities acceptance check

Date/time: 2026-06-06 10:05 UTC / 2026-06-06 12:05 Europe/Berlin
Agent: Pulse
Context: ONLINE ADMIN cron pass. Admin > Frames has a local capabilities endpoint for role-gated remote actions, but physical acceptance still needed a dedicated gate that proves the policy matrix is stable and redacted.
What changed: Added `scripts/admin-capabilities-check.sh` and wired it into Milestone 2 verification. The check validates accepted actor roles, command risk levels, authorization requirements, high/critical audit-id requirements, restart runtime opt-in state, factory-reset local-confirmation blocking, pending-command shape, and no device-key leakage. It also has `AUTOPOIESIS_REQUIRE_REMOTE_ADMIN_READY=1` for paired staged devices.
What needs review: Run the required mode on physical Pi hardware after live pairing. If it fails on paired/keyed state, capture `/local/admin/capabilities`, `/local/status`, and the latest heartbeat command response before changing Admin > Frames controls.
Next recommended action: Have Admin > Frames consume this capability contract for action-button disabled states, confirmation copy, and audit-required labels instead of duplicating command policy in frontend code.

## 2026-06-06 - Frame playback readiness signal

Date/time: 2026-06-06 09:15 UTC / 2026-06-06 11:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. Local frame playback existed, but rollout/support consumers still had to infer renderability from separate feed, cache, and frame-state counts.
What changed: Added a compact playback readiness summary to `/local/frame-state` and mirrored it into diagnostics, health, readiness, and support bundles as `framePlayback`. Added `scripts/frame-state-check.sh` with an optional `AUTOPOIESIS_REQUIRE_FRAME_ITEMS=1` hard gate, and wired the default contract validation into Milestone 2.
What needs review: Physical Pi validation should run the strict frame-state check after a real feed/cache cycle. If it reports `empty_queue` or `no_playable_items`, capture `/local/feed`, `/local/frame-state`, and cache worker output before tuning the backend feed contract.
Next recommended action: Feed Admin > Frames device detail from `framePlayback` so support can see whether a frame is blocked by pairing/network, feed sync, cache, or actual local playback.


## 2026-06-06 - Touchscreen input diagnostics

Date/time: 2026-06-06 08:35 UTC / 2026-06-06 10:35 Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE cron pass. The appliance had kiosk, network, health, readiness, and support-bundle checks, but the physical touchscreen assumption was invisible until a human touched the setup UI.
What changed: Added Linux input metadata diagnostics from `/proc/bus/input/devices`, with touchscreen/pointer/keyboard detection surfaced through diagnostics, health, readiness, and support bundles. Added `scripts/touchscreen-check.sh` and wired `AUTOPOIESIS_REQUIRE_TOUCHSCREEN=1` into Milestone 2 verification so staged Pi hardware fails if no touchscreen-class device is visible.
What needs review: Physical Pi validation should run the updated milestone script and confirm the target touchscreen HAT appears as `touchscreen_ready`. If the display works but the script reports `pointer_only`, add the device name/handler pattern to the detector rather than weakening the hard gate.
Next recommended action: Run the milestone check on the target Pi after update and collect `/proc/bus/input/devices` in the hardware report if input detection is ambiguous.

## 2026-06-06 - Local frame playback surface

Date/time: 2026-06-06 08:15 UTC / 2026-06-06 10:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The RPi could normalize mixed feeds, build a balanced `displayQueue`, and cache eligible media, but the kiosk path still depended on the hosted display unless the remote launch failed into `/offline`.
What changed: Added `/local/frame-state` as the browser-safe playback contract and `/frame` as a local kiosk surface. The frame state derives from `displayQueue`, prefers cached media URLs from `cache-index.json`, preserves display category/position, and supports image/video/audio/text items. `/launch?local=1` and `preferences.displayMode=local-feed` now route to this local surface while the default `/launch` path remains hosted-display first.
What needs review: Physical Pi validation should point Chromium at `/launch?local=1` after a real feed sync and cache pass, then confirm media rotation, video playback, text-only items, and touchscreen recovery work under the installed `frame` user.
Next recommended action: Decide whether local-first should become the default for staged devices once backend feed content is rich enough, or remain an explicit mode until the hosted display and local queue can be compared on hardware.


## 2026-06-06 - Heartbeat event ingestion cursor

Date/time: 2026-06-06 06:45 UTC / 2026-06-06 08:45 Europe/Berlin
Agent: Pulse
Context: API / DATABASE / SYNC cron pass. Device event export had idempotent keys and per-source cursors, but the Pi did not remember which event pointer the backend had accepted, so every heartbeat could only resend a newest bounded window without any acknowledgement contract.
What changed: Added redacted `event-cursor.json` persistence. Heartbeats now include the previous event ingestion cursor when available, replay from the accepted timestamp with a small overlap, accept compatible backend acknowledgement field names, and surface the cursor in diagnostics, event export, and support bundles. Factory reset clears the cursor as runtime/sync state.
What needs review: Backend heartbeat ingestion should persist events idempotently with `deviceId + eventKey`, then return `eventsAck` with `acceptedThroughObservedAt` and `acceptedThroughEventKey`. Keep the small replay overlap; duplicate rows are cheaper than missing same-second events.
Next recommended action: Add durable `aos_` event ingestion rows and acknowledgement metadata in the online Frames API, then confirm Admin > Frames can distinguish new, duplicated, and truncated device event submissions.

## 2026-06-06 - Factory reset state hygiene

Date/time: 2026-06-06 06:38 UTC / 2026-06-06 08:38 Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE cron pass. The appliance had accumulated local command, feed, cache, release, and support ledgers, but `factory-reset.sh` still only removed the original identity/preferences subset.
What changed: Reworked `factory-reset.sh` with dry-run/no-restart/support-history options. It now clears identity, pairing, preferences, network state, pending commands, broadcast/feed/cache/release state, rollback metadata, support-history JSON, and runtime cache directories, then bootstraps a fresh unpaired device and re-chowns runtime directories for the appliance user.
What needs review: Physical Pi validation should confirm the reset returns the touchscreen to setup with a new unpaired device id and that the restarted timers/services remain healthy.
Next recommended action: Run factory reset on a staged Pi after collecting a support bundle, then re-pair and run `scripts/milestone2-verify.sh`.

## 2026-06-06 - Mixed feed display queue

Date/time: 2026-06-06 06:25 UTC / 2026-06-06 08:25 Europe/Berlin
Agent: Pulse
Context: BROADCAST / FEED cron pass. The Pi could store and filter mixed feed items, but local display order was still a simple priority/recency list that could let one content class dominate.
What changed: Added a derived `displayQueue` to `/local/feed`. It preserves priority bands, then round-robins broadcast, curatorial, artwork, blog, news, and general content categories inside each band. Diagnostics and feed output now expose category counts and queue size; the cache manifest records display category/position.
What needs review: Backend feed generation should return real mixed content types and decide whether its own ranking metadata should influence category order. Kiosk/display playback should consume `displayQueue` when running local-first or offline-assisted modes.
Next recommended action: Implement the backend `/api/frames/device/{deviceId}/feed` mixed content query and map artwork/blog/news/curatorial/broadcast rows into the normalized local feed contract.

## 2026-06-06 - Event export source cursors

Date/time: 2026-06-06 06:15 UTC / 2026-06-06 08:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The unified event export gave backend ingestion one mixed event stream, but only one global cursor, which made per-source truncation ambiguous.
What changed: Added `sourceCursors` for command audit, display delivery, and release history, plus oldest/global `hasMore` cursor fields. Updated the event export check to validate cursor totals, exported counts, newest/oldest pointers, and per-source `hasMore`.
What needs review: Backend heartbeat ingestion should store per-source cursor metadata or at least alert when `hasMore` is true so support knows the heartbeat payload was truncated.
Next recommended action: Implement durable backend ingestion from heartbeat `events` into `aos_` command audit, broadcast delivery, and release rollout rows using `deviceId + eventKey` idempotency.

## 2026-06-06 - Local release rollback script

Context: RELEASE / ROLLOUT cron pass. The updater wrote rollback metadata but did not yet provide a repeatable operator path to actually restore the last known app code.
What changed: Added `scripts/rollback-release.sh` and made artifact updates snapshot the current app before replacement. Rollback restores app code only, preserves `/var/lib/autopoiesis-os`, reruns bootstrap/systemd wiring, restarts setup/kiosk services, and records metadata-only rollback events.
What needs review: Physical Pi validation should test this after a staged artifact update, including paired-device state and kiosk recovery.
Next recommended action: Add an authenticated admin rollback command only after backend command audit rows and role metadata are durable.

## 2026-06-06 - Event export acceptance gate

Date/time: 2026-06-06 05:15 UTC / 2026-06-06 07:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The unified device event export existed, but hardware validation and backend handoff still needed a simple proof that the local contract is usable and redacted.
What changed: Added `scripts/events-export-check.sh` and wired it into Milestone 2 verification. The check validates kind/schema, redaction, counts, allowed event sources, parseable timestamps, newest-first ordering, unique event keys, and cursor consistency.
What needs review: Run the updated Milestone 2 verification on physical Pi hardware after at least one command attempt, feed/broadcast display event, and release check so the script validates populated real-device history.
Next recommended action: Implement backend heartbeat event ingestion with `deviceId + eventKey` idempotency and map events into durable `aos_` command audit, delivery, and rollout rows.

## 2026-06-06 - Installer preflight and appliance user bootstrap

Date/time: 2026-06-06 04:35 UTC / 2026-06-06 06:35 Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE cron pass. The one-command install path still assumed the `frame` user already existed before the installer created owned runtime directories.
What changed: Added `scripts/ensure-appliance-user.sh`, added `scripts/preflight.sh --install`, called both from `install.sh`, and called the user helper from `scripts/bootstrap.sh` so update/bootstrap paths keep the same invariant.
What needs review: Validate on a clean Raspberry Pi OS image without a pre-created `frame` user. Confirm the created user has enough display/input access for the graphical kiosk session on that image.
Next recommended action: If clean-image validation passes, decide whether the installer should also install missing packages automatically or continue to fail/report prerequisites explicitly.

## 2026-06-05

Date/time: 2026-06-05 08:10 UTC
Agent: Pulse
Context: Ewoud supplied the Autopoiesis OS + Frames brief and asked for a major build system with extensive crons, admin/subscriber management, and clear project separation.
What changed: Created lead docs, project-management directory, database tag, and cron plan.
What needs review: Physical Raspberry Pi validation still needs the RPi-side agent or a configured hardware target.
Next recommended action: Build MVP 0.1 foundations in order: online profile, database, API, pairing, sync, kiosk, heartbeat.

## 2026-06-05 - MVP 0.1 backend start

Date/time: 2026-06-05 09:25 UTC
Agent: Pulse
Context: Ewoud asked to continue to the next phase after cron setup.
What changed: Added initial Flask/SQLite Frames API foundation in the main Autopoiesis backend using aos_ tables.
What needs review: Auth/subscriber enforcement is still scaffold-level; endpoints currently accept explicit userId for MVP integration testing.
Next recommended action: Build Profile > Frames UI and admin UI on top of these APIs, then wire the RPi local UI to the register/pair/settings/heartbeat endpoints.

## 2026-06-05 - RPi API wiring

Date/time: 2026-06-05 09:20 UTC
Agent: Pulse
Context: Next phase after backend MVP start.
What changed: Wired the RPi local UI and scripts to the Frames API for registration, pairing status, settings sync, heartbeat, and command storage. Local fallback pairing remains for offline setup.
What needs review: Run against the deployed autopoiesis.art backend once the Frames API is deployed, then validate on physical Raspberry Pi hardware.
Next recommended action: Build Profile > Frames UI so users can claim the server pairing code.

## 2026-06-05 - Diagnostics integration

Date/time: 2026-06-05 20:15 UTC
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The main blocker remains physical Raspberry Pi validation, and the admin/API/QA workstreams need one shared device health shape.
What changed: Added a local diagnostics endpoint and included the same diagnostics object in heartbeat payloads.
What needs review: Validate the values on real Pi hardware, especially temperature, disk, service states, and whether the cached NetworkManager state is fresh enough during setup.
Next recommended action: Persist and display latest heartbeat diagnostics in Admin > Frames so remote support has a single fleet health view.

## 2026-06-05 - Diagnostics health summary

Date/time: 2026-06-05 21:15 UTC
Agent: Pulse
Context: LEAD / INTEGRATION cron pass after kiosk offline fallback. Diagnostics existed, but admin/support consumers still had to infer condition from raw measurements.
What changed: Added a derived `diagnostics.health` object with `ok`/`warning`/`error` status and stable issue codes for pairing, device API key, network/offline fallback, storage, memory, temperature, release state, pending commands, and failed local services.
What needs review: Confirm thresholds on physical Raspberry Pi hardware, especially storage, temperature, and whether unpaired/network-offline warnings are right for setup flows.
Next recommended action: Surface latest heartbeat `diagnostics.health` in Admin > Frames fleet/detail views and include it in RPi hardware validation reports.

## 2026-06-05 - QA/security smoke gate

Date/time: 2026-06-05 21:50 UTC
Agent: Pulse
Context: QA / SECURITY cron pass. Device API keys are now stored locally, so the Pi repo needs a repeatable acceptance gate proving support endpoints expose only safe redacted state.
What changed: Added `scripts/security-smoke.sh` to launch the local UI against temporary keyed device state and verify `/local/status`, `/local/pairing/status`, and `/local/diagnostics` do not leak key values or key field names. The script also checks tracked files for sensitive-looking paths.
What needs review: Run the smoke test on real Raspberry Pi hardware after installation, alongside the normal milestone verification.
Next recommended action: Fold this gate into the final production-image checklist once physical Pi validation starts.

## 2026-06-06 - Online admin diagnostics health readout

Date/time: 2026-06-05 22:05 UTC / 2026-06-06 00:05 Europe/Berlin
Agent: Pulse
Context: ONLINE ADMIN cron pass. The Pi now sends `diagnostics.health` in heartbeat payloads, but Admin > Frames still exposed only the device summary fields and buried heartbeat payloads.
What changed: Updated `/data/.openclaw/workspace/autopoiesis/app/frontend/src/pages/AdminFrames.jsx` so selected device detail surfaces the newest heartbeat diagnostics health status, issue codes, and diagnostics timestamp.
What needs review: The main `autopoiesis` checkout has a large unrelated dirty backlog, so this UI source change is intentionally left uncommitted there. Review/stage only `app/frontend/src/pages/AdminFrames.jsx` when the main repo is ready for a scoped commit.
Next recommended action: Add latest-health summaries to the admin fleet list API and device cards once backend ownership/auth shape stabilizes.

## 2026-06-06 - Compact local health probe

Date/time: 2026-06-05 22:15 UTC / 2026-06-06 00:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. Diagnostics health now exists and admin detail can display it, but acceptance scripts and fleet adapters needed a smaller stable probe than the full diagnostics payload.
What changed: Added `GET /local/health`, optional service-aware derivation with `?services=1`, and `scripts/health-check.sh`. Milestone 2 verification now calls the health script, and the security smoke test covers key redaction on the new endpoint.
What needs review: Run `health-check.sh` on a physical Raspberry Pi after install to confirm warning/error thresholds match real hardware behavior.
Next recommended action: Mirror this compact shape into the online admin fleet list so device cards can show latest status without opening heartbeat detail.

## 2026-06-06 - Local feed and broadcast display foundation

Date/time: 2026-06-05 22:25 UTC / 2026-06-06 00:25 Europe/Berlin
Agent: Pulse
Context: BROADCAST / FEED cron pass. The Pi could receive `show_broadcast` commands, but it stored only raw current-broadcast JSON and had no local mixed-feed contract for artwork/news/blog/curatorial/broadcast items.
What changed: Added normalized local feed state, `/local/feed`, `/local/feed/sync`, heartbeat feed ingestion, eligibility filtering, cache-manifest metadata, and a real local `/broadcast` display route for active broadcast commands.
What needs review: Physical frame behavior still needs Pi validation for display timing, touchscreen dismissal expectations, and whether high-priority broadcasts should interrupt an already loaded remote Frames web app without a launch cycle.
Next recommended action: Implement the backend `/api/frames/device/{deviceId}/feed` content query across artwork, blog, news, curatorial notes, and broadcasts; then connect `scripts/cache-artworks.sh` to the local feed cache manifest.

## 2026-06-06 - Local cache worker foundation

Date/time: 2026-06-05 22:35 UTC / 2026-06-06 00:35 Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE cron pass. The local feed path writes a cache eligibility manifest, but the hourly cache service still only logged a placeholder.
What changed: Replaced `scripts/cache-artworks.sh` with a conservative downloader that reads `feed-cache.json`, stores media and thumbnails under the runtime cache directory, and writes `cache-index.json` with per-asset cached/failed status.
What needs review: Real Pi validation should confirm cache directory ownership under the installed `frame` user and storage pressure behavior on the target SD card.
Next recommended action: Teach `/offline` to read `cache-index.json` and show cached artwork when available, falling back to the current static offline screen only when the cache is empty.

## 2026-06-06 - Settings sync conflict handling

Date/time: 2026-06-05 22:45 UTC / 2026-06-06 00:45 Europe/Berlin
Agent: Pulse
Context: API / DATABASE / SYNC cron pass. Device settings sync existed, but explicit sync and heartbeat responses would blindly merge remote settings over local preferences.
What changed: Added local/remote `updatedAt` tracking, stamped local settings saves, routed sync/push/heartbeat settings through one resolver, rejected stale remote settings, and exposed conflicts through diagnostics `settingsSync` plus health issue code `settings_conflict`.
What needs review: The online Frames backend should return authoritative `updatedAt` values for every settings GET/POST response and should eventually report conflicts explicitly instead of relying only on device-side rejection.
Next recommended action: Mirror latest-`updatedAt` conflict handling in the backend aos settings rows and admin/profile API responses.

## 2026-06-06 - Local rollout readiness contract

Date/time: 2026-06-05 23:15 UTC / 2026-06-06 01:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. Health and diagnostics were available, but rollout still needed one cross-system readiness answer that QA, Pi validation, and admin adapters could consume.
What changed: Added `GET /local/readiness`, derived from diagnostics, with phase summaries for local UI, network, pairing/device key, settings sync, content/feed, cache, commands, and release state. Diagnostics now also includes cache index counts and cache-related health issue codes.
What needs review: Run the readiness check on physical Raspberry Pi hardware after live pairing and after a real feed/cache cycle to confirm the blocker thresholds match deployment reality.
Next recommended action: Use readiness blockers as the acceptance checklist for the first managed rollout, then mirror the same phase summaries into Admin > Frames fleet cards.

## 2026-06-06 - Offline cache playback

Date/time: 2026-06-06 00:15 UTC / 2026-06-06 02:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The feed cache worker could download local media, but the kiosk offline fallback still showed only a static status page.
What changed: Added a redacted `/local/offline-cache` inventory, safe `/local/cache/assets/{itemId}/{media|thumbnail}` serving from within the cache directory, and a `/offline` cached-media rotation view when playable cached assets exist.
What needs review: Validate on physical Raspberry Pi hardware after a real feed/cache cycle, including Chromium playback for cached video and touchscreen timing during network recovery.
Next recommended action: Add cache eviction and storage-pressure policy once the real content feed size is known.

## 2026-06-06 - Kiosk launch verification

Date/time: 2026-06-06 00:35 UTC / 2026-06-06 02:35 Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE cron pass. The Pi 3 software-rendering fix existed, but hardware validation still needed a repeatable way to prove the launcher and running Chromium process actually use those flags.
What changed: Added kiosk launcher dry-run support, `scripts/kiosk-check.sh`, and wired the check into Milestone 2 verification with process flag enforcement.
What needs review: Run the updated `milestone2-verify.sh` on physical Pi hardware after install/update and kiosk restart.
Next recommended action: If the kiosk still blanks with these flags, capture `journalctl -u autopoiesis-kiosk.service -n 200 --no-pager` plus `scripts/kiosk-check.sh` output and tune `AUTOPOIESIS_CHROMIUM_FLAGS` per hardware revision.

## 2026-06-07 - Setup launcher custom path hardening

Date/time: 2026-06-07 06:35 UTC / 2026-06-07 08:35 Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE cron pass. The installer and systemd renderer already supported custom appliance paths, but `scripts/start-setup.sh` still changed into the default `/opt/autopoiesis-os/app/local-ui`, which could break customized installs after the service unit rendered correctly.
What changed: `start-setup.sh` now uses `AUTOPOIESIS_APP_DIR` when systemd provides it, otherwise derives the app root from its installed script path. Added `scripts/setup-launcher-check.sh` to prove custom-root, script-relative default-root, and missing-server failure behavior without starting the local UI.
What needs review: Physical Pi validation should compare `systemctl cat autopoiesis-setup.service` with the setup launcher dry run after default and custom-root installs.
Next recommended action: Run full Milestone 2 on hardware after install/update and keep custom-root validation paired with `scripts/systemd-units-install-check.sh`.

## 2026-06-06 - Remote action authorization guard

Date/time: 2026-06-06 01:05 UTC / 2026-06-06 03:05 Europe/Berlin
Agent: Pulse
Context: ONLINE ADMIN cron pass. Admin > Frames can queue remote actions, but the Pi executor needed a shared command policy so role-gated online actions are not just a UI convention.
What changed: Added device-side command risk policy and authorization metadata validation for medium/high/critical remote commands. Updated the API and admin docs with the expected online admin authorization/audit shape.
What needs review: Update the online Frames backend command queueing path to create `authorization` metadata from real authenticated roles and audit rows before sending non-`sync_settings` commands.
Next recommended action: Add admin command audit persistence in the `aos_` backend tables, then surface denied-command errors in Admin > Frames.

## 2026-06-06 - Local command audit trail

Date/time: 2026-06-06 01:15 UTC / 2026-06-06 03:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The Pi now refuses unsafe remote commands without authorization metadata, but support/admin still needed local evidence of what each device actually attempted.
What changed: Added bounded metadata-only `command-audit.json` persistence, redacted `GET /local/commands/audit`, and compact command audit summaries inside diagnostics, health, and readiness.
What needs review: Confirm on physical Pi hardware that the command executor timer writes the audit trail under the installed `frame` user and that support workflows can collect it without exposing payload data.
Next recommended action: Add backend `aos_` admin command audit rows and queue real authorization metadata from authenticated roles before non-`sync_settings` commands.

## 2026-06-06 - Redacted local support bundle

Date/time: 2026-06-06 02:15 UTC / 2026-06-06 04:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. Health, readiness, offline-cache, and command audit endpoints existed separately, but physical Pi validation and future admin support adapters still needed a one-step evidence bundle.
What changed: Added `GET /local/support-bundle` and `scripts/support-bundle.sh`. The bundle reuses the existing redacted diagnostics, health, readiness, feed, offline-cache, and command-audit shapes and adds a compact summary of health status, readiness status, issue codes, blockers, pending commands, offline playable items, and recent command audit state.
What needs review: Run `scripts/support-bundle.sh` on physical Pi hardware after live pairing, real feed sync, cache worker execution, and at least one remote command attempt to confirm the collected evidence is enough for rollout decisions.
Next recommended action: Let Admin > Frames consume the same support-bundle shape or a backend-stored subset for downloadable fleet support reports.

## 2026-06-06 - Device delivery log foundation

Date/time: 2026-06-06 02:25 UTC / 2026-06-06 04:25 Europe/Berlin
Agent: Pulse
Context: BROADCAST / FEED cron pass. The Pi could show broadcasts and sync feed state, but support/admin only saw command completion, not whether the device actually reached display lifecycle events.
What changed: Added bounded local `delivery-log.json` persistence plus redacted `GET /local/delivery-log`. Feed sync writes `feed_synced`; broadcast lifecycle writes `broadcast_shown`, `broadcast_dismissed`, and one-time `broadcast_expired`. Diagnostics, health, and support bundle now include compact display-delivery summaries.
What needs review: Backend/admin still needs durable `aos_` delivery rows and should decide whether heartbeat diagnostics, a future delivery-log POST, or support-bundle ingestion is the canonical persistence path.
Next recommended action: Add backend delivery persistence and Admin > Frames delivery-state UI using these event names as the device-side source contract.

## 2026-06-07 - Online admin device action availability

Date/time: 2026-06-07 01:05 UTC / 2026-06-07 03:05 Europe/Berlin
Agent: Pulse
Context: ONLINE ADMIN cron pass. The hosted online-admin bundle already validated the global role/action matrix, but Profile > Frames and Admin > Frames still needed target-specific action decisions so UI buttons do not infer availability from broad role policy alone.
What changed: Tightened `scripts/online-admin-contract-check.sh` so every profile-owned and admin fleet device row must expose `actionAvailability` for each supported command. Allowed risky actions must mirror authorization, audit-id, and local-confirmation requirements; denied actions must include a disabled reason. Added a backend handoff note for generating this from durable device, subscription, command, and authorization state.
What needs review: The hosted backend should decide whether profile rows evaluate availability as the owner role and admin rows as the current admin actor role, then keep reason codes stable enough for UI disabled states.
Next recommended action: Generate a staging online-admin bundle with per-device action availability and use it to drive Profile/Admin remote-action controls before enabling destructive fleet actions.

## 2026-06-06 - Appliance watchdog timer

Date/time: 2026-06-06 02:35 UTC / 2026-06-06 04:35 Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE cron pass. The repo had an `autopoiesis-watchdog.service`, but it only restarted the kiosk and was not enabled by the installer, so it was not a real production self-healing path.
What changed: Added `scripts/watchdog.sh`, converted the watchdog service to run it, added `autopoiesis-watchdog.timer`, and folded the watchdog into Milestone 2 verification. Added `scripts/install-systemd-units.sh` so fresh installs and update paths copy changed units into `/etc/systemd/system`, enable newly added timers, and start timers immediately. The watchdog script restarts setup only when local HTTP routes are unreachable and restarts kiosk only when `kiosk-check.sh` says the process or launch flags are unhealthy.
What needs review: Physical Pi validation should confirm the timer runs as root, can restart both services, and does not interrupt a healthy display session.
Next recommended action: Run full `scripts/milestone2-verify.sh` on the target Pi after update, then inspect `journalctl -u autopoiesis-watchdog.service -n 120 --no-pager` for clean pass entries.

## 2026-06-06 - Command acknowledgement retry safety

Date/time: 2026-06-06 02:45 UTC / 2026-06-06 04:45 Europe/Berlin
Agent: Pulse
Context: API / DATABASE / SYNC cron pass. The command executor had durable local command storage, but a failed acknowledgement back to the Frames API could still cause the local queue to be cleared too early.
What changed: Added local-only ack retry metadata. Initial acknowledgement failures retain the command without executing it; final acknowledgement failures retain only the final ack state and do not re-run the command on the next executor pass.
What needs review: The online backend should make command ack transitions idempotent and store last ack failure/last ack timestamp in durable `aos_` command rows.
Next recommended action: Add backend/admin command audit persistence and ensure duplicate final `completed`/`error` acknowledgements are harmless.

## 2026-06-06 - Local release history contract

Date/time: 2026-06-06 03:15 UTC / 2026-06-06 05:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The Pi had release check/apply endpoints and release-state, but rollout/admin still lacked a bounded device-side history of what happened during update checks and applies.
What changed: Added metadata-only release history persistence, `GET /local/release/history`, diagnostics/readiness/health/support-bundle summaries, support-bundle CLI release summary, and security-smoke redaction coverage.
What needs review: Backend/admin should ingest these event names into durable `aos_` rollout rows and treat repeated device reports as idempotent.
Next recommended action: Build Admin > Frames rollout progress from heartbeat diagnostics/support-bundle ingestion rather than raw Pi logs.

## 2026-06-06 - Local admin capabilities contract

Date/time: 2026-06-06 04:05 UTC / 2026-06-06 06:05 Europe/Berlin
Agent: Pulse
Context: ONLINE ADMIN cron pass. Admin > Frames needs to render remote action controls from the device policy instead of hardcoding which commands are safe, audited, locally gated, or runtime-gated.
What changed: Added redacted `GET /local/admin/capabilities`, included the same object in support bundles, and extended the security smoke test to cover command policy shape and key redaction.
What needs review: Physical Pi validation should confirm support operators can collect the capability object from a paired frame and that Admin > Frames maps these policies to disabled/confirm/audit-required UI states.
Next recommended action: Build backend `aos_` admin action audit rows and have Admin > Frames read the capability contract before enabling non-`sync_settings` remote actions.

## 2026-06-06 - Unified device event export

Date/time: 2026-06-06 04:15 UTC / 2026-06-06 06:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The Pi had separate local command audit, display delivery, and release history endpoints, but backend/admin ingestion still needed one redacted event shape instead of three endpoint-specific adapters.
What changed: Added `GET /local/events/export`, included the same bounded export in heartbeat payloads under `events`, and added `deviceEvents` to support bundles. Events carry `source`, stable `eventKey`, and `observedAt` so the backend can persist durable `aos_` rows idempotently.
What needs review: Backend ingestion must decide the final table mapping, but should treat `deviceId + eventKey` as the idempotency key and ignore repeated heartbeat reports.
Next recommended action: Add backend heartbeat event ingestion for command audit, broadcast delivery, and release rollout progress, then surface those durable rows in Admin > Frames.

## 2026-06-06 - Backend admin command authorization audit

Date/time: 2026-06-06 07:05 UTC / 2026-06-06 09:05 Europe/Berlin
Agent: Pulse
Context: ONLINE ADMIN cron pass. The Pi now enforces remote command authorization metadata, but the online backend still queued admin, broadcast, and release commands without the authorization object the device requires.
What changed: Updated the main gallery backend Frames API to create `aos_admin_command_audits` rows before queueing authorized remote commands. Direct device commands, broadcast display commands, and release update commands now carry `payload.authorization` with approved actor/action/role/timestamp/audit metadata; command acknowledgements update the durable audit status. Admin device detail now returns recent command audit rows.
What needs review: The main `autopoiesis` checkout is still too dirty for a clean scoped commit from this run, so the backend change is verified but uncommitted there. Review/stage only `app/backend/production.py` once that repo's unrelated backlog is under control.
Next recommended action: Add backend heartbeat `events` ingestion into durable delivery/release/device-event rows using `deviceId + eventKey` idempotency, then wire Admin > Frames to render those rows.

## 2026-06-06 - Frame item delivery acknowledgement

Date/time: 2026-06-06 10:27 UTC / 2026-06-06 12:27 Europe/Berlin
Agent: Pulse
Context: BROADCAST / FEED cron pass. The local delivery log had feed sync and broadcast lifecycle evidence, but regular personalized stream items could rotate through `/frame` without a device-side display event.
What changed: Added `POST /local/frame/display` and wired `/frame` to call it whenever an item renders. The endpoint validates the id against the current playable `/local/frame-state` queue, appends a metadata-only `feed_item_shown` delivery event, and updates local state with current feed/artwork pointers.
What needs review: Physical Pi validation should confirm Chromium posts the acknowledgement during real playback and that repeated rotation produces a useful but bounded delivery trail.
Next recommended action: Teach backend `aos_` delivery ingestion/Admin > Frames to treat `feed_item_shown` as the non-broadcast equivalent of `broadcast_shown`.

## 2026-06-06 - Backend heartbeat event ingestion

Date/time: 2026-06-06 07:15 UTC / 2026-06-06 09:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The Pi already exported a redacted unified event stream and persisted backend acknowledgements, but the online Frames API still needed to accept those events and return the cursor ack.
What changed: Added backend `aos_device_events` ingestion in the main gallery Frames API, keyed by `device_id + event_key`. Heartbeats now return `eventsAck`; command audit, broadcast delivery, and release history events project into existing durable admin/delivery/rollout rows; Admin device detail returns recent `deviceEvents`.
What needs review: The backend code lives in the dirty main `autopoiesis` repo and remains uncommitted there. Review/stage `app/backend/production.py` only after separating it from the repo's unrelated backlog.
Next recommended action: Add Admin > Frames UI rendering for `deviceEvents` and projected rollout/delivery state, then deploy the backend patch when the main checkout is commit-safe.

## 2026-06-06 - Rollout issue report handoff

Date/time: 2026-06-06 11:15 UTC / 2026-06-06 13:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. Rollout acceptance and support bundles were available, but blocked physical Pi validation still needed a precise issue-note format instead of manually stitching endpoint output together.
What changed: Added `scripts/rollout-issue-report.sh` to collect redacted rollout acceptance plus support-bundle evidence and emit a GitHub-style Markdown report with blockers, warnings, support evidence, and reproduction commands.
What needs review: Run the script on the physical Pi after live pairing/feed/cache cycles; confirm the report gives enough context for a GitHub issue without leaking device keys or local paths.
Next recommended action: Use the report whenever staged or production rollout acceptance blocks, then attach the support bundle and hardware-specific evidence if the failure is physical-device-specific.

## 2026-06-06 - Command acknowledgement retry gate

Date/time: 2026-06-06 14:49 UTC / 2026-06-06 16:49 Europe/Berlin
Agent: Pulse
Context: API / DATABASE / SYNC cron pass. Device command retry behavior was documented, but Milestone 2 did not yet prove the acknowledgement edge cases that backend `aos_` command rows must tolerate.
What changed: Added `scripts/command-ack-retry-check.sh`, wired it into Milestone 2, and tightened final-ack audit status so successful local execution with a failed `completed` acknowledgement is immediately visible as `ack_failed`.
What needs review: Backend command acknowledgement handlers should be idempotent for repeated final `completed`/`error` statuses and should expose last ack failure/timestamp in Admin > Frames.
Next recommended action: Add the same command ack retry cases to hosted backend tests once durable command rows are isolated from the dirty main gallery checkout.

## 2026-06-07 - Hosted release rollout contract gate

Date/time: 2026-06-07 01:15 UTC / 2026-06-07 03:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. Release manifests and local rollout acceptance were covered, but hosted Admin > Frames still needed one durable evidence gate tying release rows, per-device rollout rows, update commands, admin audits, and heartbeat-ingested release history together.
What changed: Added `scripts/release-rollout-contract-check.sh` and wired `release-rollout` into `scripts/hosted-contract-suite-check.sh` after the release manifest gate. Added backend handoff docs for a read-only release-rollout contract bundle.
What needs review: Hosted staging should generate this bundle from `aos_software_releases`, `aos_release_rollouts`, `aos_device_commands`, `aos_admin_command_audits`, and `aos_device_events` projections.
Next recommended action: Run the strict hosted suite with both release manifest and release-rollout sources before enabling broad Admin > Frames update controls.


## 2026-06-06 - Hosted pairing contract gate

Date/time: 2026-06-06 17:15 UTC / 2026-06-06 19:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. Pairing sits early in the profile/database/API chain, but the hosted register/claim/status lifecycle did not yet have an executable contract gate.
What changed: Added `scripts/pairing-contract-check.sh` plus backend handoff docs for a read-only pairing contract bundle. The gate validates registration, user claim, final pairing status, bounded code TTL, durable device key handoff, owner/device consistency, settings handoff shape, and redaction boundaries.
What needs review: The online backend should assemble a staging/CI bundle from durable `aos_frame_devices` and `aos_frame_pairing_codes` rows without running a destructive live claim.
Next recommended action: Run the pairing contract checker against staging before treating physical Pi account pairing as rollout-ready.

## 2026-06-07 - Mixed-stream broadcast display evidence

Date/time: 2026-06-06 22:25 UTC / 2026-06-07 00:25 Europe/Berlin
Agent: Pulse
Context: BROADCAST / FEED cron pass. Command-delivered broadcasts produced `broadcast_shown` only when `/broadcast` rendered, but broadcast-category items inside the personalized mixed `/frame` queue were still logged as generic `feed_item_shown` events.
What changed: `POST /local/frame/display` now emits `broadcast_shown` for broadcast-category frame items while preserving `feed_item_shown` for artwork, blog, news, curatorial, and other non-broadcast stream content. The feed targeting gate now proves the delivery log and unified event export expose this mixed-stream broadcast evidence with broadcast source metadata.
What needs review: Hosted heartbeat event ingestion should map both command and mixed-stream `broadcast_shown` events into durable `aos_broadcast_deliveries` rows without treating repeated frame rotations as separate rollout failures.
Next recommended action: Surface mixed-stream broadcast delivery rows in Admin > Frames alongside command-delivered broadcast rows, keyed idempotently by `deviceId + eventKey`.

## 2026-06-06 - Systemd unit rendering gate

Date/time: 2026-06-06 18:39 UTC / 2026-06-06 20:39 Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE cron pass. The installer exposed configurable install/data/log/user paths, but the checked-in service units still hard-coded the default `/opt/autopoiesis-os`, `/var/lib/autopoiesis-os`, `/var/log/autopoiesis-os`, `/home/frame`, and `frame` user layout.
What changed: `scripts/install-systemd-units.sh` now renders service units into the systemd target from the configured paths and appliance user. Service units carry explicit runtime environment for data/log/cache/app paths, `install.sh` passes its selected values into the renderer, and `scripts/systemd-units-install-check.sh` proves the render path with a fake systemd directory and custom user/paths.
What needs review: Physical Pi install/update should confirm the default rendered units still start healthy services and that `/etc/systemd/system/autopoiesis-*.service` contains the expected production paths.
Next recommended action: Run full Milestone 2 after `sudo ./install.sh` or `sudo ./update.sh` on hardware, then inspect `systemctl cat autopoiesis-setup.service autopoiesis-kiosk.service`.

## 2026-06-07 - Active-window stream contract hardening

Date/time: 2026-06-07 06:25 UTC / 2026-06-07 08:25 Europe/Berlin
Agent: Pulse
Context: BROADCAST / FEED cron pass. The Pi defensively filters expired/future feed items, but the hosted `/stream` contract still allowed stale or premature rows to pass acceptance as long as their timestamps parsed.
What changed: Tightened `scripts/stream-contract-check.sh` so every stream item must be individually displayable, map into the known mixed-content categories, and be active relative to root `generatedAt`. It now rejects future `startsAt`, expired `expiresAt`, inverted schedule windows, unsupported type strings, and id/type-only rows.
What needs review: Hosted staging should run this gate against the real durable `aos_` stream query before physical Pi validation, because the Pi guard is a fallback rather than the primary targeting/scheduling layer.
Next recommended action: Generate a live `/api/frames/device/{deviceId}/stream` fixture with artwork, blog/news/curatorial, and broadcast rows, then run `AUTOPOIESIS_REQUIRE_STREAM_POLLING=1 scripts/stream-contract-check.sh` before cache/feed playback gates.

## 2026-06-07 - Online admin profile coherence

Date/time: 2026-06-07 07:05 UTC / 2026-06-07 09:05 Europe/Berlin
Agent: Pulse
Context: ONLINE ADMIN cron pass. The online-admin bundle validated the broad Profile/Admin shape, but Profile > Frames could still pass with contradictory cache settings, duplicate active artists, duplicate liked artworks, or active artist selections that did not match preference state.
What changed: Tightened `scripts/online-admin-contract-check.sh` so profile cache preferences must agree with mirrored cache fields in `preferences`, active artist ids are unique and coherent with `preferences.activeArtists`, liked artwork ids are unique in flat and paged forms, and paged liked-artwork totals cover returned rows. Added `docs/agent-notes/backend-online-admin-profile-coherence-issue.md` as the hosted backend handoff.
What needs review: Hosted staging should assemble Profile > Frames from one canonical preference/cache/artist/like projection instead of stitching independent endpoint responses that can drift.
Next recommended action: Run the strict hosted suite with a real online-admin bundle before enabling cache controls, active artist toggles, or liked artwork pagination in staging.

## 2026-06-07 - Hosted suite planning mode

Date/time: 2026-06-07 07:15 UTC / 2026-06-07 09:15 Europe/Berlin
Agent: Pulse
Context: LEAD / INTEGRATION cron pass. The hosted suite had strict execution and a JSON readiness report, but staging still lacked a cheap way to inspect the exact manifest/env gate matrix before running every downstream checker.
What changed: Added `--plan` / `--dry-run` to `scripts/hosted-contract-suite-check.sh`. Plan mode validates manifest and required-gate configuration, fails missing required sources, records source-present gates as `planned`, and writes the same redacted report shape with `mode: "plan"`. Required-gate names from `AUTOPOIESIS_HOSTED_CONTRACT_REQUIRE` are now typo-checked before any checker executes.
What needs review: Hosted CI should run plan mode against the generated manifest, archive the report, then run the full strict suite using the same manifest so rollout annotations and actual gate execution cannot drift silently.
Next recommended action: Add a hosted CI step that publishes both the plan report and the full run report before physical Pi validation.
