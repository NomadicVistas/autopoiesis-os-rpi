/**
 * AOS Frames — Database Query Layer
 *
 * Maps the hosted API's behavioral contracts to SQL operations against the
 * aos_ tables. Uses better-sqlite3 for SQLite (dev) with a pluggable engine
 * interface for future PostgreSQL support.
 *
 * Usage:
 *   const AosDb = require("./hosted-api/db");
 *   const db = new AosDb("./data/aos.db");
 *   const device = db.registerDevice({ deviceId: "abc", softwareVersion: "0.1.0" });
 */

"use strict";

const path = require("path");
const crypto = require("crypto");
const fs = require("fs");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function now() {
  return new Date().toISOString();
}

function uid(prefix) {
  return prefix + "_" + crypto.randomBytes(12).toString("hex");
}

function generateDeviceKey() {
  return "mk_dev_" + crypto.randomBytes(16).toString("hex");
}

function generatePairingCode() {
  return (
    Math.random().toString(36).slice(2, 6).toUpperCase() +
    "-" +
    Math.floor(1000 + Math.random() * 9000)
  );
}

function hashPairingCode(code) {
  return crypto.createHash("sha256").update(code).digest("hex");
}

function jsonParse(val, fallback) {
  if (val == null) return fallback;
  if (typeof val === "object") return val;
  try { return JSON.parse(val); }
  catch { return fallback; }
}

function jsonStringify(val) {
  if (val == null) return "{}";
  return JSON.stringify(val);
}

function _broadcastTypeToCategory(type) {
  if (!type) return 'content';
  const t = String(type).toLowerCase();
  if (t === 'artwork' || t === 'image' || t === 'video' || t === 'audio' || t === 'generative') return 'artwork';
  if (t === 'curatorial' || t === 'exhibition') return 'curatorial';
  if (t === 'blog_post' || t === 'blog') return 'blog';
  if (t === 'news' || t === 'announcement') return 'news';
  if (t === 'broadcast_message' || t === 'broadcast' || t === 'system_notice') return 'broadcast';
  return 'content';
}

function _priorityRank(priority) {
  const p = String(priority || 'normal').toLowerCase();
  if (p === 'emergency') return 500;
  if (p === 'critical') return 400;
  if (p === 'high') return 300;
  if (p === 'normal') return 200;
  if (p === 'low') return 100;
  return 200;
}

// ---------------------------------------------------------------------------
// AosDb class
// ---------------------------------------------------------------------------

class AosDb {
  /**
   * @param {string} dbPath  Path to SQLite database file
   * @param {object} [opts]
   * @param {boolean} [opts.readonly=false]
   * @param {object} [opts.sqlite3]  Override sqlite3 module (for testing)
   */
  constructor(dbPath, opts = {}) {
    if (!dbPath) throw new Error("AosDb: dbPath required");
    this.dbPath = dbPath;
    this.readonly = !!opts.readonly;

    const sqlite3 = opts.sqlite3 || this._loadBetterSqlite3();
    this.db = new sqlite3(dbPath, { readonly: this.readonly });

    // WAL mode for better concurrent read performance
    if (!this.readonly) {
      this.db.pragma("journal_mode = WAL");
      this.db.pragma("foreign_keys = ON");
    }
  }

  _loadBetterSqlite3() {
    // Try project-local, then global
    const candidates = [
      path.join(__dirname, "..", "node_modules", "better-sqlite3"),
      path.join(__dirname, "..", "..", "node_modules", "better-sqlite3"),
    ];
    for (const p of candidates) {
      try { return require(p); } catch {} // eslint-disable-line no-empty
    }
    try { return require("better-sqlite3"); } catch {} // eslint-disable-line no-empty
    throw new Error(
      "AosDb requires better-sqlite3. Install with: npm install better-sqlite3"
    );
  }

  close() {
    if (this.db) {
      this.db.close();
      this.db = null;
    }
  }

  // ── Utility ──────────────────────────────────────────────────────────────

  /**
   * Returns true if the database has the aos_ tables.
   */
  isInitialized() {
    const row = this.db.prepare(
      "SELECT count(*) AS cnt FROM sqlite_schema WHERE type='table' AND name LIKE 'aos_%'"
    ).get();
    return row.cnt >= 10;
  }

  /**
   * Returns list of aos_ table names in the database.
   */
  listTables() {
    return this.db.prepare(
      "SELECT name FROM sqlite_schema WHERE type='table' AND name LIKE 'aos_%' ORDER BY name"
    ).all().map(r => r.name);
  }

  // ── Migration Runner ────────────────────────────────────────────────────────

