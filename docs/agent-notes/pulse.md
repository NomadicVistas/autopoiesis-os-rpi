# Pulse Agent Notes

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
