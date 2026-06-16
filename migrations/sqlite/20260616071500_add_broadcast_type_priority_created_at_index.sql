-- Add index on aos_broadcasts (type, priority, created_at) to improve feed category filtering and ordering

CREATE INDEX IF NOT EXISTS idx_aos_broadcasts_type_priority_created_at
ON aos_broadcasts (type, priority, created_at);