  /**
   * Creates the aos_migrations tracking table if it does not exist.
   */
  ensureMigrationsTable() {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS aos_migrations (
        name        TEXT    NOT NULL PRIMARY KEY,
        applied_at  TEXT    NOT NULL DEFAULT (datetime('now')),
        checksum    TEXT,
        duration_ms INTEGER
      );
    `);
  }

  /**
   * Returns a Set of migration names that have been applied.
   */
  getAppliedMigrations() {
    this.ensureMigrationsTable();
    const rows = this.db.prepare(
      "SELECT name FROM aos_migrations ORDER BY name"
    ).all();
    return new Set(rows.map(r => r.name));
  }

  /**
   * Records a migration as applied.
   * @param {string} name - Migration filename (e.g. '20260607000001_initial')
   * @param {object} [opts]
   * @param {string} [opts.checksum] - SHA-256 of the migration SQL
   * @param {number} [opts.durationMs] - Time taken to apply
   */
  recordMigration(name, opts = {}) {
    this.db.prepare(
      "INSERT OR IGNORE INTO aos_migrations (name, applied_at, checksum, duration_ms) VALUES (?, datetime('now'), ?, ?)"
    ).run(name, opts.checksum || null, opts.durationMs != null ? opts.durationMs : null);
  }

  /**
   * Runs pending SQLite migrations from the given directory.
   *
   * Handles three states:
   * 1. Fresh database (no aos_ tables): caller should bootstrap from full schema first.
   * 2. Existing database without aos_migrations: registers the initial seed as applied.
   * 3. Incremental: applies any new migration files not yet recorded.
   *
   * @param {string} migrationsDir - Path to directory containing .sql migration files
   * @returns {{ applied: string[], skipped: string[], errors: Array<{name, error}> }}
   */
  runMigrations(migrationsDir) {
    const result = { applied: [], skipped: [], errors: [] };

    this.ensureMigrationsTable();

    // If aos_migrations is empty but aos_ tables exist, the database was
    // bootstrapped from the full schema before the migration system existed.
    // Register the initial seed as already applied.
    const applied = this.getAppliedMigrations();
    if (applied.size === 0 && this.isInitialized()) {
      this.recordMigration('seed_initial', { checksum: 'bootstrap' });
      result.skipped.push('seed_initial (existing database)');
      applied.add('seed_initial');
    }

    // Read migration files from directory
    let files;
    try {
      files = fs.readdirSync(migrationsDir)
        .filter(f => f.endsWith('.sql'))
        .sort();
    } catch (err) {
      // No migrations directory is fine — nothing to apply
      return result;
    }

    for (const file of files) {
      const name = file.replace(/\.sql$/, '');
      if (applied.has(name)) {
        result.skipped.push(name);
        continue;
      }

      const filePath = path.join(migrationsDir, file);
      const sql = fs.readFileSync(filePath, 'utf-8');
      const checksum = crypto.createHash('sha256').update(sql).digest('hex').slice(0, 16);
      const startMs = Date.now();

      try {
        // Apply each statement in a transaction
        this.db.exec('BEGIN');
        try {
          // Split on semicolons, skip empty/trivially-whitespace statements
          for (const stmt of sql.split(';').map(s => s.trim()).filter(s => s.length > 0 && !s.startsWith('--'))) {
            this.db.exec(stmt);
          }
          this.db.exec('COMMIT');
        } catch (txErr) {
          this.db.exec('ROLLBACK');
          throw txErr;
        }

        const durationMs = Date.now() - startMs;
        this.recordMigration(name, { checksum, durationMs });
        result.applied.push(name);
      } catch (err) {
        result.errors.push({ name, error: err.message });
      }
    }

    return result;
  }

  // ── Device Registration ──────────────────────────────────────────────────

  /**
   * Register a new device or re-register an existing one.
   * On re-registration, generates a fresh pairing code.
   *
   * @param {object} params
   * @param {string} params.deviceId
   * @param {string} [params.deviceName]
   * @param {string} [params.deviceType]
   * @param {string} [params.softwareVersion]
   * @param {object} [params.metadata]
   * @returns {{ deviceId, deviceApiKey, paired, pairingCode, expiresAt }}
   */
  registerDevice(params) {
    const { deviceId } = params;
    if (!deviceId) throw new Error("registerDevice: deviceId required");

    const pairingCode = generatePairingCode();
    const pairingCodeHash = hashPairingCode(pairingCode);
    const expiresAt = new Date(Date.now() + 15 * 60 * 1000).toISOString();
    const pairingId = uid("pair");

    // Check if device already exists
    const existing = this.db.prepare(
      "SELECT device_id, device_api_key, paired FROM aos_frame_devices WHERE device_id = ?"
    ).get(deviceId);

    let deviceApiKey;

    if (existing) {
      // Re-registration: keep existing key, refresh pairing code
      deviceApiKey = existing.device_api_key;

      this.db.prepare(
        `UPDATE aos_frame_devices
         SET software_version = ?, metadata_json = ?, updated_at = ?
         WHERE device_id = ?`
      ).run(
        params.softwareVersion || "0.0.0",
        jsonStringify(params.metadata),
        now(),
        deviceId
      );

      // Supersede old pairing code and create new one
      this.db.prepare(
        "UPDATE aos_frame_pairing_codes SET status = 'superseded' WHERE device_id = ? AND status = 'active'"
      ).run(deviceId);

      // Delete all pairing codes for this device to free the unique index,
      // then insert the fresh one. Old codes are already superseded/expired/claimed
      // so they have no remaining value.
      this.db.prepare(
        "DELETE FROM aos_frame_pairing_codes WHERE device_id = ? AND status != 'claimed'"
      ).run(deviceId);

      this.db.prepare(
        `INSERT INTO aos_frame_pairing_codes (id, device_id, pairing_code_hash, pairing_code, expires_at, status)
         VALUES (?, ?, ?, ?, ?, 'active')`
      ).run(pairingId, deviceId, pairingCodeHash, pairingCode, expiresAt);
    } else {
      // New device
      deviceApiKey = generateDeviceKey();

      this.db.prepare(
        `INSERT INTO aos_frame_devices
          (device_id, device_api_key, device_name, device_type, software_version,
           paired, metadata_json)
         VALUES (?, ?, ?, ?, ?, 0, ?)`
      ).run(
        deviceId,
        deviceApiKey,
        params.deviceName || "Autopoiesis Frame",
        params.deviceType || "raspberry_pi",
        params.softwareVersion || "0.0.0",
        jsonStringify(params.metadata)
      );

      this.db.prepare(
        `INSERT INTO aos_frame_pairing_codes (id, device_id, pairing_code_hash, pairing_code, expires_at, status)
         VALUES (?, ?, ?, ?, ?, 'active')`
      ).run(pairingId, deviceId, pairingCodeHash, pairingCode, expiresAt);

      // Create default settings row
      this.db.prepare(
        "INSERT INTO aos_frame_device_settings (device_id, settings_json) VALUES (?, '{}')"
      ).run(deviceId);
    }

    return {
      deviceId,
      deviceApiKey,
      paired: existing ? !!existing.paired : false,
      pairingCode,
      expiresAt,
    };
  }

  // ── Device Authentication ────────────────────────────────────────────────

  /**
   * Authenticate a device by API key. Returns device row or null.
   *
   * @param {string} deviceId
   * @param {string} deviceApiKey
   * @returns {object|null} Device record (columns as camelCase via _mapDevice)
   */
  authenticateDevice(deviceId, deviceApiKey) {
    if (!deviceId || !deviceApiKey) return null;
    const row = this.db.prepare(
      "SELECT * FROM aos_frame_devices WHERE device_id = ? AND device_api_key = ?"
    ).get(deviceId, deviceApiKey);
    return row ? this._mapDevice(row) : null;
  }

  /**
   * Get device by ID (no auth check).
   * @param {string} deviceId
   * @returns {object|null}
   */
  getDevice(deviceId) {
    const row = this.db.prepare(
      "SELECT * FROM aos_frame_devices WHERE device_id = ?"
    ).get(deviceId);
    return row ? this._mapDevice(row) : null;
  }

  // ── Pairing ──────────────────────────────────────────────────────────────

  /**
   * Get pairing status for a device.
   *
   * @param {string} deviceId
   * @returns {{ ok, paired, ownerUserId, pairing? }}
   */
  getPairingStatus(deviceId) {
    const device = this.db.prepare(
      "SELECT device_id, paired, owner_user_id FROM aos_frame_devices WHERE device_id = ?"
    ).get(deviceId);
    if (!device) return { ok: false, error: "Device not found" };

    if (device.paired) {
      return {
        ok: true,
        paired: true,
        ownerUserId: device.owner_user_id,
        pairing: { status: "completed" },
      };
    }

    const code = this.db.prepare(
      "SELECT pairing_code, expires_at, status FROM aos_frame_pairing_codes WHERE device_id = ? AND status = 'active' ORDER BY created_at DESC LIMIT 1"
    ).get(deviceId);

    return {
      ok: true,
      paired: false,
      ownerUserId: null,
      pairing: code
        ? {
            pairingCode: code.pairing_code,
            expiresAt: code.expires_at,
            status: code.status === "active" && new Date(code.expires_at) > new Date() ? "pending" : "expired",
          }
        : { status: "none" },
    };
  }

  /**
   * Claim (pair) a device by pairing code.
   *
   * @param {string} pairingCode
   * @param {string} ownerUserId
   * @returns {{ ok, deviceId?, error? }}
   */
  claimPairingCode(pairingCode, ownerUserId) {
    if (!pairingCode || !ownerUserId) {
      return { ok: false, error: "pairingCode and ownerUserId required" };
    }

    const codeHash = hashPairingCode(pairingCode);
    const codeRow = this.db.prepare(
      "SELECT id, device_id, expires_at, status FROM aos_frame_pairing_codes WHERE pairing_code_hash = ? AND status = 'active'"
    ).get(codeHash);

    if (!codeRow) {
      return { ok: false, error: "Invalid or expired pairing code" };
    }

    if (new Date(codeRow.expires_at) <= new Date()) {
      this.db.prepare(
        "UPDATE aos_frame_pairing_codes SET status = 'expired' WHERE id = ?"
      ).run(codeRow.id);
      return { ok: false, error: "Pairing code expired" };
    }

    // Mark code as claimed
    this.db.prepare(
      "UPDATE aos_frame_pairing_codes SET status = 'claimed', claimed_by_user_id = ?, claimed_at = ? WHERE id = ?"
    ).run(ownerUserId, now(), codeRow.id);

    // Update device
    this.db.prepare(
      `UPDATE aos_frame_devices
       SET paired = 1, owner_user_id = ?, updated_at = ?
       WHERE device_id = ?`
    ).run(ownerUserId, now(), codeRow.device_id);

    return { ok: true, deviceId: codeRow.device_id, paired: true, ownerUserId };
  }

  // ── Settings ─────────────────────────────────────────────────────────────

  /**
   * Read device settings.
   *
   * @param {string} deviceId
   * @returns {{ ok, settings, updatedAt, ownerPreferences?, ownerPreferencesUpdatedAt? }}
   */
  getSettings(deviceId) {
    const row = this.db.prepare(
      "SELECT settings_json, updated_at FROM aos_frame_device_settings WHERE device_id = ?"
    ).get(deviceId);
    if (!row) return { ok: false, error: "Device settings not found" };

    const result = {
      ok: true,
      settings: jsonParse(row.settings_json, {}),
      updatedAt: row.updated_at,
    };

    // Attach owner preferences if device has owner with overrides
    const device = this.db.prepare(
      "SELECT owner_user_id FROM aos_frame_devices WHERE device_id = ?"
    ).get(deviceId);
    if (device && device.owner_user_id) {
      const prefs = this.db.prepare(
        "SELECT preferences_json, updated_at FROM aos_frame_user_preferences WHERE user_id = ?"
      ).get(device.owner_user_id);
      if (prefs && prefs.preferences_json && prefs.preferences_json !== "{}") {
        result.ownerPreferences = jsonParse(prefs.preferences_json, {});
        result.ownerPreferencesUpdatedAt = prefs.updated_at;
      }
    }

    return result;
  }

  /**
   * Push (write) device settings with updatedAt conflict resolution.
   *
   * @param {string} deviceId
   * @param {object} settings
   * @param {string} incomingUpdatedAt
   * @returns {{ ok, settings?, updatedAt?, conflict?, reason? }}
   */
  pushSettings(deviceId, settings, incomingUpdatedAt) {
    const current = this.db.prepare(
      "SELECT settings_json, updated_at FROM aos_frame_device_settings WHERE device_id = ?"
    ).get(deviceId);
    if (!current) return { ok: false, error: "Device settings not found" };

    const incoming = incomingUpdatedAt || now();
    const existing = current.updated_at;

    if (existing && incoming < existing) {
      // Stale write: reject with conflict
      return {
        ok: false,
        error: "settings conflict",
        reason: "stale_write",
        conflict: true,
        settings: jsonParse(current.settings_json, {}),
        updatedAt: existing,
      };
    }

    // Newer or equal: merge and write
    const merged = { ...jsonParse(current.settings_json, {}), ...settings, updatedAt: incoming };
    this.db.prepare(
      "UPDATE aos_frame_device_settings SET settings_json = ?, updated_at = ? WHERE device_id = ?"
    ).run(jsonStringify(merged), incoming, deviceId);

    return {
      ok: true,
      settings: merged,
      updatedAt: incoming,
    };
  }

  // ── User Preferences ─────────────────────────────────────────────────────

  /**
   * Get user preferences.
   * @param {string} userId
   * @returns {{ preferences, updatedAt }}
   */
  getUserPreferences(userId) {
    const row = this.db.prepare(
      "SELECT preferences_json, updated_at FROM aos_frame_user_preferences WHERE user_id = ?"
    ).get(userId);
    if (!row) return { preferences: {}, updatedAt: null };
    return { preferences: jsonParse(row.preferences_json, {}), updatedAt: row.updated_at };
  }

  /**
   * Set user preferences (owner-level cascade).
   * @param {string} userId
   * @param {object} preferences
   * @returns {{ ok, preferences, updatedAt }}
   */
  setUserPreferences(userId, preferences) {
    const ts = now();
    const json = jsonStringify(preferences);
    const existing = this.db.prepare(
      "SELECT user_id FROM aos_frame_user_preferences WHERE user_id = ?"
    ).get(userId);
    if (existing) {
      this.db.prepare(
        "UPDATE aos_frame_user_preferences SET preferences_json = ?, updated_at = ? WHERE user_id = ?"
      ).run(json, ts, userId);
    } else {
      this.db.prepare(
        "INSERT INTO aos_frame_user_preferences (user_id, preferences_json, updated_at) VALUES (?, ?, ?)"
      ).run(userId, json, ts);
    }
    return { ok: true, preferences, updatedAt: ts };
  }

  // ── Heartbeat ────────────────────────────────────────────────────────────

  /**
   * Ingest a heartbeat from a device.
   *
   * @param {string} deviceId
   * @param {object} payload
   * @param {string} [payload.softwareVersion]
   * @param {object} [payload.releaseState] - Device release state (from release-state.json)
   * @param {Array}  [payload.events]
   * @param {object} [payload.broadcastDeliveries]
   * @returns {{ ok, heartbeatAt, eventAck?, deliveryAck? }}
   */
  ingestHeartbeat(deviceId, payload) {
    const ts = now();

    // Insert heartbeat record
    this.db.prepare(
      "INSERT INTO aos_heartbeats (id, device_id, payload_json) VALUES (?, ?, ?)"
    ).run(uid("hb"), deviceId, jsonStringify(payload));

    // Update device status
    // network_online/network_type come from top-level payload fields
    const networkOnline = payload.networkOnline != null ? (payload.networkOnline ? 1 : 0) : 0;
    const networkType = payload.networkType || null;

    // Release state from device (release-state.json)
    const rs = payload.releaseState || null;
    const releaseStatus = rs ? (rs.status || 'idle') : 'idle';
    const releaseTargetVersion = rs ? (rs.targetVersion || rs.previousVersion || null) : null;
    const releaseChannel = rs ? (rs.channel || null) : null;
    const releaseUpdatedAt = rs ? (rs.updatedAt || ts) : null;
    const releaseError = rs ? (rs.error || null) : null;

    this.db.prepare(
      `UPDATE aos_frame_devices
       SET last_heartbeat_at = ?,
           software_version = COALESCE(?, software_version),
           current_mode = COALESCE(?, current_mode),
           current_artwork_id = COALESCE(?, current_artwork_id),
           network_online = ?,
           network_type = COALESCE(?, network_type),
           storage_status_json = ?,
           release_status = ?,
           release_target_version = ?,
           release_channel = COALESCE(?, release_channel),
           release_updated_at = ?,
           release_error = ?,
           updated_at = ?
       WHERE device_id = ?`
    ).run(
      ts,
      payload.softwareVersion || null,
      payload.currentMode || null,
      payload.currentArtworkId || null,
      networkOnline,
      networkType,
      payload.storageStatus ? jsonStringify(payload.storageStatus) : '{}',
      releaseStatus,
      releaseTargetVersion,
      releaseChannel,
      releaseUpdatedAt,
      releaseError,
      ts,
      deviceId
    );

    // Event ingestion
    let eventAck = null;
    if (payload.events && payload.events.length > 0) {
      const upsertEvent = this.db.prepare(
        `INSERT INTO aos_device_events (id, device_id, event_key, source, event_type, status, observed_at, event_json)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (device_id, event_key) DO UPDATE SET
           status = excluded.status,
           event_json = excluded.event_json,
           updated_at = datetime('now')`
      );

      let lastObserved = null;
      let lastKey = null;
      for (const evt of payload.events) {
        const key = evt.eventKey || uid("evt");
        upsertEvent.run(
          uid("evt"),
          deviceId,
          key,
          evt.source || "heartbeat",
          evt.eventType || "unknown",
          evt.status || "observed",
          evt.observedAt || ts,
          jsonStringify(evt)
        );
        lastObserved = evt.observedAt || ts;
        lastKey = key;
      }

      eventAck = {
        accepted: true,
        acceptedCount: payload.events.length,
        acceptedThroughObservedAt: lastObserved,
        acceptedThroughEventKey: lastKey,
        cursor: {
          status: "accepted",
          acceptedAt: ts,
          acceptedThroughObservedAt: lastObserved,
          acceptedThroughEventKey: lastKey,
        },
      };
    }

    // Broadcast delivery ingestion
    let deliveryAck = null;
    const deliveries = payload.broadcastDeliveries && payload.broadcastDeliveries.deliveries;
    if (deliveries && deliveries.length > 0) {
      const upsertDelivery = this.db.prepare(
        `INSERT INTO aos_broadcast_deliveries
          (id, broadcast_id, device_id, command_id, user_id, status,
           delivered_at, displayed_at, dismissed_at, acknowledged_at, completed_at, error)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (broadcast_id, device_id) DO UPDATE SET
           status = excluded.status,
           delivered_at = COALESCE(excluded.delivered_at, delivered_at),
           displayed_at = COALESCE(excluded.displayed_at, displayed_at),
           dismissed_at = COALESCE(excluded.dismissed_at, dismissed_at),
           acknowledged_at = COALESCE(excluded.acknowledged_at, acknowledged_at),
           completed_at = COALESCE(excluded.completed_at, completed_at),
           updated_at = datetime('now')`
      );

      const device = this.db.prepare(
        "SELECT owner_user_id FROM aos_frame_devices WHERE device_id = ?"
      ).get(deviceId);

      for (const d of deliveries) {
        upsertDelivery.run(
          uid("del"),
          d.broadcastId,
          deviceId,
          d.commandId || null,
          device ? device.owner_user_id : null,
          d.status || "received",
          d.receivedAt || d.deliveredAt || null,
          d.shownAt || d.displayedAt || null,
          d.dismissedAt || null,
          d.acknowledgedAt || null,
          d.completedAt || null,
          d.error || null
        );
      }

      deliveryAck = {
        accepted: true,
        acceptedCount: deliveries.length,
      };
    }

    return {
      ok: true,
      heartbeatAt: ts,
      eventAck,
      deliveryAck,
    };
  }

  /**
   * Get latest heartbeat for a device.
   * @param {string} deviceId
   * @returns {object|null}
   */
  getLatestHeartbeat(deviceId) {
    const row = this.db.prepare(
      "SELECT * FROM aos_heartbeats WHERE device_id = ? ORDER BY created_at DESC LIMIT 1"
    ).get(deviceId);
    if (!row) return null;
    return {
      id: row.id,
      deviceId: row.device_id,
      payload: jsonParse(row.payload_json, {}),
      createdAt: row.created_at,
    };
  }

  // ── Device Commands ──────────────────────────────────────────────────────

  /**
   * Queue a command for a device.
   *
   * @param {string} deviceId
   * @param {string} commandType
   * @param {object} [payload]
   * @param {string} [risk='medium']
   * @returns {{ ok, command }}
   */
  queueCommand(deviceId, commandType, payload = {}, risk = "medium") {
    const id = uid("cmd");
    const ts = now();
    this.db.prepare(
      `INSERT INTO aos_device_commands
        (id, device_id, command_type, payload_json, status, created_at, updated_at)
       VALUES (?, ?, ?, ?, 'queued', ?, ?)`
    ).run(id, deviceId, commandType, jsonStringify(payload), ts, ts);

    return {
      ok: true,
      command: {
        commandId: id,
        commandType,
        type: commandType,
        status: "queued",
        risk,
        payload,
        createdAt: ts,
        updatedAt: ts,
      },
    };
  }

  /**
   * Get pending commands for a device.
   *
   * @param {string} deviceId
   * @returns {Array}
   */
  getPendingCommands(deviceId) {
    const rows = this.db.prepare(
      `SELECT * FROM aos_device_commands
       WHERE device_id = ? AND status IN ('queued', 'sent')
       ORDER BY created_at ASC`
    ).all(deviceId);

    return rows.map(r => ({
      commandId: r.id,
      commandType: r.command_type,
      type: r.command_type,
      status: r.status,
      payload: jsonParse(r.payload_json, {}),
      createdAt: r.created_at,
      updatedAt: r.updated_at,
    }));
  }

  /**
   * Acknowledge a command.
   *
   * @param {string} deviceId
   * @param {string} commandId
   * @param {string} ackStatus
   * @returns {{ ok, commandId, status, error? }}
   */
  acknowledgeCommand(deviceId, commandId, ackStatus = "acknowledged") {
    const cmd = this.db.prepare(
      "SELECT id, status FROM aos_device_commands WHERE id = ? AND device_id = ?"
    ).get(commandId, deviceId);
    if (!cmd) return { ok: false, error: "Command not found" };

    const ts = now();
    this.db.prepare(
      `UPDATE aos_device_commands
       SET status = ?, last_ack_status = ?, last_ack_at = ?, acknowledged_at = ?, updated_at = ?
       WHERE id = ?`
    ).run(ackStatus, ackStatus, ts, ts, ts, commandId);

    return { ok: true, commandId, status: ackStatus, updatedAt: ts };
  }

  /**
   * Get command by ID.
   * @param {string} commandId
   * @returns {object|null}
   */
  getCommand(commandId) {
    const row = this.db.prepare(
      "SELECT * FROM aos_device_commands WHERE id = ?"
    ).get(commandId);
    if (!row) return null;
    return {
      commandId: row.id,
      commandType: row.command_type,
      deviceId: row.device_id,
      status: row.status,
      payload: jsonParse(row.payload_json, {}),
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    };
  }

  // ── Device Events ────────────────────────────────────────────────────────

  /**
   * Get events for a device.
   *
   * @param {string} deviceId
   * @param {number} [limit=50]
   * @returns {Array}
   */
  getDeviceEvents(deviceId, limit = 50) {
    const rows = this.db.prepare(
      "SELECT * FROM aos_device_events WHERE device_id = ? ORDER BY observed_at DESC LIMIT ?"
    ).all(deviceId, limit);
    return rows.map(r => ({
      id: r.id,
      eventKey: r.event_key,
      source: r.source,
      eventType: r.event_type,
      status: r.status,
      observedAt: r.observed_at,
      event: jsonParse(r.event_json, {}),
      ingestedAt: r.ingested_at,
    }));
  }

  // ── Broadcast Deliveries ─────────────────────────────────────────────────

  /**
   * Get broadcast deliveries, optionally filtered.
   *
   * @param {object} [filters]
   * @param {string} [filters.deviceId]
   * @param {string} [filters.status]
   * @param {string} [filters.broadcastId]
   * @returns {Array}
   */
  getBroadcastDeliveries(filters = {}) {
    let sql = "SELECT * FROM aos_broadcast_deliveries WHERE 1=1";
    const params = [];
    if (filters.deviceId) { sql += " AND device_id = ?"; params.push(filters.deviceId); }
    if (filters.status) { sql += " AND status = ?"; params.push(filters.status); }
    if (filters.broadcastId) { sql += " AND broadcast_id = ?"; params.push(filters.broadcastId); }
    sql += " ORDER BY created_at DESC";

    const rows = this.db.prepare(sql).all(...params);
    return rows.map(r => ({
      id: r.id,
      broadcastId: r.broadcast_id,
      deviceId: r.device_id,
      commandId: r.command_id,
      userId: r.user_id,
      status: r.status,
      deliveredAt: r.delivered_at,
      displayedAt: r.displayed_at,
      dismissedAt: r.dismissed_at,
      acknowledgedAt: r.acknowledged_at,
      completedAt: r.completed_at,
      error: r.error,
      createdAt: r.created_at,
      updatedAt: r.updated_at,
    }));
  }

  // ── Releases ─────────────────────────────────────────────────────────────

  /**
   * Get latest release for a channel.
   *
   * @param {string} channel
   * @returns {object|null}
   */
  getLatestRelease(channel = "stable") {
    const row = this.db.prepare(
      "SELECT * FROM aos_releases WHERE channel = ? AND status = 'published' ORDER BY published_at DESC LIMIT 1"
    ).get(channel);
    if (!row) return null;
    return {
      id: row.id,
      version: row.version,
      channel: row.channel,
      artifactUrl: row.artifact_url,
      checksum: row.checksum,
      notes: row.notes,
      changelogUrl: row.changelog_url,
      rollbackNotes: row.rollback_notes,
      minimumVersion: row.minimum_version,
      publishedAt: row.published_at,
    };
  }

  /**
   * Create a release.
   * @param {object} params
   * @returns {{ ok, release }}
   */
  createRelease(params) {
    const id = uid("rel");
    const ts = now();
    const channel = params.channel || "stable";

    // Check for existing release with same version+channel (unique constraint)
    const existing = this.db.prepare(
      "SELECT id FROM aos_releases WHERE version = ? AND channel = ?"
    ).get(params.version, channel);

    if (existing) {
      // Update existing release
      this.db.prepare(
        `UPDATE aos_releases
         SET status = ?, artifact_url = ?, checksum = ?, notes = ?, changelog_url = ?,
             rollback_notes = ?, minimum_version = ?, rollout_percent = ?,
             published_at = ?
         WHERE id = ?`
      ).run(
        params.status || "draft",
        params.artifactUrl || null,
        params.checksum || null,
        params.notes || null,
        params.changelogUrl || null,
        params.rollbackNotes || null,
        params.minimumVersion || null,
        params.rolloutPercent != null ? params.rolloutPercent : 100.0,
        params.status === "published" ? ts : null,
        existing.id
      );
      return { ok: true, release: { id: existing.id, ...params, updatedAt: ts } };
    }

    this.db.prepare(
      `INSERT INTO aos_releases
        (id, version, channel, status, artifact_url, checksum, notes, changelog_url,
         rollback_notes, minimum_version, rollout_percent, created_by, published_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    ).run(
      id,
      params.version,
      channel,
      params.status || "draft",
      params.artifactUrl || null,
      params.checksum || null,
      params.notes || null,
      params.changelogUrl || null,
      params.rollbackNotes || null,
      params.minimumVersion || null,
      params.rolloutPercent != null ? params.rolloutPercent : 100.0,
      params.createdBy || "system",
      params.status === "published" ? ts : null
    );
    return { ok: true, release: { id, ...params, createdAt: ts } };
  }

