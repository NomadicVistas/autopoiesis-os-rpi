#!/usr/bin/env node
/**
 * AOS Frames — Hosted API Server
 *
 * Database-backed API server for the Autopoiesis OS Frames platform.
 * Uses AosDb (better-sqlite3) for all data operations against the aos_ tables.
 * Implements the same route contract as the mock hosted API for transparent
 * device-side compatibility.
 *
 * Usage:
 *   node hosted-api/server.js
 *   AOS_DB=./data/aos.db AOS_PORT=3140 node hosted-api/server.js
 *
 * Endpoints:
 *   POST /frames/device/register                    – Device registration + pairing code
 *   GET  /frames/device/:id/pairing-status          – Pairing status poll
 *   GET  /frames/device/:id/settings                – Read device settings
 *   POST /frames/device/:id/settings                – Push device settings
 *   POST /frames/device/:id/heartbeat               – Heartbeat + event ingestion
 *   GET  /frames/device/:id/stream                  – Content stream
 *   GET  /frames/device/:id/feed                    – Feed alias
 *   POST /frames/device/:id/commands/:cmdId/ack     – Command acknowledgement
 *   GET  /frames/device/:id/release                 – Release check
 *   GET  /frames/device/:id/admin-snapshot          – Admin device snapshot
 *   POST /frames/artworks/:id/like                  – Like artwork
 *   GET  /frames/admin/bundle                       – Online admin dashboard bundle
 *   GET  /frames/admin/broadcast-deliveries         – Admin: list broadcast deliveries
 *   GET  /frames/admin/broadcast-deliveries/:id     – Admin: per-broadcast delivery detail
 *   POST /frames/admin/subscriptions               – Admin: create subscription
 *   GET  /frames/admin/subscriptions/:userId       – Admin: get subscription + entitlements
 *   PATCH /frames/admin/subscriptions/:userId      – Admin: update subscription
 *   POST /frames/admin/subscriptions/:userId/cancel – Admin: cancel subscription
 *   POST /frames/admin/devices/:id/actions         – Admin: queue remote action
 *   PATCH /frames/admin/devices/:id                – Admin: update device properties
 */

"use strict";

const http = require("http");
const path = require("path");
const fs = require("fs");
const AosDb = require("./db");

// ── Configuration ────────────────────────────────────────────────────────────

const PORT = Number(process.env.AOS_PORT || process.env.PORT || 3140);
const DB_PATH = process.env.AOS_DB || path.resolve(__dirname, "..", "data", "aos.db");
const HOST = process.env.AOS_HOST || "127.0.0.1";

// ── Database bootstrap ───────────────────────────────────────────────────────

function ensureDatabase(dbPath) {
  const dir = path.dirname(dbPath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  const db = new AosDb(dbPath);

  // Fresh database: bootstrap from full schema
  const tables = db.listTables();
  if (tables.length === 0) {
    const sqliteSchema = path.resolve(__dirname, "..", "scripts", "aos-schema-sqlite-validation.sql");
    if (fs.existsSync(sqliteSchema)) {
      const sql = fs.readFileSync(sqliteSchema, "utf-8");
      for (const stmt of sql.split(";").map(s => s.trim()).filter(s => s.length > 0)) {
        db.db.prepare(stmt).run();
      }
    }
  }

  // Run incremental migrations (records seed for existing databases)
  const sqliteMigrationsDir = path.resolve(__dirname, "..", "migrations", "sqlite");
  const migrationResult = db.runMigrations(sqliteMigrationsDir);
  if (migrationResult.applied.length > 0 || migrationResult.errors.length > 0) {
    console.log("[aos-db] Migrations applied:", migrationResult.applied.join(", ") || "none");
    if (migrationResult.skipped.length > 0) {
      console.log("[aos-db] Migrations skipped:", migrationResult.skipped.join(", "));
    }
    if (migrationResult.errors.length > 0) {
      console.error("[aos-db] Migration errors:", migrationResult.errors);
    }
  }

  return db;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function now() {
  return new Date().toISOString();
}

function extractPath(url) {
  try { return new URL(url, "http://localhost").pathname; }
  catch { return url; }
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (chunk) => { data += chunk; });
    req.on("end", () => resolve(data));
    req.on("error", reject);
  });
}

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
    "access-control-allow-origin": "*"
  });
  res.end(payload);
}

function sendResult(res, result) {
  sendJson(res, result.status, result.body);
}

// ── Admin authentication ────────────────────────────────────────────────────

const ADMIN_TOKEN = process.env.AUTOPOIESIS_FRAMES_ADMIN_TOKEN || null;

/**
 * Authenticate an admin request.
 *
 * Accepts the admin token via:
 *   - Authorization: Bearer <token>
 *   - x-admin-token: <token>
 *
 * Returns { ok: true } on success, { ok: false, status, error } on failure.
 * When AUTOPOIESIS_FRAMES_ADMIN_TOKEN is not set, admin endpoints return 503
 * to prevent accidental open access in development.
 */
function authenticateAdmin(req) {
  if (!ADMIN_TOKEN) {
    return { ok: false, status: 503, error: "Admin token not configured. Set AUTOPOIESIS_FRAMES_ADMIN_TOKEN to enable admin access." };
  }
  const bearer = (req.headers["authorization"] || "").replace(/^Bearer\s+/i, "");
  const header = req.headers["x-admin-token"] || "";
  const token = bearer || header;
  if (!token) {
    return { ok: false, status: 401, error: "Missing admin token. Provide via Authorization: Bearer <token> or x-admin-token header." };
  }
  if (token !== ADMIN_TOKEN) {
    return { ok: false, status: 403, error: "Invalid admin token" };
  }
  return { ok: true };
}

// ── Device authentication ────────────────────────────────────────────────────

function authenticateDevice(db, req, deviceId) {
  const record = db.getDevice(deviceId);
  if (!record) return { ok: false, status: 404, error: "Device not found" };
  const key = req.headers["x-frame-device-key"];
  if (!key) return { ok: false, status: 401, error: "Missing device key" };
  const authResult = db.authenticateDevice(deviceId, key);
  if (!authResult) return { ok: false, status: 403, error: "Invalid device key" };
  if (!record.paired) return { ok: false, status: 403, error: "Device not paired" };
  return { ok: true, record };
}

// ── Admin platform constants ──────────────────────────────────────────────

/**
 * Subscription tier limits defining device counts, cache, artists, and features.
 */
const PLAN_LIMITS = {
  frames_trial:     { maxDevices: 1,   cacheLimitMb: 256,   activeArtistsLimit: 5,   offlineCache: false, remoteActions: true },
  frames_basic:     { maxDevices: 3,   cacheLimitMb: 512,   activeArtistsLimit: 20,  offlineCache: true,  remoteActions: true },
  frames_premium:   { maxDevices: 10,  cacheLimitMb: 2048,  activeArtistsLimit: 100, offlineCache: true,  remoteActions: true },
  frames_enterprise:{ maxDevices: Infinity, cacheLimitMb: 8192, activeArtistsLimit: Infinity, offlineCache: true, remoteActions: true }
};

/** Subscription statuses considered "degraded" (restricted access). */
const DEGRADED_STATUSES = new Set(["expired", "cancelled", "past_due"]);

/** Subscription statuses with full entitlements. */
const ENTITLED_STATUSES = new Set(["trial", "active"]);

/**
 * Compute entitlements for a user based on their subscription plan and status.
 *
 * @param {object} subscription - { plan, status } from getSubscription()
 * @param {number} deviceCount - Number of paired devices owned
 * @returns {object} Full entitlement set
 */
