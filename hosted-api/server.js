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
 *   GET  /frames/device/:id/effective-preferences   – Get effective preferences (owner cascade + device settings)
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
 *   GET  /frames/admin/pairing-queue                – Admin: read pairing setup queue
 *   POST /frames/admin/devices/:id/pairing-code     – Admin: refresh setup pairing code
 *   POST /frames/admin/subscriptions               – Admin: create subscription
 *   GET  /frames/admin/subscriptions/:userId       – Admin: get subscription + entitlements
 *   PATCH /frames/admin/subscriptions/:userId      – Admin: update subscription
 *   POST /frames/admin/subscriptions/:userId/cancel – Admin: cancel subscription
 *   POST /frames/admin/devices/:id/actions         – Admin: queue remote action
 *   PATCH /frames/admin/devices/:id                – Admin: update device properties
 *   GET  /frames/admin/users                       – Admin: list users
 *   GET  /frames/admin/users/:userId               – Admin: get user detail
 *   GET  /frames/admin/users/:userId/frame-state   – Admin: profile frame-state summary
 *   GET  /frames/admin/users/:userId/preferences   – Admin: get user preferences
 *   PATCH /frames/admin/users/:userId/preferences   – Admin: update user preferences
 *   GET  /frames/admin/subscribers                 – Admin: subscriber summary read model
 *   GET  /frames/admin/commands                    – Admin: fleet-wide command queue
 *   GET  /frames/admin/command-audits              – Admin: command audit trail
 *   GET  /frames/admin/devices                     – Admin: fleet-wide device listing
 *   GET  /frames/admin/broadcasts/:id/delivery-stats – Admin: per-broadcast delivery outcomes
 *   GET  /frames/admin/delivery-stats              – Admin: fleet broadcast delivery outcomes
 *   GET  /frames/me                                 – User: profile summary
 *   GET  /frames/me/devices                         – User: paired devices
 *   GET  /frames/me/preferences                     – User: read preferences
 *   PATCH /frames/me/preferences                    – User: update preferences
 *   POST /frames/me/pair                             – User: pair a device by pairing code
 *   GET  /frames/me/liked-artworks                  – User: liked artworks
 *   GET  /frames/me/subscription                    – User: subscription + entitlements
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
      throw new Error("AOS database migration failed; refusing to start with an unsafe schema state");
    }
  }

  return db;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function now() {
  return new Date().toISOString();
}

function isValidIsoTimestamp(value) {
  if (typeof value !== "string" ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(value)) {
    return false;
  }
  const parsed = new Date(value);
  if (!Number.isFinite(parsed.getTime())) return false;
  const canonical = parsed.toISOString();
  return canonical === value || canonical.replace(".000Z", "Z") === value;
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

// ── User authentication ────────────────────────────────────────────────────
//
// MVP user auth: AUTOPOIESIS_FRAMES_USER_TOKENS is a JSON map of { "<token>": "<userId>" }.
// For single-user setups, set to e.g. '{"my-secret-token": "user-ewoud"}'.
// This can be replaced with proper OAuth/session auth later without changing the
// /frames/me/* endpoint contract.
//
const USER_TOKENS = _parseUserTokens(process.env.AUTOPOIESIS_FRAMES_USER_TOKENS);

function _parseUserTokens(raw) {
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw);
    if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) {
      return parsed;
    }
  } catch (_) { /* ignore */ }
  return null;
}

/**
 * Authenticate a user request for /frames/me/* endpoints.
 *
 * Accepts user token via:
 *   - Authorization: Bearer <token>
 *   - x-user-token: <token>
 *
 * When AUTOPOIESIS_FRAMES_USER_TOKENS is not set, user endpoints return 503
 * (service not configured). When the token is valid, returns { ok, userId }.
 * Admin token is also accepted — admin users can access any user's data by
 * passing ?userId=<target> query parameter.
 *
 * @param {http.IncomingMessage} req
 * @param {AosDb} db
 * @returns {{ ok: boolean, userId?: string, status?: number, error?: string }}
 */
function authenticateUser(req, db) {
  // Admin pass-through: admin token grants user access
  if (ADMIN_TOKEN) {
    const bearer = (req.headers["authorization"] || "").replace(/^Bearer\s+/i, "");
    const adminHeader = req.headers["x-admin-token"] || "";
    const token = bearer || adminHeader;
    if (token === ADMIN_TOKEN) {
      // Admin access: userId comes from query param or falls back to first known user
      const url = new URL(req.url, "http://localhost");
      const targetUserId = url.searchParams.get("userId");
      if (targetUserId) return { ok: true, userId: targetUserId, adminAccess: true };
      // No userId specified — admin can still use /frames/me with explicit userId
      return { ok: true, userId: null, adminAccess: true };
    }
  }

  // User token authentication
  if (!USER_TOKENS) {
    return { ok: false, status: 503, error: "User tokens not configured. Set AUTOPOIESIS_FRAMES_USER_TOKENS to enable user access." };
  }
  const bearer = (req.headers["authorization"] || "").replace(/^Bearer\s+/i, "");
  const header = req.headers["x-user-token"] || "";
  const token = bearer || header;
  if (!token) {
    return { ok: false, status: 401, error: "Missing user token. Provide via Authorization: Bearer <token> or x-user-token header." };
  }
  const userId = USER_TOKENS[token];
  if (!userId) {
    return { ok: false, status: 403, error: "Invalid user token" };
  }
  return { ok: true, userId };
}

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

function acceptedActorRoles() {
  return ROLE_ACTION_MATRIX.map(r => r.role);
}

function getAdminReadActor(queryParams = {}) {
  const actorRole = queryParams.actorRole || "admin";
  const actorId = queryParams.actorId || "admin";
  const roleRow = ROLE_ACTION_MATRIX.find(r => r.role === actorRole);
  if (!roleRow) {
    return {
      ok: false,
      status: 400,
      body: {
        ok: false,
        error: "Invalid actorRole: " + actorRole,
        acceptedActorRoles: acceptedActorRoles()
      }
    };
  }
  return { ok: true, actorRole, actorId };
}

function getAdminWriteActor(body = {}, allowedRoles = ["admin"]) {
  const actorRole = body.actorRole || "admin";
  const actorId = body.actorId || "admin";
  const roleRow = ROLE_ACTION_MATRIX.find(r => r.role === actorRole);
  if (!roleRow) {
    return {
      ok: false,
      status: 400,
      body: {
        ok: false,
        error: "Invalid actorRole: " + actorRole,
        acceptedActorRoles: acceptedActorRoles()
      }
    };
  }
  if (allowedRoles.includes(actorRole)) {
    return { ok: true, actorRole, actorId };
  }

  const readOnlyRoles = new Set(["support", "curator"]);
  return {
    ok: false,
    status: 409,
    body: {
      ok: false,
      error: readOnlyRoles.has(actorRole)
        ? actorRole + " role is read-only for this action"
        : actorRole + " role cannot perform this action",
      reasonCode: readOnlyRoles.has(actorRole) ? "role_readonly" : "role_insufficient",
      actorId,
      actorRole,
      acceptedActorRoles: allowedRoles
    }
  };
}

function normalizeCommandStatus(status) {
  return String(status || "queued").trim().toLowerCase();
}

function normalizeCommandAckStatus(status) {
  return String(status || "").trim().toLowerCase();
}

function isTerminalCommandLifecycle(command) {
  const status = normalizeCommandStatus(command.status);
  const ackStatus = normalizeCommandAckStatus(command.lastAckStatus);
  return ["completed", "failed", "error", "denied", "expired"].includes(status) ||
    ["completed", "failed", "error", "denied", "expired"].includes(ackStatus);
}

function buildActionQueueLifecycle(command) {
  const delivered = !!command.deliveredAt;
  const acknowledged = !!(command.acknowledgedAt || command.lastAckAt);
  const terminal = isTerminalCommandLifecycle(command);
  const ackStatus = normalizeCommandAckStatus(command.lastAckStatus);
  const status = normalizeCommandStatus(command.status);

  let phase = "queued";
  if (terminal) {
    phase = "terminal";
  } else if (ackStatus === "processing") {
    phase = "processing";
  } else if (acknowledged || delivered || status === "sent" || status === "acknowledged" || status === "processing") {
    phase = "processing";
  }

  return {
    phase,
    delivered,
    acknowledged,
    terminal,
    awaitingDelivery: !terminal && !delivered,
    awaitingTerminal: !terminal && acknowledged,
    status,
    lastAckStatus: ackStatus || null
  };
}

function secondsSince(ts) {
  if (!ts) return 0;
  const parsed = new Date(ts).getTime();
  if (!Number.isFinite(parsed)) return 0;
  return Math.max(0, Math.floor((Date.now() - parsed) / 1000));
}

function computeActionQueueAttention(item, stalePendingHours) {
  const reasons = [];
  const staleThresholdSeconds = Math.max(0, Number(stalePendingHours || 2)) * 3600;
  const ageSeconds = secondsSince(item.createdAt);

  if (!item.lifecycle.terminal && item.device && item.device.online === false) {
    reasons.push("offline_target");
  }
  if (item.error) {
    reasons.push("command_error");
  }
  if (!item.lifecycle.terminal && ["high", "critical"].includes(String(item.risk || "").toLowerCase())) {
    reasons.push("high_risk_pending");
  }
  if (!item.lifecycle.terminal && ageSeconds >= staleThresholdSeconds) {
    reasons.push("stale_pending");
  }

  return { reasons, ageSeconds };
}

function defaultFramePreferences() {
  return {
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
    offlineFallbackMode: "cached"
  };
}

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
    deviceName: body.deviceName || "Autopoiesis Frame",
    deviceType: body.deviceType || "raspberry_pi",
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
    updatedAt: result.updatedAt || null
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
 * GET /frames/device/:id/effective-preferences
 * Returns the effective preferences for a device (owner cascade fields + device-level settings).
 */
function handleGetEffectivePreferences(db, deviceId, auth) {
  const record = db.getDevice(deviceId);
  if (!record) return { status: 404, body: { ok: false, error: "Device not found" } };

  // Get device settings
  const deviceSettingsResult = db.getSettings(deviceId);
  const deviceSettings = deviceSettingsResult && deviceSettingsResult.settings ? deviceSettingsResult.settings : {};

  // Get owner preferences if device has an owner
  let ownerPreferences = {};
  let ownerPreferencesUpdatedAt = null;
  if (record.ownerUserId) {
    const ownerPrefsResult = db.getUserPreferences(record.ownerUserId);
    if (ownerPrefsResult && ownerPrefsResult.preferences && Object.keys(ownerPrefsResult.preferences).length > 0) {
      ownerPreferences = ownerPrefsResult.preferences;
      ownerPreferencesUpdatedAt = ownerPrefsResult.updatedAt || null;
    }
  }

  // Subscription and entitlements
  let subscription = null;
  let entitlements = null;
  let deviceCount = 0;
  if (record.ownerUserId) {
    subscription = db.getSubscription(record.ownerUserId);
    if (subscription) {
      deviceCount = db.countDevicesByOwner(record.ownerUserId);
      entitlements = computeEntitlements(subscription, deviceCount);
    }
  }

  // Define cascade fields (must match those in local-ui/server.js)
  const OWNER_CASCADE_FIELDS = [
    "streamCategories",
    "activeArtists",
    "allowImages",
    "allowVideos",
    "allowSoundWorks",
    "allowGenerativeWorks",
    "soundEnabled",
    "autoplay",
    "videoAutoplay",
    "soundAutoplay",
    "cacheLikedArtworks",
    "cacheRecentArtworks",
    "offlineFallbackMode"
  ];

  // Build effective preferences:
  // For cascade fields: take from owner preferences (or default if missing)
  // For device-level fields (not in cascade): take from device settings (or default if missing)
  const defaults = {
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
    offlineFallbackMode: "cached"
  };

  const effectivePrefs = {};

  // First, apply defaults
  Object.assign(effectivePrefs, defaults);

  // Override with owner preferences for cascade fields
  OWNER_CASCADE_FIELDS.forEach(field => {
    if (ownerPreferences[field] !== undefined) {
      effectivePrefs[field] = ownerPreferences[field];
    }
  });

  // Override with device settings for all fields (device settings may include both cascade and device-level fields,
  // but note: device should not override cascade fields per design, but we allow it here for completeness)
  Object.assign(effectivePrefs, deviceSettings);

  return {
    status: 200,
    body: {
      ok: true,
      effectivePreferences: effectivePrefs,
      deviceSettings: deviceSettings,
      ownerPreferences: ownerPreferences,
      ownerPreferencesUpdatedAt: ownerPreferencesUpdatedAt,
      subscription: subscription,
      entitlements: entitlements,
      updatedAt: now()
    }
  };
}

/**
 * POST /frames/device/:id/settings
 * Pushes settings from the device with conflict resolution.
 */