  // ── Subscriptions ────────────────────────────────────────────────────────

  /**
   * Get subscription for a user.
   * @param {string} userId
   * @returns {object|null}
   */
  getSubscription(userId) {
    const row = this.db.prepare(
      "SELECT * FROM aos_subscriptions WHERE user_id = ?"
    ).get(userId);
    if (!row) return null;
    return {
      id: row.id,
      userId: row.user_id,
      plan: row.plan,
      status: row.status,
      provider: row.provider,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    };
  }

  /**
   * Create or update a subscription.
   * @param {string} userId
   * @param {object} params
   * @returns {{ ok, subscription }}
   */
  upsertSubscription(userId, params) {
    const ts = now();
    const existing = this.db.prepare(
      "SELECT id FROM aos_subscriptions WHERE user_id = ?"
    ).get(userId);

    if (existing) {
      this.db.prepare(
        `UPDATE aos_subscriptions
         SET plan = ?, status = ?, provider = ?, updated_at = ?
         WHERE user_id = ?`
      ).run(params.plan || "free", params.status || "inactive", params.provider || "manual", ts, userId);
    } else {
      this.db.prepare(
        `INSERT INTO aos_subscriptions (id, user_id, plan, status, provider)
         VALUES (?, ?, ?, ?, ?)`
      ).run(uid("sub"), userId, params.plan || "free", params.status || "inactive", params.provider || "manual");
    }

    return { ok: true, subscription: this.getSubscription(userId) };
  }