function computeEntitlements(subscription, deviceCount = 0) {
  const plan = (subscription && subscription.plan) || "frames_trial";
  const status = (subscription && subscription.status) || "inactive";
  const limits = PLAN_LIMITS[plan] || PLAN_LIMITS.frames_trial;
  const isDegraded = DEGRADED_STATUSES.has(status);
  const deviceLimit = limits.maxDevices;
  const deviceSlotsRemaining = Math.max(0, deviceLimit - deviceCount);

  return {
    plan,
    tier: plan,
    status,
    deviceLimit:          deviceLimit === Infinity ? null : deviceLimit,
    deviceLimitLabel:     deviceLimit === Infinity ? "unlimited" : String(deviceLimit),
    deviceUsage:          deviceCount,
    deviceSlotsRemaining,
    canAddDevice:         !isDegraded && deviceSlotsRemaining > 0,
    canUseRemoteActions:  !isDegraded,
    cacheLimitMb:         limits.cacheLimitMb,
    activeArtistsLimit:   limits.activeArtistsLimit === Infinity ? null : limits.activeArtistsLimit,
    offlineCache:         isDegraded ? false : limits.offlineCache,
    degradedAccess:       isDegraded,
    degradedReason:       isDegraded ? status + " subscription" : null,
    degradedActionsBlocked: isDegraded
      ? ["restart_device", "update_device", "factory_reset_request", "show_broadcast"]
      : []
  };
}

/**
 * Role-action matrix defining which roles can perform which remote actions.
 */
const ROLE_ACTION_MATRIX = [
  {
    role: "admin",
    actions: {
      sync_settings:        { allowed: true, requiresAuthorization: true },
      clear_cache:          { allowed: true, requiresAuthorization: true },
      restart_display:      { allowed: true, requiresAuthorization: true },
      enable_device:        { allowed: true, requiresAuthorization: true },
      disable_device:       { allowed: true, requiresAuthorization: true },
      restart_device:       { allowed: true, requiresAuthorization: true },
      update_device:        { allowed: true, requiresAuthorization: true },
      show_broadcast:       { allowed: true, requiresAuthorization: true },
      factory_reset_request:{ allowed: true, requiresAuthorization: true }
    }
  },
  {
    role: "owner",
    actions: {
      sync_settings:        { allowed: true, requiresAuthorization: true },
      clear_cache:          { allowed: true, requiresAuthorization: true },
      restart_display:      { allowed: true, requiresAuthorization: true },
      enable_device:        { allowed: true, requiresAuthorization: true },
      disable_device:       { allowed: true, requiresAuthorization: true },
      restart_device:       { allowed: true, requiresAuthorization: true },
      update_device:        { allowed: true, requiresAuthorization: true },
      show_broadcast:       { allowed: true, requiresAuthorization: true },
      factory_reset_request:{ allowed: true, requiresAuthorization: true }
    }
  },
  {
    role: "maintainer",
    actions: {
      sync_settings:        { allowed: true, requiresAuthorization: true },
      clear_cache:          { allowed: true, requiresAuthorization: true },
      restart_display:      { allowed: true, requiresAuthorization: true },
      enable_device:        { allowed: false, reason: "Insufficient permissions", reasonCode: "role_insufficient" },
      disable_device:       { allowed: false, reason: "Insufficient permissions", reasonCode: "role_insufficient" },
      restart_device:       { allowed: false, reason: "Requires admin or owner role", reasonCode: "role_insufficient" },
      update_device:        { allowed: false, reason: "Requires admin or owner role", reasonCode: "role_insufficient" },
      show_broadcast:       { allowed: true, requiresAuthorization: true },
      factory_reset_request:{ allowed: false, reason: "Only admin can request factory reset", reasonCode: "role_insufficient" }
    }
  },
  {
    role: "support",
    actions: {
      sync_settings:        { allowed: false, reason: "Read-only support role", reasonCode: "role_readonly" },
      clear_cache:          { allowed: false, reason: "Read-only support role", reasonCode: "role_readonly" },
      restart_display:      { allowed: false, reason: "Read-only support role", reasonCode: "role_readonly" },
      enable_device:        { allowed: false, reason: "Read-only support role", reasonCode: "role_readonly" },
      disable_device:       { allowed: false, reason: "Read-only support role", reasonCode: "role_readonly" },
      restart_device:       { allowed: false, reason: "Read-only support role", reasonCode: "role_readonly" },
      update_device:        { allowed: false, reason: "Read-only support role", reasonCode: "role_readonly" },
      show_broadcast:       { allowed: false, reason: "Read-only support role", reasonCode: "role_readonly" },
      factory_reset_request:{ allowed: false, reason: "Read-only support role", reasonCode: "role_readonly" }
    }
  },
  {
    role: "curator",
    actions: {
      sync_settings:        { allowed: false, reason: "Read-only curator role", reasonCode: "role_readonly" },
      clear_cache:          { allowed: false, reason: "Read-only curator role", reasonCode: "role_readonly" },
      restart_display:      { allowed: false, reason: "Read-only curator role", reasonCode: "role_readonly" },
      enable_device:        { allowed: false, reason: "Read-only curator role", reasonCode: "role_readonly" },
      disable_device:       { allowed: false, reason: "Read-only curator role", reasonCode: "role_readonly" },
      restart_device:       { allowed: false, reason: "Read-only curator role", reasonCode: "role_readonly" },
      update_device:        { allowed: false, reason: "Read-only curator role", reasonCode: "role_readonly" },
      show_broadcast:       { allowed: true, requiresAuthorization: true },
      factory_reset_request:{ allowed: false, reason: "Read-only curator role", reasonCode: "role_readonly" }
    }
  }
];

/** Actions requiring device to be online */
const ONLINE_REQUIRED_ACTIONS = new Set([
  "sync_settings", "clear_cache", "restart_display",
  "restart_device", "update_device", "show_broadcast"
]);

/** Actions blocked when device is disabled (enable_device is the escape hatch) */
const DISABLED_BLOCKED_ACTIONS = new Set([
  "sync_settings", "clear_cache", "restart_display",
  "restart_device", "update_device", "show_broadcast", "factory_reset_request"
]);

/**
 * Compute action availability for a device given an actor's role.
 * Applies five-layer gating: subscription → role → paired → disabled/remote → online.
 *
 * @param {object} device - Mapped device record from _mapDevice()
 * @param {string} actorRole - Role of the actor (admin, owner, maintainer, support, curator)
 * @param {object} [ownerSubscription] - Owner's subscription { plan, status }
 * @param {number} [pendingCommandCount=0] - Pending commands for this device
 * @returns {object} Action availability with device state
 */
function buildActionAvailability(device, actorRole, ownerSubscription = null, pendingCommandCount = 0) {
  const generatedAt = now();
  const actions = {};
  const roleRow = ROLE_ACTION_MATRIX.find(r => r.role === actorRole);
  if (!roleRow) return { generatedAt, actions: {}, deviceState: {} };

  // Compute device-level state
  const isPaired = !!device.paired;
  const isOnline = device.lastHeartbeatAt
    ? (Date.now() - new Date(device.lastHeartbeatAt).getTime()) < 300000
    : false;
  const isDisabled = !!device.disabled;
  const isRemoteEnabled = device.remoteEnabled !== false;

  for (const [actionKey, roleAction] of Object.entries(roleRow.actions)) {
    let allowed = roleAction.allowed;
    let reason = roleAction.reason || null;
    let reasonCode = roleAction.reasonCode || null;
    const roleAllowed = allowed;

    // Layer 1: Subscription degradation
    if (allowed && ownerSubscription && DEGRADED_STATUSES.has(ownerSubscription.status)) {
      const degradedBlocked = ["restart_device", "update_device", "factory_reset_request", "show_broadcast"];
      if (degradedBlocked.includes(actionKey)) {
        allowed = false;
        reason = "Subscription degraded: " + ownerSubscription.status;
        reasonCode = "subscription_degraded";
      }
    }

    // Layer 3a: Not paired
    if (allowed && !isPaired) {
      allowed = false;
      reason = "Device not paired";
      reasonCode = "not_paired";
    }

    // Layer 3b: Device disabled
    if (allowed && isDisabled && DISABLED_BLOCKED_ACTIONS.has(actionKey)) {
      allowed = false;
      reason = "Device is disabled";
      reasonCode = "device_disabled";
    }

    // Layer 3c: Remote disabled
    if (allowed && !isRemoteEnabled) {
      allowed = false;
      reason = "Remote actions disabled on this device";
      reasonCode = "remote_disabled";
    }

    // Layer 3d: Device offline (only for online-required actions)
    if (allowed && !isOnline && ONLINE_REQUIRED_ACTIONS.has(actionKey)) {
      allowed = false;
      reason = "Device is offline";
      reasonCode = "offline";
    }

    actions[actionKey] = {
      allowed,
      roleAllowed,
      ...(reason ? { reason } : {}),
      ...(reasonCode ? { reasonCode } : {}),
      ...(roleAction.requiresAuthorization ? { requiresAuthorization: true } : {})
    };
  }

  return {
    generatedAt,
    actions,
    deviceState: {
      isPaired,
      isOnline,
      isDisabled,
      isRemoteEnabled,
      pendingCommandCount
    }
  };
}