function handlePushSettings(db, deviceId, body, auth) {
  const incoming = body.settings || {};
  const incomingUpdated = incoming.updatedAt || now();
  if (incoming.updatedAt !== undefined && !isValidIsoTimestamp(incoming.updatedAt)) {
    return {
      status: 400,
      body: {
        ok: false,
        error: "settings.updatedAt must be an ISO-8601 UTC timestamp",
        reason: "invalid_updated_at"
      }
    };
  }

  const result = db.pushSettings(deviceId, incoming, incomingUpdated);
  if (!result.ok && result.reason === "invalid_updated_at") {
    return { status: 400, body: { ok: false, error: result.error, reason: result.reason } };
  }

  if (result.conflict) {
    return {
      status: 200,
      body: {
        ok: false,
        error: "settings conflict",
        reason: "stale_write",
        conflict: true,
        settings: result.settings,
        incomingSettings: result.incomingSettings,
        incomingUpdatedAt: result.incomingUpdatedAt,
        currentUpdatedAt: result.currentUpdatedAt,
        conflictPolicy: result.conflictPolicy,
        updatedAt: result.updatedAt
      }
    };
  }

  return {
    status: 200,
    body: {
      ok: true,
      settings: result.settings,
      incomingSettings: result.incomingSettings,
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
  const receivedAt = now();
  const heartbeatAt = body.heartbeatAt || receivedAt;

  if (body.heartbeatAt !== undefined && !isValidIsoTimestamp(body.heartbeatAt)) {
    return {
      status: 400,
      body: {
        ok: false,
        error: "heartbeatAt must be an ISO-8601 UTC timestamp",
        reason: "invalid_heartbeat_at"
      }
    };
  }

  // Ingest heartbeat
  const heartbeatPayload = {
    heartbeatAt,
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

  // Return pending commands and record delivery evidence for newly polled rows.
  const pendingCommands = db.getPendingCommands(deviceId);

  // Build response
  const response = {
    ok: true,
    heartbeatAt: hbResult.heartbeatAt || heartbeatAt,
    heartbeatAck: hbResult.heartbeatAck || null,
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

    // Include subscription and entitlements for integrated profile data
    const subscription = db.getSubscription(record.ownerUserId);
    if (subscription) {
      const deviceCount = db.countDevicesByOwner(record.ownerUserId);
      response.subscription = subscription;
      response.entitlements = computeEntitlements(subscription, deviceCount);
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
  let streamCategories = null; // null = all categories (no filter)
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

    // Resolve owner preferences for artist boosting and category filtering
    const ownerPrefs = db.getUserPreferences(record.ownerUserId);
    if (ownerPrefs && ownerPrefs.preferences) {
      if (ownerPrefs.preferences.activeArtists && ownerPrefs.preferences.activeArtists.length > 0) {
        activeArtists = ownerPrefs.preferences.activeArtists;
      }
      if (Array.isArray(ownerPrefs.preferences.streamCategories) && ownerPrefs.preferences.streamCategories.length > 0) {
        streamCategories = ownerPrefs.preferences.streamCategories;
      }
    }

    // Enrich with artists from liked artworks (implicit preference signal)
    const likedArtistIds = db.getLikedArtistIds(record.ownerUserId);
    if (likedArtistIds.length > 0) {
      const existingSet = new Set(activeArtists.map(a => String(a).toLowerCase()));
      for (const id of likedArtistIds) {
        if (!existingSet.has(String(id).toLowerCase())) {
          activeArtists.push(id);
        }
      }
    }
  }

  // Compose personalized stream from database content
  const items = db.getStreamContent({
    deviceId,
    ownerUserId: record.ownerUserId || null,
    subscriptionTier: ownerTier,
    activeArtists,
    streamCategories,
    limit: 30
  });

  // Add cacheEligible flag to each item for downstream cache eligibility logic
  const itemsWithCacheEligibility = items.map(item => {
    const mediaUrl = typeof item.mediaUrl === "string" ? item.mediaUrl.trim() : "";
    const cacheAllowed = item.cacheAllowed !== undefined ? item.cacheAllowed : item.cacheEligible;
    // Base eligibility: cache permission and media URL present
    const baseEligible = !!cacheAllowed && mediaUrl !== "";

    // Additional: if the item has an expiry, it should be sufficiently far in the future
    // to be worth caching (e.g., more than 30 minutes from now)
    const now = Date.now();
    let expiryEligible = true;
    if (item.expiresAt) {
      const expiryTime = new Date(item.expiresAt).getTime();
      // If expires in less than 30 minutes, not ideal for caching
      expiryEligible = (expiryTime - now) > 30 * 60 * 1000;
    }

    return {
      ...item,
      cacheEligible: baseEligible && expiryEligible
    };
  });

  // Adaptive polling logic based on content priority and expiry
  const nowMs = Date.now();
  let hasEmergency = false;
  let hasCritical = false;
  let hasHigh = false;
  let soonestExpiryMs = Infinity;
  let soonestExpiryItemId = null;

  for (const item of itemsWithCacheEligibility) {
    if (item.priority === 'emergency') {
      hasEmergency = true;
    } else if (item.priority === 'critical') {
      hasCritical = true;
    } else if (item.priority === 'high') {
      hasHigh = true;
    }
    if (item.expiresAt) {
      const expiryTime = new Date(item.expiresAt).getTime();
      const timeToExpiry = expiryTime - nowMs;
      if (timeToExpiry > 0 && timeToExpiry < soonestExpiryMs) {
        soonestExpiryMs = timeToExpiry;
        soonestExpiryItemId = item.id || null;
      }
    }
  }

  // Start with subscription-tier-based polling baseline
  let adaptiveInterval = polling.intervalSeconds;
  let adaptiveIdle = polling.idleSeconds;

  // Override based on content priority
  if (hasEmergency) {
    adaptiveInterval = 30;  // Poll every 30 seconds for emergency content
    adaptiveIdle = 60;      // Shorter idle time for emergency
  } else if (hasCritical) {
    adaptiveInterval = 60;  // Poll every 60 seconds for critical content
    adaptiveIdle = 120;     // Shorter idle time for critical
  } else if (hasHigh) {
    adaptiveInterval = Math.min(adaptiveInterval, 90);
    adaptiveIdle = Math.min(adaptiveIdle, 180);
  } else {
    // Adjust for expiring content: poll frequently enough to catch items before expiry
    // Aim to poll at least twice before expiry, but don't exceed subscription-based interval
    if (soonestExpiryMs !== Infinity) {
      const maxIntervalForExpiry = Math.ceil(soonestExpiryMs / 1000 / 2); // seconds to poll at least twice before expiry
      if (maxIntervalForExpiry < adaptiveInterval) {
        adaptiveInterval = Math.max(30, maxIntervalForExpiry); // Minimum 30 seconds to avoid excessive polling
        adaptiveIdle = Math.max(60, adaptiveInterval * 2);    // Idle time at least 2x interval
      }
    }
  }

  // Ensure polling values are within reasonable bounds
  polling.intervalSeconds = Math.max(30, Math.min(adaptiveInterval, 1800)); // Between 30s and 30min
  polling.idleSeconds = Math.max(60, Math.min(adaptiveIdle, 3600));         // Between 60s and 1h

  const generatedAt = now();
  const generatedAtMs = Date.parse(generatedAt);
  const nextPollAt = new Date(generatedAtMs + polling.intervalSeconds * 1000).toISOString();
  const staleAfter = new Date(generatedAtMs + polling.idleSeconds * 1000).toISOString();
  const streamCategoriesPresent = Array.from(new Set(itemsWithCacheEligibility.map(item => item.category).filter(Boolean)));
  const streamPriorityCounts = itemsWithCacheEligibility.reduce((counts, item) => {
    const priority = item.priority || "normal";
    counts[priority] = (counts[priority] || 0) + 1;
    return counts;
  }, {});
  const cacheEligibleItems = itemsWithCacheEligibility.filter(item => item.cacheEligible).length;
  const pollingReason = hasEmergency
    ? "emergency_content"
    : hasCritical
      ? "critical_content"
      : hasHigh
        ? "high_priority_content"
        : soonestExpiryMs !== Infinity && polling.intervalSeconds < ((ownerTier === "frames_premium" || ownerTier === "frames_enterprise") ? 180 : ownerTier === "frames_trial" ? 600 : 300)
          ? "expiry_pressure"
          : "subscription_baseline";

  const body = {
    schemaVersion: 1,
    ok: true,
    generatedAt,
    stream: {
      source: "hosted",
      profile: ownerTier || "anonymous",
      deviceId,
      ownerUserId: record.ownerUserId || null,
      itemCount: itemsWithCacheEligibility.length,
      categories: streamCategoriesPresent,
      priorityCounts: streamPriorityCounts,
      cacheEligibleItems,
      soonestExpiryItemId,
      soonestExpiryAt: soonestExpiryMs !== Infinity ? new Date(nowMs + soonestExpiryMs).toISOString() : null
    },
    items: itemsWithCacheEligibility,
    polling: {
      ...polling,
      pollAfterSeconds: polling.intervalSeconds,
      nextPollAt,
      staleAfter,
      reason: pollingReason
    },
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

  if (typeof db.recordStreamDeliveries === "function") {
    try {
      const delivery = db.recordStreamDeliveries({
        deviceId,
        ownerUserId: record.ownerUserId || null,
        items: itemsWithCacheEligibility,
        deliveredAt: body.generatedAt
      });
      const deliveredIds = itemsWithCacheEligibility.map(item => item.id).filter(Boolean);
      body.delivery = {
        ...delivery,
        deliveredIds,
        cursor: {
          deliveredThroughBroadcastId: deliveredIds.length ? deliveredIds[deliveredIds.length - 1] : null,
          deliveredAt: delivery.deliveredAt || body.generatedAt
        }
      };
      body.deliveryLog = body.delivery;
    } catch (_) {
      body.delivery = {
        status: "not_recorded",
        reason: "delivery_record_failed"
      };
      body.deliveryLog = body.delivery;
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
  const result = db.acknowledgeCommand(deviceId, commandId, ackStatus, body.updatedAt || body.updated_at || null, body.error || null);

  if (!result || (result.ok === false && result.error === "Command not found")) {
    return { status: 404, body: { ok: false, error: "Command not found" } };
  }

  if (result.ok === false) {
    const status = result.reason === "invalid_ack_status" || result.reason === "invalid_updated_at" ? 400 : 409;
    return {
      status,
      body: {
        ok: false,
        error: result.error || "Command acknowledgement rejected",
        reason: result.reason,
        acceptedStatuses: result.acceptedStatuses
      }
    };
  }

  // Update admin audit trail with acknowledgement status
  if (!result.ignored) {
    try {
      db.updateCommandAuditStatus(commandId, result.status, result.error || null);
    } catch (auditErr) {
      process.stderr.write("[audit] updateCommandAuditStatus failed: " + auditErr.message + "\n");
    }
  }

  return {
    status: 200,
    body: {
      ok: true,
      commandId,
      status: result.status,
      updatedAt: result.updatedAt || now(),
      ignored: result.ignored || undefined,
      conflict: result.conflict || undefined,
      reason: result.reason || undefined,
      incomingStatus: result.incomingStatus || undefined,
      incomingUpdatedAt: result.incomingUpdatedAt || undefined,
      currentStatus: result.currentStatus || undefined,
      currentUpdatedAt: result.currentUpdatedAt || undefined,
      lastAckStatus: result.lastAckStatus || undefined,
      lastAckAt: result.lastAckAt || undefined,
      acknowledgedAt: result.acknowledgedAt || undefined,
      completedAt: result.completedAt || undefined,
      error: result.error || undefined,
      conflictPolicy: result.conflictPolicy || undefined
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

function handleAdminBroadcastDeliveryStats(db, broadcastId) {
  const stats = db.getBroadcastDeliveryStats(broadcastId);
  if (!stats) return { status: 404, body: { ok: false, error: "Broadcast not found" } };
  return {
    status: 200,
    body: {
      ok: true,
      broadcastId,
      stats
    }
  };
}

function handleAdminFleetDeliveryStats(db, queryParams = {}) {
  const stats = db.getFleetDeliveryStats({
    type: queryParams.type || null,
    priority: queryParams.priority || null,
    status: queryParams.status || "published"
  });
  return {
    status: 200,
    body: {
      ok: true,
      stats
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
  const actor = getAdminWriteActor(body, ["admin"]);
  if (!actor.ok) return { status: actor.status, body: actor.body };
  const { actorRole, actorId } = actor;
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
  return { status: 201, body: { ok: true, created: true, actorId, actorRole, subscription: result.subscription } };
}

/**
 * PATCH /frames/admin/subscriptions/:userId
 * Update a user's subscription (plan, status, provider).
 */
function handleAdminUpdateSubscription(db, userId, body) {
  const actor = getAdminWriteActor(body, ["admin"]);
  if (!actor.ok) return { status: actor.status, body: actor.body };
  const { actorRole, actorId } = actor;
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
  return { status: 200, body: { ok: true, updated: true, actorId, actorRole, subscription: result.subscription } };
}

/**
 * POST /frames/admin/subscriptions/:userId/cancel
 * Cancel a user's subscription (sets status to 'cancelled').
 */
function handleAdminCancelSubscription(db, userId, body = {}) {
  const actor = getAdminWriteActor(body, ["admin"]);
  if (!actor.ok) return { status: actor.status, body: actor.body };
  const { actorRole, actorId } = actor;
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
  return { status: 200, body: { ok: true, cancelled: true, actorId, actorRole, subscription: result.subscription } };
}

/**
 * GET /frames/admin/subscriptions/:userId
 * Get a single user's subscription details with entitlements.
 */
function handleAdminGetSubscription(db, userId, queryParams = {}) {
  const actor = getAdminReadActor(queryParams);
  if (!actor.ok) return { status: actor.status, body: actor.body };
  const { actorRole, actorId } = actor;

  const sub = db.getSubscription(userId);
  if (!sub) return { status: 404, body: { ok: false, error: "Subscription not found for user " + userId } };
  const deviceCount = db.countDevicesByOwner(userId);
  const entitlements = computeEntitlements(sub, deviceCount);
  return {
    status: 200,
    body: { ok: true, actorId, actorRole, subscription: sub, entitlements }
  };
}

// ── Admin Device Fleet Action Endpoints ─────────────────────────────────────

/**
 * GET /frames/admin/devices/:id/actions
 * Preview remote-action policy for a device without queueing commands.
 */
function handleAdminDeviceActionPolicy(db, deviceId, queryParams = {}) {
  const actor = getAdminReadActor(queryParams);
  if (!actor.ok) return { status: actor.status, body: actor.body };
  const { actorRole, actorId } = actor;

  const device = db.getDevice(deviceId);
  if (!device) return { status: 404, body: { ok: false, error: "Device not found" } };

  let ownerSubscription = null;
  let entitlements = null;
  if (device.ownerUserId) {
    const sub = db.getSubscription(device.ownerUserId);
    ownerSubscription = sub ? { plan: sub.plan, status: sub.status, provider: sub.provider, updatedAt: sub.updatedAt } : null;
    entitlements = computeEntitlements(sub, db.countDevicesByOwner(device.ownerUserId));
  }

  const pendingCommands = db.getPendingCommands(deviceId, { markDelivered: false });
  const actionAvailability = buildActionAvailability(device, actorRole, ownerSubscription, pendingCommands.length);

  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_admin_device_action_policy",
      generatedAt: now(),
      actor: {
        actorId,
        role: actorRole
      },
      device: {
        deviceId: device.deviceId,
        deviceName: device.deviceName,
        ownerUserId: device.ownerUserId,
        deviceType: device.deviceType,
        paired: device.paired,
        remoteEnabled: device.remoteEnabled,
        disabled: device.disabled,
        lastHeartbeatAt: device.lastHeartbeatAt,
        currentMode: device.currentMode,
        networkOnline: device.networkOnline
      },
      subscription: ownerSubscription,
      entitlements,
      pendingCommands: {
        total: pendingCommands.length,
        items: pendingCommands.map(cmd => ({
          commandId: cmd.commandId,
          commandType: cmd.commandType,
          status: cmd.status,
          deliveredAt: cmd.deliveredAt,
          createdAt: cmd.createdAt,
          updatedAt: cmd.updatedAt
        }))
      },
      actionAvailability,
      acceptedActorRoles: acceptedActorRoles()
    }
  };
}

/**
 * POST /frames/admin/devices/:id/actions
 * Queue a remote action on a device. Validates against role-action matrix.
 */
function handleAdminDeviceAction(db, deviceId, body) {
  if (!body.action) return { status: 400, body: { ok: false, error: "action is required" } };

  const actorRole = body.actorRole || "admin";
  const actorId = body.actorId || "admin";
  const roleRow = ROLE_ACTION_MATRIX.find(r => r.role === actorRole);
  if (!roleRow) {
    return {
      status: 400,
      body: {
        ok: false,
        error: "Invalid actorRole: " + actorRole,
        acceptedActorRoles: acceptedActorRoles()
      }
    };
  }

  const device = db.getDevice(deviceId);
  if (!device) return { status: 404, body: { ok: false, error: "Device not found" } };
  if (!device.paired) return { status: 400, body: { ok: false, error: "Device is not paired" } };

  // Validate the action against the full action matrix before role/device gates.
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
  const pendingCommands = db.getPendingCommands(deviceId, { markDelivered: false });
  const availability = buildActionAvailability(device, actorRole, ownerSubscription, pendingCommands.length);
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

  // Record admin audit trail for this action
  const commandId = command.command?.commandId || command.commandId || command.id;
  try {
    db.logCommandAudit({
      commandId,
      deviceId,
      commandType,
      risk: riskMap[commandType] || "medium",
      actorId,
      actorRole,
      reason: body.reason || null,
      payloadSummary: { action: body.action, payloadKeys: Object.keys(payload || {}) },
      authorization: {
        actionAvailability: actionAvail || null,
        deviceState: availability.deviceState,
      },
    });
  } catch (auditErr) {
    // Audit logging failure must not break the command queue
    process.stderr.write("[audit] logCommandAudit failed: " + auditErr.message + "\n");
  }

  return {
    status: 200,
    body: {
      ok: true,
      queued: true,
      commandId,
      auditId: commandId,       // audit is keyed on commandId for lookup
      action: body.action,
      commandType,
      risk: riskMap[commandType] || "medium",
      deviceId,
      actorId,
      actorRole,
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
  const actor = getAdminWriteActor(body, ["admin"]);
  if (!actor.ok) return { status: actor.status, body: actor.body };
  const { actorRole, actorId } = actor;
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
    body: { ok: true, updated: true, actorId, actorRole, device: safeDevice }
  };
}

/**
 * GET /frames/admin/devices
 *
 * Fleet-wide device listing with filters and pagination.
 * Returns per-device: state, subscription context, action availability, pending command count.
 *
 * Query params:
 *   ownerUserId   – filter by owner
 *   paired        – "true"/"false" filter paired status
 *   online        – "true"/"false" filter online (<5min heartbeat)
 *   disabled      – "true"/"false" filter disabled
 *   deviceType    – filter by device type
 *   updateChannel – filter by update channel
 *   search        – search device_id, device_name, owner_user_id
 *   limit         – page size (default 50)
 *   offset        – page offset
 */
function buildFleetActionSummary(devices, actorRole) {
  const summary = {
    scope: "current_page",
    actorRole,
    devices: {
      total: devices.length,
      online: 0,
      offline: 0,
      disabled: 0,
      remoteDisabled: 0
    },
    devicesWithAllowedRemoteAction: 0,
    devicesWithBlockedRemoteActionsOnly: 0,
    allowedActionCount: 0,
    blockedActionCount: 0,
    byBlocker: {},
    actions: {}
  };

  for (const device of devices) {
    if (device.online) summary.devices.online++;
    else summary.devices.offline++;
    if (device.disabled) summary.devices.disabled++;
    if (device.remoteEnabled === false) summary.devices.remoteDisabled++;

    let hasAllowed = false;
    let hasBlocked = false;
    const actions = (device.actionAvailability && device.actionAvailability.actions) || {};
    for (const [actionKey, actionResult] of Object.entries(actions)) {
      if (!summary.actions[actionKey]) {
        summary.actions[actionKey] = { allowed: 0, blocked: 0, reasonCodes: {} };
      }
      if (actionResult.allowed) {
        hasAllowed = true;
        summary.allowedActionCount++;
        summary.actions[actionKey].allowed++;
      } else {
        hasBlocked = true;
        summary.blockedActionCount++;
        summary.actions[actionKey].blocked++;
        const reasonCode = actionResult.reasonCode || "unknown";
        summary.byBlocker[reasonCode] = (summary.byBlocker[reasonCode] || 0) + 1;
        summary.actions[actionKey].reasonCodes[reasonCode] =
          (summary.actions[actionKey].reasonCodes[reasonCode] || 0) + 1;
      }
    }
    if (hasAllowed) summary.devicesWithAllowedRemoteAction++;
    else if (hasBlocked) summary.devicesWithBlockedRemoteActionsOnly++;
  }

  return summary;
}

function handleAdminListDevices(db, queryParams) {
  const actor = getAdminReadActor(queryParams);
  if (!actor.ok) return { status: actor.status, body: actor.body };
  const { actorRole, actorId } = actor;

  const {
    ownerUserId, paired, online, disabled, deviceType, updateChannel, search,
    limit: rawLimit, offset: rawOffset
  } = queryParams;

  const limit = Math.min(Math.max(parseInt(rawLimit, 10) || 50, 1), 500);
  const offset = Math.max(parseInt(rawOffset, 10) || 0, 0);

  // Build db.listDevices opts
  const listOpts = { limit, offset };
  if (ownerUserId) listOpts.ownerUserId = ownerUserId;
  if (paired !== undefined) listOpts.paired = paired === "true";
  if (disabled !== undefined) listOpts.disabled = disabled === "true";
  if (deviceType) listOpts.deviceType = deviceType;
  if (updateChannel) listOpts.updateChannel = updateChannel;
  if (search) listOpts.search = search;

  const fleet = db.listDevices(listOpts);

  // Load subscriptions for owner context
  const subs = db.listSubscriptions({ limit: 1000 });
  const subMap = new Map(subs.items.map(s => [s.userId, s]));

  const nowMs = Date.now();
  const ONLINE_THRESHOLD_MS = 300000; // 5 minutes

  const items = fleet.items.map(device => {
    const ownerSub = device.ownerUserId ? subMap.get(device.ownerUserId) : null;
    const ownerSubscription = ownerSub ? { plan: ownerSub.plan, status: ownerSub.status } : null;
    const isOnline = device.lastHeartbeatAt
      ? (nowMs - new Date(device.lastHeartbeatAt).getTime()) < ONLINE_THRESHOLD_MS
      : false;
    const pendingCommandCount = db.getPendingCommandCount(device.deviceId);

    return {
      deviceId: device.deviceId,
      deviceName: device.deviceName,
      deviceType: device.deviceType,
      ownerUserId: device.ownerUserId,
      softwareVersion: device.softwareVersion,
      currentMode: device.currentMode || "display",
      updateChannel: device.updateChannel,
      paired: device.paired,
      online: isOnline,
      remoteEnabled: device.remoteEnabled,
      disabled: !!device.disabled,
      lastHeartbeatAt: device.lastHeartbeatAt,
      releaseStatus: device.releaseStatus || "idle",
      pendingCommandCount,
      subscription: ownerSub ? {
        subscriptionId: ownerSub.subscriptionId,
        status: ownerSub.status,
        plan: ownerSub.plan,
        tier: ownerSub.tier
      } : null,
      entitlements: computeEntitlements(ownerSub, db.countDevicesByOwner(device.ownerUserId)),
      actionAvailability: buildActionAvailability(device, actorRole, ownerSubscription, pendingCommandCount)
    };
  });

  // Apply online filter (computed, not in SQL)
  const filtered = online !== undefined
    ? items.filter(d => online === "true" ? d.online : !d.online)
    : items;

  const total = online !== undefined
    ? (online === "true"
        ? fleet.items.filter(d => d.lastHeartbeatAt && (nowMs - new Date(d.lastHeartbeatAt).getTime()) < ONLINE_THRESHOLD_MS).length
        : fleet.items.filter(d => !d.lastHeartbeatAt || (nowMs - new Date(d.lastHeartbeatAt).getTime()) >= ONLINE_THRESHOLD_MS).length)
    : fleet.total;

  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_admin_device_list",
      actor: {
        actorId,
        role: actorRole
      },
      summary: buildFleetActionSummary(filtered, actorRole),
      acceptedActorRoles: acceptedActorRoles(),
      devices: { items: filtered, total, limit, offset }
    }
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

/**
 * GET /frames/admin/commands
 * Fleet-wide command queue listing with filters.
 */
function handleAdminListCommands(db, filters = {}) {
  const result = db.listAllCommands({
    deviceId: filters.deviceId,
    status: filters.status,
    commandType: filters.commandType,
    limit: filters.limit ? Number(filters.limit) : undefined,
    offset: filters.offset ? Number(filters.offset) : undefined,
  });
  return {
    status: 200,
    body: {
      ok: true,
      ...result,
      actionQueue: {
        items: result.items,
        total: result.total,
        limit: result.limit,
        offset: result.offset
      }
    }
  };
}

/**
 * GET /frames/admin/command-audits
 * Admin command audit trail with filters.
 */
function handleAdminListCommandAudits(db, filters = {}) {
  const result = db.listCommandAudits({
    deviceId: filters.deviceId,
    commandType: filters.commandType,
    status: filters.status,
    actorId: filters.actorId,
    actorRole: filters.actorRole,
    risk: filters.risk,
    limit: filters.limit ? Number(filters.limit) : undefined,
    offset: filters.offset ? Number(filters.offset) : undefined,
  });
  return { status: 200, body: { ok: true, ...result } };
}

function handleAdminActionQueue(db, filters = {}) {
  const actor = getAdminReadActor(filters);
  if (!actor.ok) return { status: actor.status, body: actor.body };
  const { actorRole, actorId } = actor;

  const acceptedStatuses = ["queued", "sent", "acknowledged", "processing", "completed", "failed", "error", "denied", "expired"];
  const acceptedRisks = ["low", "medium", "high", "critical"];
  if (filters.status && !acceptedStatuses.includes(filters.status)) {
    return {
      status: 400,
      body: {
        ok: false,
        error: "Invalid status: " + filters.status,
        acceptedStatuses
      }
    };
  }
  if (filters.risk && !acceptedRisks.includes(filters.risk)) {
    return {
      status: 400,
      body: {
        ok: false,
        error: "Invalid risk: " + filters.risk,
        acceptedRisks
      }
    };
  }
  if (filters.queuedByRole && !acceptedActorRoles().includes(filters.queuedByRole)) {
    return {
      status: 400,
      body: {
        ok: false,
        error: "Invalid queuedByRole: " + filters.queuedByRole,
        acceptedActorRoles: acceptedActorRoles()
      }
    };
  }

  const stalePendingHours = filters.stalePendingHours != null && filters.stalePendingHours !== ""
    ? Number(filters.stalePendingHours)
    : 2;
  if (!Number.isFinite(stalePendingHours) || stalePendingHours <= 0) {
    return {
      status: 400,
      body: {
        ok: false,
        error: "stalePendingHours must be a positive number",
        acceptedStalePendingHours: {
          minExclusive: 0,
          default: 2
        }
      }
    };
  }

  const commandResult = db.listAllCommands({
    deviceId: filters.deviceId,
    status: filters.status,
    commandType: filters.commandType,
    limit: filters.limit ? Number(filters.limit) : 200,
    offset: filters.offset ? Number(filters.offset) : 0
  });

  const auditResult = db.listCommandAudits({
    deviceId: filters.deviceId,
    commandType: filters.commandType,
    actorId: filters.queuedByActorId,
    actorRole: filters.queuedByRole,
    risk: filters.risk,
    limit: 500,
    offset: 0
  });

  const latestAuditByCommandId = new Map();
  for (const audit of auditResult.items) {
    if (!latestAuditByCommandId.has(audit.commandId)) {
      latestAuditByCommandId.set(audit.commandId, audit);
    }
  }

  const items = [];
  for (const command of commandResult.items) {
    const audit = latestAuditByCommandId.get(command.commandId) || null;
    const device = db.getDevice(command.deviceId);
    if (!device) continue;
    if (filters.ownerUserId && device.ownerUserId !== filters.ownerUserId) continue;
    if (filters.risk && (!audit || audit.risk !== filters.risk)) continue;
    if (filters.queuedByRole && (!audit || audit.actorRole !== filters.queuedByRole)) continue;
    if (filters.queuedByActorId && (!audit || audit.actorId !== filters.queuedByActorId)) continue;

    const online = device.lastHeartbeatAt
      ? (Date.now() - new Date(device.lastHeartbeatAt).getTime()) < 300000
      : false;
    const lifecycle = buildActionQueueLifecycle(command);
    const item = {
      commandId: command.commandId,
      commandType: command.commandType,
      status: command.status,
      risk: audit?.risk || null,
      actorId: audit?.actorId || null,
      actorRole: audit?.actorRole || null,
      reason: audit?.reason || null,
      payloadSummary: audit?.payloadSummary || {},
      authorization: audit?.authorization || {},
      error: command.error || audit?.error || null,
      createdAt: command.createdAt,
      updatedAt: command.updatedAt,
      deliveredAt: command.deliveredAt,
      acknowledgedAt: command.acknowledgedAt,
      completedAt: command.completedAt,
      lastAckStatus: command.lastAckStatus,
      lastAckAt: command.lastAckAt,
      lifecycle,
      device: {
        deviceId: device.deviceId,
        deviceName: device.deviceName,
        ownerUserId: device.ownerUserId,
        online,
        paired: device.paired,
        disabled: device.disabled,
        remoteEnabled: device.remoteEnabled !== false,
        lastHeartbeatAt: device.lastHeartbeatAt
      }
    };
    const attention = computeActionQueueAttention(item, stalePendingHours);
    item.ageSeconds = attention.ageSeconds;
    item.attentionReasons = attention.reasons;
    item.needsAttention = attention.reasons.length > 0;
    items.push(item);
  }

  const allMatchingBeforeAttentionFilter = items.length;
  const filteredItems = filters.attentionOnly ? items.filter(item => item.needsAttention) : items;

  const summary = {
    attention: 0,
    inProgress: 0,
    terminal: 0,
    byRisk: {},
    byActorRole: {},
    byAttentionReason: {},
    stalePendingHours,
    byLifecyclePhase: {},
    lifecycle: {
      delivered: 0,
      acknowledged: 0,
      terminal: 0,
      awaitingDelivery: 0,
      awaitingTerminal: 0,
      maxAgeSeconds: 0
    },
    devices: {
      total: 0,
      online: 0,
      offline: 0,
      withAttention: 0,
      withInProgress: 0,
      withTerminal: 0
    },
    allMatchingBeforeAttentionFilter
  };

  const deviceSummary = new Map();
  for (const item of filteredItems) {
    if (item.needsAttention) summary.attention += 1;
    if (item.lifecycle.terminal) summary.terminal += 1;
    else summary.inProgress += 1;
    if (item.risk) summary.byRisk[item.risk] = (summary.byRisk[item.risk] || 0) + 1;
    if (item.actorRole) summary.byActorRole[item.actorRole] = (summary.byActorRole[item.actorRole] || 0) + 1;
    for (const reason of item.attentionReasons) {
      summary.byAttentionReason[reason] = (summary.byAttentionReason[reason] || 0) + 1;
    }
    summary.byLifecyclePhase[item.lifecycle.phase] = (summary.byLifecyclePhase[item.lifecycle.phase] || 0) + 1;
    if (item.lifecycle.delivered) summary.lifecycle.delivered += 1;
    if (item.lifecycle.acknowledged) summary.lifecycle.acknowledged += 1;
    if (item.lifecycle.terminal) summary.lifecycle.terminal += 1;
    if (item.lifecycle.awaitingDelivery) summary.lifecycle.awaitingDelivery += 1;
    if (item.lifecycle.awaitingTerminal) summary.lifecycle.awaitingTerminal += 1;
    summary.lifecycle.maxAgeSeconds = Math.max(summary.lifecycle.maxAgeSeconds, item.ageSeconds || 0);

    const existing = deviceSummary.get(item.device.deviceId) || {
      online: item.device.online,
      needsAttention: false,
      hasInProgress: false,
      hasTerminal: false
    };
    existing.online = item.device.online;
    existing.needsAttention = existing.needsAttention || item.needsAttention;
    existing.hasInProgress = existing.hasInProgress || !item.lifecycle.terminal;
    existing.hasTerminal = existing.hasTerminal || item.lifecycle.terminal;
    deviceSummary.set(item.device.deviceId, existing);
  }

  summary.devices.total = deviceSummary.size;
  for (const device of deviceSummary.values()) {
    if (device.online) summary.devices.online += 1;
    else summary.devices.offline += 1;
    if (device.needsAttention) summary.devices.withAttention += 1;
    if (device.hasInProgress) summary.devices.withInProgress += 1;
    if (device.hasTerminal) summary.devices.withTerminal += 1;
  }

  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_admin_action_queue",
      generatedAt: now(),
      actor: {
        actorId,
        role: actorRole
      },
      filters: {
        deviceId: filters.deviceId || null,
        ownerUserId: filters.ownerUserId || null,
        status: filters.status || null,
        commandType: filters.commandType || null,
        risk: filters.risk || null,
        queuedByRole: filters.queuedByRole || null,
        queuedByActorId: filters.queuedByActorId || null,
        stalePendingHours
      },
      actionQueue: {
        total: filteredItems.length,
        limit: commandResult.limit,
        offset: commandResult.offset,
        items: filteredItems
      },
      summary
    }
  };
}

// ── Admin User Management Handlers ─────────────────────────────────────────

/**
 * GET /frames/admin/users
 *
 * List all users with their device count, subscription status, and entitlements.
 * Supports pagination (limit/offset) and filtering by subscription status/plan.
 *
 * @param {AosDb} db
 * @param {object} [filters]
 * @returns {{ status: number, body: object }}
 */
function handleAdminListUsers(db, filters = {}) {
  const { limit = 50, offset = 0, subscriptionStatus, subscriptionPlan } = filters;

  // Derive users from device owners + subscriptions
  const ownerIds = db.listOwnerUserIds();
  const subs = db.listSubscriptions({ limit: 1000 });
  const subMap = new Map(subs.items.map(s => [s.userId, s]));
  const allUserIds = new Set([...ownerIds, ...subs.items.map(s => s.userId)]);

  const users = [];
  for (const userId of allUserIds) {
    const sub = subMap.get(userId);

    // Apply filters
    if (subscriptionStatus && (!sub || sub.status !== subscriptionStatus)) continue;
    if (subscriptionPlan && (!sub || sub.plan !== subscriptionPlan)) continue;

    const deviceCount = db.countDevicesByOwner(userId);
    const entitlements = computeEntitlements(sub, deviceCount);
    users.push({
      userId,
      deviceCount,
      subscription: sub ? {
        subscriptionId: sub.subscriptionId,
        status: sub.status,
        plan: sub.plan,
        tier: sub.tier,
        currentPeriodEnd: sub.currentPeriodEnd,
        cancelAtPeriodEnd: sub.cancelAtPeriodEnd
      } : null,
      entitlements
    });
  }

  const total = users.length;
  const paged = users.slice(offset, offset + limit);

  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_admin_user_list",
      users: { items: paged, total, page: Math.floor(offset / limit) + 1, pageSize: limit }
    }
  };
}

function handleAdminUserFrameState(db, userId, queryParams = {}) {
  const actor = getAdminReadActor(queryParams);
  if (!actor.ok) return { status: actor.status, body: actor.body };
  const { actorRole, actorId } = actor;

  const sub = db.getSubscription(userId);
  const deviceCount = db.countDevicesByOwner(userId);
  const rawPrefs = db.getUserPreferences(userId);
  const preferences = {
    ...defaultFramePreferences(),
    ...((rawPrefs && rawPrefs.preferences) || {})
  };
  const likedIds = db.getLikedArtworks(userId);
  const fleet = db.listDevices({ ownerUserId: userId, pairedOnly: true, limit: 200 });

  const hasProfileData = !!sub ||
    deviceCount > 0 ||
    likedIds.length > 0 ||
    !!(rawPrefs && rawPrefs.updatedAt) ||
    Object.keys((rawPrefs && rawPrefs.preferences) || {}).length > 0;
  if (!hasProfileData) {
    return { status: 404, body: { ok: false, error: "User not found" } };
  }

  const entitlements = computeEntitlements(sub, deviceCount);
  const devices = fleet.items.map((d) => {
    const ownerSub = sub ? { plan: sub.plan, status: sub.status, provider: sub.provider, updatedAt: sub.updatedAt } : null;
    return {
      deviceId: d.deviceId,
      deviceName: d.deviceName,
      ownerUserId: d.ownerUserId,
      deviceType: d.deviceType,
      softwareVersion: d.softwareVersion,
      updateChannel: d.updateChannel,
      paired: d.paired,
      online: d.lastHeartbeatAt
        ? (Date.now() - new Date(d.lastHeartbeatAt).getTime()) < 300000
        : false,
      remoteEnabled: d.remoteEnabled,
      disabled: !!d.disabled,
      lastHeartbeatAt: d.lastHeartbeatAt,
      currentMode: d.currentMode || "display",
      actionAvailability: buildActionAvailability(d, actorRole, ownerSub)
    };
  });

  const actionReadiness = buildFleetActionSummary(devices, actorRole);
  actionReadiness.scope = "user_devices";

  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_admin_user_frame_state",
      generatedAt: now(),
      actor: {
        actorId,
        role: actorRole
      },
      userId,
      subscription: sub ? {
        subscriptionId: sub.subscriptionId,
        status: sub.status,
        plan: sub.plan,
        tier: sub.tier,
        provider: sub.provider,
        currentPeriodEnd: sub.currentPeriodEnd,
        cancelAtPeriodEnd: sub.cancelAtPeriodEnd
      } : null,
      entitlements,
      activeArtists: {
        items: preferences.activeArtists.map((artistId) => ({ artistId })),
        total: preferences.activeArtists.length,
        limit: entitlements.activeArtistsLimit,
        remaining: entitlements.activeArtistsLimit == null
          ? null
          : Math.max(0, entitlements.activeArtistsLimit - preferences.activeArtists.length)
      },
      likedArtworks: {
        items: likedIds.map((artworkId) => ({ artworkId })),
        total: likedIds.length
      },
      cachePreferences: {
        cacheLikedArtworks: !!preferences.cacheLikedArtworks,
        cacheRecentArtworks: !!preferences.cacheRecentArtworks,
        offlineFallbackMode: preferences.offlineFallbackMode,
        effective: {
          cacheLikedArtworks: !!preferences.cacheLikedArtworks && !!entitlements.offlineCache,
          cacheRecentArtworks: !!preferences.cacheRecentArtworks && !!entitlements.offlineCache
        }
      },
      devices: {
        items: devices,
        total: devices.length
      },
      actionReadiness
    }
  };
}

function handleAdminSubscribers(db, queryParams = {}) {
  const actor = getAdminReadActor(queryParams);
  if (!actor.ok) return { status: actor.status, body: actor.body };
  const { actorRole, actorId } = actor;

  const ownerIds = db.listOwnerUserIds();
  const subs = db.listSubscriptions({ limit: 1000 });
  const subMap = new Map(subs.items.map(s => [s.userId, s]));
  const allUserIds = new Set([...ownerIds, ...subs.items.map(s => s.userId)]);

  const normalizedStatus = queryParams.status || null;
  const normalizedPlan = queryParams.plan || null;
  const attentionOnly = queryParams.attentionOnly === true || queryParams.attentionOnly === "true";
  const devicesByUser = new Map();
  for (const device of db.listDevices({ pairedOnly: true, limit: 1000 }).items) {
    if (!device.ownerUserId) continue;
    const items = devicesByUser.get(device.ownerUserId) || [];
    items.push(device);
    devicesByUser.set(device.ownerUserId, items);
  }

  const rows = [];
  for (const userId of allUserIds) {
    const sub = subMap.get(userId) || null;
    const devices = devicesByUser.get(userId) || [];
    const rawPrefs = db.getUserPreferences(userId);
    const preferences = {
      ...defaultFramePreferences(),
      ...((rawPrefs && rawPrefs.preferences) || {})
    };
    const likedArtworkIds = db.getLikedArtworks(userId);
    const entitlements = computeEntitlements(sub, devices.length);
    const cacheBlocked = (!!preferences.cacheLikedArtworks || !!preferences.cacheRecentArtworks) && !entitlements.offlineCache;
    const noOnlineDevices = devices.length > 0 && devices.every((device) => {
      if (!device.lastHeartbeatAt) return true;
      return (Date.now() - new Date(device.lastHeartbeatAt).getTime()) >= 300000;
    });
    const activeArtistLimitReached = entitlements.activeArtistsLimit != null &&
      preferences.activeArtists.length >= entitlements.activeArtistsLimit;

    const attentionFlags = [];
    if (entitlements.degradedAccess) attentionFlags.push("degraded_subscription");
    if (!sub) attentionFlags.push("no_subscription");
    const deviceLimitExceeded = entitlements.deviceLimit != null && devices.length > entitlements.deviceLimit;
    if (deviceLimitExceeded) attentionFlags.push("device_limit_exceeded");
    if (cacheBlocked) attentionFlags.push("offline_cache_blocked");
    if (noOnlineDevices) attentionFlags.push("no_online_devices");
    if (activeArtistLimitReached) attentionFlags.push("active_artist_limit_reached");

    const status = sub ? sub.status : "none";
    const plan = sub ? sub.plan : null;
    if (normalizedStatus && status !== normalizedStatus) continue;
    if (normalizedPlan && plan !== normalizedPlan) continue;
    if (attentionOnly && attentionFlags.length === 0) continue;

    rows.push({
      userId,
      status,
      plan,
      tier: sub ? sub.tier : null,
      subscriptionId: sub ? sub.subscriptionId : null,
      deviceCount: devices.length,
      likedArtworkCount: likedArtworkIds.length,
      entitlements,
      cachePreferences: {
        cacheLikedArtworks: !!preferences.cacheLikedArtworks,
        cacheRecentArtworks: !!preferences.cacheRecentArtworks,
        offlineFallbackMode: preferences.offlineFallbackMode,
        effective: {
          likedArtworks: !!preferences.cacheLikedArtworks && !!entitlements.offlineCache,
          recentArtworks: !!preferences.cacheRecentArtworks && !!entitlements.offlineCache
        }
      },
      attentionFlags
    });
  }

  const summary = {
    subscribedUsers: 0,
    usersWithoutSubscription: 0,
    byStatus: {},
    devices: { total: 0, online: 0, offline: 0 },
    attention: {
      degraded: 0,
      deviceLimitExceeded: 0,
      offlineCacheBlocked: 0,
      noSubscription: 0,
      noOnlineDevices: 0,
      activeArtistLimitReached: 0
    }
  };

  for (const row of rows) {
    summary.byStatus[row.status] = (summary.byStatus[row.status] || 0) + 1;
    if (row.subscriptionId) summary.subscribedUsers += 1;
    else summary.usersWithoutSubscription += 1;
    summary.devices.total += row.deviceCount;
    const userDevices = devicesByUser.get(row.userId) || [];
    for (const device of userDevices) {
      const online = device.lastHeartbeatAt
        ? (Date.now() - new Date(device.lastHeartbeatAt).getTime()) < 300000
        : false;
      if (online) summary.devices.online += 1;
      else summary.devices.offline += 1;
    }
    if (row.attentionFlags.includes("degraded_subscription")) summary.attention.degraded += 1;
    if (row.attentionFlags.includes("device_limit_exceeded")) summary.attention.deviceLimitExceeded += 1;
    if (row.attentionFlags.includes("offline_cache_blocked")) summary.attention.offlineCacheBlocked += 1;
    if (row.attentionFlags.includes("no_subscription")) summary.attention.noSubscription += 1;
    if (row.attentionFlags.includes("no_online_devices")) summary.attention.noOnlineDevices += 1;
    if (row.attentionFlags.includes("active_artist_limit_reached")) summary.attention.activeArtistLimitReached += 1;
  }

  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_admin_subscriber_summary",
      generatedAt: now(),
      actor: {
        actorId,
        role: actorRole
      },
      subscribers: {
        items: rows,
        total: rows.length
      },
      summary
    }
  };
}

/**
 * GET /frames/admin/release-rollouts
 * Admin endpoint: list release rollout progress with filters and pagination.
 * Returns enriched data including device name, type, release version, channel, etc.
 */
function handleAdminListReleaseRollouts(db, queryParams) {
  const {
    releaseId, deviceId, status,
    limit: rawLimit, offset: rawOffset
  } = queryParams;

  const limit = Math.min(Math.max(parseInt(rawLimit, 10) || 50, 1), 200);
  const offset = Math.max(parseInt(rawOffset, 10) || 0, 0);

  const result = db.getReleaseRollouts({ releaseId, deviceId, status, limit, offset });
  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_admin_release_rollouts",
      ...result
    }
  };
}

/**
 * GET /frames/admin/pairing-queue
 *
 * Read-only pairing setup queue for Admin/Profile > Frames setup views.
 */
function handleAdminPairingQueue(db, queryParams = {}) {
  const actor = getAdminReadActor(queryParams);
  if (!actor.ok) return { status: actor.status, body: actor.body };

  const acceptedStatuses = ["pending", "expired", "paired", "no_code"];
  const status = queryParams.status || null;
  if (status && !acceptedStatuses.includes(status)) {
    return {
      status: 400,
      body: {
        ok: false,
        error: "Invalid status: " + status,
        acceptedStatuses
      }
    };
  }

  const limit = queryParams.limit ? parseInt(queryParams.limit, 10) : 100;
  const offset = queryParams.offset ? parseInt(queryParams.offset, 10) : 0;
  const result = db.listPairingQueue({
    status,
    attentionOnly: queryParams.attentionOnly === "true" || queryParams.attentionOnly === true,
    search: queryParams.search || null,
    limit,
    offset
  });

  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_admin_pairing_queue",
      generatedAt: now(),
      actor: {
        actorId: actor.actorId,
        role: actor.actorRole
      },
      pairings: {
        items: result.items,
        total: result.total,
        limit: result.limit,
        offset: result.offset
      },
      summary: result.summary,
      filters: {
        acceptedStatuses,
        status,
        attentionOnly: queryParams.attentionOnly === "true" || queryParams.attentionOnly === true,
        search: queryParams.search || null
      }
    }
  };
}

