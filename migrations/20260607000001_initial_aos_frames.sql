-- AOS Frames initial schema
-- Creates all durable aos_ tables for the Autopoiesis OS + Frames platform.
-- Target: PostgreSQL (compatible with SQLite for local validation).
-- All tables use the aos_ namespace prefix as required by the migration contract.

BEGIN;

-- Core device identity and fleet management
CREATE TABLE IF NOT EXISTS aos_frame_devices (
  device_id           TEXT    NOT NULL,
  device_api_key      TEXT    NOT NULL,
  owner_user_id       TEXT,
  device_name         TEXT    NOT NULL DEFAULT '',
  device_type         TEXT    NOT NULL DEFAULT 'raspberry_pi',
  software_version    TEXT    NOT NULL DEFAULT '0.0.0',
  update_channel      TEXT    NOT NULL DEFAULT 'stable',
  paired              BOOLEAN NOT NULL DEFAULT FALSE,
  remote_enabled      BOOLEAN NOT NULL DEFAULT TRUE,
  subscription_status TEXT    NOT NULL DEFAULT 'inactive',
  last_heartbeat_at   TIMESTAMPTZ,
  current_mode        TEXT,
  current_artwork_id  TEXT,
  network_online      BOOLEAN NOT NULL DEFAULT FALSE,
  network_type        TEXT,
  storage_status_json TEXT    NOT NULL DEFAULT '{}',
  metadata_json       TEXT    NOT NULL DEFAULT '{}',
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (device_id)
);

