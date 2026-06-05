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