/**
 * POST /frames/admin/devices/:id/pairing-code
 *
 * Role-gated operator path for refreshing expired or missing setup codes.
 */
function handleAdminRefreshPairingCode(db, deviceId, body = {}) {
  const actor = getAdminWriteActor(body, ["admin", "maintainer"]);
  if (!actor.ok) return { status: actor.status, body: actor.body };

  const record = db.getDevice(deviceId);
  if (!record) return { status: 404, body: { ok: false, error: "Device not found", reason: "device_not_found" } };
  if (record.paired) {
    return {
      status: 409,
      body: {
        ok: false,
        error: "Cannot refresh pairing code for a paired device",
        reason: "device_already_paired",
        actorId: actor.actorId,
        actorRole: actor.actorRole
      }
    };
  }

  const result = db.refreshPairingCode(deviceId);
  if (!result.ok) {
    const status = result.reason === "device_not_found" ? 404 : 409;
    return { status, body: { ok: false, error: result.error, reason: result.reason } };
  }

  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_admin_pairing_code_refreshed",
      generatedAt: now(),
      actorId: actor.actorId,
      actorRole: actor.actorRole,
      device: {
        deviceId,
        deviceName: record.deviceName,
        deviceType: record.deviceType,
        paired: false
      },
      pairing: {
        status: "pending",
        pairingCode: result.pairingCode,
        expiresAt: result.expiresAt,
        refreshedAt: result.refreshedAt
      }
    }
  };
}

