## 2026-06-16 02:30 PM Europe/Berlin - LEAD / INTEGRATION — Added index on aos_frame_devices(owner_user_id, paired) for faster device lookups

Changed files:
- migrations/sqlite/20260616123000_add_index_on_devices_owner_user_id_paired.sql

Implemented:
- Added index on owner_user_id and paired columns in aos_frame_devices table to speed up queries that filter by owner and paired status.

Why this matters:
- Speeds up the countDevicesByOwner function used for entitlement computation.
- Improves listDevices filtering by owner and paired status.
- Benefits multiple workstreams: profile (subscription entitlements), API (device listing), admin (fleet management), and sync (device ownership checks).
- Reduces query latency for device-centric operations, improving overall system responsiveness.

Verification:
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed
- node --check local-ui/server.js passed
- node --check hosted-api/server.js passed
- Verified index creation via schema query.

Next step:
- Monitor query performance in logs for owner/device lookups.


## 2026-06-16 12:41 PM Europe/Berlin - LEAD / BROADCAST/FEED — Enhanced polling logic for personalized content stream

Changed files:
- hosted-api/server.js

Implemented:
- Enhanced handleStream function to implement adaptive polling based on content priority and expiry
- Added logic to detect emergency/critical broadcast items and increase polling frequency
- Added logic to adjust polling interval based on soonest-expiring content to catch items before expiry
- Maintained subscription-tier-based polling as baseline with reasonable bounds (30s-30min interval, 60s-1h idle)

Why this matters:
- Improves responsiveness to high-priority broadcasts (emergency/critical) by polling more frequently
- Ensures timely delivery of expiring content by adjusting polling to catch items before they expire
- Reduces unnecessary polling for low-priority content while maintaining subscription-tier fairness
- Enhances device-side experience by providing more relevant polling guidance based on actual stream content
- Supports broadcast/feed workstream by making content delivery more adaptive and efficient

Verification:
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed
- node --check local-ui/server.js passed
- node --check hosted-api/server.js passed
- Manual verification of the adapted polling logic (no regression in stream endpoint)

Next step:
- Monitor device-side polling behavior to confirm improvement

## 2026-06-16 11:10 AM Europe/Berlin - LEAD / INTEGRATION — Enhanced effective preferences endpoint with subscription and entitlements

Changed files:
- hosted-api/server.js

Implemented:
- Extended GET /frames/device/:id/effective-preferences to include subscription and entitlements for the device owner.
- Added logic to fetch owner subscription, compute device count and entitlements using existing computeEntitlements function.
- Returned subscription and entitlements in the response alongside existing effective preferences, device settings, and owner preferences.

Why this matters:
- Reduces round trips for devices needing both effective preferences and subscription/entitlement data during startup or reconfiguration.
- Integrates profile (subscription) data directly into the effective preferences endpoint, simplifying device-side logic.
- Supports multiple workstreams (profile, API, pairing, sync) by providing a more complete device context in a single call.
- Lays foundation for future features like dynamic feature gating based on entitlements.

Verification:
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed
- node --check local-ui/server.js passed
- node --check hosted-api/server.js passed
- Manual verification of the updated endpoint returns correct subscription and entitlements for paired devices with owners, and null for unpaired devices.

Next step:
- Consider adding device-specific flags to the effective preferences endpoint for further granularity.

## 2026-06-16 08:46 AM Europe/Berlin - LEAD / BROADCAST/FEED — Improved cache eligibility logic for personalized content stream

Changed files:
- hosted-api/server.js

Implemented:
- Enhanced the handleStream function to correctly calculate cacheEligible flag:
  * Fixed field reference from snake_case media_url to camelCase mediaUrl
  * Added expiry-aware eligibility: items expiring in less than 30 minutes are not considered cache eligible
  * Maintained requirement that cache_allowed must be true and media URL present

Why this matters:
- Fixes a bug where cache eligibility was incorrectly evaluated due to field name mismatch
- Improves offline living frame functionality by ensuring only suitably persistent content is marked for caching
- Enhances broadcast/feed workstream by aligning cache eligibility with content lifespan
- Supports MVP 0.3 - Offline Living Frame by providing more reliable cache hints to devices

Verification:
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed
- node --check local-ui/server.js passed
- node --check hosted-api/server.js passed
- Manual verification of the corrected logic (no regression in stream endpoint)

Next step:
- Monitor device-side cache behavior to confirm improvement
- Consider adding device-specific cache preferences in future iterations

## 2026-06-16 08:26 AM Europe/Berlin - LEAD / INTEGRATION — Added /frames/status endpoint for enhanced API observability

Changed files:
- hosted-api/server.js

Implemented:
- Added GET /frames/status endpoint that provides detailed API status including:
  * Service information (name, version, timestamp)
  * Database statistics (path, table count, device counts)
  * Complete API endpoint inventory with counts
- Endpoint is lightweight and does not require authentication
- Provides better observability than the basic /health endpoint while being less comprehensive than /frames/admin/readiness

Why this matters:
- Enhances API workstream by providing better visibility into service status
- Benefits integration workstream by offering a standardized status check for monitoring and health checks
- Supports updates workstream with detailed information for pre/post-deployment verification
- aids admin workstream with service metrics that can be consumed by dashboard components
- Improves overall system observability without adding significant overhead

Verification:
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed
- node --check local-ui/server.js passed
- node --check hosted-api/server.js passed
- Manual verification of endpoint responsiveness and content correctness

Next step:
- Consider adding basic metrics (request counts, error rates) to the status endpoint for enhanced monitoring
- Evaluate adding version-specific information to help with API compatibility checking
## 2026-06-16 10:35 AM Europe/Berlin - LEAD / RPI APPLIANCE — Enhanced diagnostics script for comprehensive appliance health

Changed files:
- scripts/diagnostics.sh

Implemented:
- Added kiosk process verification to confirm local-ui/server.js is running when service is active
- Added port 3030 listening count to ensure UI is ready to serve
- Added local UI content validation to confirm HTML interface is served
- Added checks for factory reset, update, and install script availability and executability
- Added port conflict detection for port 3030
- Added recent error scanning in local UI logs (non-quick mode)
- Enhanced service health section with kiosk-specific process checks

Why this matters:
- Provides deeper insight into appliance readiness beyond basic service status
- Helps diagnose kiosk startup issues where service is active but UI fails to launch
- Verifies that the local UI is not only running but actually serving the kiosk interface
- Checks critical recovery and maintenance scripts are present and executable
- Helps identify port conflicts that could prevent UI from binding
- Supports all RPI APPLIANCE workstream areas: installer verification, kiosk launch, diagnostics, and production cleanup

Verification:
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed
- node --check local-ui/server.js passed
- node --check hosted-api/server.js passed (from previous verification)
- Manual verification of new check logic (no regression in existing functionality)

Next step:
- Consider adding touchscreen calibration verification in future iterations
- Consider adding hardware-specific checks for different Raspberry Pi models