-- Migration: 20260614000008_add_index_on_owner_userid
-- Add index on owner_user_id in aos_frame_devices to improve admin device listing and owner-based queries.
-- Safe to re-run (IF NOT EXISTS).

CREATE INDEX IF NOT EXISTS idx_aos_devices_owner_user_id
ON aos_frame_devices(owner_user_id);