-e # Progress

## 2026-06-14 20:47 UTC - RPI APPLIANCE — install.sh enhanced with automatic kiosk OS configuration and optional skip flag

Changed files:
- install.sh

Implemented:
- Modified install.sh to automatically run configure-kiosk-os.sh during installation unless the --skip-kiosk-config flag is provided.
- Added --skip-kiosk-config flag to allow advanced users to skip automatic kiosk OS configuration.
- When the flag is not provided, the script runs configure-kiosk-os.sh and then instructs the user to reboot (after which the appliance starts automatically).
- When the flag is provided, the script skips kiosk OS configuration and provides instructions to manually run configure-kiosk-os.sh after reboot and before starting the appliance.
- This reduces the manual setup steps for most users to two steps: run install.sh and reboot.
- Preserves all existing functionality and error handling.

Why this matters:
The Autopoiesis OS appliance installation previously required distinct manual steps: run install.sh, run configure-kiosk-os.sh, reboot, and start the appliance. This created friction for users trying to set up their Frames device. By integrating kiosk OS configuration into the installation script, we move closer to the MVP 1.0 goal of a true "one-command install" experience (run install.sh and reboot) while preserving flexibility for advanced users.

Verification:
- bash -n install.sh passed
- bash -n update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed
- node --check local-ui/server.js passed

Next step:
- Test the enhanced install.sh on a physical Raspberry Pi to verify the complete flow from installation to running appliance with and without the flag.

## 2026-06-14 20:00 UTC - ONLINE ADMIN — Added release rollout history to admin device snapshot

Changed files:
- hosted-api/server.js

Implemented:
- Added release rollout history (last 10) to the admin device snapshot endpoint (GET /frames/device/:id/admin-snapshot) to provide admins with update history for specific devices.

Why this matters:
Admins can now see the update lifecycle of a device directly from the device snapshot, including queued, started, completed, failed, and rolled back states, along with timestamps and version details. This improves fleet management by allowing proactive identification of problematic devices and verification of update campaigns without needing to query the separate release rollouts endpoint.

Verification:
- node --check hosted-api/server.js passed
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed

Next step:
- Consider adding a summary of release rollout statistics (e.g., success rate, average update time) to the admin dashboard.