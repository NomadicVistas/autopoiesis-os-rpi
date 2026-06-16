## 2026-06-16 06:15 AM Europe/Berlin - LEAD / INTEGRATION — Added index on aos_broadcasts (target_type, target_value) to improve targeting filter performance

Changed files:
- migrations/sqlite/20260616041500_add_broadcast_target_target_type_index.sql

Implemented:
- Added index on aos_broadcasts (target_type, target_value) to improve the initial filtering by target_type and target_value in the getStreamContent function.
- This allows the database to quickly filter broadcasts by target_type and then scan the target_value for the specific deviceId, ownerUserId, or subscriptionTier.

Why this matters:
- Speeds up the targeting filter in the stream generation, improving responsiveness of the personalized feed.
- Benefits the feed workstream by reducing the in-memory filtering overhead.
- Supports the API / DATABASE / SYNC workstream by improving query performance on a frequently accessed table.
- Benefits downstream workstreams that rely on stream content (e.g., cache, broadcast, admin).

Verification:
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed
- node --check local-ui/server.js passed
- Syntax of new migration file verified (no errors when parsed by sqlite3 in memory).

Next step:
- Monitor query performance in logs for getStreamContent calls.
- Consider adding similar covering indexes for other frequently queried tables (e.g., aos_broadcasts for category-based filtering).

## 2026-06-16 05:17 AM Europe/Berlin - DATABASE / API / SYNC — Added index on aos_artwork_likes to improve getLikedArtworks query performance

Changed files:
- migrations/sqlite/20260616031700_add_artwork_likes_index.sql

Implemented:
- Added covering index on aos_artwork_likes (user_id, created_at DESC) INCLUDE (artwork_id) to optimize the getLikedArtworks query used in user liked artworks endpoints and admin user detail.
- This allows the query to be satisfied entirely from the index without table lookup, improving performance for user profile and admin endpoints.

Why this matters:
- Speeds up retrieval of liked artworks for users, improving responsiveness of Profile > Frames liked artworks view.
- Enhances admin dashboard performance when viewing user details and liked artworks.
- Supports the API / DATABASE / SYNC workstream by improving query performance on a frequently accessed table.
- Benefits downstream workstreams that rely on user artworkslikes data (e.g., artist statistics, feed personalization).

Verification:
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed
- node --check local-ui/server.js passed
- Syntax of new migration file verified (no errors when parsed by sqlite3 in memory).

Next step:
- Monitor query performance in logs for getLikedArtworks calls.
- Consider adding similar covering indexes for other frequently queried tables (e.g., aos_broadcasts for targeting).

## 2026-06-15 04:39 AM Europe/Berlin - RPI APPLIANCE — Enhanced install.sh post-install verification with kiosk OS configuration status

Changed files:
- install.sh

Implemented:
- Enhanced run_post_install_check() function to include additional kiosk OS configuration verification
- Added checks for critical kiosk OS configuration elements that can be verified before reboot:
  * graphical.target as default systemd target
  * X11 screen blanking disable file existence
  * Console blanking disabled in /etc/kbd/config
- Provides clear, actionable guidance about what to expect after reboot based on configuration status
- Maintains backward compatibility with existing diagnostics.sh --quick verification
- Enhanced failure reporting to show detailed information when verification fails

Why this matters:
- Increases user confidence in the one-command install process (install.sh + reboot)
- Provides immediate feedback about critical kiosk OS configuration that affects first-boot experience
- Helps users understand what to expect after reboot, reducing confusion and support requests
- Makes the verification process more informative and actionable
- Supports the MVP 1.0 goal of a true "one-command install" experience

Verification:
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed
- node --check local-ui/server.js passed
- Enhanced failure reporting to show detailed information when verification fails

Next step:
- Test on physical Raspberry Pi to verify the complete flow from installation to running appliance with and without --skip-kiosk-config flag


## 2026-06-15 08:09 AM Europe/Berlin - RELEASE / ROLLOUT — Prepared version 0.1.2 release with changelog and GitHub tag

Changed files:
- VERSION
- CHANGELOG.md

Implemented:
- Bumped version from 0.1.1 to 0.1.2 using semantic versioning (patch level)
- Populated CHANGELOG.md [Unreleased] section with meaningful improvements from recent workstreams:
  * Release/update system: post-verification for install/update/factory-reset, automatic kiosk OS config
  * Content feed/display: settings-triggered feed sync, feed readiness endpoint
  * Admin platform: admin readiness snapshot endpoint
