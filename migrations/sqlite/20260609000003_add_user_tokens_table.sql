-- Migration: 20260609000003_add_user_tokens_table
-- Adds user tokens table for proper authentication system
-- Replaces AUTOPOIESIS_FRAMES_USER_TOKENS environment variable approach

CREATE TABLE IF NOT EXISTS aos_user_tokens (
  id           TEXT    NOT NULL PRIMARY KEY,
  user_id      TEXT    NOT NULL,
  token_hash   TEXT    NOT NULL UNIQUE,
  name         TEXT,  -- Descriptive name for the token (e.g., "iPhone", "Web Browser")
  created_at   TEXT    NOT NULL DEFAULT (datetime('now')),
  expires_at   TEXT,  -- NULL means no expiration
  last_used_at TEXT,
  revoked      INTEGER NOT NULL DEFAULT 0,
  revoked_at   TEXT,
  FOREIGN KEY (user_id) REFERENCES aos_frame_user_preferences(user_id) ON DELETE CASCADE
);

-- Index for fast token lookup by hash
CREATE INDEX IF NOT EXISTS idx_aos_user_tokens_token_hash ON aos_user_tokens(token_hash);

-- Index for looking up tokens by user
CREATE INDEX IF NOT EXISTS idx_aos_user_tokens_user_id ON aos_user_tokens(user_id);

-- Index for active (non-revoked, non-expired) tokens
CREATE INDEX IF NOT EXISTS idx_aos_user_tokens_active 
  ON aos_user_tokens(user_id, revoked, expires_at) 
  WHERE revoked = 0 AND (expires_at IS NULL OR expires_at > datetime('now'));