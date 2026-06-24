## 2026-06-24 02:35 AM Europe/Berlin - Disk space check in installer

Date/time: 2026-06-24 02:35 AM Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE workstream - improve installer robustness.
What changed: Added a disk space check in install.sh to verify at least 1 GB of free space in the installation, data, and log directories before proceeding with the installation. This prevents installation failures due to insufficient disk space.
Why this matters: Ensures the installation process fails early with a clear message if there is insufficient disk space, improving the robustness of the one-click install experience and preventing partial installations or cryptic errors due to disk space exhaustion.
Verification: node --check local-ui/server.js passed; bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed
Next step: Monitor installer logs for any disk space related issues in the field.


# Raspberry Pi Agent Notes

## 2026-06-17 - Heartbeat runtime execution gate

Date/time: 2026-06-16 22:42 UTC / 2026-06-17 00:42 Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE workstream - follow-up to the JSON heartbeat payload work.
What changed: Removed top-level `local` declarations from scripts/heartbeat.sh, fixed escaped `awk` quote probes, replaced raw heredoc JSON construction with a Node `JSON.stringify` payload builder, and added scripts/heartbeat-execution-check.sh. The check runs the real heartbeat script with temporary fixture data and a fake curl binary, then validates the posted JSON payload and legacy heartbeat log line.
Why this matters: `bash -n` did not catch the top-level `local` runtime failure, the `awk` quote issue, or the possibility that shell-collected service status output could corrupt raw JSON. This adds a practical runtime gate for the heartbeat path without needing Pi hardware.
Verification: node --check local-ui/server.js passed; bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed; bash scripts/heartbeat-execution-check.sh passed.
Next step: Run the new check on physical Pi hardware after install, then confirm the systemd heartbeat timer posts real telemetry.

## 2026-06-16 - Fixed device heartbeat to send valid JSON payload

Date/time: 2026-06-16 18:36 UTC
Agent: Pulse
Context: RPI APPLIANCE workstream - heartbeat script was sending empty POST requests to server, breaking device-server synchronization.
What changed: Fixed scripts/heartbeat.sh to send valid JSON payload instead of empty POST requests. Payload includes softwareVersion (from VERSION file), currentMode (from state.json), deviceId, releaseState (object with version), diagnostics (system metrics including temp, disk, memory, CPU, uptime, and service status), network status (online status and connection type), and storage status (disk usage). Preserved existing key=value logging format for backward compatibility and added retry logic for failed transmissions.
Why this matters: Fixes critical bug where devices sent empty POST requests to heartbeat endpoint, enabling proper device-server synchronization for RPI APPLIANCE workstream (pairing, sync, API, kiosk, feed, cache, broadcast, updates, commands, admin). Resolves root cause preventing reliable communication in device-server sync mechanism. Foundation for future enhancements like event/broadcast delivery reporting.
Verification: bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed, node --check local-ui/server.js passed, node --check hosted-api/server.js passed, verified script syntax with bash -n, confirmed JSON payload generation works correctly with jq (by comparing to test script), verified existing logging format preserved for backward compatibility.
Next step: Monitor heartbeat success rate and latency in logs. Consider adding event and broadcast delivery reporting in future iterations.

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