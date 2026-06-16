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