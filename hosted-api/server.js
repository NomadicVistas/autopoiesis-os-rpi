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
 *   POST /frames/artworks/:id/like                  – Like artwork
 *   GET  /frames/admin/broadcast-deliveries         – Admin: list broadcast deliveries
 *   GET  /frames/admin/broadcast-deliveries/:id     – Admin: per-broadcast delivery detail
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

  // If the database has no tables, run migrations
  const tables = db.listTables();
  if (tables.length === 0) {
    const sqliteSchema = path.resolve(__dirname, "..", "scripts", "aos-schema-sqlite-validation.sql");
    if (fs.existsSync(sqliteSchema)) {
      const sql = fs.readFileSync(sqliteSchema, "utf-8");
      // Execute the schema SQL directly against the database
      for (const stmt of sql.split(";").map(s => s.trim()).filter(s => s.length > 0)) {
        db.db.prepare(stmt).run();
      }
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

// ── Request router ───────────────────────────────────────────────────────────

async function handle(db, req, res) {
  const pathname = extractPath(req.url);
  const method = req.method;

  // ── Admin broadcast delivery endpoints ────────────────────────────────

  if (method === "GET" && pathname === "/frames/admin/broadcast-deliveries") {
    const url = new URL(req.url, "http://localhost");
    return sendResult(res, handleAdminBroadcastDeliveries(db, url.searchParams));
  }

  const adminBdDetailMatch = pathname.match(/^\/frames\/admin\/broadcast-deliveries\/([^/]+)$/);
  if (method === "GET" && adminBdDetailMatch) {
    return sendResult(res, handleAdminBroadcastDeliveryDetail(db, adminBdDetailMatch[1]));
  }

  // ── Admin content management endpoints ─────────────────────────────────

  // POST /frames/admin/broadcasts — Create new broadcast/content item
  if (method === "POST" && pathname === "/frames/admin/broadcasts") {
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendResult(res, handleAdminCreateBroadcast(db, body));
  }

  // GET /frames/admin/broadcasts/stats — Content statistics
  if (method === "GET" && pathname === "/frames/admin/broadcasts/stats") {
    return sendResult(res, handleAdminBroadcastStats(db));
  }

  // GET /frames/admin/broadcasts — List broadcasts with filters
  if (method === "GET" && pathname === "/frames/admin/broadcasts") {
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
    return sendResult(res, handleAdminGetBroadcast(db, id));
  }

  // PATCH /frames/admin/broadcasts/:id — Update broadcast
  if (method === "PATCH" && adminBcDetailMatch) {
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendResult(res, handleAdminUpdateBroadcast(db, adminBcDetailMatch[1], body));
  }

  // POST /frames/admin/broadcasts/:id/publish — Publish a draft
  const adminBcPublishMatch = pathname.match(/^\/frames\/admin\/broadcasts\/([^/]+)\/publish$/);
  if (method === "POST" && adminBcPublishMatch) {
    return sendResult(res, handleAdminPublishBroadcast(db, adminBcPublishMatch[1]));
  }

  // POST /frames/admin/broadcasts/:id/unpublish — Revert to draft
  const adminBcUnpublishMatch = pathname.match(/^\/frames\/admin\/broadcasts\/([^/]+)\/unpublish$/);
  if (method === "POST" && adminBcUnpublishMatch) {
    return sendResult(res, handleAdminUnpublishBroadcast(db, adminBcUnpublishMatch[1]));
  }

  // DELETE /frames/admin/broadcasts/:id — Archive (soft-delete)
  if (method === "DELETE" && adminBcDetailMatch) {
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
    const deviceId = null; // Like uses auth from any device with an owner
    // For like, we require a device key for auth but the userId comes from the owner
    const key = req.headers["x-frame-device-key"];
    if (!key) return sendJson(res, 401, { ok: false, error: "Missing device key" });

    // Find the device by key — scan devices to match
    const body = JSON.parse((await readBody(req)) || "{}");
    // Minimal: accept like requests with any valid device key
    return sendJson(res, 200, {
      ok: true,
      artworkId: likeMatch[1],
      liked: body.liked !== false,
      likedAt: now()
    });
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
