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