// ── Route handlers ───────────────────────────────────────────────────────────

/**
 * POST /frames/device/register
 * Registers a new device or re-registers an existing one.
 */
function handleRegister(db, body) {
  const deviceId = body.deviceId || ("aos_" + crypto.randomBytes(8).toString("hex"));
  const result = db.registerDevice({
    deviceId,
    softwareVersion: body.softwareVersion || "0.1.0",
    metadata: body.metadata || {}
  });
  return {
    status: 200,
    body: {
      ok: true,
      device: {
        deviceId: result.deviceId,
        deviceApiKey: result.deviceApiKey,
        paired: result.paired || false
      },
      pairingCode: result.pairingCode,
      expiresAt: result.expiresAt
    }
  };
}

/**
 * GET /frames/device/:id/pairing-status
 * Returns the current pairing status for a device.
 */
function handlePairingStatus(db, deviceId) {
  const record = db.getDevice(deviceId);
  if (!record) return { status: 404, body: { ok: false, error: "Device not found" } };

  // Use getPairingStatus which returns the full contract shape
  const pairingStatus = db.getPairingStatus(deviceId);
  if (!pairingStatus) {
    return {
      status: 200,
      body: { ok: true, paired: false, ownerUserId: null, pairing: { status: "none" } }
    };
  }
  // getPairingStatus already returns the correct body shape
  return { status: 200, body: pairingStatus };
}

/**
 * GET /frames/device/:id/settings
 * Returns the current device settings, including owner preferences cascade.
 */
function handleGetSettings(db, deviceId) {
  const record = db.getDevice(deviceId);
  if (!record) return { status: 404, body: { ok: false, error: "Device not found" } };

  const result = db.getSettings(deviceId);
  if (!result) return { status: 404, body: { ok: false, error: "Settings not found" } };

  const response = {
    ok: true,
    settings: result.settings || {},
    updatedAt: result.updatedAt || now()
  };

  // Include owner preferences if device has an owner with cascade overrides
  if (record.ownerUserId) {
    const ownerPrefs = db.getUserPreferences(record.ownerUserId);
    if (ownerPrefs && ownerPrefs.preferences && Object.keys(ownerPrefs.preferences).length > 0) {
      response.ownerPreferences = ownerPrefs.preferences;
      response.ownerPreferencesUpdatedAt = ownerPrefs.updatedAt || null;
    }
  }

  return { status: 200, body: response };
}

/**
 * POST /frames/device/:id/settings
 * Pushes settings from the device with conflict resolution.
 */
function handlePushSettings(db, deviceId, body, auth) {
  const incoming = body.settings || {};
  const incomingUpdated = incoming.updatedAt || now();

  const result = db.pushSettings(deviceId, incoming, incomingUpdated);

  if (result.conflict) {
    return {
      status: 200,
      body: {
        ok: false,
        error: "settings conflict",
        reason: "stale_write",
        conflict: true,
        settings: result.settings,
        updatedAt: result.updatedAt
      }
    };
  }

  return {
    status: 200,
    body: {
      ok: true,
      settings: result.settings,
      updatedAt: result.updatedAt
    }
  };
}

/**
 * POST /frames/device/:id/heartbeat
 * Processes heartbeat with event and broadcast delivery ingestion.
 */
function handleHeartbeat(db, deviceId, body, auth) {
  const record = auth.record;

  // Ingest heartbeat
  const heartbeatPayload = {
    softwareVersion: body.softwareVersion || record.softwareVersion,
    currentMode: body.currentMode || "setup",
    currentArtworkId: body.currentArtworkId || null,
    networkOnline: body.networkOnline !== undefined ? body.networkOnline : true,
    networkType: body.networkType || null,
    storageStatus: body.storageStatus || null,
    diagnostics: body.diagnostics || null,
    releaseState: body.releaseState || null,
    events: body.events || null,
    broadcastDeliveries: body.broadcastDeliveries || null
  };

  const hbResult = db.ingestHeartbeat(deviceId, heartbeatPayload);

  // Use the eventAck/deliveryAck returned by ingestHeartbeat (which actually
  // persists events to aos_device_events and deliveries to aos_broadcast_deliveries).
  // Fall back to cursor-only ack when the DB layer has nothing to report.
  let eventAck = hbResult.eventAck || null;
  if (!eventAck && body.eventIngestionCursor) {
    eventAck = {
      accepted: true,
      acceptedCount: 0,
      cursor: body.eventIngestionCursor
    };
  }

  const deliveryAck = hbResult.deliveryAck || null;

  // Return pending commands
  const pendingCommands = db.getPendingCommands(deviceId);

  // Build response
  const response = {
    ok: true,
    heartbeatAt: now(),
    eventAck,
    deliveryAck,
    commands: pendingCommands.length > 0 ? { items: pendingCommands } : undefined
  };

  // Include owner preferences if device has an owner with cascade overrides
  if (record.ownerUserId) {
    const ownerPrefs = db.getUserPreferences(record.ownerUserId);
    if (ownerPrefs && ownerPrefs.preferences && Object.keys(ownerPrefs.preferences).length > 0) {
      response.ownerPreferences = ownerPrefs.preferences;
    }
  }

  return { status: 200, body: response };
}

/**
 * GET /frames/device/:id/stream
 * Returns the personalized content stream for a device.
 *
 * Queries aos_broadcasts for real content, applies targeting/scheduling/priority
 * filtering, boosts artist-matched items, and returns subscription-tier-aware
 * polling defaults.
 */
function handleStream(db, deviceId, auth) {
  const record = auth.record;
  const settings = db.getSettings(deviceId) || {};

  // Resolve owner context for targeting and polling
  let ownerTier = null;
  let activeArtists = [];
  let polling = { intervalSeconds: 300, idleSeconds: 900 };

  if (record.ownerUserId) {
    const sub = db.getSubscription(record.ownerUserId);
    if (sub && sub.plan) {
      ownerTier = sub.plan;
      if (sub.plan === "frames_trial") {
        polling = { intervalSeconds: 600, idleSeconds: 1200 };
      } else if (sub.plan === "frames_premium" || sub.plan === "frames_enterprise") {
        polling = { intervalSeconds: 180, idleSeconds: 600 };
      }
    }

    // Resolve owner preferences for artist boosting
    const ownerPrefs = db.getUserPreferences(record.ownerUserId);
    if (ownerPrefs && ownerPrefs.preferences) {
      if (ownerPrefs.preferences.activeArtists && ownerPrefs.preferences.activeArtists.length > 0) {
        activeArtists = ownerPrefs.preferences.activeArtists;
      }
    }
  }

  // Compose personalized stream from database content
  const items = db.getStreamContent({
    deviceId,
    ownerUserId: record.ownerUserId || null,
    subscriptionTier: ownerTier,
    activeArtists,
    limit: 30
  });

  const body = {
    ok: true,
    generatedAt: now(),
    items,
    polling,
    settings: {
      displayMode: (settings.settings && settings.settings.displayMode) || "shuffle",
      shuffleInterval: (settings.settings && settings.settings.shuffleInterval) || 30
    }
  };

  // Include owner preferences cascade if present
  if (record.ownerUserId) {
    const ownerPrefs = db.getUserPreferences(record.ownerUserId);
    if (ownerPrefs && ownerPrefs.preferences && Object.keys(ownerPrefs.preferences).length > 0) {
      body.ownerPreferences = ownerPrefs.preferences;
      body.ownerPreferencesUpdatedAt = ownerPrefs.updatedAt || null;
    }
  }

  return { status: 200, body };
}

