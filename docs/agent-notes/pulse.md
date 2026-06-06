# Pulse Agent Notes

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