/**
 * GET /frames/admin/readiness
 * Admin endpoint: platform-level readiness snapshot for Admin > Frames dashboard.
 * Returns a comprehensive view of system health and readiness across users, devices, subscriptions, and actions.
 *
 * Query params:
 *   actorRole - Role to compute action availability for (admin, owner, maintainer, support, curator)
 *   actorId   - Identifier for the actor (used for echoing back)
 *
 * @param {AosDb} db
 * @param {object} [queryParams]
 * @returns {{ status: number, body: object }}
 */
function handleAdminReadiness(db, queryParams) {
  const actorRole = queryParams.actorRole || "admin";
  const actorId = queryParams.actorId || "admin";

  // Validate actorRole
  const validRoles = ["admin", "owner", "maintainer", "support", "curator"];
  if (!actorRole || !validRoles.includes(actorRole)) {
    return {
      status: 400,
      body: {
        ok: false,
        error: `Invalid actorRole. Must be one of: ${validRoles.join(", ")}`,
        acceptedActorRoles: validRoles
      }
    };
  }

  const generatedAt = now();

  // ── Gather base data ──────────────────────────────────────────────────────
  const ownerIds = db.listOwnerUserIds();
  const subs = db.listSubscriptions({ limit: 1000 });
  const subMap = new Map(subs.items.map(s => [s.userId, s]));
  const allUserIds = new Set([...ownerIds, ...subs.items.map(s => s.userId)]);

  const fleet = db.listDevices({ limit: 10000 }); // Get all devices for platform view
  const nowMs = Date.now();
  const ONLINE_THRESHOLD_MS = 300000; // 5 minutes
  const STALE_PENDING_HOURS = 4; // Pending commands older than this are considered stale

  // ── User statistics ───────────────────────────────────────────────────────
  const users = [];
  const usersWithPreferences = [];
  const usersWithLikedArtworks = [];
  
  for (const userId of allUserIds) {
    const sub = subMap.get(userId);
    const deviceCount = db.countDevicesByOwner(userId);
    const prefs = db.getUserPreferences(userId);
    const likedIds = db.getLikedArtworks(userId);
    
    users.push({ userId, sub, deviceCount });
    
    if (prefs && prefs.preferences && Object.keys(prefs.preferences).length > 0) {
      usersWithPreferences.push(userId);
    }
    
    if (likedIds && likedIds.length > 0) {
      usersWithLikedArtworks.push(userId);
    }
  }

  // ── Subscription statistics ───────────────────────────────────────────────
  const subscriptionStatusCounts = {};
  const subscriptionPlanCounts = {};
  let degradedSubscriptionCount = 0;
  
  for (const sub of subs.items) {
    subscriptionStatusCounts[sub.status] = (subscriptionStatusCounts[sub.status] || 0) + 1;
    subscriptionPlanCounts[sub.plan] = (subscriptionPlanCounts[sub.plan] || 0) + 1;
    
    if (DEGRADED_STATUSES.has(sub.status)) {
      degradedSubscriptionCount++;
    }
  }

  // ── Device fleet statistics ───────────────────────────────────────────────
  const fleetStats = {
    total: fleet.items.length,
    paired: 0,
    unpaired: 0,
    online: 0,
    offline: 0,
    disabled: 0,
    remoteEnabled: 0,
    remoteDisabled: 0
  };
  
  const pairedDevices = [];
  const unpairedDevices = [];
  const onlineDevices = [];
  const offlineDevices = [];
  const disabledDevices = [];
  
  for (const device of fleet.items) {
    if (device.paired) {
      fleetStats.paired++;
      pairedDevices.push(device);
    } else {
      fleetStats.unpaired++;
      unpairedDevices.push(device);
    }
    
    const isOnline = device.lastHeartbeatAt
      ? (nowMs - new Date(device.lastHeartbeatAt).getTime()) < ONLINE_THRESHOLD_MS
      : false;
    
    if (isOnline) {
      fleetStats.online++;
      onlineDevices.push(device);
    } else {
      fleetStats.offline++;
      offlineDevices.push(device);
    }
    
    if (device.disabled) {
      fleetStats.disabled++;
      disabledDevices.push(device);
    }
    
    if (device.remoteEnabled !== false) {
      fleetStats.remoteEnabled++;
    } else {
      fleetStats.remoteDisabled++;
    }
  }

  // ── Pairing state statistics ──────────────────────────────────────────────
  const pairingQueue = db.listPairingQueue({ limit: 10000 });
  const pairingByStatus = pairingQueue.summary.byStatus;
  const pairingStats = {
    pending: pairingByStatus.pending || 0,
    expired: pairingByStatus.expired || 0,
    paired: pairingByStatus.paired || 0,
    noCode: pairingByStatus.no_code || 0,
    attention: pairingQueue.summary.attention || 0,
    byStatus: pairingByStatus
  };

  // ── Settings and preferences readiness ────────────────────────────────────
  // Users with explicit preferences vs those using defaults
  const settingsReadiness = {
    totalUsers: users.length,
    usersWithPreferences: usersWithPreferences.length,
    usersUsingDefaults: users.length - usersWithPreferences.length,
    hasExplicitPreferences: usersWithPreferences.length > 0
  };

  // ── Cache preference readiness ────────────────────────────────────────────
  // Users who have caching enabled (cacheLikedArtworks or cacheRecentArtworks)
  const cacheEnabledUsers = [];
  const cacheDisabledUsers = [];
  const cacheBlockedUsers = [];
  
  for (const userId of allUserIds) {
    const sub = subMap.get(userId);
    const deviceCount = db.countDevicesByOwner(userId);
    const entitlements = computeEntitlements(sub, deviceCount);
    const prefs = db.getUserPreferences(userId);
    const cacheLiked = prefs && prefs.preferences && prefs.preferences.cacheLikedArtworks === true;
    const cacheRecent = prefs && prefs.preferences && prefs.preferences.cacheRecentArtworks === true;
    
    if (cacheLiked || cacheRecent) {
      cacheEnabledUsers.push(userId);
    } else {
      cacheDisabledUsers.push(userId);
    }
    if (!entitlements.offlineCache) {
      cacheBlockedUsers.push(userId);
    }
  }

  // ── Active artists readiness ──────────────────────────────────────────────
  // Users who have selected active artists
  const usersWithActiveArtists = [];
  
  for (const userId of allUserIds) {
    const prefs = db.getUserPreferences(userId);
    const activeArtists = prefs && prefs.preferences && prefs.preferences.activeArtists;
    if (activeArtists && Array.isArray(activeArtists) && activeArtists.length > 0) {
      usersWithActiveArtists.push(userId);
    }
  }

  // ── Stale pending commands ───────────────────────────────────────────────
  // Commands that have been pending longer than STALE_PENDING_HOURS
  const stalePendingCommands = [];
  const stalePendingDevices = new Set();
  
  for (const device of fleet.items) {
    const pendingCommands = db.getPendingCommands(device.deviceId, { markDelivered: false });
    for (const cmd of pendingCommands) {
      const createdAt = new Date(cmd.createdAt || cmd.updatedAt || now());
      const ageHours = (nowMs - createdAt.getTime()) / (1000 * 60 * 60);
      
      if (ageHours > STALE_PENDING_HOURS) {
        stalePendingCommands.push(cmd);
        stalePendingDevices.add(device.deviceId);
      }
    }
  }

  // ── Role-gated action availability across fleet ───────────────────────────
  // For the requested actorRole, compute how many devices allow/block each action
  const roleActionMatrixRow = ROLE_ACTION_MATRIX.find(r => r.role === actorRole);
  const actionAvailability = {};
  
  if (roleActionMatrixRow) {
    // Initialize counters for each action
    for (const [actionKey] of Object.entries(roleActionMatrixRow.actions)) {
      actionAvailability[actionKey] = {
        allowedDevices: 0,
        blockedDevices: 0,
        blockerCounts: {}
      };
    }
    
    // Check each device
    for (const device of fleet.items) {
      const ownerSub = device.ownerUserId ? subMap.get(device.ownerUserId) : null;
      const ownerSubscription = ownerSub ? { plan: ownerSub.plan, status: ownerSub.status } : null;
      const pendingCommandCount = db.getPendingCommandCount(device.deviceId);
      
      const availability = buildActionAvailability(
        device,
        actorRole,
        ownerSubscription,
        pendingCommandCount
      );
      
      // Tally results for each action
      for (const [actionKey, actionResult] of Object.entries(availability.actions)) {
        if (actionAvailability[actionKey]) {
          if (actionResult.allowed) {
            actionAvailability[actionKey].allowedDevices++;
          } else {
            actionAvailability[actionKey].blockedDevices++;
            const reasonCode = actionResult.reasonCode || "unknown";
            actionAvailability[actionKey].blockerCounts[reasonCode] = 
              (actionAvailability[actionKey].blockerCounts[reasonCode] || 0) + 1;
          }
        }
      }
    }
  }

  // ── Compute surface statuses ─────────────────────────────────────────────
  // Helper to determine status based on counts
  const computeSurfaceStatus = (hasAny, total, threshold = 0) => {
    if (!hasAny) return "empty";
    if (hasAny >= total) return "ready";
    return "needs_attention";
  };
  
  const computeReadinessStatus = (readyCount, totalCount) => {
    if (readyCount === totalCount) return "ready";
    if (readyCount === 0) return "blocked";
    return "needs_attention";
  };

  const surfaceStatus = {
    profile: computeSurfaceStatus(usersWithPreferences.length, users.length),
    pairing: computeSurfaceStatus(
      pairingStats.paired,
      pairingStats.paired + pairingStats.pending + pairingStats.expired + pairingStats.noCode
    ),
    settings: computeSurfaceStatus(usersWithPreferences.length, users.length),
    cachePreferences: computeReadinessStatus(cacheEnabledUsers.length, users.length),
    subscribers: computeSurfaceStatus(
      allUserIds.size - ownerIds.size,
      allUserIds.size
    ),
    subscriptions: degradedSubscriptionCount === 0 ? "ready" : "needs_attention",
    fleet: computeReadinessStatus(fleetStats.online, fleetStats.total),
    roleGatedActions: computeReadinessStatus(
      roleActionMatrixRow
        ? Object.values(roleActionMatrixRow.actions).filter(a => a.allowed).length
        : 0,
      roleActionMatrixRow ? Object.keys(roleActionMatrixRow.actions).length : 0
    )
  };

  const surfaces = {
    profile: { status: surfaceStatus.profile },
    pairing: { status: surfaceStatus.pairing },
    settings: { status: surfaceStatus.settings },
    cache: { status: surfaceStatus.cachePreferences },
    cachePreferences: { status: surfaceStatus.cachePreferences },
    subscribers: { status: surfaceStatus.subscribers },
    subscriptions: { status: surfaceStatus.subscriptions },
    fleet: { status: surfaceStatus.fleet },
    roleGatedActions: { status: surfaceStatus.roleGatedActions }
  };

  // ── Summary counts ───────────────────────────────────────────────────────
  const summary = {
    users: {
      total: users.length,
      withPreferences: usersWithPreferences.length,
      withLikedArtworks: usersWithLikedArtworks.length,
      withActiveArtists: usersWithActiveArtists.length
    },
    subscriptions: {
      total: subs.items.length,
      byStatus: subscriptionStatusCounts,
      byPlan: subscriptionPlanCounts,
      degradedCount: degradedSubscriptionCount
    },
    devices: {
      total: fleetStats.total,
      paired: fleetStats.paired,
      unpaired: fleetStats.unpaired,
      online: fleetStats.online,
      offline: fleetStats.offline,
      disabled: fleetStats.disabled,
      remoteEnabled: fleetStats.remoteEnabled,
      remoteDisabled: fleetStats.remoteDisabled,
      withStalePendingCommands: stalePendingDevices.size
    },
    pairing: {
      pending: pairingStats.pending,
      expired: pairingStats.expired,
      paired: pairingStats.paired,
      noCode: pairingStats.noCode,
      attention: pairingStats.attention,
      byStatus: pairingStats.byStatus
    },
    cache: {
      enabledUsers: cacheEnabledUsers.length,
      disabledUsers: cacheDisabledUsers.length,
      blockedUsers: cacheBlockedUsers.length
    },
    actions: {
      totalActions: Object.keys(actionAvailability).length,
      allowedDevices: {}, // Will fill below
      blockedDevices: {}, // Will fill below
      byAction: {},
      byBlocker: {}
    },
    attentionReasons: {
      // Count of devices blocked for each reason across all actions
      // This would require aggregating blockerCounts from actionAvailability
      // For simplicity, we'll compute a few key ones
      subscriptionDegraded: degradedSubscriptionCount,
      offlineDevices: fleetStats.offline,
      disabledDevices: fleetStats.disabled,
      remoteDisabledDevices: fleetStats.remoteDisabled,
      stalePendingCommands: stalePendingDevices.size
    }
  };
  
  // Fill in per-action allowed/blocked device counts
  for (const [actionKey, actionData] of Object.entries(actionAvailability)) {
    summary.actions.allowedDevices[actionKey] = actionData.allowedDevices;
    summary.actions.blockedDevices[actionKey] = actionData.blockedDevices;
    summary.actions.byAction[actionKey] = {
      allowed: actionData.allowedDevices,
      blocked: actionData.blockedDevices,
      allowedDevices: actionData.allowedDevices,
      blockedDevices: actionData.blockedDevices,
      blockerCounts: actionData.blockerCounts
    };
    for (const [reasonCode, count] of Object.entries(actionData.blockerCounts)) {
      summary.actions.byBlocker[reasonCode] = (summary.actions.byBlocker[reasonCode] || 0) + count;
    }
  }

  // ── Filters info ───────────────────────────────────────────────────────
  const filters = {
    scanLimit: fleet.items.length,
    stalePendingHours: STALE_PENDING_HOURS
  };

  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_admin_readiness",
      generatedAt,
      actor: {
        actorId: actorId || null,
        role: actorRole
      },
      surfaces,
      summary,
      filters
    }
  };
}