/**
 * GET /frames/device/:id/feed
 * Feed is an alias for stream.
 */
function handleFeed(db, deviceId, auth) {
  return handleStream(db, deviceId, auth);
}

/**
 * POST /frames/device/:id/commands/:cmdId/ack
 * Acknowledges a command.
 */
function handleCommandAck(db, deviceId, commandId, body, auth) {
  const ackStatus = body.status || "acknowledged";
  const result = db.acknowledgeCommand(deviceId, commandId, ackStatus);

  if (!result) {
    return { status: 404, body: { ok: false, error: "Command not found" } };
  }

  return {
    status: 200,
    body: {
      ok: true,
      commandId,
      status: result.status,
      updatedAt: result.updatedAt || now()
    }
  };
}

/**
 * GET /frames/device/:id/release
 * Returns the latest release for the device's channel.
 */
function handleRelease(db, deviceId, auth) {
  const record = auth.record;
  const channel = (record.softwareVersion && record.softwareVersion.includes("beta"))
    ? "beta" : "stable";

  const release = db.getLatestRelease(channel);

  return {
    status: 200,
    body: {
      ok: true,
      release: release || null,
      currentVersion: record.softwareVersion || "0.1.0"
    }
  };
}

/**
 * POST /frames/artworks/:id/like
 * Likes or unlikes an artwork.
 */
function handleLikeArtwork(db, artworkId, body, auth) {
  const userId = auth.record.ownerUserId;
  if (!userId) {
    return { status: 403, body: { ok: false, error: "Device has no owner" } };
  }

  if (body.liked === false) {
    db.unlikeArtwork(userId, artworkId);
  } else {
    db.likeArtwork(userId, artworkId);
  }

  return {
    status: 200,
    body: {
      ok: true,
      artworkId,
      liked: body.liked !== false,
      likedAt: now()
    }
  };
}

/**
 * GET /frames/admin/broadcast-deliveries
 * Admin endpoint: list all broadcast delivery records.
 */
function handleAdminBroadcastDeliveries(db, queryParams) {
  const filters = {};
  if (queryParams.get("deviceId")) filters.deviceId = queryParams.get("deviceId");
  if (queryParams.get("status")) filters.status = queryParams.get("status");
  if (queryParams.get("broadcastId")) filters.broadcastId = queryParams.get("broadcastId");

  const deliveries = db.getBroadcastDeliveries(filters);
  return {
    status: 200,
    body: {
      ok: true,
      deliveries: deliveries || [],
      total: (deliveries || []).length,
      filters
    }
  };
}

/**
 * GET /frames/admin/broadcast-deliveries/:broadcastId
 * Admin endpoint: per-broadcast delivery detail.
 */
function handleAdminBroadcastDeliveryDetail(db, broadcastId) {
  const deliveries = db.getBroadcastDeliveries({ broadcastId });
  return {
    status: 200,
    body: {
      ok: true,
      broadcastId,
      deliveries: deliveries || [],
      total: (deliveries || []).length
    }
  };
}

/* --------------------------------------------------------------------------
 * Admin Content Management Handlers
 * -------------------------------------------------------------------------- */

function handleAdminCreateBroadcast(db, body) {
  if (!body.title && body.type !== 'system_notice') {
    return { status: 400, body: { ok: false, error: "Title is required" } };
  }
  try {
    const broadcast = db.createBroadcast({
      id: body.id || null,
      title: body.title || '',
      body: body.body,
      type: body.type,
      mediaUrl: body.mediaUrl,
      thumbnailUrl: body.thumbnailUrl,
      artist: body.artist,
      artistId: body.artistId,
      targetType: body.targetType,
      targetValue: body.targetValue,
      priority: body.priority,
      duration: body.duration,
      startsAt: body.startsAt,
      expiresAt: body.expiresAt,
      repeatCount: body.repeatCount,
      dismissible: body.dismissible,
      cacheAllowed: body.cacheAllowed,
      soundAllowed: body.soundAllowed,
      status: body.status || 'draft',
      createdBy: body.createdBy || 'admin',
      metadata: body.metadata
    });
    return { status: 200, body: { ok: true, created: true, broadcast } };
  } catch (err) {
    return { status: 500, body: { ok: false, error: err.message } };
  }
}

function handleAdminListBroadcasts(db, filters) {
  try {
    const result = db.listBroadcasts(filters);
    return { status: 200, body: { ok: true, ...result } };
  } catch (err) {
    return { status: 500, body: { ok: false, error: err.message } };
  }
}

function handleAdminGetBroadcast(db, id) {
  const broadcast = db.getBroadcast(id);
  if (!broadcast) return { status: 404, body: { ok: false, error: "Broadcast not found" } };
  return { status: 200, body: { ok: true, broadcast } };
}

// ── Admin Subscription Management Handlers ─────────────────────────────────

/**
 * POST /frames/admin/subscriptions
 * Create a new subscription for a user.
 */
function handleAdminCreateSubscription(db, body) {
  if (!body.userId) return { status: 400, body: { ok: false, error: "userId is required" } };
  const validPlans = Object.keys(PLAN_LIMITS);
  if (body.plan && !validPlans.includes(body.plan)) {
    return { status: 400, body: { ok: false, error: "Invalid plan. Valid: " + validPlans.join(", ") } };
  }
  const validStatuses = ["trial", "active", "expired", "cancelled", "past_due", "inactive"];
  if (body.status && !validStatuses.includes(body.status)) {
    return { status: 400, body: { ok: false, error: "Invalid status. Valid: " + validStatuses.join(", ") } };
  }
  // Check if subscription already exists
  const existing = db.getSubscription(body.userId);
  if (existing) {
    return { status: 409, body: { ok: false, error: "Subscription already exists for user " + body.userId, existingSubscription: existing } };
  }
  const result = db.upsertSubscription(body.userId, {
    plan: body.plan || "frames_trial",
    status: body.status || "trial",
    provider: body.provider || "manual"
  });
  return { status: 201, body: { ok: true, created: true, subscription: result.subscription } };
}

/**
 * PATCH /frames/admin/subscriptions/:userId
 * Update a user's subscription (plan, status, provider).
 */
function handleAdminUpdateSubscription(db, userId, body) {
  const existing = db.getSubscription(userId);
  if (!existing) return { status: 404, body: { ok: false, error: "Subscription not found for user " + userId } };

  const validPlans = Object.keys(PLAN_LIMITS);
  if (body.plan && !validPlans.includes(body.plan)) {
    return { status: 400, body: { ok: false, error: "Invalid plan. Valid: " + validPlans.join(", ") } };
  }
  const validStatuses = ["trial", "active", "expired", "cancelled", "past_due", "inactive"];
  if (body.status && !validStatuses.includes(body.status)) {
    return { status: 400, body: { ok: false, error: "Invalid status. Valid: " + validStatuses.join(", ") } };
  }

  const result = db.upsertSubscription(userId, {
    plan: body.plan || existing.plan,
    status: body.status || existing.status,
    provider: body.provider || existing.provider
  });
  return { status: 200, body: { ok: true, updated: true, subscription: result.subscription } };
}

