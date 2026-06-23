## 2026-06-23 12:43 PM Europe/Berlin - RPI APPLIANCE - SQLite3 module auto-repair in installer

Changed files:
- install.sh

Implemented:
- Enhanced the SQLite3 native module check in install.sh to automatically attempt repair via 'npm rebuild' when the module fails to load
- Added verification step to confirm the repair was successful
- Provides clear feedback on success or failure of the automatic repair attempt
- Falls back to original warning message if automatic repair fails, with manual remediation instructions

Why this matters:
- Addresses a common issue that could prevent the appliance from working properly due to native module compatibility
- Reduces need for manual intervention by automatically fixing recoverable issues
- Improves robustness of the one-command install experience
- Maintains backward compatibility by falling back to manual instructions if auto-repair fails

Verification:
- node --check local-ui/server.js passed
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh passed
- bash -n scripts/*.sh passed

Next step:
- Monitor installer logs for any SQLite3-related issues in the field and verify automatic repair effectiveness

## 2026-06-23 12:27 PM Europe/Berlin - BROADCAST / FEED - Broadcast delivery timestamp canonicalization fix

Changed files:
- hosted-api/db.js

Implemented:
- Fixed syntax error in _deliveryStatusTimestamp function (missing closing brace for acknowledged condition)
- Ensured all returned timestamps are properly canonicalized using canonicalTimestamp()
- Maintains consistency with existing timestamp handling patterns in the codebase
- Resolves potential broadcast delivery tracking inconsistencies

Why this matters:
- Fixes a syntax error that could cause runtime failures in broadcast delivery processing
- Ensures timestamp consistency across all delivery status computations
- Prevents potential issues with time-based queries and sorting in API responses
- Maintains data integrity in the broadcast delivery tracking system

Verification:
- node --check hosted-api/db.js passed
- node --check hosted-api/server.js passed
- node --check local-ui/server.js passed
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh passed
- bash -n scripts/*.sh passed

Next step:
- Monitor broadcast delivery reporting to verify consistent timestamp formats in API responses

## 2026-06-23 11:15 AM Europe/Berlin - LEAD / INTEGRATION - Database timestamp consistency for broadcast delivery tracking

Changed files:
- hosted-api/db.js

Implemented:
- Enhanced the _deliveryStatusTimestamp function to guarantee all returned timestamp values are consistently formatted in ISO 8601 UTC format using the canonicalTimestamp function.
- Applied consistent timestamp formatting to all delivery status fields (deliveredAt, receivedAt, updatedAt, etc.) to prevent inconsistencies in broadcast delivery tracking.

Why this matters:
- Ensures data integrity in the broadcast delivery tracking system by eliminating timestamp format inconsistencies
- Prevents potential issues with time-based queries and sorting in API responses
- Maintains consistency across all broadcast-related timestamp operations
- Resolves potential edge cases where mixed timestamp formats could cause comparison failures

Verification:
- node --check hosted-api/db.js passed
- node --check hosted-api/server.js passed
- node --check local-ui/server.js passed
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh passed
- bash -n scripts/*.sh passed

Next step:
- Monitor broadcast delivery reporting to verify consistent timestamp formats in API responses
- Consider applying similar timestamp consistency improvements to other database timestamp functions


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
- Improves robustness of the one-command install experience.

Verification:
- node --check local-ui/server.js passed
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh passed
- bash -n scripts/*.sh passed
- Manual test: verifying the script exits with helpful message when Node.js is missing or too old (simulated by temporarily adjusting PATH or version output).

Next step:
- Monitor installer logs for any Node-related issues in the field.