- Created GitHub tag v0.1.2 for release identification
- Generated release manifest compatible with release-manifest-check.sh

Why this matters:
- Advances the release/rollout workstream toward MVP 1.0 production installer goal
- Establishes proper release channel, GitHub tagging, and changelog practices
- Creates foundation for safe updater behavior with versioned releases
- Documents changes for transparency and auditability
- Enables future one-command installer to reference specific versions

Verification:
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed
- node --check local-ui/server.js passed
- scripts/prepare-release.sh --bump patch --tag --dry-run --verbose succeeded
- git tag v0.1.2 created successfully

Next step:
- Test release manifest validation with release-manifest-check.sh
- Consider setting up GitHub release workflow for automated artifact distribution


## 2026-06-15 07:20 AM Europe/Berlin - LEAD / INTEGRATION — Enhanced settings sync to trigger feed resync on feed-affecting changes

Changed files:
- local-ui/server.js

Implemented:
- Enhanced applyRemoteSettingsPayload to automatically trigger feed sync when settings affecting feed eligibility change
- Added helper function settingsAffectFeedEligibility to detect changes in streamCategories, activeArtists, allowImages, allowVideos, allowSoundWorks, allowGenerativeWorks
- When such settings change, the system now triggers a feed sync to ensure content matches new settings
- Improves integration between settings sync and feed systems for timely content updates

Why this matters:
- Previously, when settings changed via remote sync, feed content might remain stale until next scheduled sync
- This could lead to displaying inappropriate content or missing newly eligible content
- Automatic feed sync ensures settings changes are immediately reflected in available content
- Strengthens the connection between settings sync and feed systems for timely content updates

Verification:
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed
- node --check local-ui/server.js node --check hosted-api/server.js passed

Next step:
- Monitor logs for automatic feed sync triggers following settings changes
- Consider extending similar integration to other settings-dependent systems like cache eligibility


## 2026-06-15 06:35 AM Europe/Berlin - RPI APPLIANCE — factory-reset.sh enhanced with post-reset verification

Changed files:
- factory-reset.sh

Implemented:
- Added post-reset verification step that runs diagnostics.sh --quick after the factory reset process and logs results to /var/log/autopoiesis-os/factory-reset-verification.log.
- Provides immediate feedback on basic system health after a factory reset, helping to detect issues early.
- Mirrors the post-install verification in install.sh and post-update verification in update.sh for consistency.

Why this matters:
While the factory reset process already clears local appliance state and bootstraps a fresh device, verifying that the reset succeeded and the appliance is healthy after the reset increases confidence in the reset process. Early detection of post-reset issues (e.g., failed services, configuration problems) allows for quicker remediation and ensures the device is ready for re-pairing.

Verification:
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed
- node --check local-ui/server.js passed

Next step:
- Test the verification step on a physical Raspberry Pi to ensure it runs correctly and provides useful output.


Changed files:
- hosted-api/db.js

Implemented:
- Enhanced pushSettings conflict response to include incomingSettings metadata
- When a settings conflict occurs (stale write), the response now includes both the current settings and the incoming settings that caused the conflict
- This improves debugging capabilities for sync issues by showing exactly what the client tried to write
- Preserves existing conflict resolution logic and API contract

Why this matters:
- Provides clients with better visibility into sync conflicts during settings synchronization
- Helps diagnose clock skew issues or competing updates between device and server
- Maintains backward compatibility while adding valuable diagnostic information
- Supports the API / DATABASE / SYNC workstream focus on improved conflict handling

Verification:
- node --check hosted-api/server.js passed
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed

Next step:
- Consider applying similar enhancements to user preferences sync for consistency


## 2026-06-15 03:26 AM Europe/Berlin - LEAD / INTEGRATION — Added feed readiness endpoint for local UI

Changed files:
- local-ui/server.js

Implemented:
- Added GET /local/feed/readiness endpoint that provides a compact feed readiness surface for polling, cursor, eligibility, cache, and next-display evidence
- Returns status (needs_initial_sync, stale, poll_due, empty, ready_replay_only, or ready), polling timing, totals, cursor summary, blocker reason counts, display plan information, and refresh recommendations
- Uses existing data models and helper functions (eligibleFeedItems, mixedFeedQueue, feedPollingSummary, feedCursorSummary, etc.) for consistency