/**
 * POST /frames/admin/subscriptions/:userId/cancel
 * Cancel a user's subscription (sets status to 'cancelled').
 */
function handleAdminCancelSubscription(db, userId) {
  const existing = db.getSubscription(userId);
  if (!existing) return { status: 404, body: { ok: false, error: "Subscription not found for user " + userId } };
  if (existing.status === "cancelled") {
    return { status: 400, body: { ok: false, error: "Subscription already cancelled" } };
  }
  const result = db.upsertSubscription(userId, {
    plan: existing.plan,
    status: "cancelled",
    provider: existing.provider
  });
  return { status: 200, body: { ok: true, cancelled: true, subscription: result.subscription } };
}

/**
 * GET /frames/admin/subscriptions/:userId
 * Get a single user's subscription details with entitlements.
 */
function handleAdminGetSubscription(db, userId) {
  const sub = db.getSubscription(userId);
  if (!sub) return { status: 404, body: { ok: false, error: "Subscription not found for user " + userId } };
  const deviceCount = db.countDevicesByOwner(userId);
  const entitlements = computeEntitlements(sub, deviceCount);
  return {
    status: 200,
    body: { ok: true, subscription: sub, entitlements }
  };
}

// ── Admin Device Fleet Action Endpoints ─────────────────────────────────────

/**
 * POST /frames/admin/devices/:id/actions
 * Queue a remote action on a device. Validates against role-action matrix.
 */
function handleAdminDeviceAction(db, deviceId, body) {
  if (!body.action) return { status: 400, body: { ok: false, error: "action is required" } };

  const device = db.getDevice(deviceId);
  if (!device) return { status: 404, body: { ok: false, error: "Device not found" } };
  if (!device.paired) return { status: 400, body: { ok: false, error: "Device is not paired" } };

  // Validate action against admin role in the action matrix
  const adminRole = ROLE_ACTION_MATRIX.find(r => r.role === "admin");
  if (!adminRole || !adminRole.actions[body.action]) {
    return { status: 400, body: { ok: false, error: "Unknown action: " + body.action } };
  }

  // Compute action availability to check device-state gates
  let ownerSubscription = null;
  if (device.ownerUserId) {
    const sub = db.getSubscription(device.ownerUserId);
    ownerSubscription = sub ? { plan: sub.plan, status: sub.status } : null;
  }
  const pendingCommands = db.getPendingCommands(deviceId);
  const availability = buildActionAvailability(device, "admin", ownerSubscription, pendingCommands.length);
  const actionAvail = availability.actions[body.action];

  if (actionAvail && !actionAvail.allowed) {
    return {
      status: 409,
      body: {
        ok: false,
        error: "Action not available: " + (actionAvail.reason || "device state prevents this action"),
        reasonCode: actionAvail.reasonCode || "action_blocked",
        deviceState: availability.deviceState
      }
    };
  }

  // Map action names to command types
  const ACTION_TO_COMMAND = {
    sync_settings: "sync_settings",
    clear_cache: "clear_cache",
    restart_display: "restart_display",
    enable_device: "enable_device",
    disable_device: "disable_device",
    restart_device: "restart_device",
    update_device: "update_device",
    show_broadcast: "show_broadcast",
    factory_reset_request: "factory_reset_request"
  };

  const commandType = ACTION_TO_COMMAND[body.action];
  if (!commandType) {
    return { status: 400, body: { ok: false, error: "Cannot map action to command: " + body.action } };
  }

  // Determine risk level
  const riskMap = {
    sync_settings: "low",
    clear_cache: "low",
    restart_display: "medium",
    enable_device: "low",
    disable_device: "high",
    restart_device: "high",
    update_device: "high",
    show_broadcast: "low",
    factory_reset_request: "critical"
  };

  const payload = body.payload || {};

  const command = db.queueCommand(deviceId, commandType, payload, riskMap[commandType] || "medium");

  return {
    status: 200,
    body: {
      ok: true,
      queued: true,
      commandId: command.commandId || command.id,
      action: body.action,
      commandType,
      risk: riskMap[commandType] || "medium",
      deviceId,
      queuedAt: now(),
      deviceState: availability.deviceState
    }
  };
}

/**
 * PATCH /frames/admin/devices/:id
 * Update device properties (e.g. disabled, remoteEnabled, deviceName).
 */
function handleAdminUpdateDevice(db, deviceId, body) {
  const device = db.getDevice(deviceId);
  if (!device) return { status: 404, body: { ok: false, error: "Device not found" } };

  const allowedFields = ["disabled", "remoteEnabled", "deviceName", "updateChannel"];
  const updates = {};
  for (const field of allowedFields) {
    if (body[field] !== undefined) {
      updates[field] = body[field];
    }
  }

  if (Object.keys(updates).length === 0) {
    return { status: 400, body: { ok: false, error: "No updatable fields provided. Allowed: " + allowedFields.join(", ") } };
  }

  // Apply updates via direct DB operations
  const setClauses = [];
  const params = [];
  if (updates.disabled !== undefined) { setClauses.push("disabled = ?"); params.push(updates.disabled ? 1 : 0); }
  if (updates.remoteEnabled !== undefined) { setClauses.push("remote_enabled = ?"); params.push(updates.remoteEnabled ? 1 : 0); }
  if (updates.deviceName !== undefined) { setClauses.push("device_name = ?"); params.push(updates.deviceName); }
  if (updates.updateChannel !== undefined) { setClauses.push("update_channel = ?"); params.push(updates.updateChannel); }

  if (setClauses.length > 0) {
    setClauses.push("updated_at = datetime('now')");
    params.push(deviceId);
    db.db.prepare(
      `UPDATE aos_frame_devices SET ${setClauses.join(", ")} WHERE device_id = ?`
    ).run(...params);
  }

  const updated = db.getDevice(deviceId);
  const { deviceApiKey, ...safeDevice } = updated;
  return {
    status: 200,
    body: { ok: true, updated: true, device: safeDevice }
  };
}

/* --------------------------------------------------------------------------
 * Admin Content Management Handlers
 * -------------------------------------------------------------------------- */

function handleAdminUpdateBroadcast(db, id, updates) {
  const existing = db.getBroadcast(id);
  if (!existing) return { status: 404, body: { ok: false, error: "Broadcast not found" } };
  const broadcast = db.updateBroadcast(id, updates);
  return { status: 200, body: { ok: true, updated: true, broadcast } };
}

function handleAdminPublishBroadcast(db, id) {
  const existing = db.getBroadcast(id);
  if (!existing) return { status: 404, body: { ok: false, error: "Broadcast not found" } };
  if (existing.status === 'published') return { status: 400, body: { ok: false, error: "Already published" } };
  if (existing.status === 'archived') return { status: 400, body: { ok: false, error: "Cannot publish archived item" } };
  const broadcast = db.publishBroadcast(id);
  return { status: 200, body: { ok: true, published: true, broadcast } };
}

function handleAdminUnpublishBroadcast(db, id) {
  const existing = db.getBroadcast(id);
  if (!existing) return { status: 404, body: { ok: false, error: "Broadcast not found" } };
  if (existing.status !== 'published') return { status: 400, body: { ok: false, error: "Not published" } };
  const broadcast = db.unpublishBroadcast(id);
  return { status: 200, body: { ok: true, unpublished: true, broadcast } };
}

