# Raspberry Pi Agent Notes

## 2026-06-05

Date/time: 2026-06-05 08:10 UTC
Agent: Pulse
Context: The RPi agent should focus on physical hardware validation and Pi-specific hardening.
What changed: Pulse created docs and cron workstreams; Milestone 2 includes LAN support and a physical verification script.
What needs review: Run scripts/milestone2-verify.sh on the physical Pi after install.
Next recommended action: Test boot, touchscreen setup, LAN/Wi-Fi, kiosk launch, service restart, one-command install path, and local cache behavior.

## 2026-06-05 - Offline launch fallback check

Date/time: 2026-06-05 20:35 UTC
Agent: Pulse
Context: RPI APPLIANCE cron pass. Paired frames previously launched directly to the remote Frames URL, which could leave Chromium on a browser network error when LAN/Wi-Fi dropped.
What changed: `/launch` now probes the configured Frames URL, redirects to local `/offline` when unreachable, records offline/frame mode in state, and lets the offline page retry launch automatically.
What needs review: On physical Pi, pair the frame, launch kiosk, disconnect network, confirm `/offline` appears instead of Chromium's network error, reconnect network, and confirm the automatic retry reaches the remote Frames app.
Next recommended action: Add cached artwork rendering behind `/offline` once the feed/cache contract is stable.
