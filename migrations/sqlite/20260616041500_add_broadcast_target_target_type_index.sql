-- Migration: 20260616041500_add_broadcast_target_target_type_index
-- Adds index on aos_broadcasts for target_type and target_value to improve targeting filter performance
-- Safe to re-run (IF NOT EXISTS).

-- Index for target_type and target_value: improves the initial filtering by target_type and target_value in the getStreamContent function.
-- This allows the database to quickly filter broadcasts by target_type and then scan the target_value for the specific deviceId, ownerUserId, or subscriptionTier.
CREATE INDEX IF NOT EXISTS idx_aos_broadcasts_target_type_target_value
  ON aos_broadcasts (target_type, target_value);