function handleAdminArchiveBroadcast(db, id) {
  const existing = db.getBroadcast(id);
  if (!existing) return { status: 404, body: { ok: false, error: "Broadcast not found" } };
  if (existing.status === 'archived') return { status: 400, body: { ok: false, error: "Already archived" } };
  const broadcast = db.archiveBroadcast(id);
  return { status: 200, body: { ok: true, archived: true, broadcast } };
}

function handleAdminBroadcastStats(db) {
  try {
    const stats = db.getBroadcastStats();
    return { status: 200, body: { ok: true, stats } };
  } catch (err) {
    return { status: 500, body: { ok: false, error: err.message } };
  }
}

// ── Online admin bundle ─────────────────────────────────────────────────────

/**
 * GET /frames/admin/bundle
 *
 * Returns the complete admin dashboard bundle from the real database:
 * - profileFrames: devices owned by the requesting user, preferences, liked artworks
 * - adminFrames: all users, subscriptions, fleet devices, plan limits, role matrix
 *
 * @param {AosDb} db
 * @param {string} [profileUserId] - User ID for profile section (defaults to admin)
 * @returns {{ status: number, body: object }}
 */
function handleAdminBundle(db, profileUserId) {
  const generatedAt = now();

  // ── Fleet devices ──────────────────────────────────────────────────────
  const fleet = db.listDevices({ pairedOnly: true, limit: 500 });

  // ── Subscriptions ─────────────────────────────────────────────────────
  const subs = db.listSubscriptions({ limit: 500 });
  const subMap = new Map(subs.items.map(s => [s.userId, s]));

  // ── Users (derived from device owners + subscriptions) ─────────────────
  const ownerIds = db.listOwnerUserIds();
  const allUserIds = new Set([...ownerIds, ...subs.items.map(s => s.userId)]);
  const usersItems = [];
  for (const userId of allUserIds) {
    const sub = subMap.get(userId);
    const ownerDeviceCount = db.countDevicesByOwner(userId);
    usersItems.push({
      userId,
      frameCount: ownerDeviceCount,
      subscription: sub ? {
        subscriptionId: sub.subscriptionId,
        status: sub.status,
        plan: sub.plan,
        tier: sub.tier,
        currentPeriodEnd: sub.currentPeriodEnd,
        cancelAtPeriodEnd: sub.cancelAtPeriodEnd
      } : null,
      entitlements: computeEntitlements(sub, ownerDeviceCount)
    });
  }

  // ── Fleet devices with action availability ─────────────────────────────
  const fleetDevices = fleet.items.map(device => {
    const ownerSub = device.ownerUserId ? subMap.get(device.ownerUserId) : null;
    const ownerSubscription = ownerSub ? { plan: ownerSub.plan, status: ownerSub.status } : null;
    return {
      deviceId: device.deviceId,
      deviceName: device.deviceName,
      ownerUserId: device.ownerUserId,
      softwareVersion: device.softwareVersion,
      currentMode: device.currentMode || "display",
      updateChannel: device.updateChannel,
      paired: device.paired,
      online: device.lastHeartbeatAt
        ? (Date.now() - new Date(device.lastHeartbeatAt).getTime()) < 300000
        : false,
      remoteEnabled: device.remoteEnabled,
      disabled: !!device.disabled,
      lastHeartbeatAt: device.lastHeartbeatAt,
      cache: {
        enabled: true,
        likedArtworks: true,
        recentArtworks: true,
        selectedArtists: false,
        sizeLimitMb: 512
      },
      subscription: ownerSub ? {
        subscriptionId: ownerSub.subscriptionId,
        status: ownerSub.status,
        plan: ownerSub.plan,
        tier: ownerSub.tier
      } : null,
      health: {
        status: "healthy",
        lastHeartbeat: device.lastHeartbeatAt
      },
      releaseStatus: device.releaseStatus || 'idle',
      releaseTargetVersion: device.releaseTargetVersion || null,
      releaseError: device.releaseError || null,
      actionAvailability: buildActionAvailability(device, "admin", ownerSubscription)
    };
  });

  // ── Profile frames (filtered to requested owner) ──────────────────────
  const effectiveUserId = profileUserId || (ownerIds.length > 0 ? ownerIds[0] : null);
  let profileDevices = [];
  let profilePreferences = null;
  let profileLikedArtworks = [];
  let profileEntitlements = null;

  if (effectiveUserId) {
    const profileFleet = db.listDevices({ ownerUserId: effectiveUserId, pairedOnly: true, limit: 100 });
    const profileSub = subMap.get(effectiveUserId);
    const profileOwnerSub = profileSub ? { plan: profileSub.plan, status: profileSub.status } : null;

    profileDevices = profileFleet.items.map(device => ({
      deviceId: device.deviceId,
      deviceName: device.deviceName,
      ownerUserId: device.ownerUserId,
      softwareVersion: device.softwareVersion,
      currentMode: device.currentMode || "display",
      updateChannel: device.updateChannel,
      paired: device.paired,
      online: device.lastHeartbeatAt
        ? (Date.now() - new Date(device.lastHeartbeatAt).getTime()) < 300000
        : false,
      remoteEnabled: device.remoteEnabled,
      disabled: !!device.disabled,
      lastHeartbeatAt: device.lastHeartbeatAt,
      actionAvailability: buildActionAvailability(device, "owner", profileOwnerSub)
    }));

    // Owner preferences
    const rawPrefs = db.getUserPreferences(effectiveUserId);
    profilePreferences = (rawPrefs && rawPrefs.preferences) ? rawPrefs.preferences : {
      activeArtists: [],
      streamCategories: ["artwork", "curatorial", "blog"],
      allowImages: true,
      allowVideos: true,
      allowSoundWorks: false,
      allowGenerativeWorks: true,
      autoplay: true,
      videoAutoplay: false,
      soundAutoplay: false,
      soundEnabled: false,
      cacheLikedArtworks: true,
      cacheRecentArtworks: true,
      offlineFallbackMode: "cached",
      updatedAt: generatedAt
    };

    // Liked artworks
    const likedIds = db.getLikedArtworks(effectiveUserId);
    profileLikedArtworks = likedIds.map(artworkId => ({
      artworkId,
      likedAt: generatedAt
    }));

    profileEntitlements = computeEntitlements(profileSub, profileFleet.total);
  }

  // ── Plan limits (for admin reference) ──────────────────────────────────
  const planLimits = {};
  for (const [plan, limits] of Object.entries(PLAN_LIMITS)) {
    planLimits[plan] = {
      maxDevices: limits.maxDevices === Infinity ? null : limits.maxDevices,
      maxDevicesLabel: limits.maxDevices === Infinity ? "unlimited" : String(limits.maxDevices),
      remoteActions: limits.remoteActions,
      cacheLimitMb: limits.cacheLimitMb,
      activeArtistsLimit: limits.activeArtistsLimit === Infinity ? null : limits.activeArtistsLimit,
      offlineCache: limits.offlineCache
    };
  }

  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_online_admin_bundle",
      schemaVersion: 1,
      generatedAt,
      profileFrames: {
        userId: effectiveUserId,
        preferences: profilePreferences,
        likedArtworks: profileLikedArtworks,
        devices: profileDevices,
        entitlements: profileEntitlements
      },
      adminFrames: {
        actor: {
          actorId: "admin",
          userId: effectiveUserId,
          role: "admin"
        },
        users: { items: usersItems, total: usersItems.length, page: 1, pageSize: 50 },
        subscriptions: { items: subs.items, total: subs.total, page: 1, pageSize: 50 },
        devices: { items: fleetDevices, total: fleetDevices.length, page: 1, pageSize: 50 },
        remoteActions: {
          acceptedActorRoles: ["admin", "owner", "maintainer", "support", "curator"],
          authorizationWindowSeconds: 300,
          highRiskRequiresAuditId: true,
          criticalRiskRequiresAuditId: true,
          roleActionMatrix: ROLE_ACTION_MATRIX
        },
        planLimits
      }
    }
  };
}

