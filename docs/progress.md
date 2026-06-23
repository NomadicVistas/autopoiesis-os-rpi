## 2026-06-23 10:15 AM Europe/Berlin - LEAD / INTEGRATION - Timestamp consistency improvement for delivery status handling

Changed files:
- hosted-api/db.js

Implemented:
- Modified the _deliveryStatusTimestamp function to ensure all returned timestamp values are consistently formatted using the canonicalTimestamp function, guaranteeing ISO 8601 UTC format for all timestamp values used in delivery status computations and storage operations.

Why this matters:
- Ensures consistent timestamp formatting across all delivery status-related operations
- Prevents potential inconsistencies when comparing or storing timestamp values
- Maintains data integrity in the broadcast delivery tracking system
- Supports reliable time-based filtering and sorting in API responses

Verification:
- node --check hosted-api/db.js passed
- node --check hosted-api/server.js passed
- node --check local-ui/server.js passed
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh passed
- bash -n scripts/*.sh passed

Next step:
- Monitor delivery status handling to confirm consistent timestamp formats
- Consider applying similar timestamp consistency improvements to other timestamp-handling functions if needed


## 2026-06-23 10:35 AM Europe/Berlin - LEAD / RPI APPLIANCE - Node.js version check in installer

Changed files:
- install.sh

Implemented:
- Added a check for Node.js presence and version (>=18) in the install.sh script before proceeding with installation.
- The check ensures the runtime dependency is met early, preventing failed boots due to missing Node.js.

Why this matters:
- The Autopoiesis OS appliance requires Node.js >=18 for the local UI server.
- Early detection avoids proceeding with installation only to fail later during bootstrap or runtime.
- Improves the robustness of the one-command install experience.

Verification:
- node --check local-ui/server.js passed
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh passed
- bash -n scripts/*.sh passed
- Manual test: verifying the script exits with helpful message when Node.js is missing or too old (simulated by temporarily adjusting PATH or version output).

Next step:
- Monitor installer logs for any Node-related issues in the field.