/**
 * GET /frames/admin/users/:userId
 *
 * Get a single user's full profile: devices, subscription, preferences,
 * liked artworks, entitlements, and activity summary.
 *
 * @param {AosDb} db
 * @param {string} userId
 * @returns {{ status: number, body: object }}
 */
function handleAdminGetUser(db, userId, queryParams = {}) {
  const actor = getAdminReadActor(queryParams);
  if (!actor.ok) return { status: actor.status, body: actor.body };
  const { actorRole, actorId } = actor;

  // Verify the user exists (has devices or a subscription)
  const deviceCount = db.countDevicesByOwner(userId);
  const sub = db.getSubscription(userId);

  if (deviceCount === 0 && !sub) {
    return { status: 404, body: { ok: false, error: "User not found: " + userId } };
  }

  const entitlements = computeEntitlements(sub, deviceCount);

  // Devices owned by this user
  const deviceList = db.listDevices({ ownerUserId: userId, pairedOnly: true, limit: 100 });
  const devices = deviceList.items.map(d => {
    const ownerSub = sub ? { plan: sub.plan, status: sub.status } : null;
    return {
      deviceId: d.deviceId,
      deviceName: d.deviceName,
      deviceType: d.deviceType,
      softwareVersion: d.softwareVersion,
      updateChannel: d.updateChannel,
      paired: d.paired,
      online: d.lastHeartbeatAt
        ? (Date.now() - new Date(d.lastHeartbeatAt).getTime()) < 300000
        : false,
      remoteEnabled: d.remoteEnabled,
      disabled: !!d.disabled,
      lastHeartbeatAt: d.lastHeartbeatAt,
      currentMode: d.currentMode || "display",
      releaseStatus: d.releaseStatus || 'idle',
      actionAvailability: buildActionAvailability(d, actorRole, ownerSub)
    };
  });

  // User preferences
  const rawPrefs = db.getUserPreferences(userId);
  const preferences = (rawPrefs && rawPrefs.preferences && Object.keys(rawPrefs.preferences).length > 0)
    ? rawPrefs.preferences
    : null;

  // Liked artworks
  const likedIds = db.getLikedArtworks(userId);

  // Subscription detail
  const subscription = sub ? {
    subscriptionId: sub.subscriptionId,
    status: sub.status,
    plan: sub.plan,
    tier: sub.tier,
    provider: sub.provider,
    currentPeriodEnd: sub.currentPeriodEnd,
    cancelAtPeriodEnd: sub.cancelAtPeriodEnd,
    createdAt: sub.createdAt,
    updatedAt: sub.updatedAt
  } : null;

  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_admin_user_detail",
      generatedAt: now(),
      actor: {
        actorId,
        role: actorRole
      },
      user: {
        userId,
        deviceCount,
        devices,
        subscription,
        entitlements,
        preferences: preferences || {
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
          offlineFallbackMode: "cached"
        },
        likedArtworks: likedIds.map(artworkId => ({ artworkId })),
        likedArtworkCount: likedIds.length
      }
    }
  };
}