  // ── Artwork Likes ────────────────────────────────────────────────────────

  /**
   * Like an artwork.
   * @param {string} userId
   * @param {string} artworkId
   * @returns {{ ok, liked }}
   */
  likeArtwork(userId, artworkId) {
    this.db.prepare(
      "INSERT OR IGNORE INTO aos_artwork_likes (user_id, artwork_id) VALUES (?, ?)"
    ).run(userId, artworkId);
    return { ok: true, liked: true, userId, artworkId };
  }

  /**
   * Unlike an artwork.
   * @param {string} userId
   * @param {string} artworkId
   * @returns {{ ok, liked }}
   */
  unlikeArtwork(userId, artworkId) {
    this.db.prepare(
      "DELETE FROM aos_artwork_likes WHERE user_id = ? AND artwork_id = ?"
    ).run(userId, artworkId);
    return { ok: true, liked: false, userId, artworkId };
  }

  /**
   * Get liked artworks for a user.
   * @param {string} userId
   * @returns {Array<string>} artwork IDs
   */
  getLikedArtworks(userId) {
    const rows = this.db.prepare(
      "SELECT artwork_id FROM aos_artwork_likes WHERE user_id = ? ORDER BY created_at DESC"
    ).all(userId);
    return rows.map(r => r.artwork_id);
  }