/**
 * GET /frames/device/:id/admin-snapshot
 *
 * Returns a detailed admin snapshot for a specific device including
 * device state, recent events, pending commands, subscription, and action availability.
 *
 * @param {AosDb} db
 * @param {string} deviceId
 * @returns {{ status: number, body: object }}
 */
function handleAdminDeviceSnapshot(db, deviceId) {
  const device = db.getDevice(deviceId);
  if (!device) return { status: 404, body: { ok: false, error: "Device not found" } };

  // Owner subscription
  let ownerSubscription = null;
  let ownerEntitlements = null;
  if (device.ownerUserId) {
    const sub = db.getSubscription(device.ownerUserId);
    ownerSubscription = sub ? { plan: sub.plan, status: sub.status } : null;
    const deviceCount = db.countDevicesByOwner(device.ownerUserId);
    ownerEntitlements = computeEntitlements(sub, deviceCount);
  }

  // Recent events
  const events = db.getDeviceEvents(deviceId, 20);

  // Pending commands
  const pendingCommands = db.getPendingCommands(deviceId);

  // Action availability (from admin perspective)
  const actionAvailability = buildActionAvailability(device, "admin", ownerSubscription, pendingCommands.length);

  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_admin_device_snapshot",
      generatedAt: now(),
      device: {
        deviceId: device.deviceId,
        deviceName: device.deviceName,
        ownerUserId: device.ownerUserId,
        deviceType: device.deviceType,
        softwareVersion: device.softwareVersion,
        updateChannel: device.updateChannel,
        paired: device.paired,
        remoteEnabled: device.remoteEnabled,
        online: device.lastHeartbeatAt
          ? (Date.now() - new Date(device.lastHeartbeatAt).getTime()) < 300000
          : false,
        lastHeartbeatAt: device.lastHeartbeatAt,
        currentMode: device.currentMode,
        currentArtworkId: device.currentArtworkId,
        networkOnline: device.networkOnline,
        networkType: device.networkType,
        releaseStatus: device.releaseStatus || 'idle',
        releaseTargetVersion: device.releaseTargetVersion || null,
        releaseChannel: device.releaseChannel || null,
        releaseUpdatedAt: device.releaseUpdatedAt || null,
        releaseError: device.releaseError || null,
        createdAt: device.createdAt,
        updatedAt: device.updatedAt
      },
      events: events.slice(0, 20),
      pendingCommands,
      ownerSubscription,
      ownerEntitlements,
      actionAvailability
    }
  };
}

// ── Request router ───────────────────────────────────────────────────────────