/**
 * GET /frames/admin/users/:userId/preferences
 *
 * Get a user's preferences for the admin dashboard.
 *
 * @param {AosDb} db
 * @param {string} userId
 * @returns {{ status: number, body: object }}
 */
function handleAdminGetUserPreferences(db, userId, queryParams = {}) {
  const actor = getAdminReadActor(queryParams);
  if (!actor.ok) return { status: actor.status, body: actor.body };
  const { actorRole, actorId } = actor;

  const rawPrefs = db.getUserPreferences(userId);
  if (!rawPrefs || !rawPrefs.preferences || Object.keys(rawPrefs.preferences).length === 0) {
    // Return defaults for users without explicit preferences
    return {
      status: 200,
      body: {
        ok: true,
        actorId,
        actorRole,
        userId,
        preferences: {
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
          offlineFallbackMode: "cached"
        },
        updatedAt: null
      }
    };
  }
  return {
    status: 200,
    body: {
      ok: true,
      actorId,
      actorRole,
      userId,
      preferences: rawPrefs.preferences,
      updatedAt: rawPrefs.updatedAt
    }
  };
}

/**
 * PATCH /frames/admin/users/:userId/preferences
 *
 * Update a user's preferences. Supports partial updates (merges with existing).
 * Validates known preference fields and rejects unknown keys.
 *
 * @param {AosDb} db
 * @param {string} userId
 * @param {object} body
 * @returns {{ status: number, body: object }}
 */
function handleAdminUpdateUserPreferences(db, userId, body) {
  const actor = getAdminWriteActor(body, ["admin"]);
  if (!actor.ok) return { status: actor.status, body: actor.body };
  const { actorRole, actorId } = actor;
  const VALID_KEYS = new Set([
    "actorId",
    "actorRole",
    "activeArtists",
    "streamCategories",
    "allowImages",
    "allowVideos",
    "allowSoundWorks",
    "allowGenerativeWorks",
    "autoplay",
    "videoAutoplay",
    "soundAutoplay",
    "soundEnabled",
    "cacheLikedArtworks",
    "cacheRecentArtworks",
    "offlineFallbackMode",
    "updatedAt"  // metadata — stripped before merge, used for conflict detection
  ]);

  // Validate keys
  const unknownKeys = Object.keys(body).filter(k => !VALID_KEYS.has(k));
  if (unknownKeys.length > 0) {
    return { status: 400, body: { ok: false, error: "Unknown preference keys: " + unknownKeys.join(", "), validKeys: [...VALID_KEYS] } };
  }

  const preferenceKeys = Object.keys(body).filter(k => !["updatedAt", "actorId", "actorRole"].includes(k));
  if (preferenceKeys.length === 0) {
    return { status: 400, body: { ok: false, error: "No preferences to update. Send at least one preference key." } };
  }

  // Validate specific fields
  if (body.activeArtists !== undefined && !Array.isArray(body.activeArtists)) {
    return { status: 400, body: { ok: false, error: "activeArtists must be an array" } };
  }
  if (body.streamCategories !== undefined && !Array.isArray(body.streamCategories)) {
    return { status: 400, body: { ok: false, error: "streamCategories must be an array" } };
  }
  if (body.offlineFallbackMode !== undefined && !["cached", "black", "message"].includes(body.offlineFallbackMode)) {
    return { status: 400, body: { ok: false, error: "offlineFallbackMode must be one of: cached, black, message" } };
  }

  // Extract client's last-seen updatedAt for conflict detection
  const clientUpdatedAt = body.updatedAt || null;
  if (body.updatedAt !== undefined && !isValidIsoTimestamp(body.updatedAt)) {
    return {
      status: 400,
      body: {
        ok: false,
        error: "updatedAt must be an ISO-8601 UTC timestamp",
        reason: "invalid_updated_at"
      }
    };
  }

  // Build the preference patch (strip updatedAt — it's metadata, not a preference)
  const patch = { ...body };
  delete patch.actorId;
  delete patch.actorRole;
  delete patch.updatedAt;

  const result = db.setUserPreferences(userId, patch, clientUpdatedAt);

  if (result.conflict) {
    return {
      status: 200,
      body: {
        ok: false,
        error: "preferences conflict",
        reason: "stale_write",
        conflict: true,
        preferences: result.preferences,
        incomingPreferences: result.incomingPreferences,
        incomingUpdatedAt: result.incomingUpdatedAt,
        currentUpdatedAt: result.currentUpdatedAt,
        conflictPolicy: result.conflictPolicy,
        updatedAt: result.updatedAt
      }
    };
  }

  return {
    status: 200,
    body: {
      ok: true,
      updated: true,
      actorId,
      actorRole,
      userId,
      preferences: result.preferences,
      updatedAt: result.updatedAt
    }
  };
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
function handleAdminBundle(db, profileUserId, queryParams = {}) {
  const actor = getAdminReadActor(queryParams);
  if (!actor.ok) return { status: actor.status, body: actor.body };
  const { actorRole, actorId } = actor;

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
      actionAvailability: buildActionAvailability(device, actorRole, ownerSubscription)
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
          actorId,
          userId: effectiveUserId,
          role: actorRole
        },
        users: { items: usersItems, total: usersItems.length, page: 1, pageSize: 50 },
        subscriptions: { items: subs.items, total: subs.total, page: 1, pageSize: 50 },
        devices: { items: fleetDevices, total: fleetDevices.length, page: 1, pageSize: 50 },
        remoteActions: {
          acceptedActorRoles: acceptedActorRoles(),
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
function handleAdminDeviceSnapshot(db, deviceId, queryParams = {}) {
  const actor = getAdminReadActor(queryParams);
  if (!actor.ok) return { status: actor.status, body: actor.body };
  const { actorRole, actorId } = actor;

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
  const pendingCommands = db.getPendingCommands(deviceId, { markDelivered: false });

  const actionAvailability = buildActionAvailability(device, actorRole, ownerSubscription, pendingCommands.length);

  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_admin_device_snapshot",
      generatedAt: now(),
      actor: {
        actorId,
        role: actorRole
      },
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
      actionAvailability,
      releaseRollouts: db.getReleaseRollouts({ deviceId, limit: 10 })
    }
  };
}

// ── Request router ───────────────────────────────────────────────────────────

// ── CORS helpers ────────────────────────────────────────────────────────────

const CORS_HEADERS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, PATCH, PUT, DELETE, OPTIONS",
  "access-control-allow-headers": "Content-Type, Authorization, x-admin-token, x-frame-device-key, x-user-token",
  "access-control-max-age": "86400"
};

/**
 * Send a CORS preflight response for OPTIONS requests.
 * Browsers send OPTIONS before cross-origin requests with custom headers.
 * Without this, any browser-based admin dashboard or Profile > Frames page
 * at a different origin cannot call the hosted API.
 */
function sendCorsPreflight(res) {
  res.writeHead(204, CORS_HEADERS);
  res.end();
}

// ── User-facing Profile endpoints (/frames/me/*) ────────────────────────
//
// These endpoints serve the Profile > Frames page in the online app.
// They require user authentication (user token or admin token).
// The userId is resolved from the token — callers never specify it in the path.
//

/**
 * GET /frames/me — User profile summary
 *
 * Returns: user info, device count, subscription summary, preferences summary,
 * liked artwork count, and entitlements.
 *
 * Auth: user token or admin token (with ?userId=...)
 */
function handleMeProfile(db, userId) {
  if (!userId) return { status: 400, body: { ok: false, error: "userId required (pass ?userId=... for admin access)" } };

  const deviceCount = db.countDevicesByOwner(userId);
  const sub = db.getSubscription(userId);
  const entitlements = computeEntitlements(sub, deviceCount);
  const rawPrefs = db.getUserPreferences(userId);
  const likedIds = db.getLikedArtworks(userId);

  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_me_profile",
      generatedAt: now(),
      profile: {
        userId,
        deviceCount,
        subscription: sub ? {
          plan: sub.plan,
          status: sub.status,
          provider: sub.provider,
          createdAt: sub.createdAt,
          updatedAt: sub.updatedAt
        } : null,
        entitlements: {
          maxDevices: entitlements.deviceLimit === null ? null : entitlements.deviceLimit,
          devicesRemaining: entitlements.deviceSlotsRemaining,
          offlineCache: entitlements.offlineCache,
          remoteActions: entitlements.canUseRemoteActions,
          activeArtistsLimit: entitlements.activeArtistsLimit
        },
        likedArtworkCount: likedIds.length,
        preferences: rawPrefs.preferences || {},
        preferencesUpdatedAt: rawPrefs.updatedAt
      }
    }
  };
}

/**
 * GET /frames/me/devices — User's paired devices
 *
 * Returns: list of devices owned by the user with online status, current mode,
 * release status, and action availability.
 *
 * Auth: user token or admin token (with ?userId=...)
 */
function handleMeDevices(db, userId) {
  if (!userId) return { status: 400, body: { ok: false, error: "userId required (pass ?userId=... for admin access)" } };

  const sub = db.getSubscription(userId);
  const ownerSub = sub ? { plan: sub.plan, status: sub.status } : null;
  const deviceList = db.listDevices({ ownerUserId: userId, pairedOnly: true, limit: 100 });

  const devices = deviceList.items.map(d => ({
    deviceId: d.deviceId,
    deviceName: d.deviceName,
    deviceType: d.deviceType,
    softwareVersion: d.softwareVersion,
    updateChannel: d.updateChannel,
    online: d.lastHeartbeatAt
      ? (Date.now() - new Date(d.lastHeartbeatAt).getTime()) < 300000
      : false,
    remoteEnabled: d.remoteEnabled,
    disabled: !!d.disabled,
    lastHeartbeatAt: d.lastHeartbeatAt,
    currentMode: d.currentMode || "display",
    releaseStatus: d.releaseStatus || "idle"
  }));

  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_me_devices",
      generatedAt: now(),
      devices,
      total: deviceList.total
    }
  };
}

/**
 * GET /frames/me/preferences — User preferences
 *
 * Returns: the user's full preferences object with updatedAt timestamp.
 * If no preferences exist yet, returns defaults.
 *
 * Auth: user token or admin token (with ?userId=...)
 */
function handleMeGetPreferences(db, userId) {
  if (!userId) return { status: 400, body: { ok: false, error: "userId required (pass ?userId=... for admin access)" } };

  const rawPrefs = db.getUserPreferences(userId);
  const defaults = {
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
    offlineFallbackMode: "cached"
  };

  const preferences = (rawPrefs && rawPrefs.preferences && Object.keys(rawPrefs.preferences).length > 0)
    ? rawPrefs.preferences
    : defaults;

  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_me_preferences",
      generatedAt: now(),
      preferences,
      updatedAt: rawPrefs.updatedAt
    }
  };
}

