-- SQLite-compatible version of 20260607000001_initial_aos_frames.sql
-- Used only for local schema contract validation.
-- The canonical migration targets PostgreSQL.

BEGIN TRANSACTION;

CREATE TABLE IF NOT EXISTS aos_frame_devices (
  device_id           TEXT    NOT NULL PRIMARY KEY,
  device_api_key      TEXT    NOT NULL,
  owner_user_id       TEXT,
  device_name         TEXT    NOT NULL DEFAULT '',
  device_type         TEXT    NOT NULL DEFAULT 'raspberry_pi',
  software_version    TEXT    NOT NULL DEFAULT '0.0.0',
  update_channel      TEXT    NOT NULL DEFAULT 'stable',
  paired              INTEGER NOT NULL DEFAULT 0,
  remote_enabled      INTEGER NOT NULL DEFAULT 1,
  subscription_status TEXT    NOT NULL DEFAULT 'inactive',
  last_heartbeat_at   TEXT,
  current_mode        TEXT,
  current_artwork_id  TEXT,
  network_online      INTEGER NOT NULL DEFAULT 0,
  network_type        TEXT,
  storage_status_json TEXT    NOT NULL DEFAULT '{}',
  metadata_json       TEXT    NOT NULL DEFAULT '{}',
  created_at          TEXT    NOT NULL DEFAULT (datetime('now')),
  updated_at          TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS aos_frame_pairing_codes (
  id                  TEXT    NOT NULL PRIMARY KEY,
  device_id           TEXT    NOT NULL,
  pairing_code_hash   TEXT    NOT NULL,
  pairing_code        TEXT,
  expires_at          TEXT    NOT NULL,
  claimed_by_user_id  TEXT,
  claimed_at          TEXT,
  status              TEXT    NOT NULL DEFAULT 'active',
  created_at          TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_aos_pairing_device ON aos_frame_pairing_codes (device_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_aos_pairing_hash   ON aos_frame_pairing_codes (pairing_code_hash);

CREATE TABLE IF NOT EXISTS aos_frame_device_settings (
  device_id      TEXT    NOT NULL PRIMARY KEY,
  settings_json  TEXT    NOT NULL DEFAULT '{}',
  updated_at     TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS aos_frame_user_preferences (
  user_id          TEXT    NOT NULL PRIMARY KEY,
  preferences_json TEXT    NOT NULL DEFAULT '{}',
  updated_at       TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS aos_heartbeats (
  id            TEXT    NOT NULL PRIMARY KEY,
  device_id     TEXT    NOT NULL,
  payload_json  TEXT    NOT NULL DEFAULT '{}',
  created_at    TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_aos_heartbeats_device ON aos_heartbeats (device_id, created_at DESC);

CREATE TABLE IF NOT EXISTS aos_device_commands (
  id               TEXT    NOT NULL PRIMARY KEY,
  device_id        TEXT    NOT NULL,
  command_type     TEXT    NOT NULL,
  payload_json     TEXT    NOT NULL DEFAULT '{}',
  status           TEXT    NOT NULL DEFAULT 'queued',
  delivered_at     TEXT,
  acknowledged_at  TEXT,
  completed_at     TEXT,
  last_ack_status  TEXT,
  last_ack_at      TEXT,
  error            TEXT,
  created_at       TEXT    NOT NULL DEFAULT (datetime('now')),
  updated_at       TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_aos_commands_device_status ON aos_device_commands (device_id, status, created_at);

CREATE TABLE IF NOT EXISTS aos_admin_command_audits (
  id                    TEXT    NOT NULL PRIMARY KEY,
  command_id            TEXT    NOT NULL,
  device_id             TEXT    NOT NULL,
  command_type          TEXT    NOT NULL,
  risk                  TEXT    NOT NULL DEFAULT 'medium',
  actor_id              TEXT    NOT NULL,
  actor_role            TEXT    NOT NULL,
  reason                TEXT,
  payload_summary_json  TEXT    NOT NULL DEFAULT '{}',
  authorization_json    TEXT    NOT NULL DEFAULT '{}',
  status                TEXT    NOT NULL DEFAULT 'pending',
  error                 TEXT,
  created_at            TEXT    NOT NULL DEFAULT (datetime('now')),
  updated_at            TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_aos_cmd_audit_command ON aos_admin_command_audits (command_id);
CREATE INDEX IF NOT EXISTS idx_aos_cmd_audit_device  ON aos_admin_command_audits (device_id, created_at DESC);

CREATE TABLE IF NOT EXISTS aos_device_events (
  id            TEXT    NOT NULL PRIMARY KEY,
  device_id     TEXT    NOT NULL,
  event_key     TEXT    NOT NULL,
  source        TEXT    NOT NULL,
  event_type    TEXT    NOT NULL,
  status        TEXT    NOT NULL DEFAULT 'observed',
  observed_at   TEXT    NOT NULL,
  event_json    TEXT    NOT NULL DEFAULT '{}',
  ingested_at   TEXT    NOT NULL DEFAULT (datetime('now')),
  updated_at    TEXT    NOT NULL DEFAULT (datetime('now')),
  UNIQUE (device_id, event_key)
);

CREATE INDEX IF NOT EXISTS idx_aos_events_device ON aos_device_events (device_id, observed_at DESC);

CREATE TABLE IF NOT EXISTS aos_artwork_likes (
  user_id       TEXT    NOT NULL,
  artwork_id    TEXT    NOT NULL,
  created_at    TEXT    NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY (user_id, artwork_id)
);

CREATE TABLE IF NOT EXISTS aos_broadcasts (
  id            TEXT    NOT NULL PRIMARY KEY,
  title         TEXT    NOT NULL DEFAULT '',
  body          TEXT,
  type          TEXT    NOT NULL DEFAULT 'system_notice',
  media_url     TEXT,
  thumbnail_url TEXT,
  artist        TEXT,
  artist_id     TEXT,
  target_type   TEXT    NOT NULL DEFAULT 'all',
  target_value  TEXT    NOT NULL DEFAULT '',
  priority      TEXT    NOT NULL DEFAULT 'normal',
  duration      INTEGER,
  starts_at     TEXT,
  expires_at    TEXT,
  repeat_count  INTEGER NOT NULL DEFAULT 0,
  dismissible   INTEGER NOT NULL DEFAULT 1,
  cache_allowed INTEGER NOT NULL DEFAULT 0,
  sound_allowed INTEGER NOT NULL DEFAULT 1,
  status        TEXT    NOT NULL DEFAULT 'draft',
  created_by    TEXT    NOT NULL,
  metadata_json TEXT    NOT NULL DEFAULT '{}',
  created_at    TEXT    NOT NULL DEFAULT (datetime('now')),
  updated_at    TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_aos_broadcasts_status ON aos_broadcasts (status, starts_at, expires_at);

CREATE TABLE IF NOT EXISTS aos_broadcast_deliveries (
  id              TEXT    NOT NULL PRIMARY KEY,
  broadcast_id    TEXT    NOT NULL,
  device_id       TEXT    NOT NULL,
  command_id      TEXT,
  user_id         TEXT,
  status          TEXT    NOT NULL DEFAULT 'queued',
  queued_at       TEXT,
  delivered_at    TEXT,
  displayed_at    TEXT,
  dismissed_at    TEXT,
  acknowledged_at TEXT,
  completed_at    TEXT,
  error           TEXT,
  created_at      TEXT    NOT NULL DEFAULT (datetime('now')),
  updated_at      TEXT    NOT NULL DEFAULT (datetime('now')),
  UNIQUE (broadcast_id, device_id)
);

CREATE INDEX IF NOT EXISTS idx_aos_broadcast_del_device ON aos_broadcast_deliveries (device_id, created_at DESC);

CREATE TABLE IF NOT EXISTS aos_releases (
  id               TEXT    NOT NULL PRIMARY KEY,
  version          TEXT    NOT NULL,
  channel          TEXT    NOT NULL DEFAULT 'stable',
  git_ref          TEXT,
  status           TEXT    NOT NULL DEFAULT 'draft',
  artifact_url     TEXT,
  checksum         TEXT,
  notes            TEXT,
  changelog_url    TEXT,
  rollback_notes   TEXT,
  minimum_version  TEXT,
  rollout_percent  REAL    NOT NULL DEFAULT 100.0,
  created_by       TEXT    NOT NULL,
  created_at       TEXT    NOT NULL DEFAULT (datetime('now')),
  published_at     TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS uniq_aos_releases_version_channel ON aos_releases (version, channel);

CREATE TABLE IF NOT EXISTS aos_release_rollouts (
  id               TEXT    NOT NULL PRIMARY KEY,
  release_id       TEXT    NOT NULL,
  device_id        TEXT    NOT NULL,
  command_id       TEXT,
  current_version  TEXT,
  target_version   TEXT    NOT NULL,
  status           TEXT    NOT NULL DEFAULT 'pending',
  queued_at        TEXT,
  started_at       TEXT,
  completed_at     TEXT,
  failed_at        TEXT,
  rolled_back_at   TEXT,
  failure_reason   TEXT,
  acknowledged_at  TEXT,
  error            TEXT,
  last_seen_at     TEXT,
  created_at       TEXT    NOT NULL DEFAULT (datetime('now')),
  updated_at       TEXT    NOT NULL DEFAULT (datetime('now')),
  UNIQUE (release_id, device_id)
);

CREATE INDEX IF NOT EXISTS idx_aos_rollouts_device ON aos_release_rollouts (device_id, created_at DESC);

CREATE TABLE IF NOT EXISTS aos_subscriptions (
  id                       TEXT    NOT NULL PRIMARY KEY,
  user_id                  TEXT    NOT NULL,
  plan                     TEXT    NOT NULL DEFAULT 'free',
  status                   TEXT    NOT NULL DEFAULT 'inactive',
  provider                 TEXT    NOT NULL DEFAULT 'manual',
  external_subscription_id TEXT,
  current_period_start     TEXT,
  current_period_end       TEXT,
  cancel_at                TEXT,
  created_at               TEXT    NOT NULL DEFAULT (datetime('now')),
  updated_at               TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE UNIQUE INDEX IF NOT EXISTS uniq_aos_subscriptions_user ON aos_subscriptions (user_id);

COMMIT;