  // ── Stream Content ─────────────────────────────────────────────────────

  /**
   * Get active content items from aos_broadcasts for stream composition.
   *
   * Returns published, non-expired broadcasts ordered by priority desc, then
   * created_at desc. Filters by target_type/target_value for device/owner/tier
   * targeting, and respects starts_at/expires_at scheduling.
   *
   * @param {object} context
   * @param {string} context.deviceId
   * @param {string} [context.ownerUserId]
   * @param {string} [context.subscriptionTier]
   * @param {string[]} [context.activeArtists]
   * @param {number} [context.limit=30]
   * @returns {Array<object>}
   */
  getStreamContent(context = {}) {
    const { deviceId, ownerUserId, subscriptionTier, activeArtists = [] } = context;
    const limit = context.limit || 30;
    const nowISO = now();

    // Build set of already-displayed broadcast IDs for this device (dedup)
    const displayedSet = new Set();
    if (deviceId) {
      try {
        const displayed = this.db.prepare(
          `SELECT broadcast_id FROM aos_broadcast_deliveries
           WHERE device_id = ? AND status IN ('displayed', 'completed', 'acknowledged')`
        ).all(deviceId);
        for (const row of displayed) displayedSet.add(row.broadcast_id);
      } catch (_) { /* table may not exist in fresh bootstrap */ }
    }

    // Fetch all published, non-expired broadcasts
    const rows = this.db.prepare(
      `SELECT * FROM aos_broadcasts
       WHERE status = 'published'
         AND (expires_at IS NULL OR expires_at > ?)
         AND (starts_at IS NULL OR starts_at <= ?)
       ORDER BY
         CASE priority
           WHEN 'emergency' THEN 500
           WHEN 'critical' THEN 400
           WHEN 'high' THEN 300
           WHEN 'normal' THEN 200
           WHEN 'low' THEN 100
           ELSE 200
         END DESC,
         created_at DESC`
    ).all(nowISO, nowISO);

    // Filter by targeting
    const filtered = rows.filter(row => {
      const targetType = row.target_type;
      const targetValue = row.target_value;

      // "all" targets pass through
      if (!targetType || targetType === 'all') return true;

      // Parse target_value as comma-separated list
      const values = String(targetValue || '')
        .split(',')
        .map(v => v.trim())
        .filter(Boolean);

      if (values.length === 0) return true;

      switch (targetType) {
        case 'device':
        case 'device_id':
          return deviceId ? values.includes(deviceId) : false;
        case 'owner':
        case 'user_id':
          return ownerUserId ? values.includes(ownerUserId) : false;
        case 'tier':
        case 'subscription_tier':
          return subscriptionTier ? values.includes(subscriptionTier) : false;
        case 'exclude_device':
          return deviceId ? !values.includes(deviceId) : true;
        case 'exclude_owner':
        case 'exclude_user':
          return ownerUserId ? !values.includes(ownerUserId) : true;
        default:
          return true;
      }
    });

    // Map rows to stream items with source attribution and delivery dedup
    const items = filtered.filter(row => {
      // Exclude already-displayed items (unless they are emergency/critical priority)
      if (displayedSet.has(row.id)) {
        const rank = _priorityRank(row.priority);
        return rank >= 400; // keep emergency (500) and critical (400)
      }
      return true;
    }).slice(0, limit).map(row => {
      const category = _broadcastTypeToCategory(row.type);
      const item = {
        id: row.id,
        source: category === 'broadcast' ? 'admin' : 'admin',
        type: row.type || 'content',
        category,
        title: row.title,
        priority: row.priority || 'normal',
        cacheEligible: !!row.cache_allowed,
        soundRequired: !!(row.sound_allowed && row.type === 'video'),
      };

      if (row.body) item.body = row.body;
      if (row.media_url) {
        item.mediaUrl = row.media_url;
      }
      if (row.thumbnail_url) {
        item.thumbnailUrl = row.thumbnail_url;
      } else if (row.media_url && (row.type === 'image' || row.type === 'artwork')) {
        item.thumbnailUrl = row.media_url;
      }
      if (row.duration) item.duration = row.duration;
      if (row.starts_at) item.startsAt = row.starts_at;
      if (row.expires_at) item.expiresAt = row.expires_at;

      // Artist attribution from dedicated columns
      if (row.artist) item.artist = row.artist;
      if (row.artist_id) item.artistId = row.artist_id;

      // Additional metadata from metadata_json
      const meta = jsonParse(row.metadata_json || '{}', {});
      if (!item.artist && meta.artist) item.artist = meta.artist;
      if (!item.artistId && meta.artistId) item.artistId = meta.artistId;
      if (meta.url) item.url = meta.url;
      if (!item.thumbnailUrl && meta.thumbnailUrl) item.thumbnailUrl = meta.thumbnailUrl;
      if (meta.targeting) item.targeting = meta.targeting;

      return item;
    });

    // Boost artist-matched items within priority groups
    if (activeArtists.length > 0) {
      const lowerArtists = activeArtists.map(a => String(a).toLowerCase());
      items.sort((a, b) => {
        const pa = _priorityRank(a.priority);
        const pb = _priorityRank(b.priority);
        if (pa !== pb) return pb - pa;
        const am = a.artistId && lowerArtists.includes(String(a.artistId).toLowerCase()) ? 1 : 0;
        const bm = b.artistId && lowerArtists.includes(String(b.artistId).toLowerCase()) ? 1 : 0;
        return bm - am;
      });
    }

    return items;
  }