/**
 * PATCH /frames/me/preferences — Update user preferences
 *
 * Accepts a partial preferences object. Merges with existing preferences.
 * Supports conflict resolution via optional `updatedAt` field.
 *
 * Auth: user token or admin token (with ?userId=...)
 */
function handleMeUpdatePreferences(db, userId, body) {
  if (!userId) return { status: 400, body: { ok: false, error: "userId required (pass ?userId=... for admin access)" } };
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return { status: 400, body: { ok: false, error: "Request body must be a JSON object" } };
  }

  // Valid preference keys (same as admin endpoint)
  const VALID_KEYS = new Set([
    "activeArtists", "streamCategories", "allowImages", "allowVideos",
    "allowSoundWorks", "allowGenerativeWorks", "autoplay", "videoAutoplay",
    "soundAutoplay", "soundEnabled", "cacheLikedArtworks", "cacheRecentArtworks",
    "offlineFallbackMode", "updatedAt"
  ]);

  const incomingUpdatedAt = body.updatedAt || null;
  if (body.updatedAt !== undefined && !isValidIsoTimestamp(body.updatedAt)) {
    return {
      status: 400,
      body: {
        ok: false,
        error: "updatedAt must be an ISO-8601 UTC timestamp",
        reason: "invalid_updated_at"
      }
    };
  }
  const patch = { ...body };
  delete patch.updatedAt;

  const keys = Object.keys(patch);
  if (keys.length === 0) {
    return { status: 400, body: { ok: false, error: "No preferences to update" } };
  }

  const unknown = keys.filter(k => !VALID_KEYS.has(k));
  if (unknown.length > 0) {
    return { status: 400, body: { ok: false, error: "Unknown preference keys: " + unknown.join(", ") } };
  }

  const result = db.setUserPreferences(userId, patch, incomingUpdatedAt);
  if (!result.ok) {
    return { status: 409, body: { ok: false, error: "Preferences conflict", reason: result.reason, conflict: true, preferences: result.preferences, incomingPreferences: result.incomingPreferences, incomingUpdatedAt: result.incomingUpdatedAt, currentUpdatedAt: result.currentUpdatedAt, conflictPolicy: result.conflictPolicy, updatedAt: result.updatedAt } };
  }

  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_me_preferences_updated",
      preferences: result.preferences,
      updatedAt: result.updatedAt
    }
  };
}

/**
 * GET /frames/me/liked-artworks — User's liked artworks
 *
 * Returns: list of liked artwork IDs with like timestamps.
 * Supports pagination via ?limit and ?offset.
 *
 * Auth: user token or admin token (with ?userId=...)
 */
function handleMeLikedArtworks(db, userId, queryParams) {
  if (!userId) return { status: 400, body: { ok: false, error: "userId required (pass ?userId=... for admin access)" } };

  const likedIds = db.getLikedArtworks(userId);
  const limit = Math.min(parseInt(queryParams.limit, 10) || 50, 200);
  const offset = parseInt(queryParams.offset, 10) || 0;
  const page = likedIds.slice(offset, offset + limit);

  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_me_liked_artworks",
      generatedAt: now(),
      likedArtworks: page.map(artworkId => ({ artworkId })),
      total: likedIds.length,
      limit,
      offset
    }
  };
}

/**
 * GET /frames/me/subscription — User's subscription and entitlements
 *
 * Returns: subscription details with computed entitlements.
 * If no subscription exists, returns defaults (trial tier).
 *
 * Auth: user token or admin token (with ?userId=...)
 */
function handleMeSubscription(db, userId) {
  if (!userId) return { status: 400, body: { ok: false, error: "userId required (pass ?userId=... for admin access)" } };

  const deviceCount = db.countDevicesByOwner(userId);
  const sub = db.getSubscription(userId);
  const entitlements = computeEntitlements(sub, deviceCount);

  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_me_subscription",
      generatedAt: now(),
      subscription: sub ? {
        plan: sub.plan,
        status: sub.status,
        provider: sub.provider,
        createdAt: sub.createdAt,
        updatedAt: sub.updatedAt
      } : null,
      entitlements: {
        maxDevices: entitlements.deviceLimit === null ? null : entitlements.deviceLimit,
        devicesRemaining: entitlements.deviceSlotsRemaining,
        offlineCache: entitlements.offlineCache,
        remoteActions: entitlements.canUseRemoteActions,
        activeArtistsLimit: entitlements.activeArtistsLimit
      },
      deviceCount
    }
  };
}

/**
 * POST /frames/me/pair — User-initiated device pairing
 *
 * Accepts { pairingCode } in the request body. Validates the pairing code,
 * checks entitlements (maxDevices limit, subscription status), and claims
 * the device for the authenticated user.
 *
 * Returns the paired device details on success.
 *
 * Entitlement gating:
 *   - Degraded subscription (expired, cancelled, past_due) → 403
 *   - Device limit reached → 403
 *   - Trial users: 1 device max
 *   - Basic: 3 devices, Premium: 10, Enterprise: unlimited
 *
 * Auth: user token or admin token (with ?userId=...)
 */
function handleMePairDevice(db, userId, body) {
  if (!userId) return { status: 400, body: { ok: false, error: "userId required (pass ?userId=... for admin access)" } };

  // Validate pairing code presence
  const { pairingCode } = body;
  if (!pairingCode) {
    return { status: 400, body: { ok: false, error: "pairingCode is required" } };
  }

  // Validate pairing code format (e.g. "ABCD-1234" or alphanumeric 4-12 chars)
  if (typeof pairingCode !== "string" || !/^[A-Z0-9-]{4,16}$/.test(pairingCode)) {
    return { status: 400, body: { ok: false, error: "Invalid pairing code format" } };
  }

  // Check entitlements before attempting to pair
  const deviceCount = db.countDevicesByOwner(userId);
  const sub = db.getSubscription(userId);
  const entitlements = computeEntitlements(sub, deviceCount);

  if (!entitlements.canAddDevice) {
    const isDegraded = sub && DEGRADED_STATUSES.has(sub.status);
    if (isDegraded) {
      return {
        status: 403,
        body: {
          ok: false,
          error: "Subscription is not active",
          reason: "subscription_degraded",
          subscription: { plan: sub.plan, status: sub.status },
          entitlements: {
            maxDevices: entitlements.deviceLimit === null ? null : entitlements.deviceLimit,
            devicesRemaining: entitlements.deviceSlotsRemaining,
            currentDeviceCount: deviceCount
          }
        }
      };
    }
    return {
      status: 403,
      body: {
        ok: false,
        error: "Device limit reached",
        reason: "device_limit_reached",
        entitlements: {
          maxDevices: entitlements.deviceLimit === null ? null : entitlements.deviceLimit,
          devicesRemaining: entitlements.deviceSlotsRemaining,
          currentDeviceCount: deviceCount
        }
      }
    };
  }

  // Attempt to claim the pairing code
  const result = db.claimPairingCode(pairingCode, userId);
  if (!result.ok) {
    // Map DB errors to appropriate HTTP status
    if (result.error === "Pairing code expired") {
      return { status: 410, body: { ok: false, error: result.error, reason: "code_expired" } };
    }
    if (result.error === "Invalid or expired pairing code") {
      return { status: 404, body: { ok: false, error: "Pairing code not found", reason: "code_not_found" } };
    }
    return { status: 400, body: { ok: false, error: result.error } };
  }

  // Fetch full device details for the response
  const device = db.getDevice(result.deviceId);
  return {
    status: 200,
    body: {
      ok: true,
      kind: "autopoiesis_frames_me_pair",
      generatedAt: now(),
      device: {
        deviceId: device.deviceId,
        deviceName: device.deviceName || "Autopoiesis Frame",
        deviceType: device.deviceType || "raspberry_pi",
        softwareVersion: device.softwareVersion,
        updateChannel: device.updateChannel || "stable",
        paired: true,
        pairedAt: device.updatedAt,
        ownerUserId: userId
      },
      entitlements: {
        maxDevices: entitlements.deviceLimit === null ? null : entitlements.deviceLimit,
        devicesRemaining: Math.max(0, (entitlements.deviceLimit === null ? Infinity : entitlements.deviceLimit) - (deviceCount + 1)),
        currentDeviceCount: deviceCount + 1
      }
    }
  };
}