CREATE TABLE IF NOT EXISTS aos_frame_pairing_codes (
  id                  TEXT    NOT NULL,
  device_id           TEXT    NOT NULL,
  pairing_code_hash   TEXT    NOT NULL,
  pairing_code        TEXT,
  expires_at          TIMESTAMPTZ NOT NULL,
  claimed_by_user_id  TEXT,
  claimed_at          TIMESTAMPTZ,
  status              TEXT    NOT NULL DEFAULT 'active',
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_aos_pairing_device ON aos_frame_pairing_codes (device_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_aos_pairing_hash   ON aos_frame_pairing_codes (pairing_code_hash);

-- Device-specific settings overrides
CREATE TABLE IF NOT EXISTS aos_frame_device_settings (
  device_id      TEXT    NOT NULL,
  settings_json  TEXT    NOT NULL DEFAULT '{}',
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (device_id)
);

-- User-level preference defaults synced to all owned frames
CREATE TABLE IF NOT EXISTS aos_frame_user_preferences (
  user_id          TEXT    NOT NULL,
  preferences_json TEXT    NOT NULL DEFAULT '{}',
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id)
);

-- Heartbeat telemetry
CREATE TABLE IF NOT EXISTS aos_heartbeats (
  id            TEXT    NOT NULL,
  device_id     TEXT    NOT NULL,
  payload_json  TEXT    NOT NULL DEFAULT '{}',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_aos_heartbeats_device ON aos_heartbeats (device_id, created_at DESC);

-- Remote command queue
CREATE TABLE IF NOT EXISTS aos_device_commands (
  id               TEXT    NOT NULL,
  device_id        TEXT    NOT NULL,
  command_type     TEXT    NOT NULL,
  payload_json     TEXT    NOT NULL DEFAULT '{}',
  status           TEXT    NOT NULL DEFAULT 'queued',
  delivered_at     TIMESTAMPTZ,
  acknowledged_at  TIMESTAMPTZ,
  completed_at     TIMESTAMPTZ,
  last_ack_status  TEXT,
  last_ack_at      TIMESTAMPTZ,
  error            TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_aos_commands_device_status ON aos_device_commands (device_id, status, created_at);

-- Admin command audit trail
CREATE TABLE IF NOT EXISTS aos_admin_command_audits (
  id                    TEXT    NOT NULL,
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
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_aos_cmd_audit_command ON aos_admin_command_audits (command_id);
CREATE INDEX IF NOT EXISTS idx_aos_cmd_audit_device  ON aos_admin_command_audits (device_id, created_at DESC);

-- Unified device event log (ingested from heartbeat)
CREATE TABLE IF NOT EXISTS aos_device_events (
  id            TEXT    NOT NULL,
  device_id     TEXT    NOT NULL,
  event_key     TEXT    NOT NULL,
  source        TEXT    NOT NULL,
  event_type    TEXT    NOT NULL,
  status        TEXT    NOT NULL DEFAULT 'observed',
  observed_at   TIMESTAMPTZ NOT NULL,
  event_json    TEXT    NOT NULL DEFAULT '{}',
  ingested_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id),
  UNIQUE (device_id, event_key)
);

CREATE INDEX IF NOT EXISTS idx_aos_events_device ON aos_device_events (device_id, observed_at DESC);

-- Artwork likes
CREATE TABLE IF NOT EXISTS aos_artwork_likes (
  user_id       TEXT    NOT NULL,
  artwork_id    TEXT    NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, artwork_id)
);

-- Broadcasts
CREATE TABLE IF NOT EXISTS aos_broadcasts (
  id            TEXT    NOT NULL,
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
  starts_at     TIMESTAMPTZ,
  expires_at    TIMESTAMPTZ,
  repeat_count  INTEGER NOT NULL DEFAULT 0,
  dismissible   BOOLEAN NOT NULL DEFAULT TRUE,
  cache_allowed BOOLEAN NOT NULL DEFAULT FALSE,
  sound_allowed BOOLEAN NOT NULL DEFAULT TRUE,
  status        TEXT    NOT NULL DEFAULT 'draft',
  created_by    TEXT    NOT NULL,
  metadata_json TEXT    NOT NULL DEFAULT '{}',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_aos_broadcasts_status ON aos_broadcasts (status, starts_at, expires_at);

-- Broadcast delivery tracking
CREATE TABLE IF NOT EXISTS aos_broadcast_deliveries (
  id              TEXT    NOT NULL,
  broadcast_id    TEXT    NOT NULL,
  device_id       TEXT    NOT NULL,
  command_id      TEXT,
  user_id         TEXT,
  status          TEXT    NOT NULL DEFAULT 'queued',
  queued_at       TIMESTAMPTZ,
  delivered_at    TIMESTAMPTZ,
  displayed_at    TIMESTAMPTZ,
  dismissed_at    TIMESTAMPTZ,
  acknowledged_at TIMESTAMPTZ,
  completed_at    TIMESTAMPTZ,
  error           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id),
  UNIQUE (broadcast_id, device_id)
);

CREATE INDEX IF NOT EXISTS idx_aos_broadcast_del_device ON aos_broadcast_deliveries (device_id, created_at DESC);

-- Software releases
CREATE TABLE IF NOT EXISTS aos_releases (
  id               TEXT    NOT NULL,
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
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  published_at     TIMESTAMPTZ,
  PRIMARY KEY (id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uniq_aos_releases_version_channel ON aos_releases (version, channel);

-- Release rollout tracking per device
CREATE TABLE IF NOT EXISTS aos_release_rollouts (
  id               TEXT    NOT NULL,
  release_id       TEXT    NOT NULL,
  device_id        TEXT    NOT NULL,
  command_id       TEXT,
  current_version  TEXT,
  target_version   TEXT    NOT NULL,
  status           TEXT    NOT NULL DEFAULT 'pending',
  queued_at        TIMESTAMPTZ,
  started_at       TIMESTAMPTZ,
  completed_at     TIMESTAMPTZ,
  failed_at        TIMESTAMPTZ,
  rolled_back_at   TIMESTAMPTZ,
  failure_reason   TEXT,
  acknowledged_at  TIMESTAMPTZ,
  error            TEXT,
  last_seen_at     TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id),
  UNIQUE (release_id, device_id)
);

CREATE INDEX IF NOT EXISTS idx_aos_rollouts_device ON aos_release_rollouts (device_id, created_at DESC);

-- Subscriptions
CREATE TABLE IF NOT EXISTS aos_subscriptions (
  id                       TEXT    NOT NULL,
  user_id                  TEXT    NOT NULL,
  plan                     TEXT    NOT NULL DEFAULT 'free',
  status                   TEXT    NOT NULL DEFAULT 'inactive',
  provider                 TEXT    NOT NULL DEFAULT 'manual',
  external_subscription_id TEXT,
  current_period_start     TIMESTAMPTZ,
  current_period_end       TIMESTAMPTZ,
  cancel_at                TIMESTAMPTZ,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uniq_aos_subscriptions_user ON aos_subscriptions (user_id);

COMMIT;
