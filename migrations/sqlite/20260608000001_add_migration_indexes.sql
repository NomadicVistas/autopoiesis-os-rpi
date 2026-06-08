-- Migration: 20260608000001_add_migration_indexes
-- Adds useful indexes for common query patterns on the migration tracking table
-- and device search. Safe to re-run (IF NOT EXISTS).

CREATE INDEX IF NOT EXISTS idx_aos_migrations_applied
  ON aos_migrations (applied_at DESC);

-- Index for looking up devices by owner (admin bundle, entitlement computation)
CREATE INDEX IF NOT EXISTS idx_aos_devices_owner
  ON aos_frame_devices (owner_user_id);

-- Index for subscription lookups by status (admin dashboard filtering)
CREATE INDEX IF NOT EXISTS idx_aos_subscriptions_status
  ON aos_subscriptions (status);