async function handle(db, req, res) {
  const pathname = extractPath(req.url);
  const method = req.method;

  // CORS preflight — handle before any route matching
  if (method === "OPTIONS") {
    return sendCorsPreflight(res);
  }

  // ── User Profile endpoints (/frames/me/*) ────────────────────────────

  // GET /frames/me — User profile summary
  if (method === "GET" && pathname === "/frames/me") {
    const userAuth = authenticateUser(req, db);
    if (!userAuth.ok) return sendJson(res, userAuth.status, { ok: false, error: userAuth.error });
    return sendResult(res, handleMeProfile(db, userAuth.userId));
  }

  // GET /frames/me/devices — User's paired devices
  if (method === "GET" && pathname === "/frames/me/devices") {
    const userAuth = authenticateUser(req, db);
    if (!userAuth.ok) return sendJson(res, userAuth.status, { ok: false, error: userAuth.error });
    return sendResult(res, handleMeDevices(db, userAuth.userId));
  }

  // GET /frames/me/preferences — User preferences
  if (method === "GET" && pathname === "/frames/me/preferences") {
    const userAuth = authenticateUser(req, db);
    if (!userAuth.ok) return sendJson(res, userAuth.status, { ok: false, error: userAuth.error });
    return sendResult(res, handleMeGetPreferences(db, userAuth.userId));
  }

  // PATCH /frames/me/preferences — Update user preferences
  if (method === "PATCH" && pathname === "/frames/me/preferences") {
    const userAuth = authenticateUser(req, db);
    if (!userAuth.ok) return sendJson(res, userAuth.status, { ok: false, error: userAuth.error });
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendResult(res, handleMeUpdatePreferences(db, userAuth.userId, body));
  }

  // POST /frames/me/pair — User-initiated device pairing
  if (method === "POST" && pathname === "/frames/me/pair") {
    const userAuth = authenticateUser(req, db);
    if (!userAuth.ok) return sendJson(res, userAuth.status, { ok: false, error: userAuth.error });
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendResult(res, handleMePairDevice(db, userAuth.userId, body));
  }

  // GET /frames/me/liked-artworks — User's liked artworks
  if (method === "GET" && pathname === "/frames/me/liked-artworks") {
    const userAuth = authenticateUser(req, db);
    if (!userAuth.ok) return sendJson(res, userAuth.status, { ok: false, error: userAuth.error });
    const url = new URL(req.url, "http://localhost");
    const queryParams = {};
    if (url.searchParams.get("limit")) queryParams.limit = url.searchParams.get("limit");
    if (url.searchParams.get("offset")) queryParams.offset = url.searchParams.get("offset");
    return sendResult(res, handleMeLikedArtworks(db, userAuth.userId, queryParams));
  }

  // GET /frames/me/subscription — User's subscription
  if (method === "GET" && pathname === "/frames/me/subscription") {
    const userAuth = authenticateUser(req, db);
    if (!userAuth.ok) return sendJson(res, userAuth.status, { ok: false, error: userAuth.error });
    return sendResult(res, handleMeSubscription(db, userAuth.userId));
  }

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
    return sendResult(res, handleAdminBundle(db, profileUserId, {
      actorRole: url.searchParams.get("actorRole") || undefined,
      actorId: url.searchParams.get("actorId") || undefined
    }));
  }

  // GET /frames/admin/readiness — Online admin readiness snapshot
  if (method === "GET" && pathname === "/frames/admin/readiness") {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const url = new URL(req.url, "http://localhost");
    return sendResult(res, handleAdminReadiness(db, {
      actorRole: url.searchParams.get("actorRole") || undefined,
      actorId: url.searchParams.get("actorId") || undefined
    }));
  }

  // GET /frames/admin/pairing-queue — read-only setup queue for pairing UI
  if (method === "GET" && pathname === "/frames/admin/pairing-queue") {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const url = new URL(req.url, "http://localhost");
    const queryParams = {};
    for (const key of ["actorRole", "actorId", "status", "attentionOnly", "search", "limit", "offset"]) {
      const val = url.searchParams.get(key);
      if (val !== null) queryParams[key] = val;
    }
    return sendResult(res, handleAdminPairingQueue(db, queryParams));
  }

  // POST /frames/admin/devices/:id/pairing-code — refresh expired/missing setup code
  const adminPairingCodeMatch = pathname.match(/^\/frames\/admin\/devices\/([^/]+)\/pairing-code$/);
  if (method === "POST" && adminPairingCodeMatch) {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendResult(res, handleAdminRefreshPairingCode(db, adminPairingCodeMatch[1], body));
  }

  // ── Device admin snapshot ───────────────────────────────────────────────

  // GET /frames/device/:id/admin-snapshot — Detailed device snapshot for admin
  const adminSnapshotMatch = pathname.match(/^\/frames\/device\/([^/]+)\/admin-snapshot$/);
  if (method === "GET" && adminSnapshotMatch) {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const url = new URL(req.url, "http://localhost");
    return sendResult(res, handleAdminDeviceSnapshot(db, adminSnapshotMatch[1], {
      actorRole: url.searchParams.get("actorRole") || undefined,
      actorId: url.searchParams.get("actorId") || undefined
    }));
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
    const url = new URL(req.url, "http://localhost");
    return sendResult(res, handleAdminGetSubscription(db, adminSubMatch[1], {
      actorRole: url.searchParams.get("actorRole") || undefined,
      actorId: url.searchParams.get("actorId") || undefined
    }));
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
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendResult(res, handleAdminCancelSubscription(db, adminSubCancelMatch[1], body));
  }

  // ── Admin device fleet action endpoints ──────────────────────────────────

  // GET /frames/admin/devices/:id/actions — Preview remote action policy
  const adminDevActionMatch = pathname.match(/^\/frames\/admin\/devices\/([^/]+)\/actions$/);
  if (method === "GET" && adminDevActionMatch) {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const url = new URL(req.url, "http://localhost");
    return sendResult(res, handleAdminDeviceActionPolicy(db, adminDevActionMatch[1], {
      actorRole: url.searchParams.get("actorRole") || undefined,
      actorId: url.searchParams.get("actorId") || undefined
    }));
  }

  // POST /frames/admin/devices/:id/actions — Queue remote action
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

  // POST /frames/admin/devices/actions — Bulk device actions
  const adminDevBulkMatch = pathname.match(/^\/frames\/admin\/devices\/actions$/);
  if (method === "POST" && adminDevBulkMatch) {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendResult(res, handleAdminBulkDeviceActions(db, body));
  }

  // ── Admin user management endpoints ────────────────────────────────────

  // GET /frames/admin/users/:userId/frame-state — Profile > Frames state
  const adminUserFrameStateMatch = pathname.match(/^\/frames\/admin\/users\/([^/]+)\/frame-state$/);
  if (method === "GET" && adminUserFrameStateMatch) {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const url = new URL(req.url, "http://localhost");
    return sendResult(res, handleAdminUserFrameState(db, adminUserFrameStateMatch[1], {
      actorRole: url.searchParams.get("actorRole") || undefined,
      actorId: url.searchParams.get("actorId") || undefined
    }));
  }

  // GET /frames/admin/users/:userId/preferences — Get user preferences
  const adminUserPrefMatch = pathname.match(/^\/frames\/admin\/users\/([^/]+)\/preferences$/);
  if (method === "GET" && adminUserPrefMatch) {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const url = new URL(req.url, "http://localhost");
    return sendResult(res, handleAdminGetUserPreferences(db, adminUserPrefMatch[1], {
      actorRole: url.searchParams.get("actorRole") || undefined,
      actorId: url.searchParams.get("actorId") || undefined
    }));
  }

  // PATCH /frames/admin/users/:userId/preferences — Update user preferences
  if (method === "PATCH" && adminUserPrefMatch) {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendResult(res, handleAdminUpdateUserPreferences(db, adminUserPrefMatch[1], body));
  }

  // GET /frames/admin/users/:userId — Get user detail
  const adminUserMatch = pathname.match(/^\/frames\/admin\/users\/([^/]+)$/);
  if (method === "GET" && adminUserMatch) {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const url = new URL(req.url, "http://localhost");
    return sendResult(res, handleAdminGetUser(db, adminUserMatch[1], {
      actorRole: url.searchParams.get("actorRole") || undefined,
      actorId: url.searchParams.get("actorId") || undefined
    }));
  }

  // GET /frames/admin/users — List users
  if (method === "GET" && pathname === "/frames/admin/users") {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const url = new URL(req.url, "http://localhost");
    const filters = {};
    if (url.searchParams.get("limit")) filters.limit = parseInt(url.searchParams.get("limit"), 10);
    if (url.searchParams.get("offset")) filters.offset = parseInt(url.searchParams.get("offset"), 10);
    if (url.searchParams.get("subscriptionStatus")) filters.subscriptionStatus = url.searchParams.get("subscriptionStatus");
    if (url.searchParams.get("subscriptionPlan")) filters.subscriptionPlan = url.searchParams.get("subscriptionPlan");
    return sendResult(res, handleAdminListUsers(db, filters));
  }

  // GET /frames/admin/subscribers — Subscriber summary read model
  if (method === "GET" && pathname === "/frames/admin/subscribers") {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const url = new URL(req.url, "http://localhost");
    return sendResult(res, handleAdminSubscribers(db, {
      actorRole: url.searchParams.get("actorRole") || undefined,
      actorId: url.searchParams.get("actorId") || undefined,
      status: url.searchParams.get("status") || undefined,
      plan: url.searchParams.get("plan") || undefined,
      attentionOnly: url.searchParams.get("attentionOnly") || undefined
    }));
  }

  // ── Admin fleet device listing ───────────────────────────────────────

  // GET /frames/admin/devices — Fleet-wide device listing with filters
  if (method === "GET" && pathname === "/frames/admin/devices") {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const url = new URL(req.url, "http://localhost");
    const queryParams = {};
    for (const key of ["ownerUserId", "paired", "online", "disabled", "deviceType", "updateChannel", "search", "limit", "offset", "actorRole", "actorId"]) {
      const val = url.searchParams.get(key);
      if (val !== null) queryParams[key] = val;
    }
    return sendResult(res, handleAdminListDevices(db, queryParams));
  }

  // GET /frames/admin/release-rollouts — Admin endpoint: list release rollout progress with filters and pagination
  if (method === "GET" && pathname === "/frames/admin/release-rollouts") {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const url = new URL(req.url, "http://localhost");
    const queryParams = {};
    for (const key of ["releaseId", "deviceId", "status", "limit", "offset"]) {
      const val = url.searchParams.get(key);
      if (val !== null) queryParams[key] = val;
    }
    return sendResult(res, handleAdminListReleaseRollouts(db, queryParams));
  }

  // ── Admin fleet commands + audit trail ────────────────────────────────

  // GET /frames/admin/commands — Fleet-wide command queue
  if (method === "GET" && pathname === "/frames/admin/commands") {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const url = new URL(req.url, "http://localhost");
    const filters = {};
    if (url.searchParams.get("deviceId")) filters.deviceId = url.searchParams.get("deviceId");
    if (url.searchParams.get("status")) filters.status = url.searchParams.get("status");
    if (url.searchParams.get("commandType")) filters.commandType = url.searchParams.get("commandType");
    if (url.searchParams.get("limit")) filters.limit = parseInt(url.searchParams.get("limit"), 10);
    if (url.searchParams.get("offset")) filters.offset = parseInt(url.searchParams.get("offset"), 10);
    return sendResult(res, handleAdminListCommands(db, filters));
  }

  // GET /frames/admin/action-queue — summarized remote-action queue read model
  if (method === "GET" && pathname === "/frames/admin/action-queue") {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const url = new URL(req.url, "http://localhost");
    const filters = {};
    if (url.searchParams.get("actorRole")) filters.actorRole = url.searchParams.get("actorRole");
    if (url.searchParams.get("actorId")) filters.actorId = url.searchParams.get("actorId");
    if (url.searchParams.get("deviceId")) filters.deviceId = url.searchParams.get("deviceId");
    if (url.searchParams.get("ownerUserId")) filters.ownerUserId = url.searchParams.get("ownerUserId");
    if (url.searchParams.get("status")) filters.status = url.searchParams.get("status");
    if (url.searchParams.get("commandType")) filters.commandType = url.searchParams.get("commandType");
    if (url.searchParams.get("risk")) filters.risk = url.searchParams.get("risk");
    if (url.searchParams.get("queuedByRole")) filters.queuedByRole = url.searchParams.get("queuedByRole");
    if (url.searchParams.get("queuedByActorId")) filters.queuedByActorId = url.searchParams.get("queuedByActorId");
    if (url.searchParams.get("attentionOnly")) filters.attentionOnly = url.searchParams.get("attentionOnly") === "true";
    if (url.searchParams.get("stalePendingHours")) filters.stalePendingHours = Number(url.searchParams.get("stalePendingHours"));
    if (url.searchParams.get("limit")) filters.limit = parseInt(url.searchParams.get("limit"), 10);
    if (url.searchParams.get("offset")) filters.offset = parseInt(url.searchParams.get("offset"), 10);
    return sendResult(res, handleAdminActionQueue(db, filters));
  }

  // GET /frames/admin/command-audits — Admin command audit trail
  if (method === "GET" && pathname === "/frames/admin/command-audits") {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const url = new URL(req.url, "http://localhost");
    const filters = {};
    if (url.searchParams.get("deviceId")) filters.deviceId = url.searchParams.get("deviceId");
    if (url.searchParams.get("commandType")) filters.commandType = url.searchParams.get("commandType");
    if (url.searchParams.get("status")) filters.status = url.searchParams.get("status");
    if (url.searchParams.get("actorId")) filters.actorId = url.searchParams.get("actorId");
    if (url.searchParams.get("actorRole")) filters.actorRole = url.searchParams.get("actorRole");
    if (url.searchParams.get("risk")) filters.risk = url.searchParams.get("risk");
    if (url.searchParams.get("limit")) filters.limit = parseInt(url.searchParams.get("limit"), 10);
    if (url.searchParams.get("offset")) filters.offset = parseInt(url.searchParams.get("offset"), 10);
    return sendResult(res, handleAdminListCommandAudits(db, filters));
  }

  const adminBcDeliveryStatsMatch = pathname.match(/^\/frames\/admin\/broadcasts\/([^/]+)\/delivery-stats$/);
  if (method === "GET" && adminBcDeliveryStatsMatch) {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    return sendResult(res, handleAdminBroadcastDeliveryStats(db, adminBcDeliveryStatsMatch[1]));
  }

  // GET /frames/admin/delivery-stats — fleet broadcast delivery outcomes
  if (method === "GET" && pathname === "/frames/admin/delivery-stats") {
    const adminAuth = authenticateAdmin(req);
    if (!adminAuth.ok) return sendJson(res, adminAuth.status, { ok: false, error: adminAuth.error });
    const url = new URL(req.url, "http://localhost");
    return sendResult(res, handleAdminFleetDeliveryStats(db, {
      type: url.searchParams.get("type") || undefined,
      priority: url.searchParams.get("priority") || undefined,
      status: url.searchParams.get("status") || undefined
    }));
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
    const deviceId = body.deviceId;
    if (!deviceId) {
      const result = handleRegister(db, body);
      return sendResult(res, {
        status: result.status,
        body: { ...result.body, registrationStatus: "created" }
      });
    }
    const existing = db.getDevice(deviceId);
    if (!existing) {
      // New device registration
      const result = handleRegister(db, body);
      return sendResult(res, {
        status: result.status,
        body: { ...result.body, registrationStatus: "created" }
      });
    }
    // Existing device: require authentication
    const deviceKey = req.headers["x-frame-device-key"];
    const authenticated = deviceKey ? db.authenticateDevice(deviceId, deviceKey) : null;
    if (!authenticated) {
      // Return 409 with safe fields
      return sendResult(res, {
        status: 409,
        body: {
          ok: false,
          error: "registration_auth_required",
          reason: "registration_auth_required",
          deviceId,
          paired: !!existing.paired,
        }
      });
    }
    // Valid key: treat as refresh
    const result = handleRegister(db, body);
    return sendResult(res, {
      status: result.status,
      body: { ...result.body, registrationStatus: "refreshed" }
    });
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

  const effectivePreferencesMatch = pathname.match(/^\/frames\/device\/([^/]+)\/effective-preferences$/);
  if (method === "GET" && effectivePreferencesMatch) {
    const deviceId = effectivePreferencesMatch[1];
    const auth = authenticateDevice(db, req, deviceId);
    if (!auth.ok) return sendJson(res, auth.status, { ok: false, error: auth.error });
    return sendResult(res, handleGetEffectivePreferences(db, deviceId, auth));
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

  // Graceful shutdown test
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

/**
 * POST /frames/admin/devices/actions — Bulk device actions
 * Queue the same action on multiple devices. Validates each device individually
 * against role-action matrix and device-state gates.
 *
 * Expects: { deviceIds: string[], action: string, payload?: object, reason?: string, actorRole?: string, actorId?: string }
 * Returns: Results for each device with success/failure status
 */
function handleAdminBulkDeviceActions(db, body) {
  const {
    deviceIds = [],
    action,
    payload = {},
    reason = null,
    actorRole = "admin",
    actorId = "admin"
  } = body;

  // Validate required fields
  if (!Array.isArray(deviceIds) || deviceIds.length === 0) {
    return { status: 400, body: { ok: false, error: "deviceIds must be a non-empty array" } };
  }
  if (!action || typeof action !== "string") {
    return { status: 400, body: { ok: false, error: "action is required and must be a string" } };
  }
  if (deviceIds.length > 100) {
    return { status: 400, body: { ok: false, error: "Cannot process more than 100 devices per request" } };}

  const roleRow = ROLE_ACTION_MATRIX.find(r => r.role === actorRole);
  if (!roleRow) {
    return {
      status: 400,
      body: {
        ok: false,
        error: "Invalid actorRole: " + actorRole,
        acceptedActorRoles: ROLE_ACTION_MATRIX.map(r => r.role)
      }
    };
  }

  // Validate action against admin role in the action matrix
  const adminRole = ROLE_ACTION_MATRIX.find(r => r.role === "admin");
  if (!adminRole || !adminRole.actions[action]) {
    return { status: 400, body: { ok: false, error: "Unknown action: " + action } };
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

  const commandType = ACTION_TO_COMMAND[action];
  if (!commandType) {
    return { status: 400, body: { ok: false, error: "Cannot map action to command: " + action } };
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

  const results = {
    successful: [],
    failed: [],
    totalRequested: deviceIds.length
  };

  // Process each device
  for (const deviceId of deviceIds) {
    try {
      const device = db.getDevice(deviceId);
      if (!device) {
        results.failed.push({
          deviceId,
          error: "Device not found",
          status: 404
        });
        continue;
      }

      if (!device.paired) {
        results.failed.push({
          deviceId,
          error: "Device is not paired",
          status: 400
        });
        continue;
      }

      // Compute action availability to check device-state gates
      let ownerSubscription = null;
      if (device.ownerUserId) {
        const sub = db.getSubscription(device.ownerUserId);
        ownerSubscription = sub ? { plan: sub.plan, status: sub.status } : null;
      }
      const pendingCommands = db.getPendingCommands(deviceId, { markDelivered: false });
      const availability = buildActionAvailability(device, actorRole, ownerSubscription, pendingCommands.length);
      const actionAvail = availability.actions[action];

      if (actionAvail && !actionAvail.allowed) {
        results.failed.push({
          deviceId,
          error: "Action not available: " + (actionAvail.reason || "device state prevents this action"),
          reasonCode: actionAvail.reasonCode || "action_blocked",
          deviceState: availability.deviceState,
          status: 409
        });
        continue;
      }

      // Queue the command
      const command = db.queueCommand(deviceId, commandType, payload, riskMap[commandType] || "medium");

      // Record admin audit trail for this action
      const commandId = command.command?.commandId || command.commandId || command.id;
      try {
        db.logCommandAudit({
          commandId,
          deviceId,
          commandType,
          risk: riskMap[commandType] || "medium",
          actorId,
          actorRole,
          reason: reason || null,
          payloadSummary: { action, payloadKeys: Object.keys(payload || {}) },
          authorization: {
            actionAvailability: actionAvail || null,
            deviceState: availability.deviceState
          },
        });
      } catch (auditErr) {
        // Audit logging failure must not break the command queue
        process.stderr.write("[audit] logCommandAudit failed: " + auditErr.message + "\n");
      }

      results.successful.push({
        deviceId,
        queued: true,
        commandId,
        auditId: commandId,
        action,
        actionType: commandType,
        risk: riskMap[commandType] || "medium",
        actorId,
        actorRole,
        queuedAt: now(),
        deviceState: availability.deviceState
      });
    } catch (err) {
      results.failed.push({
        deviceId,
        error: err.message || "Unknown error",
        status: 500
      });
    }
  }

  // Determine overall status
  let statusCode = 200;
  if (results.successful.length === 0 && results.failed.length > 0) {
    // All failed
    statusCode = results.failed[0].status || 400;
  } else if (results.failed.length > 0) {
    // Partial success
    statusCode = 207; // Multi-status
  }

  return {
    status: statusCode,
    body: {
      ok: statusCode < 400,
      actorId,
      actorRole,
      ...results
    }
  };
}

main();
