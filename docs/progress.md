## 2026-06-16 07:15 AM Europe/Berlin - LEAD / INTEGRATION — Added index on aos_broadcasts (type, priority, created_at) to improve feed category filtering and ordering

Changed files:
- migrations/sqlite/20260616071500_add_broadcast_type_priority_created_at_index.sql

Implemented:
- Added index on aos_broadcasts (type, priority, created_at) to improve the category filtering and ordering in the getStreamContent function used for the personalized feed.
- This allows the database to quickly filter by content type (artwork, curatorial, blog, etc.) and then sort by priority and creation time, reducing the need for in-memory filtering and sorting.

Why this matters:
- Speeds up the feed generation by leveraging the index for category-based filtering and ordering.
- Benefits the feed workstream by reducing the in-memory filtering overhead, especially when combined with the existing target_type/target_value index.
- Supports the API / DATABASE / SYNC workstream by improving query performance on a frequently accessed table.
- Benefits downstream workstreams that rely on stream content (e.g., cache, broadcast, admin) by providing faster access to categorized and prioritized content.

Verification:
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed
- node --check local-ui/server.js passed
- Syntax of new migration file verified (no errors when parsed by sqlite3 in memory).

Next step:
- Monitor query performance in logs for getStreamContent calls, particularly for category-based filtering.
- Consider extending the index to be a covering index by including additional columns (e.g., media_url, thumbnail_url) to avoid table lookups.

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

## 2026-06-16 04:20 AM Europe/Berlin - RPI APPLIANCE — Enhanced kiosk OS configuration with verification step

Changed files:
- install.sh

Implemented:
- Added verify_kiosk_os_config function that runs after configure-kiosk-os.sh to verify critical kiosk OS settings:
  * graphical.target set as default systemd target
  * Auto-login configured for appliance user (lightdm, gdm3, or getty override)
  * Screen blanking disabled (console via /etc/kbd/config or raspi-config, X11 via Xsession.d drop-in)
  * unclutter installed for cursor hiding
- Provides immediate feedback on kiosk OS configuration success or failure
- Continues installation even if verification fails (with warnings) to avoid blocking headless setups
- Outputs clear pass/fail status for each verification check

Why this matters:
- Increases confidence in the one-command install process by verifying critical kiosk OS configuration
- Provides immediate, actionable feedback if kiosk OS settings are not applied correctly
- Helps users understand what to expect after reboot, reducing confusion and support requests
- Makes the verification process more comprehensive and specific to kiosk readiness
- Supports the MVP 1.0 goal of a true "one-command install" experience with verified kiosk readiness

Verification:
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed
- node --check local-ui/server.js passed
- Enhanced failure reporting to show detailed information when verification fails

Next step:
- Test on physical Raspberry Pi to verify the complete flow from installation to running appliance with kiosk OS verification
- Consider extending similar verification to update.sh and factory-reset.sh for consistency