  /**
   * Get active (published, non-expired) broadcast count for monitoring.
   * @returns {number}
   */
  getActiveBroadcastCount() {
    const nowISO = now();
    const row = this.db.prepare(
      `SELECT count(*) AS cnt FROM aos_broadcasts
       WHERE status = 'published'
         AND (expires_at IS NULL OR expires_at > ?)
         AND (starts_at IS NULL OR starts_at <= ?)`
    ).get(nowISO, nowISO);
    return row ? row.cnt : 0;
  }

  // ── Broadcast Content Management ──────────────────────────────────────────

  /**
   * Create a new broadcast / content item in aos_broadcasts.
   * @param {object} data
   * @param {string} data.id          – Optional custom ID (auto-generated if omitted)
   * @param {string} data.title
   * @param {string} [data.body]
   * @param {string} [data.type]      – Content type (default: 'system_notice')
   * @param {string} [data.mediaUrl]
   * @param {string} [data.thumbnailUrl]
   * @param {string} [data.artist]
   * @param {string} [data.artistId]
   * @param {string} [data.targetType] – Targeting type (default: 'all')
   * @param {string} [data.targetValue]
   * @param {string} [data.priority]   – Priority level (default: 'normal')
   * @param {number} [data.duration]   – Display duration in seconds
   * @param {string} [data.startsAt]   – Scheduled start ISO timestamp
   * @param {string} [data.expiresAt]  – Expiry ISO timestamp
   * @param {number} [data.repeatCount]
   * @param {boolean} [data.dismissible]
   * @param {boolean} [data.cacheAllowed]
   * @param {boolean} [data.soundAllowed]
   * @param {string} [data.status]     – 'draft' | 'published' | 'archived' (default: 'draft')
   * @param {string} data.createdBy    – User ID of the creator
   * @param {object} [data.metadata]   – Arbitrary JSON metadata
   * @returns {object} Created broadcast row
   */
  createBroadcast(data = {}) {
    const id = data.id || uid("bcast");
    const stmt = this.db.prepare(`
      INSERT INTO aos_broadcasts (
        id, title, body, type, media_url, thumbnail_url, artist, artist_id,
        target_type, target_value, priority, duration,
        starts_at, expires_at, repeat_count,
        dismissible, cache_allowed, sound_allowed,
        status, created_by, metadata_json
      ) VALUES (
        ?, ?, ?, ?, ?, ?, ?, ?,
        ?, ?, ?, ?,
        ?, ?, ?,
        ?, ?, ?,
        ?, ?, ?
      )
    `);
    stmt.run(
      id,
      data.title || '',
      data.body || null,
      data.type || 'system_notice',
      data.mediaUrl || null,
      data.thumbnailUrl || null,
      data.artist || null,
      data.artistId || null,
      data.targetType || 'all',
      data.targetValue || '',
      data.priority || 'normal',
      data.duration || null,
      data.startsAt || null,
      data.expiresAt || null,
      data.repeatCount || 0,
      data.dismissible !== undefined ? (data.dismissible ? 1 : 0) : 1,
      data.cacheAllowed !== undefined ? (data.cacheAllowed ? 1 : 0) : 0,
      data.soundAllowed !== undefined ? (data.soundAllowed ? 1 : 0) : 1,
      data.status || 'draft',
      data.createdBy || 'system',
      jsonStringify(data.metadata || {})
    );
    return this.getBroadcast(id);
  }