async function handle(db, req, res) {
  const pathname = extractPath(req.url);
  const method = req.method;

  // ── Admin broadcast delivery endpoints ────────────────────────────────

  if (method === "GET" && pathname === "/frames/admin/broadcast-deliveries") {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const url = new URL(req.url, "http://localhost");
    return sendResult(res, handleAdminBroadcastDeliveries(db, url.searchParams));
  }

  const adminBdDetailMatch = pathname.match(/^\/frames\/admin\/broadcast-deliveries\/([^/]+)$/);
  if (method === "GET" && adminBdDetailMatch) {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    return sendResult(res, handleAdminBroadcastDeliveryDetail(db, adminBdDetailMatch[1]));
  }

  // ── Admin bundle ────────────────────────────────────────────────────────

  // GET /frames/admin/bundle?userId=... — Online admin dashboard bundle
  if (method === "GET" && pathname === "/frames/admin/bundle") {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const url = new URL(req.url, "http://localhost");
    const profileUserId = url.searchParams.get("userId") || null;
    return sendResult(res, handleAdminBundle(db, profileUserId));
  }

  // ── Device admin snapshot ───────────────────────────────────────────────

  // GET /frames/device/:id/admin-snapshot — Detailed device snapshot for admin
  const adminSnapshotMatch = pathname.match(/^\/frames\/device\/([^/]+)\/admin-snapshot$/);
  if (method === "GET" && adminSnapshotMatch) {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    return sendResult(res, handleAdminDeviceSnapshot(db, adminSnapshotMatch[1]));
  }

  // ── Admin subscription management endpoints ────────────────────────────

  // POST /frames/admin/subscriptions — Create subscription
  if (method === "POST" && pathname === "/frames/admin/subscriptions") {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendResult(res, handleAdminCreateSubscription(db, body));
  }

  // GET /frames/admin/subscriptions/:userId — Get subscription + entitlements
  const adminSubMatch = pathname.match(/^\/frames\/admin\/subscriptions\/([^/]+)$/);
  if (method === "GET" && adminSubMatch) {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    return sendResult(res, handleAdminGetSubscription(db, adminSubMatch[1]));
  }

  // PATCH /frames/admin/subscriptions/:userId — Update subscription
  if (method === "PATCH" && adminSubMatch) {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendResult(res, handleAdminUpdateSubscription(db, adminSubMatch[1], body));
  }

  // POST /frames/admin/subscriptions/:userId/cancel — Cancel subscription
  const adminSubCancelMatch = pathname.match(/^\/frames\/admin\/subscriptions\/([^/]+)\/cancel$/);
  if (method === "POST" && adminSubCancelMatch) {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    return sendResult(res, handleAdminCancelSubscription(db, adminSubCancelMatch[1]));
  }

  // ── Admin device fleet action endpoints ──────────────────────────────────

  // POST /frames/admin/devices/:id/actions — Queue remote action
  const adminDevActionMatch = pathname.match(/^\/frames\/admin\/devices\/([^/]+)\/actions$/);
  if (method === "POST" && adminDevActionMatch) {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendResult(res, handleAdminDeviceAction(db, adminDevActionMatch[1], body));
  }

  // PATCH /frames/admin/devices/:id — Update device properties
  const adminDevUpdateMatch = pathname.match(/^\/frames\/admin\/devices\/([^/]+)$/);
  if (method === "PATCH" && adminDevUpdateMatch) {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendResult(res, handleAdminUpdateDevice(db, adminDevUpdateMatch[1], body));
  }

  // ── Admin content management endpoints ─────────────────────────────────

  // POST /frames/admin/broadcasts — Create new broadcast/content item
  if (method === "POST" && pathname === "/frames/admin/broadcasts") {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendResult(res, handleAdminCreateBroadcast(db, body));
  }

  // GET /frames/admin/broadcasts/stats — Content statistics
  if (method === "GET" && pathname === "/frames/admin/broadcasts/stats") {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    return sendResult(res, handleAdminBroadcastStats(db));
  }

  // GET /frames/admin/broadcasts — List broadcasts with filters
  if (method === "GET" && pathname === "/frames/admin/broadcasts") {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const url = new URL(req.url, "http://localhost");
    const filters = {};
    if (url.searchParams.get("status")) filters.status = url.searchParams.get("status");
    if (url.searchParams.get("type")) filters.type = url.searchParams.get("type");
    if (url.searchParams.get("priority")) filters.priority = url.searchParams.get("priority");
    if (url.searchParams.get("artistId")) filters.artistId = url.searchParams.get("artistId");
    if (url.searchParams.get("targetType")) filters.targetType = url.searchParams.get("targetType");
    if (url.searchParams.get("createdBy")) filters.createdBy = url.searchParams.get("createdBy");
    if (url.searchParams.get("activeOnly")) filters.activeOnly = url.searchParams.get("activeOnly") === "true";
    if (url.searchParams.get("limit")) filters.limit = parseInt(url.searchParams.get("limit"), 10);
    if (url.searchParams.get("offset")) filters.offset = parseInt(url.searchParams.get("offset"), 10);
    if (url.searchParams.get("sortBy")) filters.sortBy = url.searchParams.get("sortBy");
    if (url.searchParams.get("sortOrder")) filters.sortOrder = url.searchParams.get("sortOrder");
    return sendResult(res, handleAdminListBroadcasts(db, filters));
  }

  // GET /frames/admin/broadcasts/:id — Get single broadcast
  const adminBcDetailMatch = pathname.match(/^\/frames\/admin\/broadcasts\/([^/]+)$/);
  if (method === "GET" && adminBcDetailMatch) {
    const id = adminBcDetailMatch[1];
    if (id === "stats") return; // already handled above
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    return sendResult(res, handleAdminGetBroadcast(db, id));
  }

  // PATCH /frames/admin/broadcasts/:id — Update broadcast
  if (method === "PATCH" && adminBcDetailMatch) {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendResult(res, handleAdminUpdateBroadcast(db, adminBcDetailMatch[1], body));
  }

  // POST /frames/admin/broadcasts/:id/publish — Publish a draft
  const adminBcPublishMatch = pathname.match(/^\/frames\/admin\/broadcasts\/([^/]+)\/publish$/);
  if (method === "POST" && adminBcPublishMatch) {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    return sendResult(res, handleAdminPublishBroadcast(db, adminBcPublishMatch[1]));
  }

  // POST /frames/admin/broadcasts/:id/unpublish — Revert to draft
  const adminBcUnpublishMatch = pathname.match(/^\/frames\/admin\/broadcasts\/([^/]+)\/unpublish$/);
  if (method === "POST" && adminBcUnpublishMatch) {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    return sendResult(res, handleAdminUnpublishBroadcast(db, adminBcUnpublishMatch[1]));
  }

  // DELETE /frames/admin/broadcasts/:id — Archive (soft-delete)
  if (method === "DELETE" && adminBcDetailMatch) {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    return sendResult(res, handleAdminArchiveBroadcast(db, adminBcDetailMatch[1]));
  }

  // ── Device registration ───────────────────────────────────────────────

  if (method === "POST" && pathname === "/frames/device/register") {
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendResult(res, handleRegister(db, body));
  }

  // ── Pairing status ────────────────────────────────────────────────────

  const pairingMatch = pathname.match(/^\/frames\/device\/([^/]+)\/pairing-status$/);
  if (method === "GET" && pairingMatch) {
    return sendResult(res, handlePairingStatus(db, pairingMatch[1]));
  }

  // ── Settings ──────────────────────────────────────────────────────────

  const settingsMatch = pathname.match(/^\/frames\/device\/([^/]+)\/settings$/);
  if (method === "GET" && settingsMatch) {
    return sendResult(res, handleGetSettings(db, settingsMatch[1]));
  }
  if (method === "POST" && settingsMatch) {
    const deviceId = settingsMatch[1];
    const auth = authenticateDevice(db, req, deviceId);
    if (!auth.ok) return sendJson(res, auth.status, { ok: false, error: auth.error });
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendResult(res, handlePushSettings(db, deviceId, body, auth));
  }

  // ── Heartbeat ─────────────────────────────────────────────────────────

  const heartbeatMatch = pathname.match(/^\/frames\/device\/([^/]+)\/heartbeat$/);
  if (method === "POST" && heartbeatMatch) {
    const deviceId = heartbeatMatch[1];
    const auth = authenticateDevice(db, req, deviceId);
    if (!auth.ok) return sendJson(res, auth.status, { ok: false, error: auth.error });
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendResult(res, handleHeartbeat(db, deviceId, body, auth));
  }

  // ── Stream / Feed ─────────────────────────────────────────────────────

  const streamMatch = pathname.match(/^\/frames\/device\/([^/]+)\/stream$/);
  if (method === "GET" && streamMatch) {
    const deviceId = streamMatch[1];
    const auth = authenticateDevice(db, req, deviceId);
    if (!auth.ok) return sendJson(res, auth.status, { ok: false, error: auth.error });
    return sendResult(res, handleStream(db, deviceId, auth));
  }

  const feedMatch = pathname.match(/^\/frames\/device\/([^/]+)\/feed$/);
  if (method === "GET" && feedMatch) {
    const deviceId = feedMatch[1];
    const auth = authenticateDevice(db, req, deviceId);
    if (!auth.ok) return sendJson(res, auth.status, { ok: false, error: auth.error });
    return sendResult(res, handleFeed(db, deviceId, auth));
  }

  // ── Command acknowledgement ───────────────────────────────────────────

  const cmdAckMatch = pathname.match(/^\/frames\/device\/([^/]+)\/commands\/([^/]+)\/ack$/);
  if (method === "POST" && cmdAckMatch) {
    const deviceId = cmdAckMatch[1];
    const auth = authenticateDevice(db, req, deviceId);
    if (!auth.ok) return sendJson(res, auth.status, { ok: false, error: auth.error });
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendResult(res, handleCommandAck(db, deviceId, cmdAckMatch[2], body, auth));
  }

  // ── Release ───────────────────────────────────────────────────────────

  const releaseMatch = pathname.match(/^\/frames\/device\/([^/]+)\/release$/);
  if (method === "GET" && releaseMatch) {
    const deviceId = releaseMatch[1];
    const auth = authenticateDevice(db, req, deviceId);
    if (!auth.ok) return sendJson(res, auth.status, { ok: false, error: auth.error });
    return sendResult(res, handleRelease(db, deviceId, auth));
  }

  // ── Artwork like ──────────────────────────────────────────────────────

  const likeMatch = pathname.match(/^\/frames\/artworks\/([^/]+)\/like$/);
  if (method === "POST" && likeMatch) {
    const body = JSON.parse((await readBody(req)) || "{}");
    // Device ID can come from the body (local-ui sends it) or from a query param
    const likeUrl = new URL(req.url, "http://localhost");
    const likeDeviceId = body.deviceId || likeUrl.searchParams.get("deviceId");
    if (!likeDeviceId) {
      return sendJson(res, 400, { ok: false, error: "Missing deviceId in body or query" });
    }
    const auth = authenticateDevice(db, req, likeDeviceId);
    if (!auth.ok) return sendJson(res, auth.status, { ok: false, error: auth.error });
    return sendResult(res, handleLikeArtwork(db, likeMatch[1], body, auth));
  }

  // ── Health / status ───────────────────────────────────────────────────

  if (method === "GET" && pathname === "/health") {
    const tables = db.listTables();
    return sendJson(res, 200, {
      ok: true,
      service: "aos-hosted-api",
      database: DB_PATH,
      tables: tables.length,
      uptime: process.uptime()
    });
  }

  // ── Fallback ──────────────────────────────────────────────────────────

  sendJson(res, 404, { ok: false, error: "Not found", path: pathname });
}

// ── Server bootstrap ─────────────────────────────────────────────────────────

const crypto = require("crypto");

function main() {
  let db;
  try {
    db = ensureDatabase(DB_PATH);
  } catch (err) {
    process.stderr.write(JSON.stringify({
      ok: false,
      error: "Database initialization failed",
      details: err.message
    }) + "\n");
    process.exit(1);
  }

  const server = http.createServer((req, res) => {
    handle(db, req, res).catch((err) => {
      process.stderr.write("Unhandled error: " + err.message + "\n");
      sendJson(res, 500, { ok: false, error: "Internal server error" });
    });
  });

  server.listen(PORT, HOST, () => {
    process.stdout.write(JSON.stringify({
      ok: true,
      message: "AOS hosted API listening",
      port: PORT,
      host: HOST,
      database: DB_PATH,
      tables: db.listTables().length
    }) + "\n");
  });

  // Graceful shutdown
  function shutdown(signal) {
    process.stdout.write(JSON.stringify({ ok: true, message: "Shutting down", signal }) + "\n");
    server.close(() => {
      db.close();
      process.exit(0);
    });
    // Force exit after 5s
    setTimeout(() => process.exit(0), 5000);
  }

  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
}

main();
