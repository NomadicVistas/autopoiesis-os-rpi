-- Migration: 20260609000004_add_performance_indexes
-- Adds indexes to improve query performance for feed generation, device listing, and command holding.
-- Safe to re-run (IF NOT EXISTS).

-- Index for feed generation: improves the correlated subquery in getStreamContent that calculates
-- average display rate per broadcast. Also helps with delivery stats queries.
CREATE INDEX IF NOT EXISTS idx_aos_broadcast_deliveries_broadcast_id_status
  ON aos_broadcast_deliveries (broadcast_id, status);

-- Index for device listing: filters by owner_user_id, paired, device_type, update_channel, disabled.
-- Already have idx_aos_devices_owner on owner_user_id; add others for common filters.
CREATE INDEX IF NOT EXISTS idx_aos_devices_paired
  ON aos_frame_devices (paired);
CREATE INDEX IF NOT EXISTS idx_aos_devices_device_type
  ON aos_frame_devices (device_type);
CREATE INDEX IF NOT EXISTS idx_aos_devices_update_channel
  ON aos_frame_devices (update_channel);
CREATE INDEX IF NOT EXISTS idx_aos_devices_disabled
  ON aos_frame_devices (disabled);
-- Composite index for owner + paired (common in entitlement computation)
CREATE INDEX IF NOT EXISTS idx_aos_devices_owner_paired
  ON aos_frame_devices (owner_user_id, paired);
-- Index for search on device_id, device_name, owner_user_id (used in listDevices search)
CREATE INDEX IF NOT EXISTS idx_aos_devices_device_id_name
  ON aos_frame_devices (device_id, device_name);
CREATE INDEX IF NOT EXISTS idx_aos_devices_owner_user_id
  ON aos_frame_devices (owner_user_id); -- duplicate of existing, but fine

-- Index for pairing code lookups: claimPairingCode and getPairingCode.
CREATE INDEX IF NOT EXISTS idx_aos_pairing_codes_hash_status
  ON aos_frame_pairing_codes (pairing_code_hash, status);
CREATE INDEX IF NOT EXISTS idx_aos_pairing_codes_device_id_status
  ON aos_frame_pairing_codes (device_id, status);

-- Index for device commands: pending commands, acknowledgments, fleet listings.
CREATE INDEX IF NOT EXISTS idx_aos_device_commands_device_id_status
  ON aos_device_commands (device_id, status);
CREATE INDEX IF NOT EXISTS idx_aos_device_commands_status_command_type
  ON aos_device_commands (status, command_type);
CREATE INDEX IF NOT EXISTS idx_aos_device_commands_device_id_status_command_type
  ON aos_device_commands (device_id, status, command_type);
-- Index for command ID lookups (primary key on id already exists, but explicit)
CREATE INDEX IF NOT EXISTS idx_aos_device_commands_id
  ON aos_device_commands (id);

-- Index for admin command audit: filtering in listCommandAudits.
CREATE INDEX IF NOT EXISTS idx_aos_admin_command_audits_device_id
  ON aos_admin_command_audits (device_id);
CREATE INDEX IF NOT EXISTS idx_aos_admin_command_audits_command_type
  ON aos_admin_command_audits (command_type);
CREATE INDEX IF NOT EXISTS idx_aos_admin_command_audits_status
  ON aos_admin_command_audits (status);
CREATE INDEX IF NOT EXISTS idx_aos_admin_command_audits_actor_id
  ON aos_admin_command_audits (actor_id);
CREATE INDEX IF NOT EXISTS idx_aos_admin_command_audits_actor_role
  ON aos_admin_command_audits (actor_role);
CREATE INDEX IF NOT EXISTS idx_aos_admin_command_audits_risk
  ON aos_admin_command_audits (risk);
-- Composite index for common filter combinations
CREATE INDEX IF NOT EXISTS idx_aos_admin_command_audits_device_id_command_type
  ON aos_admin_command_audits (device_id, command_type);
CREATE INDEX IF NOT EXISTS idx_aos_admin_command_audits_device_id_status
  ON aos_admin_command_audits (device_id, status);

-- Index for broadcast deliveries: filtering by device_id, status, broadcast_id.
CREATE INDEX IF NOT EXISTS idx_aos_broadcast_deliveries_device_id
  ON aos_broadcast_deliveries (device_id);
CREATE INDEX IF NOT EXISTS idx_aos_broadcast_deliveries_status
  ON aos_broadcast_deliveries (status);
CREATE INDEX IF NOT EXISTS idx_aos_broadcast_deliveries_broadcast_id
  ON aos_broadcast_deliveries (broadcast_id);
-- Composite for common queries
CREATE INDEX IF NOT EXISTS idx_aos_broadcast_deliveries_device_id_status
  ON aos_broadcast_deliveries (device_id, status);
CREATE INDEX IF NOT EXISTS idx_aos_broadcast_deliveries_broadcast_id_status
  ON aos_broadcast_deliveries (broadcast_id, status);

-- Index for artwork likes: used in getLikedArtistIds and getLikedArtworks.
CREATE INDEX IF NOT EXISTS idx_aos_artwork_likes_user_id
  ON aos_artwork_likes (user_id);
CREATE INDEX IF NOT EXISTS idx_aos_artwork_likes_artwork_id
  ON aos_artwork_likes (artwork_id);
-- Composite for the join in getLikedArtistIds
CREATE INDEX IF NOT EXISTS idx_aos_artwork_likes_user_id_artwork_id
  ON aos_artwork_likes (user_id, artwork_id);

-- Index for broadcasts: filtering in listBroadcasts and getStreamContent targeting.
CREATE INDEX IF NOT EXISTS idx_aos_broadcasts_status
  ON aos_broadcasts (status);
CREATE INDEX IF NOT EXISTS idx_aos_broadcasts_priority
  ON aos_broadcasts (priority);
CREATE INDEX IF NOT EXISTS idx_aos_broadcasts_target_type
  ON aos_broadcasts (target_type);
CREATE INDEX IF NOT EXISTS idx_aos_broadcasts_artist_id
  ON aos_broadcasts (artist_id);
CREATE INDEX IF NOT EXISTS idx_aos_broadcasts_expires_at
  ON aos_broadcasts (expires_at);
CREATE INDEX IF NOT EXISTS idx_aos_broadcasts_starts_at
  ON aos_broadcasts (starts_at);
-- Composite for active non-expired queries
CREATE INDEX IF NOT EXISTS idx_aos_broadcasts_status_expires_starts
  ON aos_broadcasts (status, expires_at, starts_at);

-- Index for user tokens: validation in validateUserToken.
CREATE INDEX IF NOT EXISTS idx_aos_user_tokens_hash
  ON aos_user_tokens (token_hash);
CREATE INDEX IF NOT EXISTS idx_aos_user_tokens_user_id
  ON aos_user_tokens (user_id);
CREATE INDEX IF NOT EXISTS idx_aos_user_tokens_expires
  ON aos_user_tokens (expires_at);
CREATE INDEX IF NOT EXISTS idx_aos_user_tokens_revoked
  ON aos_user_tokens (revoked);