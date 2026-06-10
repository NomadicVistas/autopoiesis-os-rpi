-- Migration: 20260609000005_add_settings_updated_at_indexes
-- Adds indexes on updated_at columns for settings tables to improve sync performance
-- Safe to re-run (IF NOT EXISTS).

-- Index for user preferences updated_at to efficiently find recently updated preferences for sync
CREATE INDEX IF NOT EXISTS idx_aos_user_preferences_updated_at
  ON aos_frame_user_preferences (updated_at);

-- Index for device settings updated_at to efficiently find recently updated settings for sync
CREATE INDEX IF NOT EXISTS idx_aos_device_settings_updated_at
  ON aos_frame_device_settings (updated_at);

-- Composite index for user preferences: user_id + updated_at for common sync patterns
CREATE INDEX IF NOT EXISTS idx_aos_user_preferences_user_id_updated_at
  ON aos_frame_user_preferences (user_id, updated_at);

-- Composite index for device settings: device_id + updated_at for common sync patterns
CREATE INDEX IF NOT EXISTS idx_aos_device_settings_device_id_updated_at
  ON aos_frame_device_settings (device_id, updated_at);