  /**
   * Get a single broadcast by ID.
   * @param {string} id
   * @returns {object|null} Mapped broadcast or null
   */
  getBroadcast(id) {
    const row = this.db.prepare('SELECT * FROM aos_broadcasts WHERE id = ?').get(id);
    return row ? this._mapBroadcast(row) : null;
  }

  /**
   * List broadcasts with optional filters and pagination.
   * @param {object} [filters]
   * @param {string} [filters.status]      – Filter by status
   * @param {string} [filters.type]        – Filter by content type
   * @param {string} [filters.priority]    – Filter by priority
   * @param {string} [filters.artistId]    – Filter by artist ID
   * @param {string} [filters.targetType]  – Filter by target type
   * @param {string} [filters.createdBy]   – Filter by creator
   * @param {boolean} [filters.activeOnly] – Only published, non-expired (default: false)
   * @param {number} [filters.limit]       – Max results (default: 50, max: 200)
   * @param {number} [filters.offset]      – Offset for pagination
   * @param {string} [filters.sortBy]      – 'created_at' | 'updated_at' | 'priority' (default: 'created_at')
   * @param {string} [filters.sortOrder]   – 'asc' | 'desc' (default: 'desc')
   * @returns {{ items: object[], total: number, limit: number, offset: number }}
   */
  listBroadcasts(filters = {}) {
    const limit = Math.min(Math.max(1, filters.limit || 50), 200);
    const offset = Math.max(0, filters.offset || 0);

    const clauses = [];
    const params = [];

    if (filters.status) { clauses.push('status = ?'); params.push(filters.status); }
    if (filters.type) { clauses.push('type = ?'); params.push(filters.type); }
    if (filters.priority) { clauses.push('priority = ?'); params.push(filters.priority); }
    if (filters.artistId) { clauses.push('artist_id = ?'); params.push(filters.artistId); }
    if (filters.targetType) { clauses.push('target_type = ?'); params.push(filters.targetType); }
    if (filters.createdBy) { clauses.push('created_by = ?'); params.push(filters.createdBy); }

    if (filters.activeOnly) {
      const nowISO = now();
      clauses.push("status = 'published'");
      clauses.push('(expires_at IS NULL OR expires_at > ?)');
      params.push(nowISO);
      clauses.push('(starts_at IS NULL OR starts_at <= ?)');
      params.push(nowISO);
    }

    const where = clauses.length > 0 ? 'WHERE ' + clauses.join(' AND ') : '';

    // Validate sort
    const allowedSorts = { 'created_at': 'created_at', 'updated_at': 'updated_at', 'priority': 'priority' };
    const sortCol = allowedSorts[filters.sortBy] || 'created_at';
    const order = filters.sortOrder === 'asc' ? 'ASC' : 'DESC';

    // For priority sort, use numeric rank
    const orderBy = sortCol === 'priority'
      ? `ORDER BY CASE priority WHEN 'emergency' THEN 500 WHEN 'critical' THEN 400 WHEN 'high' THEN 300 WHEN 'normal' THEN 200 WHEN 'low' THEN 100 ELSE 200 END ${order}`
      : `ORDER BY ${sortCol} ${order}`;

    const countRow = this.db.prepare(`SELECT count(*) AS cnt FROM aos_broadcasts ${where}`).get(...params);
    const total = countRow ? countRow.cnt : 0;

    const rows = this.db.prepare(
      `SELECT * FROM aos_broadcasts ${where} ${orderBy} LIMIT ? OFFSET ?`
    ).all(...params, limit, offset);

    return {
      items: rows.map(r => this._mapBroadcast(r)),
      total,
      limit,
      offset
    };
  }

  /**
   * Update an existing broadcast. Only provided fields are updated.
   * @param {string} id
   * @param {object} updates
   * @returns {object|null} Updated broadcast or null if not found
   */
  updateBroadcast(id, updates = {}) {
    const existing = this.db.prepare('SELECT * FROM aos_broadcasts WHERE id = ?').get(id);
    if (!existing) return null;

    const fields = [];
    const values = [];

    const columnMap = {
      title: 'title', body: 'body', type: 'type',
      mediaUrl: 'media_url', thumbnailUrl: 'thumbnail_url',
      artist: 'artist', artistId: 'artist_id',
      targetType: 'target_type', targetValue: 'target_value',
      priority: 'priority', duration: 'duration',
      startsAt: 'starts_at', expiresAt: 'expires_at',
      repeatCount: 'repeat_count', status: 'status'
    };

    for (const [key, col] of Object.entries(columnMap)) {
      if (updates[key] !== undefined) {
        fields.push(`${col} = ?`);
        values.push(updates[key]);
      }
    }

    // Boolean fields need integer conversion
    if (updates.dismissible !== undefined) {
      fields.push('dismissible = ?');
      values.push(updates.dismissible ? 1 : 0);
    }
    if (updates.cacheAllowed !== undefined) {
      fields.push('cache_allowed = ?');
      values.push(updates.cacheAllowed ? 1 : 0);
    }
    if (updates.soundAllowed !== undefined) {
      fields.push('sound_allowed = ?');
      values.push(updates.soundAllowed ? 1 : 0);
    }
    if (updates.metadata !== undefined) {
      fields.push('metadata_json = ?');
      values.push(jsonStringify(updates.metadata));
    }

    if (fields.length === 0) return this._mapBroadcast(existing);

    fields.push('updated_at = ?');
    values.push(now());
    values.push(id);

    this.db.prepare(`UPDATE aos_broadcasts SET ${fields.join(', ')} WHERE id = ?`).run(...values);
    return this.getBroadcast(id);
  }

  /**
   * Archive (soft-delete) a broadcast by setting status to 'archived'.
   * @param {string} id
   * @returns {object|null} Archived broadcast or null if not found
   */
  archiveBroadcast(id) {
    return this.updateBroadcast(id, { status: 'archived' });
  }

  /**
   * Publish a draft broadcast.
   * @param {string} id
   * @returns {object|null} Published broadcast or null
   */
  publishBroadcast(id) {
    return this.updateBroadcast(id, { status: 'published' });
  }

  /**
   * Unpublish a broadcast (set back to draft).
   * @param {string} id
   * @returns {object|null} Unpublished broadcast or null
   */
  unpublishBroadcast(id) {
    return this.updateBroadcast(id, { status: 'draft' });
  }

