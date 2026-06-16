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
- Added port 3030 listening check to ensure UI is ready to serve
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

