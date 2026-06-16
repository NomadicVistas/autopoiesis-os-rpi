-- Migration: 20260616180900_add_index_on_devices_owner_user_id_last_heartbeat_at
-- Add index on owner_user_id and last_heartbeat_at for faster device lookup by owner sorted by heartbeat
-- Safe to re-run (IF NOT EXISTS).

CREATE INDEX IF NOT EXISTS idx_aos_devices_owner_user_id_last_heartbeat_at
ON aos_frame_devices(owner_user_id, last_heartbeat_at DESC);