  /**
   * Get broadcast content statistics for admin dashboard.
   * @returns {object} Content stats
   */
  getBroadcastStats() {
    const nowISO = now();

    const statusCounts = this.db.prepare(
      `SELECT status, count(*) AS cnt FROM aos_broadcasts GROUP BY status`
    ).all().reduce((acc, r) => { acc[r.status] = r.cnt; return acc; }, {});

    const typeCounts = this.db.prepare(
      `SELECT type, count(*) AS cnt FROM aos_broadcasts GROUP BY type`
    ).all().reduce((acc, r) => { acc[r.type] = r.cnt; return acc; }, {});

    const priorityCounts = this.db.prepare(
      `SELECT priority, count(*) AS cnt FROM aos_broadcasts GROUP BY priority`
    ).all().reduce((acc, r) => { acc[r.priority] = r.cnt; return acc; }, {});

    const activeCount = this.db.prepare(
      `SELECT count(*) AS cnt FROM aos_broadcasts
       WHERE status = 'published'
         AND (expires_at IS NULL OR expires_at > ?)
         AND (starts_at IS NULL OR starts_at <= ?)`
    ).get(nowISO, nowISO).cnt;

    const expiredCount = this.db.prepare(
      `SELECT count(*) AS cnt FROM aos_broadcasts
       WHERE status = 'published' AND expires_at IS NOT NULL AND expires_at <= ?`
    ).get(nowISO).cnt;

    const scheduledCount = this.db.prepare(
      `SELECT count(*) AS cnt FROM aos_broadcasts
       WHERE status = 'published' AND starts_at IS NOT NULL AND starts_at > ?`
    ).get(nowISO).cnt;

    const artistCounts = this.db.prepare(
      `SELECT artist_id, artist, count(*) AS cnt FROM aos_broadcasts
       WHERE artist_id IS NOT NULL AND status = 'published'
       GROUP BY artist_id, artist
       ORDER BY cnt DESC LIMIT 20`
    ).all().map(r => ({ artistId: r.artist_id, artist: r.artist, count: r.cnt }));

    return {
      total: Object.values(statusCounts).reduce((a, b) => a + b, 0),
      active: activeCount,
      draft: statusCounts.draft || 0,
      published: statusCounts.published || 0,
      archived: statusCounts.archived || 0,
      expired: expiredCount,
      scheduled: scheduledCount,
      byType: typeCounts,
      byPriority: priorityCounts,
      byStatus: statusCounts,
      topArtists: artistCounts
    };
  }

  // ── Internal helpers ─────────────────────────────────────────────────────

  // ── Fleet Admin ──────────────────────────────────────────────────────

  /**
   * List all devices with optional filters.
   *
   * @param {object} [opts]
   * @param {string} [opts.ownerUserId] - Filter to devices owned by this user.
   * @param {boolean} [opts.pairedOnly] - Only include paired devices.
   * @param {number} [opts.limit] - Max results (default 100).
   * @param {number} [opts.offset] - Offset for pagination.
   * @returns {{ items: Array<object>, total: number }}
   */
  listDevices(opts = {}) {
    const { ownerUserId, pairedOnly = false, limit = 100, offset = 0 } = opts;
    const conditions = [];
    const params = [];

    if (ownerUserId) {
      conditions.push("owner_user_id = ?");
      params.push(ownerUserId);
    }
    if (pairedOnly) {
      conditions.push("paired = 1");
    }

    const where = conditions.length > 0 ? "WHERE " + conditions.join(" AND ") : "";

    const countRow = this.db.prepare(
      `SELECT COUNT(*) AS cnt FROM aos_frame_devices ${where}`
    ).get(...params);
    const total = countRow ? countRow.cnt : 0;

    const rows = this.db.prepare(
      `SELECT * FROM aos_frame_devices ${where} ORDER BY created_at DESC LIMIT ? OFFSET ?`
    ).all(...params, limit, offset);

    return {
      items: rows.map(r => this._mapDevice(r)),
      total
    };
  }

  /**
   * Count devices owned by a specific user. Used for entitlement computation.
   *
   * @param {string} userId
   * @returns {number}
   */
  countDevicesByOwner(userId) {
    if (!userId) return 0;
    const row = this.db.prepare(
      "SELECT COUNT(*) AS cnt FROM aos_frame_devices WHERE owner_user_id = ? AND paired = 1"
    ).get(userId);
    return row ? row.cnt : 0;
  }

  /**
   * List all subscriptions. Used by the admin bundle for the subscriptions view.
   *
   * @param {object} [opts]
   * @param {number} [opts.limit] - Max results (default 100).
   * @param {number} [opts.offset] - Offset for pagination.
   * @returns {{ items: Array<object>, total: number }}
   */
  listSubscriptions(opts = {}) {
    const { limit = 100, offset = 0 } = opts;
    const countRow = this.db.prepare(
      "SELECT COUNT(*) AS cnt FROM aos_subscriptions"
    ).get();
    const total = countRow ? countRow.cnt : 0;

    const rows = this.db.prepare(
      "SELECT * FROM aos_subscriptions ORDER BY created_at DESC LIMIT ? OFFSET ?"
    ).all(limit, offset);

    return {
      items: rows.map(r => ({
        subscriptionId: r.id,
        userId: r.user_id,
        status: r.status,
        plan: r.plan,
        tier: r.plan, // tier mirrors plan in the DB schema
        currentPeriodEnd: r.current_period_end || null,
        cancelAtPeriodEnd: !!r.cancel_at,
        provider: r.provider || 'manual',
        createdAt: r.created_at,
        updatedAt: r.updated_at
      })),
      total
    };
  }

  /**
   * List unique owner user IDs across all devices.
   * Used to derive user list for the admin bundle.
   *
   * @returns {Array<string>}
   */
  listOwnerUserIds() {
    const rows = this.db.prepare(
      "SELECT DISTINCT owner_user_id FROM aos_frame_devices WHERE owner_user_id IS NOT NULL AND paired = 1"
    ).all();
    return rows.map(r => r.owner_user_id);
  }

  /**
   * Map an aos_broadcasts row to a camelCase response object.
   * @param {object} row
   * @returns {object}
   */
  _mapBroadcast(row) {
    return {
      id: row.id,
      title: row.title,
      body: row.body || null,
      type: row.type,
      category: _broadcastTypeToCategory(row.type),
      mediaUrl: row.media_url || null,
      thumbnailUrl: row.thumbnail_url || null,
      artist: row.artist || null,
      artistId: row.artist_id || null,
      targetType: row.target_type,
      targetValue: row.target_value,
      priority: row.priority,
      duration: row.duration || null,
      startsAt: row.starts_at || null,
      expiresAt: row.expires_at || null,
      repeatCount: row.repeat_count,
      dismissible: !!row.dismissible,
      cacheAllowed: !!row.cache_allowed,
      soundAllowed: !!row.sound_allowed,
      status: row.status,
      createdBy: row.created_by,
      metadata: jsonParse(row.metadata_json, {}),
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    };
  }

  _mapDevice(row) {
    return {
      deviceId: row.device_id,
      deviceApiKey: row.device_api_key,
      ownerUserId: row.owner_user_id,
      deviceName: row.device_name,
      deviceType: row.device_type,
      softwareVersion: row.software_version,
      updateChannel: row.update_channel,
      paired: !!row.paired,
      remoteEnabled: !!row.remote_enabled,
      subscriptionStatus: row.subscription_status,
      lastHeartbeatAt: row.last_heartbeat_at,
      currentMode: row.current_mode,
      currentArtworkId: row.current_artwork_id,
      networkOnline: !!row.network_online,
      networkType: row.network_type,
      storageStatus: jsonParse(row.storage_status_json, {}),
      metadata: jsonParse(row.metadata_json, {}),
      releaseStatus: row.release_status || 'idle',
      releaseTargetVersion: row.release_target_version || null,
      releaseChannel: row.release_channel || null,
      releaseUpdatedAt: row.release_updated_at || null,
      releaseError: row.release_error || null,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    };
  }
}

module.exports = AosDb;