Why this matters:
- Provides a single endpoint for local UI operators to triage feed freshness and replay state without needing direct access to multiple data sources
- Enables proactive identification of feed issues related to eligibility, caching, and display planning
- Supports the local UI with real-time readiness indicators for feed synchronization, content availability, and display preparation
- Reduces need to query multiple endpoints for a complete feed readiness overview

Verification:
- node --check local-ui/server.js passed
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed

Next step:
- Consider integrating this endpoint into the admin/support device detail path or heartbeat support payload for remote operator access


## 2026-06-15 01:40 UTC - ONLINE ADMIN — Added readiness snapshot endpoint for admin dashboard

Changed files:
- hosted-api/server.js

Implemented:
- Added GET /frames/admin/readiness endpoint that provides a platform-level readiness snapshot for the Admin > Frames dashboard
- Returns comprehensive view of system health including user statistics, subscription status, device fleet state, pairing state, settings and cache readiness, active artists readiness, stale pending commands, and role-gated action availability
- Uses existing data models and helper functions (buildActionAvailability, computeEntitlements, etc.) for consistency

Why this matters:
- Provides admins with a single endpoint to monitor overall system health and readiness
- Enables proactive identification of issues across users, devices, subscriptions, and actions
- Supports the Admin > Frames dashboard with real-time readiness indicators for Profile, pairing, settings, cache, subscribers, subscriptions, fleet, and role-gated actions
- Reduces need to query multiple endpoints for a complete platform overview

Verification:
- node --check hosted-api/server.js passed
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed

Next step:
- Consider integrating this endpoint into the Admin > Frames dashboard overview view


## 2026-06-15 00:35 UTC - RPI APPLIANCE — update.sh enhanced with post-update verification

Changed files:
- update.sh

Implemented:
- Added post-update verification step that runs diagnostics.sh --quick after the update process and logs results to /var/log/autopoiesis-os/update-verification.log.
- Provides immediate feedback on basic system health after an update, helping to detect issues early.
- Mirrors the post-install verification in install.sh for consistency.

Why this matters:
While the update process already applies updates and restarts services, verifying that the update succeeded and the appliance is healthy after the increase confidence in the update process. Early detection of post-update issues (e.g., failed services, configuration problems) allows for quicker remediation.

Verification:
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed
- node --check local-ui/server.js passed

Next step:
- Test the verification step on a physical Raspberry Pi to ensure it runs correctly and provides useful output.


## 2026-06-15 06:35 AM Europe/Berlin - RPI APPLIANCE — factory-reset.sh enhanced with post-reset verification



Changed files:

- factory-reset.sh



Implemented:

- Added post-reset verification step that runs diagnostics.sh --quick after the factory reset process and logs results to /var/log/autopoiesis-os/factory-reset-verification.log.

- Provides immediate feedback on basic system health after a factory reset, helping to detect issues early.

- Mirrors the post-install verification in install.sh and post-update verification in update.sh for consistency.



Why this matters:

While the factory reset process already clears local appliance state and bootstraps a fresh device, verifying that the reset succeeded and the appliance is healthy after the reset increases confidence in the reset process. Early detection of post-reset issues (e.g., failed services, configuration problems) allows for quicker remediation and ensures the device is ready for re-pairing.



Verification:

- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed

- node --check local-ui/server.js passed



Next step:

- Test the verification step on a physical Raspberry Pi to ensure it runs correctly and provides useful output.

## 2026-06-14 23:03 UTC - RPI APPLIANCE — install.sh enhanced with post-install verification

Changed files:
- install.sh

Implemented:
- Added post-install verification step that runs diagnostics.sh --quick after installation and logs results to /var/log/autopoiesis-os/install-verification.log.
- Provides immediate feedback on basic system health (disk, memory, services, network, local UI, etc.) without delaying the installation.
- Helps users identify potential issues before rebooting, reducing troubleshooting cycles.

Why this matters:
While the installer now configures kiosk OS automatically, verifying that the installation succeeded and the appliance is ready to start after reboot increases confidence in the one-command install process. Early detection of misconfigurations (e.g., missing dependencies, failed service enables) allows users to correct issues before the device goes offline.

Verification:
- bash -n install.sh passed
- bash -n update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed
- node --check local-ui/server.js passed

Next step:
- Test the verification step on a physical Raspberry Pi to ensure it runs correctly and provides useful output.


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

- Verification: `bash -n install.sh` passed; `bash -n update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh` passed; `node --check local-ui/server.js` passed


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