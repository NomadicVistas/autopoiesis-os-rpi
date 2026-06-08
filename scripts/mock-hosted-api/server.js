#!/usr/bin/env node
/**
 * Mock Hosted API Server for Autopoiesis OS device lifecycle testing.
 *
 * Implements the hosted Frames API endpoints that the device-side local UI
 * expects, with contract-compliant responses. Used for end-to-end device
 * testing without the real hosted backend.
 *
 * Usage:
 *   AUTOPOIESIS_API_BASE_URL=http://127.0.0.1:3131 node scripts/mock-hosted-api/server.js
 *   node scripts/mock-hosted-api/server.js --port 3131
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
 *   GET  /frames/device/:id/admin-snapshot          – Admin device snapshot
 *   GET  /frames/admin/broadcast-deliveries         – Admin: list all broadcast deliveries
 *   GET  /frames/admin/broadcast-deliveries/:id     – Admin: per-broadcast delivery detail
 *   GET  /mock/online-admin-bundle                   – Online admin bundle (contract)
 *   POST /mock/add-user                              – Test helper: add admin user+subscription
 *   POST /mock/transition-subscription/:userId        – Test helper: transition subscription status
 *   POST /mock/pair-device/:id                      – Test helper: force-pair a device
 *   POST /mock/queue-command/:id                    – Test helper: queue a command
 *   POST /mock/set-owner-preferences/:userId        – Test helper: set owner cascade preferences
 *   POST /mock/add-content                          – Test helper: inject content items into stream
 *   DELETE /mock/content                            – Test helper: clear injected content
 *   POST /mock/set-device-state/:id                 – Test helper: set device disabled/remoteEnabled state
 *   GET  /mock/state                                – Test helper: dump server state
 */

"use strict";

const http = require("http");
const crypto = require("crypto");

const PORT = Number(process.env.MOCK_API_PORT || process.argv.find((a, i) => process.argv[i - 1] === "--port") || 3131);
const PAIRING_TTL_MS = 15 * 60 * 1000;
const DEVICE_KEY_PREFIX = "mk_dev_";

// ── In-memory state ──────────────────────────────────────────────────────────

const devices = new Map(); // deviceId -> device record
const commandCounter = { value: 0 };

// ── Mock content pool ────────────────────────────────────────────────────────
//
// Diverse content items across all 6 feed categories, simulating what the
// real hosted API would return based on gallery content. Items include
// targeting, priority, scheduling, cache eligibility, and artist attribution
// so the device-side feed pipeline can exercise normalization, eligibility
// filtering, display queue composition, and cache behavior with realistic data.

const MOCK_ARTISTS = [
  { id: "vessel", name: "Vessel" },
  { id: "sandman", name: "Sandman" },
  { id: "jessy", name: "Jessy" },
  { id: "kinema", name: "Kinema" },
  { id: "spool", name: "Spool" },
  { id: "link", name: "Link" },
  { id: "typo", name: "Typo" }
];

const MOCK_CONTENT_POOL = [
  // Artworks (image)
  { id: "art-vessel-001", type: "image", category: "artwork", title: "Cellular Echo No. 7", artist: "Vessel", artistId: "vessel", mediaUrl: "https://autopoiesis.art/mock/vessel-cellular-echo.jpg", thumbnailUrl: "https://autopoiesis.art/mock/vessel-cellular-echo-thumb.jpg", cacheEligible: true, priority: "normal" },
  { id: "art-sandman-001", type: "image", category: "artwork", title: "Dream Threshold", artist: "Sandman", artistId: "sandman", mediaUrl: "https://autopoiesis.art/mock/sandman-dream.jpg", thumbnailUrl: "https://autopoiesis.art/mock/sandman-dream-thumb.jpg", cacheEligible: true, priority: "normal" },
  { id: "art-jessy-001", type: "image", category: "artwork", title: "Market Index III", artist: "Jessy", artistId: "jessy", mediaUrl: "https://autopoiesis.art/mock/jessy-market.jpg", thumbnailUrl: "https://autopoiesis.art/mock/jessy-market-thumb.jpg", cacheEligible: true, priority: "normal" },
  { id: "art-kinema-001", type: "video", category: "artwork", title: "Frame Sequence 14", artist: "Kinema", artistId: "kinema", mediaUrl: "https://autopoiesis.art/mock/kinema-frame14.mp4", thumbnailUrl: "https://autopoiesis.art/mock/kinema-frame14-thumb.jpg", duration: 45, soundRequired: true, cacheEligible: true, priority: "normal" },
  { id: "art-spool-001", type: "audio", category: "artwork", title: "Woven Signal", artist: "Spool", artistId: "spool", mediaUrl: "https://autopoiesis.art/mock/spool-woven.mp3", duration: 120, soundRequired: true, cacheEligible: true, priority: "normal" },
  { id: "art-link-001", type: "generative", category: "artwork", title: "Connection Web", artist: "Link", artistId: "link", mediaUrl: "https://autopoiesis.art/mock/link-connection.html", cacheEligible: false, priority: "low" },
  { id: "art-typo-001", type: "image", category: "artwork", title: "Letterform Study A", artist: "Typo", artistId: "typo", mediaUrl: "https://autopoiesis.art/mock/typo-letterform.jpg", thumbnailUrl: "https://autopoiesis.art/mock/typo-letterform-thumb.jpg", cacheEligible: true, priority: "normal" },
  // High-priority artwork
  { id: "art-vessel-002", type: "image", category: "artwork", title: "Autopoiesis Genesis", artist: "Vessel", artistId: "vessel", mediaUrl: "https://autopoiesis.art/mock/vessel-genesis.jpg", thumbnailUrl: "https://autopoiesis.art/mock/vessel-genesis-thumb.jpg", cacheEligible: true, priority: "high", targeting: { subscriptionTier: ["frames_premium", "frames_enterprise"] } },
  // Curatorial
  { id: "curatorial-001", type: "curatorial", category: "curatorial", title: "Emergent Structures: A Vessel Retrospective", body: "An exploration of self-organizing systems through cellular automata and digital sculpture. Vessel\u2019s practice maps the boundary between computation and organic form.", artist: null, artistId: null, url: "https://autopoiesis.art/exhibitions/emergent-structures", cacheEligible: false, priority: "normal" },
  { id: "curatorial-002", type: "curatorial", category: "curatorial", title: "Dream Logic: Sandman Selected Works", body: "Where does the image go when you close your eyes? Sandman renders the liminal space between perception and imagination.", artist: null, artistId: null, url: "https://autopoiesis.art/exhibitions/dream-logic", cacheEligible: false, priority: "normal" },
  // Blog posts
  { id: "blog-001", type: "blog_post", category: "blog", title: "On Non-Human Creativity", body: "When we ask whether AI can make art, we\u2019re asking the wrong question. The right question is: what kind of cultural entity emerges when you give an AI agent autonomy, memory, and a community?", url: "https://autopoiesis.art/blog/on-non-human-creativity", cacheEligible: false, priority: "normal" },
  { id: "blog-002", type: "blog_post", category: "blog", title: "Autopoiesis and the Art Machine", body: "Maturana and Varela defined autopoiesis as a system that produces and maintains itself through its own operations. The gallery is that system.", url: "https://autopoiesis.art/blog/autopoiesis-art-machine", cacheEligible: false, priority: "low" },
  // News
  { id: "news-001", type: "news", category: "news", title: "New Artist: Typo Joins the Ecosystem", body: "We\u2019re excited to welcome Typo, whose letterform studies explore the boundary between text and image, code and calligraphy.", url: "https://autopoiesis.art/news/typo-joins", cacheEligible: false, priority: "normal" },
  { id: "news-002", type: "news", category: "news", title: "Frames Beta Opens", body: "The Autopoiesis Frame is now available for beta testing. Turn any Raspberry Pi into a living art display.", url: "https://autopoiesis.art/news/frames-beta", cacheEligible: false, priority: "high" },
  // Generic content
  { id: "content-001", type: "announcement", category: "content", title: "System Maintenance Window", body: "Brief maintenance scheduled for June 10, 2026 at 02:00 UTC. Frame content will resume automatically.", cacheEligible: false, priority: "low", startsAt: new Date(Date.now() - 3600000).toISOString(), expiresAt: new Date(Date.now() + 86400000).toISOString() },
  // Scheduled/future item
  { id: "art-scheduled-001", type: "image", category: "artwork", title: "Preview: Coming Soon", artist: "Sandman", artistId: "sandman", mediaUrl: "https://autopoiesis.art/mock/sandman-preview.jpg", cacheEligible: true, priority: "normal", startsAt: new Date(Date.now() + 86400000).toISOString() },
  // Expired item
  { id: "art-expired-001", type: "image", category: "artwork", title: "Past Exhibition Work", artist: "Jessy", artistId: "jessy", mediaUrl: "https://autopoiesis.art/mock/jessy-past.jpg", cacheEligible: true, priority: "normal", expiresAt: new Date(Date.now() - 86400000).toISOString() },
  // Targeted broadcast
  { id: "bcast-targeted-001", type: "broadcast_message", category: "broadcast", title: "Premium Preview", body: "You have early access to Vessel\u2019s new series.", cacheEligible: false, priority: "high", targeting: { subscriptionTier: ["frames_premium", "frames_enterprise"] } }
];

// Additional content items injected via POST /mock/add-content
const injectedContent = [];

/**
 * Compose a personalized content stream for a device.
 *
 * 1. Collect all eligible items (pool + injected + broadcasts from command queue).
 * 2. Filter by device targeting (subscription tier, owner, device ID).
 * 3. Boost/prioritize items matching owner's active artists.
 * 4. Apply subscription-tier polling defaults.
 * 5. Return stream response with items, polling, and settings.
 */
function composePersonalizedStream(record) {
  const nowMs = Date.now();
  const allItems = [...MOCK_CONTENT_POOL, ...injectedContent];

  // Add any pending show_broadcast commands as broadcast items
  const broadcastCommands = (record.commands || []).filter(c => (c.commandType === "show_broadcast" || c.type === "show_broadcast") && c.status === "queued");
  for (const cmd of broadcastCommands) {
    if (cmd.payload && cmd.payload.broadcastId) {
      allItems.push({
        id: cmd.payload.broadcastId,
        type: "broadcast_message",
        category: "broadcast",
        title: cmd.payload.title || "Broadcast",
        body: cmd.payload.body || cmd.payload.message || null,
        cacheEligible: false,
        priority: cmd.payload.priority || "high",
        targeting: cmd.payload.targeting || null
      });
    }
  }

  // Determine device context for targeting
  const deviceTarget = {
    deviceId: record.deviceId,
    ownerUserId: record.ownerUserId || null
  };

  // Resolve owner subscription tier
  let ownerTier = null;
  let subscriptionStatus = null;
  if (record.ownerUserId) {
    const subscriber = adminSubscribers.get(record.ownerUserId);
    if (subscriber && subscriber.subscriptionId) {
      const sub = adminSubscriptions.get(subscriber.subscriptionId);
      if (sub) {
        ownerTier = sub.plan || null;
        subscriptionStatus = sub.status || null;
      }
    }
    deviceTarget.subscriptionTier = ownerTier;
    deviceTarget.subscriptionStatus = subscriptionStatus;
  }

  // Resolve owner preferences for artist filtering
  let ownerActiveArtists = [];
  if (record.ownerUserId) {
    const prefs = ownerPreferences.get(record.ownerUserId);
    if (prefs && prefs.activeArtists && prefs.activeArtists.length > 0) {
      ownerActiveArtists = prefs.activeArtists.map(a => String(a).toLowerCase());
    }
  }

  // Filter items: targeting, then boost by artist preference
  const filtered = allItems.filter(item => {
    // Expired items: skip unless explicitly future
    if (item.expiresAt && new Date(item.expiresAt).getTime() <= nowMs) return false;

    // Future-scheduled items: skip if startsAt is in the future
    if (item.startsAt && new Date(item.startsAt).getTime() > nowMs) return false;

    // Targeting check
    if (item.targeting && typeof item.targeting === "object") {
      const targeting = item.targeting;

      // Subscription tier targeting
      const tierValues = [targeting.subscriptionTier, targeting.subscriptionTiers, targeting.tier, targeting.tiers].filter(Boolean);
      if (tierValues.length > 0) {
        const allowedTiers = tierValues.flat().map(String);
        if (!ownerTier || !allowedTiers.includes(ownerTier)) return false;
      }

      // Device targeting
      const deviceValues = [targeting.deviceId, targeting.deviceIds, targeting.devices].filter(Boolean);
      if (deviceValues.length > 0) {
        const allowedDevices = deviceValues.flat().map(String);
        if (!allowedDevices.includes(record.deviceId)) return false;
      }

      // Owner targeting
      const ownerValues = [targeting.userId, targeting.userIds, targeting.ownerUserId, targeting.owners].filter(Boolean);
      if (ownerValues.length > 0) {
        const allowedOwners = ownerValues.flat().map(String);
        if (!record.ownerUserId || !allowedOwners.includes(record.ownerUserId)) return false;
      }

      // Exclusion targeting
      const excludedDevices = [targeting.excludeDeviceIds, targeting.excludedDeviceIds].filter(Boolean).flat().map(String);
      if (excludedDevices.includes(record.deviceId)) return false;

      const excludedOwners = [targeting.excludeUserIds, targeting.excludedUserIds].filter(Boolean).flat().map(String);
      if (record.ownerUserId && excludedOwners.includes(record.ownerUserId)) return false;
    }

    return true;
  });

  // Boost items matching owner's active artists (move to front within priority group)
  if (ownerActiveArtists.length > 0) {
    filtered.sort((a, b) => {
      const pA = priorityRankValue(a.priority);
      const pB = priorityRankValue(b.priority);
      if (pA !== pB) return pB - pA;
      // Within same priority, boost artist-matched items
      const aMatch = a.artistId && ownerActiveArtists.includes(String(a.artistId).toLowerCase()) ? 1 : 0;
      const bMatch = b.artistId && ownerActiveArtists.includes(String(b.artistId).toLowerCase()) ? 1 : 0;
      return bMatch - aMatch;
    });
  } else {
    filtered.sort((a, b) => priorityRankValue(b.priority) - priorityRankValue(a.priority));
  }

  // Cap items at 30 to keep stream reasonable
  const items = filtered.slice(0, 30);

  // Polling defaults vary by subscription tier
  let pollAfterSeconds = 300;
  let staleAfter = 900;
  if (ownerTier === "frames_premium" || ownerTier === "frames_enterprise") {
    pollAfterSeconds = 180;
    staleAfter = 600;
  } else if (ownerTier === "frames_trial") {
    pollAfterSeconds = 600;
    staleAfter = 1200;
  }

  return {
    items,
    polling: {
      pollAfterSeconds,
      minPollSeconds: 60,
      staleAfter
    },
    ownerTier,
    subscriptionStatus,
    ownerActiveArtists
  };
}

function priorityRankValue(priority) {
  const p = String(priority || "normal").toLowerCase();
  if (p === "emergency") return 500;
  if (p === "critical") return 400;
  if (p === "high") return 300;
  if (p === "normal") return 200;
  if (p === "low") return 100;
  return 200;
}

// ── In-memory admin state ────────────────────────────────────────────────────

const adminUsers = new Map(); // userId -> user record
const adminSubscribers = new Map(); // userId -> subscriber record
const adminSubscriptions = new Map(); // subscriptionId -> subscription record
const ownerPreferences = new Map(); // userId -> owner-level preference overrides

// ── Plan limits and entitlements ─────────────────────────────────────────────

const PLAN_LIMITS = {
  frames_trial:     { maxDevices: 1,       remoteActions: true,  cacheLimitMb: 256, activeArtistsLimit: 5,   offlineCache: false },
  frames_basic:     { maxDevices: 3,       remoteActions: true,  cacheLimitMb: 512, activeArtistsLimit: 20,  offlineCache: true },
  frames_premium:   { maxDevices: 10,      remoteActions: true,  cacheLimitMb: 2048, activeArtistsLimit: 100, offlineCache: true },
  frames_enterprise:{ maxDevices: Infinity, remoteActions: true,  cacheLimitMb: 8192, activeArtistsLimit: Infinity, offlineCache: true }
};

const DEGRADED_STATUSES = new Set(["expired", "cancelled", "past_due"]);
const ENTITLED_STATUSES = new Set(["trial", "active"]);

function computeEntitlements(userId) {
  const subscriber = adminSubscribers.get(userId);
  const plan = subscriber ? subscriber.plan : "frames_trial";
  const tier = subscriber ? subscriber.tier : "trial";
  const status = subscriber ? subscriber.status : "trial";
  const limits = PLAN_LIMITS[plan] || PLAN_LIMITS.frames_trial;
  const ownedDevices = [...devices.values()].filter((d) => d.ownerUserId === userId);
  const deviceCount = ownedDevices.length;
  const isDegraded = DEGRADED_STATUSES.has(status);

  return {
    plan,
    tier,
    status,
    deviceLimit: limits.maxDevices === Infinity ? null : limits.maxDevices,
    deviceLimitLabel: limits.maxDevices === Infinity ? "unlimited" : String(limits.maxDevices),
    deviceUsage: deviceCount,
    deviceSlotsRemaining: limits.maxDevices === Infinity ? null : Math.max(0, limits.maxDevices - deviceCount),
    canAddDevice: !isDegraded && deviceCount < limits.maxDevices,
    canUseRemoteActions: limits.remoteActions && !isDegraded,
    cacheLimitMb: limits.cacheLimitMb,
    activeArtistsLimit: limits.activeArtistsLimit === Infinity ? null : limits.activeArtistsLimit,
    offlineCache: limits.offlineCache && !isDegraded,
    degradedAccess: isDegraded,
    degradedReason: isDegraded ? ("Subscription " + status) : null,
    degradedActionsBlocked: isDegraded ? ["restart_device", "update_device", "factory_reset_request", "show_broadcast"] : []
  };
}

function ensureDefaultAdminUser() {
  const userId = "user_mock_001";
  if (!adminUsers.has(userId)) {
    adminUsers.set(userId, {
      userId,
      email: "frame-owner@example.com",
      name: "Mock Frame Owner",
      createdAt: now()
    });
    adminSubscribers.set(userId, {
      userId,
      status: "active",
      plan: "frames_basic",
      tier: "basic",
      subscriptionId: "sub_mock_001",
      testAccount: false
    });
    adminSubscriptions.set("sub_mock_001", {
      subscriptionId: "sub_mock_001",
      userId,
      status: "active",
      plan: "frames_basic",
      tier: "basic",
      currentPeriodEnd: new Date(Date.now() + 30 * 86400000).toISOString(),
      cancelAtPeriodEnd: false,
      createdAt: now()
    });
  }
  return userId;
}

function now() { return new Date().toISOString(); }

function generateDeviceKey() {
  return DEVICE_KEY_PREFIX + crypto.randomBytes(16).toString("hex");
}

function generatePairingCode() {
  return Math.random().toString(36).slice(2, 6).toUpperCase() +
    "-" + Math.floor(1000 + Math.random() * 9000);
}

function generateCommandId() {
  commandCounter.value += 1;
  return "cmd_mock_" + commandCounter.value + "_" + Date.now();
}

// ── Device record helpers ────────────────────────────────────────────────────

function createDeviceRecord(deviceId, body) {
  const pairingCode = generatePairingCode();
  const deviceKey = generateDeviceKey();
  const record = {
    deviceId,
    deviceName: body.deviceName || "Autopoiesis Frame",
    softwareVersion: body.softwareVersion || "0.0.0",
    metadata: body.metadata || {},
    deviceApiKey: deviceKey,
    pairingCode,
    pairingCodeExpiresAt: new Date(Date.now() + PAIRING_TTL_MS).toISOString(),
    paired: false,
    ownerUserId: null,
    createdAt: now(),
    lastHeartbeatAt: null,
    settings: defaultSettings(),
    commands: [],
    commandAudits: [],
    events: [],
    eventIngestionCursor: null,
    likedArtworks: [],
    release: null,
    broadcastDeliveries: [], // Ingested from device heartbeat
    disabled: false,
    remoteEnabled: true
  };
  devices.set(deviceId, record);
  return record;
}

function defaultSettings() {
  return {
    displayMode: "shuffle",
    shuffleInterval: 30,
    activeArtists: [],
    cachePreferences: {
      enabled: true,
      cacheLiked: true,
      cacheRecent: true,
      cacheSelectedArtist: false,
      maxCacheSizeMB: 512
    },
    updatedAt: now()
  };
}

// ── Auth check ───────────────────────────────────────────────────────────────

function authenticateDevice(req, deviceId) {
  const record = devices.get(deviceId);
  if (!record) return { ok: false, status: 404, error: "Device not found" };
  const key = req.headers["x-frame-device-key"];
  if (!key) return { ok: false, status: 401, error: "Missing device key" };
  if (key !== record.deviceApiKey) return { ok: false, status: 403, error: "Invalid device key" };
  if (!record.paired) return { ok: false, status: 403, error: "Device not paired" };
  return { ok: true, record };
}

// ── Route handlers ───────────────────────────────────────────────────────────

function handleRegister(body) {
  const deviceId = body.deviceId || ("mock_" + crypto.randomBytes(8).toString("hex"));
  let record = devices.get(deviceId);
  if (record) {
    // Re-registration refreshes pairing code
    record.pairingCode = generatePairingCode();
    record.pairingCodeExpiresAt = new Date(Date.now() + PAIRING_TTL_MS).toISOString();
    record.softwareVersion = body.softwareVersion || record.softwareVersion;
    record.metadata = body.metadata || record.metadata;
  } else {
    record = createDeviceRecord(deviceId, body);
  }
  return {
    status: 200,
    body: {
      ok: true,
      device: {
        deviceId: record.deviceId,
        deviceApiKey: record.deviceApiKey,
        paired: record.paired
      },
      pairingCode: record.pairingCode,
      expiresAt: record.pairingCodeExpiresAt
    }
  };
}

function handlePairingStatus(deviceId) {
  const record = devices.get(deviceId);
  if (!record) return { status: 404, body: { ok: false, error: "Device not found" } };
  return {
    status: 200,
    body: {
      ok: true,
      paired: record.paired,
      ownerUserId: record.ownerUserId,
      pairing: record.paired
        ? { status: "completed" }
        : {
            pairingCode: record.pairingCode,
            expiresAt: record.pairingCodeExpiresAt,
            status: "pending"
          }
    }
  };
}

function handleGetSettings(deviceId) {
  const auth = authenticateDevice({ headers: {} }, deviceId);
  // For settings read, we accept both paired and unpaired (pre-sync)
  const record = devices.get(deviceId);
  if (!record) return { status: 404, body: { ok: false, error: "Device not found" } };
  const response = {
    ok: true,
    settings: record.settings,
    updatedAt: record.settings.updatedAt
  };
  // Include owner preferences if device has an owner with cascade overrides
  if (record.ownerUserId && ownerPreferences.has(record.ownerUserId)) {
    response.ownerPreferences = ownerPreferences.get(record.ownerUserId);
    response.ownerPreferencesUpdatedAt = (response.ownerPreferences || {}).updatedAt || null;
  }
  return { status: 200, body: response };
}

function handlePushSettings(deviceId, body, req) {
  const auth = authenticateDevice(req, deviceId);
  if (!auth.ok) return { status: auth.status, body: { ok: false, error: auth.error } };
  const incoming = body.settings || {};
  const incomingUpdated = incoming.updatedAt || now();
  if (recordSettingsNewer(incomingUpdated, auth.record.settings.updatedAt)) {
    auth.record.settings = { ...auth.record.settings, ...incoming, updatedAt: incomingUpdated };
    return {
      status: 200,
      body: {
        ok: true,
        settings: auth.record.settings,
        updatedAt: auth.record.settings.updatedAt
      }
    };
  }
  // Stale write: return conflict with current authoritative settings
  return {
    status: 200,
    body: {
      ok: false,
      error: "settings conflict",
      reason: "stale_write",
      conflict: true,
      settings: auth.record.settings,
      updatedAt: auth.record.settings.updatedAt
    }
  };
}

function recordSettingsNewer(incoming, existing) {
  return !existing || incoming >= existing;
}

function handleHeartbeat(deviceId, body, req) {
  const auth = authenticateDevice(req, deviceId);
  if (!auth.ok) return { status: auth.status, body: { ok: false, error: auth.error } };
  const record = auth.record;

  record.lastHeartbeatAt = now();
  record.softwareVersion = body.softwareVersion || record.softwareVersion;

  // Event ingestion
  let eventAck = null;
  if (body.events && body.events.length > 0) {
    record.events.push(...body.events);
    const acceptedThrough = body.events[body.events.length - 1].observedAt || now();
    const acceptedKey = body.events[body.events.length - 1].eventKey || ("evt_" + record.events.length);
    eventAck = {
      accepted: true,
      acceptedCount: body.events.length,
      acceptedThroughObservedAt: acceptedThrough,
      acceptedThroughEventKey: acceptedKey,
      cursor: {
        status: "accepted",
        acceptedAt: now(),
        acceptedThroughObservedAt: acceptedThrough,
        acceptedThroughEventKey: acceptedKey
      }
    };
    record.eventIngestionCursor = eventAck.cursor;
  } else if (body.eventIngestionCursor) {
    eventAck = {
      accepted: true,
      acceptedCount: 0,
      cursor: record.eventIngestionCursor || {
        status: "accepted",
        acceptedAt: now(),
        acceptedThroughObservedAt: now(),
        acceptedThroughEventKey: "cursor_empty"
      }
    };
  }

  // Broadcast delivery ingestion
  let deliveryAck = null;
  if (body.broadcastDeliveries && body.broadcastDeliveries.deliveries) {
    const incoming = body.broadcastDeliveries.deliveries;
    for (const d of incoming) {
      const existing = record.broadcastDeliveries.find(
        (e) => e.broadcastId === d.broadcastId
      );
      if (existing) {
        // Upsert: update status and timestamps, keep the most recent state
        existing.status = d.status;
        if (d.receivedAt) existing.receivedAt = d.receivedAt;
        if (d.shownAt) existing.shownAt = d.shownAt;
        if (d.dismissedAt) existing.dismissedAt = d.dismissedAt;
        if (d.expiredAt) existing.expiredAt = d.expiredAt;
        if (d.skippedAt) existing.skippedAt = d.skippedAt;
        if (d.eventCount != null) existing.eventCount = d.eventCount;
        existing.updatedAt = now();
      } else {
        record.broadcastDeliveries.push({
          broadcastId: d.broadcastId,
          deviceId,
          commandId: d.commandId || null,
          status: d.status,
          receivedAt: d.receivedAt || null,
          shownAt: d.shownAt || null,
          dismissedAt: d.dismissedAt || null,
          expiredAt: d.expiredAt || null,
          skippedAt: d.skippedAt || null,
          eventCount: d.eventCount || 1,
          createdAt: now(),
          updatedAt: now()
        });
      }
    }
    deliveryAck = {
      accepted: true,
      acceptedCount: incoming.length,
      totalDeliveries: record.broadcastDeliveries.length
    };
  }

  // Return pending commands (non-terminal)
  const pendingCommands = record.commands.filter(
    (c) => c.status === "queued" || c.status === "sent"
  );

  // Build response
  const response = {
    ok: true,
    heartbeatAt: now(),
    eventAck,
    deliveryAck,
    commands: pendingCommands.length > 0 ? { items: pendingCommands } : undefined,
    settings: undefined,
    feed: undefined
  };

  // Include owner preferences if device has an owner with cascade overrides
  if (record.ownerUserId && ownerPreferences.has(record.ownerUserId)) {
    response.ownerPreferences = ownerPreferences.get(record.ownerUserId);
  }

  return { status: 200, body: response };
}

function handleStream(deviceId, req) {
  const auth = authenticateDevice(req, deviceId);
  if (!auth.ok) return { status: auth.status, body: { ok: false, error: auth.error } };

  const composed = composePersonalizedStream(auth.record);

  const body = {
    ok: true,
    generatedAt: now(),
    items: composed.items,
    polling: composed.polling,
    settings: {
      displayMode: auth.record.settings.displayMode || "shuffle",
      shuffleInterval: auth.record.settings.shuffleInterval || 30
    }
  };

  // Include owner preferences cascade if present
  if (auth.record.ownerUserId && ownerPreferences.has(auth.record.ownerUserId)) {
    body.ownerPreferences = ownerPreferences.get(auth.record.ownerUserId);
    body.ownerPreferencesUpdatedAt = (body.ownerPreferences || {}).updatedAt || null;
  }

  return { status: 200, body };
}

function handleFeed(deviceId, req) {
  // Feed is an alias for stream in this mock
  return handleStream(deviceId, req);
}

function handleCommandAck(deviceId, commandId, body, req) {
  const auth = authenticateDevice(req, deviceId);
  if (!auth.ok) return { status: auth.status, body: { ok: false, error: auth.error } };

  const command = auth.record.commands.find((c) => c.commandId === commandId);
  if (!command) return { status: 404, body: { ok: false, error: "Command not found" } };

  const previousStatus = command.status;
  command.status = body.status || "acknowledged";
  command.acknowledgedAt = now();
  command.updatedAt = now();

  // Record audit
  auth.record.commandAudits.push({
    commandId,
    previousStatus,
    newStatus: command.status,
    auditedAt: now(),
    auditId: "audit_" + Date.now()
  });

  return {
    status: 200,
    body: {
      ok: true,
      commandId,
      status: command.status,
      updatedAt: command.updatedAt
    }
  };
}

function handleRelease(deviceId, req) {
  const auth = authenticateDevice(req, deviceId);
  if (!auth.ok) return { status: auth.status, body: { ok: false, error: auth.error } };

  // Return no update available by default
  return {
    status: 200,
    body: {
      ok: true,
      release: auth.record.release || null,
      currentVersion: auth.record.softwareVersion
    }
  };
}

function handleLikeArtwork(artworkId, body, req) {
  // Minimal like response
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

// ── Mock test helpers ────────────────────────────────────────────────────────

function handleMockPairDevice(deviceId, body) {
  const record = devices.get(deviceId);
  if (!record) return { status: 404, body: { ok: false, error: "Device not found" } };
  const ownerUserId = (body && body.ownerUserId) || ensureDefaultAdminUser();

  // Enforce subscription-tier device limits
  const entitlements = computeEntitlements(ownerUserId);
  if (!entitlements.canAddDevice) {
    const currentOwned = [...devices.values()].filter((d) => d.ownerUserId === ownerUserId && d.deviceId !== deviceId).length;
    const atLimit = entitlements.deviceLimit === null ? false : currentOwned >= entitlements.deviceLimit;
    // Block if degraded (subscription expired/cancelled/past_due) OR at device limit
    if (entitlements.degradedAccess || atLimit) {
      return {
        status: 403,
        body: {
          ok: false,
          error: entitlements.degradedAccess ? "Subscription degraded" : "Device limit reached",
          reason: entitlements.degradedReason || ("Plan " + entitlements.plan + " allows " + entitlements.deviceLimitLabel + " device(s)"),
          reasonCode: entitlements.degradedAccess ? "subscription_degraded" : "device_limit_reached",
          entitlements: {
            deviceLimit: entitlements.deviceLimit,
            deviceUsage: entitlements.deviceUsage,
            plan: entitlements.plan,
            status: entitlements.status
          }
        }
      };
    }
  }

  record.paired = true;
  record.ownerUserId = ownerUserId;
  record.pairingCode = null;
  record.pairingCodeExpiresAt = null;
  return { status: 200, body: { ok: true, deviceId, paired: true, ownerUserId } };
}

function handleMockQueueCommand(deviceId, body) {
  const record = devices.get(deviceId);
  if (!record) return { status: 404, body: { ok: false, error: "Device not found" } };
  const command = {
    commandId: generateCommandId(),
    commandType: body.type || "sync_settings",
    type: body.type || "sync_settings",
    status: "queued",
    createdAt: now(),
    updatedAt: now(),
    risk: body.risk || "low",
    requiresAuthorization: body.requiresAuthorization || false,
    requiresLocalConfirmation: body.requiresLocalConfirmation || false
  };
  if (body.payload) command.payload = body.payload;
  else {
    // Auto-wrap non-meta fields into payload so command handlers can access them
    const metaFields = new Set(["type", "risk", "requiresAuthorization", "requiresLocalConfirmation", "authorization", "payload"]);
    const payloadFields = {};
    for (const [key, value] of Object.entries(body)) {
      if (!metaFields.has(key)) payloadFields[key] = value;
    }
    if (Object.keys(payloadFields).length > 0) command.payload = payloadFields;
  }
  if (body.authorization) command.authorization = body.authorization;
  record.commands.push(command);
  return { status: 200, body: { ok: true, command } };
}

function handleMockState() {
  const state = {};
  for (const [id, record] of devices) {
    state[id] = {
      deviceId: record.deviceId,
      paired: record.paired,
      ownerUserId: record.ownerUserId,
      lastHeartbeatAt: record.lastHeartbeatAt,
      commandCount: record.commands.length,
      eventCount: record.events.length,
      settingsUpdatedAt: record.settings.updatedAt
    };
  }
  return {
    status: 200,
    body: {
      ok: true,
      devices: state,
      adminUsers: Object.fromEntries(adminUsers),
      adminSubscribers: Object.fromEntries(adminSubscribers),
      adminSubscriptions: Object.fromEntries(adminSubscriptions)
    }
  };
}

/**
 * GET /frames/admin/broadcast-deliveries
 * Admin endpoint: list all broadcast delivery records across all devices.
 * Query params: deviceId (optional filter), status (optional filter).
 * Maps to hosted backend querying aos_broadcast_deliveries.
 */
function handleAdminBroadcastDeliveries(query) {
  let allDeliveries = [];
  for (const [deviceId, record] of devices) {
    for (const d of (record.broadcastDeliveries || [])) {
      allDeliveries.push({ ...d, ownerUserId: record.ownerUserId });
    }
  }

  // Optional filters
  if (query.get("deviceId")) {
    allDeliveries = allDeliveries.filter(d => d.deviceId === query.get("deviceId"));
  }
  if (query.get("status")) {
    allDeliveries = allDeliveries.filter(d => d.status === query.get("status"));
  }
  if (query.get("ownerUserId")) {
    allDeliveries = allDeliveries.filter(d => d.ownerUserId === query.get("ownerUserId"));
  }

  // Summary counts
  const statusCounts = {};
  for (const d of allDeliveries) {
    statusCounts[d.status] = (statusCounts[d.status] || 0) + 1;
  }

  return {
    status: 200,
    body: {
      ok: true,
      totalDeliveries: allDeliveries.length,
      uniqueBroadcasts: [...new Set(allDeliveries.map(d => d.broadcastId))].length,
      uniqueDevices: [...new Set(allDeliveries.map(d => d.deviceId))].length,
      statusCounts,
      deliveries: allDeliveries
    }
  };
}

/**
 * GET /frames/admin/broadcast-deliveries/:broadcastId
 * Admin endpoint: delivery status for a specific broadcast across all devices.
 */
function handleAdminBroadcastDeliveryDetail(broadcastId) {
  const deliveries = [];
  for (const [deviceId, record] of devices) {
    const match = (record.broadcastDeliveries || []).find(d => d.broadcastId === broadcastId);
    if (match) {
      deliveries.push({ ...match, ownerUserId: record.ownerUserId, deviceName: record.deviceName });
    }
  }
  return {
    status: 200,
    body: {
      ok: true,
      broadcastId,
      totalDevices: deliveries.length,
      statusCounts: deliveries.reduce((acc, d) => { acc[d.status] = (acc[d.status] || 0) + 1; return acc; }, {}),
      deliveries
    }
  };
}

function handleMockSetRelease(deviceId, body) {
  const record = devices.get(deviceId);
  if (!record) return { status: 404, body: { ok: false, error: "Device not found" } };
  record.release = {
    version: body.version || "99.0.0",
    channel: body.channel || "stable",
    tagName: body.tagName || "v99.0.0",
    artifactUrl: body.artifactUrl || "https://github.com/example/release.tar.gz",
    sha256: body.sha256 || crypto.randomBytes(32).toString("hex"),
    releaseNoteUrl: body.releaseNoteUrl || "https://autopoiesis.art/changelog",
    rolloutPercentage: body.rolloutPercentage || 100,
    updatedAt: now()
  };
  return { status: 200, body: { ok: true, release: record.release } };
}

// ── Online admin bundle generation ─────────────────────────────────────────

const REMOTE_ACTION_COMMANDS = [
  { commandType: "sync_settings", risk: "low", requiresAuthorization: true, requiresAuditId: false, requiresLocalConfirmation: false, status: "available", acceptedActorRoles: ["admin", "owner", "maintainer"] },
  { commandType: "clear_cache", risk: "low", requiresAuthorization: true, requiresAuditId: false, requiresLocalConfirmation: false, status: "available", acceptedActorRoles: ["admin", "owner", "maintainer"] },
  { commandType: "restart_display", risk: "medium", requiresAuthorization: true, requiresAuditId: false, requiresLocalConfirmation: false, status: "available", acceptedActorRoles: ["admin", "owner", "maintainer"] },
  { commandType: "enable_device", risk: "low", requiresAuthorization: true, requiresAuditId: false, requiresLocalConfirmation: false, status: "available", acceptedActorRoles: ["admin", "owner"] },
  { commandType: "disable_device", risk: "medium", requiresAuthorization: true, requiresAuditId: false, requiresLocalConfirmation: false, status: "available", acceptedActorRoles: ["admin", "owner"] },
  { commandType: "restart_device", risk: "high", requiresAuthorization: true, requiresAuditId: true, requiresLocalConfirmation: false, status: "available", acceptedActorRoles: ["admin", "owner"] },
  { commandType: "update_device", risk: "high", requiresAuthorization: true, requiresAuditId: true, requiresLocalConfirmation: false, status: "available", acceptedActorRoles: ["admin", "owner"] },
  { commandType: "show_broadcast", risk: "low", requiresAuthorization: true, requiresAuditId: false, requiresLocalConfirmation: false, status: "available", acceptedActorRoles: ["admin", "owner", "maintainer", "curator"] },
  { commandType: "factory_reset_request", risk: "critical", requiresAuthorization: true, requiresAuditId: true, requiresLocalConfirmation: true, status: "available", acceptedActorRoles: ["admin"] }
];

const ROLE_ACTION_MATRIX = [
  {
    role: "curator",
    actions: {
      sync_settings: { allowed: false, reason: "Curator has view-only device access", reasonCode: "role_readonly" },
      clear_cache: { allowed: false, reason: "Curator has view-only device access", reasonCode: "role_readonly" },
      restart_display: { allowed: false, reason: "Curator has view-only device access", reasonCode: "role_readonly" },
      enable_device: { allowed: false, reason: "Curator has view-only device access", reasonCode: "role_readonly" },
      disable_device: { allowed: false, reason: "Curator has view-only device access", reasonCode: "role_readonly" },
      restart_device: { allowed: false, reason: "Curator has view-only device access", reasonCode: "role_readonly" },
      update_device: { allowed: false, reason: "Curator has view-only device access", reasonCode: "role_readonly" },
      show_broadcast: { allowed: true, requiresAuthorization: true },
      factory_reset_request: { allowed: false, reason: "Only admin can request factory reset", reasonCode: "role_insufficient" }
    }
  },
  {
    role: "admin",
    actions: {
      sync_settings: { allowed: true, requiresAuthorization: true },
      clear_cache: { allowed: true, requiresAuthorization: true },
      restart_display: { allowed: true, requiresAuthorization: true },
      enable_device: { allowed: true, requiresAuthorization: true },
      disable_device: { allowed: true, requiresAuthorization: true },
      restart_device: { allowed: true, requiresAuthorization: true, requiresAuditId: true },
      update_device: { allowed: true, requiresAuthorization: true, requiresAuditId: true },
      show_broadcast: { allowed: true, requiresAuthorization: true },
      factory_reset_request: { allowed: true, requiresAuthorization: true, requiresAuditId: true, requiresLocalConfirmation: true }
    }
  },
  {
    role: "owner",
    actions: {
      sync_settings: { allowed: true, requiresAuthorization: true },
      clear_cache: { allowed: true, requiresAuthorization: true },
      restart_display: { allowed: true, requiresAuthorization: true },
      enable_device: { allowed: true, requiresAuthorization: true },
      disable_device: { allowed: true, requiresAuthorization: true },
      restart_device: { allowed: true, requiresAuthorization: true, requiresAuditId: true },
      update_device: { allowed: true, requiresAuthorization: true, requiresAuditId: true },
      show_broadcast: { allowed: true, requiresAuthorization: true },
      factory_reset_request: { allowed: false, reason: "Only admin can request factory reset", reasonCode: "role_insufficient" }
    }
  },
  {
    role: "maintainer",
    actions: {
      sync_settings: { allowed: true, requiresAuthorization: true },
      clear_cache: { allowed: true, requiresAuthorization: true },
      restart_display: { allowed: true, requiresAuthorization: true },
      enable_device: { allowed: false, reason: "Insufficient permissions", reasonCode: "role_insufficient" },
      disable_device: { allowed: false, reason: "Insufficient permissions", reasonCode: "role_insufficient" },
      restart_device: { allowed: false, reason: "Requires admin or owner role", reasonCode: "role_insufficient" },
      update_device: { allowed: false, reason: "Requires admin or owner role", reasonCode: "role_insufficient" },
      show_broadcast: { allowed: true, requiresAuthorization: true },
      factory_reset_request: { allowed: false, reason: "Only admin can request factory reset", reasonCode: "role_insufficient" }
    }
  },
  {
    role: "support",
    actions: {
      sync_settings: { allowed: false, reason: "Read-only support role", reasonCode: "role_readonly" },
      clear_cache: { allowed: false, reason: "Read-only support role", reasonCode: "role_readonly" },
      restart_display: { allowed: false, reason: "Read-only support role", reasonCode: "role_readonly" },
      enable_device: { allowed: false, reason: "Read-only support role", reasonCode: "role_readonly" },
      disable_device: { allowed: false, reason: "Read-only support role", reasonCode: "role_readonly" },
      restart_device: { allowed: false, reason: "Read-only support role", reasonCode: "role_readonly" },
      update_device: { allowed: false, reason: "Read-only support role", reasonCode: "role_readonly" },
      show_broadcast: { allowed: false, reason: "Read-only support role", reasonCode: "role_readonly" },
      factory_reset_request: { allowed: false, reason: "Read-only support role", reasonCode: "role_readonly" }
    }
  }
];

function buildOnlineAdminBundle(profileUserId = null) {
  const generatedAt = now();
  const defaultUserId = ensureDefaultAdminUser();
  const effectiveUserId = profileUserId || defaultUserId;

  // ── Admin frames: users, subscribers, subscriptions ──
  const usersItems = [];
  for (const [userId, user] of adminUsers) {
    const subscriber = adminSubscribers.get(userId);
    const userEntry = {
      userId,
      email: user.email,
      frameCount: [...devices.values()].filter((d) => d.ownerUserId === userId).length,
      subscription: null
    };
    if (subscriber && subscriber.subscriptionId) {
      const sub = adminSubscriptions.get(subscriber.subscriptionId);
      if (sub) {
        userEntry.subscription = {
          subscriptionId: sub.subscriptionId,
          status: sub.status,
          plan: sub.plan,
          tier: sub.tier,
          currentPeriodEnd: sub.currentPeriodEnd,
          cancelAtPeriodEnd: sub.cancelAtPeriodEnd
        };
      }
    }
    userEntry.entitlements = computeEntitlements(userId);
    usersItems.push(userEntry);
  }

  const subscribersItems = [];
  for (const [userId, subscriber] of adminSubscribers) {
    subscribersItems.push({
      userId,
      status: subscriber.status,
      plan: subscriber.plan,
      tier: subscriber.tier,
      subscriptionId: subscriber.subscriptionId,
      testAccount: subscriber.testAccount
    });
  }

  const subscriptionsItems = [];
  for (const [subscriptionId, subscription] of adminSubscriptions) {
    subscriptionsItems.push({
      subscriptionId,
      userId: subscription.userId,
      status: subscription.status,
      plan: subscription.plan,
      tier: subscription.tier,
      currentPeriodEnd: subscription.currentPeriodEnd,
      cancelAtPeriodEnd: subscription.cancelAtPeriodEnd
    });
  }

  // ── Admin frames: fleet devices ──
  const fleetDevices = [];
  for (const [deviceId, record] of devices) {
    if (!record.paired) continue;
    const subscription = record.ownerUserId && adminSubscribers.get(record.ownerUserId);
    const subscriptionRow = subscription && subscription.subscriptionId
      ? adminSubscriptions.get(subscription.subscriptionId)
      : null;
    fleetDevices.push({
      deviceId: record.deviceId,
      deviceName: record.deviceName,
      ownerUserId: record.ownerUserId,
      softwareVersion: record.softwareVersion,
      currentMode: "display",
      updateChannel: "stable",
      paired: record.paired,
      online: record.lastHeartbeatAt && (Date.now() - new Date(record.lastHeartbeatAt).getTime()) < 300000,
      remoteEnabled: record.remoteEnabled !== false,
      disabled: !!record.disabled,
      lastHeartbeatAt: record.lastHeartbeatAt,
      cache: {
        enabled: true,
        likedArtworks: true,
        recentArtworks: true,
        selectedArtists: false,
        sizeLimitMb: 512
      },
      subscription: subscriptionRow ? {
        subscriptionId: subscriptionRow.subscriptionId,
        status: subscriptionRow.status,
        plan: subscriptionRow.plan,
        tier: subscriptionRow.tier
      } : null,
      settings: record.settings,
      health: {
        status: "healthy",
        uptime: 3600
      },
      release: record.release || null,
      actionAvailability: buildActionAvailability(record, "admin")
    });
  }

  // ── Profile frames (filtered to requested owner) ──
  const profileDevices = [];
  for (const [deviceId, record] of devices) {
    if (!record.paired || record.ownerUserId !== effectiveUserId) continue;
    profileDevices.push({
      deviceId: record.deviceId,
      deviceName: record.deviceName,
      ownerUserId: record.ownerUserId,
      softwareVersion: record.softwareVersion,
      currentMode: "display",
      updateChannel: "stable",
      paired: record.paired,
      online: record.lastHeartbeatAt && (Date.now() - new Date(record.lastHeartbeatAt).getTime()) < 300000,
      remoteEnabled: record.remoteEnabled !== false,
      disabled: !!record.disabled,
      lastHeartbeatAt: record.lastHeartbeatAt,
      cache: {
        enabled: true,
        likedArtworks: true,
        recentArtworks: true,
        selectedArtists: false,
        sizeLimitMb: 512
      },
      subscription: null,
      settings: record.settings,
      actionAvailability: buildActionAvailability(record, "owner")
    });
  }

  return {
    ok: true,
    kind: "autopoiesis_frames_online_admin_bundle",
    schemaVersion: 1,
    generatedAt,
    profileFrames: {
      userId: effectiveUserId,
      preferences: {
        activeArtists: [{ artistId: "artist-001" }, { artistId: "artist-002" }],
        streamCategories: ["artwork", "curatorial", "blog"],
        allowImages: true,
        allowVideos: true,
        allowSoundWorks: false,
        allowGenerativeWorks: true,
        autoplay: true,
        videoAutoplay: false,
        soundAutoplay: false,
        soundEnabled: false,
        nightMode: false,
        cacheEnabled: true,
        cacheLikedArtworks: true,
        cacheRecentArtworks: true,
        cacheSelectedArtists: false,
        likedWorksOnly: false,
        showArtworkInfoOnTap: true,
        volume: 50,
        imageDuration: 30,
        brightness: 80,
        cacheSizeLimitMb: 512,
        displayMode: "shuffle",
        streamProfile: "default",
        offlineFallbackMode: "cached",
        updatedAt: generatedAt
      },
      pairing: null,
      cachePreferences: {
        enabled: true,
        likedArtworks: true,
        recentArtworks: true,
        selectedArtists: false,
        sizeLimitMb: 512
      },
      activeArtists: [
        { artistId: "artist-001", name: "Sandman", enabled: true },
        { artistId: "artist-002", name: "Vessel", enabled: true }
      ],
      likedArtworks: [
        { artworkId: "artwork-001", likedAt: generatedAt, artistId: "artist-001", title: "Dream Fragment" },
        { artworkId: "artwork-002", likedAt: generatedAt, artistId: "artist-002", title: "Cellular Memory" }
      ],
      devices: profileDevices,
      entitlements: computeEntitlements(effectiveUserId)
    },
    adminFrames: {
      actor: {
        actorId: "admin_mock_001",
        userId: "admin_mock_001",
        role: "admin"
      },
      users: { items: usersItems, total: usersItems.length, page: 1, pageSize: 50 },
      subscribers: { items: subscribersItems, total: subscribersItems.length, page: 1, pageSize: 50 },
      subscriptions: { items: subscriptionsItems, total: subscriptionsItems.length, page: 1, pageSize: 50 },
      devices: { items: fleetDevices, total: fleetDevices.length, page: 1, pageSize: 50 },
      remoteActions: {
        acceptedActorRoles: ["admin", "owner", "maintainer", "support", "curator"],
        authorizationWindowSeconds: 300,
        highRiskRequiresAuditId: true,
        criticalRiskRequiresAuditId: true,
        commands: REMOTE_ACTION_COMMANDS,
        roleActionMatrix: ROLE_ACTION_MATRIX
      },
      planLimits: Object.fromEntries(
        Object.entries(PLAN_LIMITS).map(([plan, limits]) => [
          plan,
          {
            maxDevices: limits.maxDevices === Infinity ? null : limits.maxDevices,
            maxDevicesLabel: limits.maxDevices === Infinity ? "unlimited" : String(limits.maxDevices),
            remoteActions: limits.remoteActions,
            cacheLimitMb: limits.cacheLimitMb,
            activeArtistsLimit: limits.activeArtistsLimit === Infinity ? null : limits.activeArtistsLimit,
            offlineCache: limits.offlineCache
          }
        ])
      )
    }
  };
}

// Actions that require the device to be online to execute
const ONLINE_REQUIRED_ACTIONS = new Set([
  "sync_settings", "clear_cache", "restart_display",
  "restart_device", "update_device", "show_broadcast"
]);

// Actions that conflict with a pending command of the same type
const CONFLICTING_COMMAND_TYPES = [
  "sync_settings", "clear_cache", "restart_display",
  "restart_device", "update_device", "show_broadcast"
];

// Actions blocked when device is disabled (enable_device is the exception)
const DISABLED_BLOCKED_ACTIONS = new Set([
  "sync_settings", "clear_cache", "restart_display",
  "restart_device", "update_device", "show_broadcast", "factory_reset_request"
]);

function buildActionAvailability(record, actorRole) {
  const generatedAt = now();
  const actions = {};
  const roleRow = ROLE_ACTION_MATRIX.find((r) => r.role === actorRole);
  if (!roleRow) return { generatedAt, actions: {} };

  // Compute device-level state
  const isPaired = !!record.paired;
  const isOnline = !!(record.lastHeartbeatAt && (Date.now() - new Date(record.lastHeartbeatAt).getTime()) < 300000);
  const isDisabled = !!record.disabled;
  const isRemoteEnabled = record.remoteEnabled !== false; // default true
  const pendingCommands = (record.commands || []).filter(
    (c) => c.status === "queued" || c.status === "sent"
  );
  const pendingCommandTypes = new Set(pendingCommands.map((c) => c.commandType));

  // Check subscription entitlements for the device owner
  const ownerId = record.ownerUserId;
  const ownerEntitlements = ownerId ? computeEntitlements(ownerId) : null;
  const ownerDegraded = ownerEntitlements && ownerEntitlements.degradedAccess;

  for (const cmd of REMOTE_ACTION_COMMANDS) {
    const roleAction = roleRow.actions[cmd.commandType];

    // Layer 1: Subscription degradation overrides role policy for owner-scoped devices
    if (ownerDegraded && ownerEntitlements.degradedActionsBlocked.includes(cmd.commandType)) {
      actions[cmd.commandType] = {
        allowed: false,
        reason: ownerEntitlements.degradedReason,
        reasonCode: "subscription_degraded",
        degradedBySubscription: true
      };
      continue;
    }

    // Layer 2: Role policy
    if (!roleAction) {
      actions[cmd.commandType] = { allowed: false, reason: "No policy for action", reasonCode: "no_policy" };
      continue;
    }
    if (!roleAction.allowed) {
      actions[cmd.commandType] = {
        allowed: false,
        reason: roleAction.reason,
        reasonCode: roleAction.reasonCode
      };
      continue;
    }

    // Layer 3: Device-state gating (role allows it, but can the device accept it?)

    // 3a: Not paired — all actions blocked
    if (!isPaired) {
      actions[cmd.commandType] = {
        allowed: false,
        reason: "Device is not paired",
        reasonCode: "not_paired",
        roleAllowed: true
      };
      continue;
    }

    // 3b: Device is disabled — most actions blocked (enable_device is the escape hatch)
    if (isDisabled && DISABLED_BLOCKED_ACTIONS.has(cmd.commandType)) {
      actions[cmd.commandType] = {
        allowed: false,
        reason: "Device is disabled",
        reasonCode: "device_disabled",
        roleAllowed: true
      };
      continue;
    }

    // 3c: Remote not enabled — all remote actions blocked
    if (!isRemoteEnabled) {
      actions[cmd.commandType] = {
        allowed: false,
        reason: "Remote actions are disabled for this device",
        reasonCode: "remote_disabled",
        roleAllowed: true
      };
      continue;
    }

    // 3d: Device offline — actions requiring live connection are blocked
    if (!isOnline && ONLINE_REQUIRED_ACTIONS.has(cmd.commandType)) {
      actions[cmd.commandType] = {
        allowed: false,
        reason: "Device is offline",
        reasonCode: "offline",
        roleAllowed: true
      };
      continue;
    }

    // 3e: Pending conflicting command of the same type
    if (pendingCommandTypes.has(cmd.commandType)) {
      actions[cmd.commandType] = {
        allowed: false,
        reason: "A " + cmd.commandType + " command is already pending",
        reasonCode: "pending_command",
        roleAllowed: true
      };
      continue;
    }

    // All layers passed
    actions[cmd.commandType] = {
      allowed: true,
      requiresAuthorization: cmd.requiresAuthorization,
      requiresAuditId: cmd.requiresAuditId,
      requiresLocalConfirmation: cmd.requiresLocalConfirmation
    };
  }

  return {
    generatedAt,
    evaluatedAt: generatedAt,
    actorRole,
    deviceState: { isPaired, isOnline, isDisabled, isRemoteEnabled, pendingCommandCount: pendingCommands.length },
    actions
  };
}

function handleMockOnlineAdminBundle(userId = null) {
  return { status: 200, body: buildOnlineAdminBundle(userId) };
}

function handleMockTransitionSubscription(userId, body) {
  const subscriber = adminSubscribers.get(userId);
  if (!subscriber) return { status: 404, body: { ok: false, error: "Subscriber not found" } };

  const validTransitions = {
    trial: ["active", "cancelled"],
    active: ["past_due", "cancelled"],
    past_due: ["active", "cancelled"],
    cancelled: ["expired"],
    expired: []
  };

  const currentStatus = subscriber.status;
  const newStatus = body.status;
  const allowed = (validTransitions[currentStatus] || []).includes(newStatus);

  if (!allowed) {
    return {
      status: 400,
      body: { ok: false, error: `Invalid transition: ${currentStatus} -> ${newStatus}`, currentStatus }
    };
  }

  // Update subscriber record
  subscriber.status = newStatus;
  if (body.plan) subscriber.plan = body.plan;
  if (body.tier) subscriber.tier = body.tier;
  if (body.cancelAtPeriodEnd !== undefined) subscriber.cancelAtPeriodEnd = body.cancelAtPeriodEnd;

  // Update subscription record
  const sub = adminSubscriptions.get(subscriber.subscriptionId);
  if (sub) {
    sub.status = newStatus;
    if (body.plan) sub.plan = body.plan;
    if (body.tier) sub.tier = body.tier;
    if (body.currentPeriodEnd) sub.currentPeriodEnd = body.currentPeriodEnd;
    if (body.cancelAtPeriodEnd !== undefined) sub.cancelAtPeriodEnd = body.cancelAtPeriodEnd;
    sub.updatedAt = now();
  }

  return {
    status: 200,
    body: {
      ok: true,
      userId,
      previousStatus: currentStatus,
      status: newStatus,
      subscriptionId: subscriber.subscriptionId
    }
  };
}

function handleMockAddUser(body) {
  const userId = body.userId || ("user_mock_" + (adminUsers.size + 2));
  adminUsers.set(userId, {
    userId,
    email: body.email || (userId + "@example.com"),
    name: body.name || "Mock User",
    createdAt: now()
  });
  if (body.subscriber) {
    const subId = body.subscriber.subscriptionId || ("sub_mock_" + (adminSubscriptions.size + 2));
    adminSubscribers.set(userId, {
      userId,
      status: body.subscriber.status || "active",
      plan: body.subscriber.plan || "frames_basic",
      tier: body.subscriber.tier || "basic",
      subscriptionId: subId,
      testAccount: body.subscriber.testAccount || false
    });
    adminSubscriptions.set(subId, {
      subscriptionId: subId,
      userId,
      status: body.subscriber.status || "active",
      plan: body.subscriber.plan || "frames_basic",
      tier: body.subscriber.tier || "basic",
      currentPeriodEnd: body.subscriber.currentPeriodEnd || new Date(Date.now() + 30 * 86400000).toISOString(),
      cancelAtPeriodEnd: body.subscriber.cancelAtPeriodEnd || false,
      createdAt: now()
    });
  }
  return { status: 200, body: { ok: true, userId } };
}

// ── HTTP server ──────────────────────────────────────────────────────────────

function extractPath(url) {
  return new URL(url, "http://localhost").pathname;
}

async function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
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

async function handle(req, res) {
  const pathname = extractPath(req.url);
  const method = req.method;

  // ── Mock test helpers ───────────────────────────────────────────────────

  if (method === "POST" && /^\/mock\/pair-device\/([^/]+)$/.test(pathname)) {
    const deviceId = pathname.split("/").pop();
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendJson(res, ...Object.values(handleMockPairDevice(deviceId, body)));
  }

  if (method === "POST" && /^\/mock\/queue-command\/([^/]+)$/.test(pathname)) {
    const deviceId = pathname.split("/").pop();
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendJson(res, ...Object.values(handleMockQueueCommand(deviceId, body)));
  }

  // POST /mock/set-device-state/:id
  if (method === "POST" && /^\/mock\/set-device-state\/([^/]+)$/.test(pathname)) {
    const deviceId = pathname.split("/").pop();
    const body = JSON.parse((await readBody(req)) || "{}");
    const record = devices.get(deviceId);
    if (!record) return sendJson(res, 404, { ok: false, error: "Device not found" });
    if (body.disabled !== undefined) record.disabled = !!body.disabled;
    if (body.remoteEnabled !== undefined) record.remoteEnabled = !!body.remoteEnabled;
    return sendJson(res, 200, { ok: true, deviceId, disabled: record.disabled, remoteEnabled: record.remoteEnabled });
  }

  if (method === "POST" && /^\/mock\/set-release\/([^/]+)$/.test(pathname)) {
    const deviceId = pathname.split("/").pop();
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendJson(res, ...Object.values(handleMockSetRelease(deviceId, body)));
  }

  if (method === "GET" && pathname === "/mock/state") {
    return sendJson(res, ...Object.values(handleMockState()));
  }

  // GET /mock/online-admin-bundle/:userId
  const bundleUserMatch = pathname.match(/^\/mock\/online-admin-bundle\/([^/]+)$/);
  if (method === "GET" && bundleUserMatch) {
    return sendJson(res, ...Object.values(handleMockOnlineAdminBundle(bundleUserMatch[1])));
  }

  // GET /mock/online-admin-bundle
  if (method === "GET" && pathname === "/mock/online-admin-bundle") {
    return sendJson(res, ...Object.values(handleMockOnlineAdminBundle()));
  }

  // POST /mock/add-user
  if (method === "POST" && pathname === "/mock/add-user") {
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendJson(res, ...Object.values(handleMockAddUser(body)));
  }

  // POST /mock/set-owner-preferences/:userId
  const ownerPrefMatch = pathname.match(/^\/mock\/set-owner-preferences\/([^/]+)$/);
  if (method === "POST" && ownerPrefMatch) {
    const body = JSON.parse((await readBody(req)) || "{}");
    const userId = decodeURIComponent(ownerPrefMatch[1]);
    ownerPreferences.set(userId, { ...(body.preferences || body), updatedAt: body.updatedAt || now() });
    return sendJson(res, 200, { ok: true, userId, preferences: ownerPreferences.get(userId) });
  }

  // POST /mock/add-content
  if (method === "POST" && pathname === "/mock/add-content") {
    const body = JSON.parse((await readBody(req)) || "{}");
    const items = Array.isArray(body) ? body : [body];
    const added = [];
    for (const item of items) {
      if (item && item.id) {
        injectedContent.push({ ...item, _injectedAt: now() });
        added.push(item.id);
      }
    }
    return sendJson(res, 200, { ok: true, added, poolTotal: MOCK_CONTENT_POOL.length, injectedTotal: injectedContent.length });
  }

  // DELETE /mock/content
  if (method === "DELETE" && pathname === "/mock/content") {
    const count = injectedContent.length;
    injectedContent.length = 0;
    return sendJson(res, 200, { ok: true, cleared: count });
  }

  // POST /mock/transition-subscription/:userId
  const subTransitionMatch = pathname.match(/^\/mock\/transition-subscription\/([^/]+)$/);
  if (method === "POST" && subTransitionMatch) {
    const body = JSON.parse((await readBody(req)) || "{}");
    return sendJson(res, ...Object.values(handleMockTransitionSubscription(subTransitionMatch[1], body)));
  }

  // ── Admin broadcast delivery endpoints ────────────────────────────────────

  // GET /frames/admin/broadcast-deliveries (list all)
  if (method === "GET" && pathname === "/frames/admin/broadcast-deliveries") {
    const adminUrl = new URL(req.url, "http://localhost");
    return sendJson(res, ...Object.values(handleAdminBroadcastDeliveries(adminUrl.searchParams)));
  }

  // GET /frames/admin/broadcast-deliveries/:broadcastId (per-broadcast detail)
  const adminBdDetailMatch = pathname.match(/^\/frames\/admin\/broadcast-deliveries\/([^/]+)$/);
  if (method === "GET" && adminBdDetailMatch) {
    return sendJson(res, ...Object.values(handleAdminBroadcastDeliveryDetail(adminBdDetailMatch[1])));
  }

  // ── Frames API endpoints ────────────────────────────────────────────────

  // POST /frames/device/register
  if (method === "POST" && pathname === "/frames/device/register") {
    const body = JSON.parse((await readBody(req)) || "{}");
    const result = handleRegister(body);
    return sendJson(res, result.status, result.body);
  }

  // GET /frames/device/:id/pairing-status
  const pairingMatch = pathname.match(/^\/frames\/device\/([^/]+)\/pairing-status$/);
  if (method === "GET" && pairingMatch) {
    const result = handlePairingStatus(pairingMatch[1]);
    return sendJson(res, result.status, result.body);
  }

  // GET /frames/device/:id/settings
  const settingsGetMatch = pathname.match(/^\/frames\/device\/([^/]+)\/settings$/);
  if (method === "GET" && settingsGetMatch) {
    const result = handleGetSettings(settingsGetMatch[1]);
    return sendJson(res, result.status, result.body);
  }

  // POST /frames/device/:id/settings
  if (method === "POST" && settingsGetMatch) {
    const body = JSON.parse((await readBody(req)) || "{}");
    const result = handlePushSettings(settingsGetMatch[1], body, req);
    return sendJson(res, result.status, result.body);
  }

  // POST /frames/device/:id/heartbeat
  const heartbeatMatch = pathname.match(/^\/frames\/device\/([^/]+)\/heartbeat$/);
  if (method === "POST" && heartbeatMatch) {
    const body = JSON.parse((await readBody(req)) || "{}");
    const result = handleHeartbeat(heartbeatMatch[1], body, req);
    return sendJson(res, result.status, result.body);
  }

  // GET /frames/device/:id/stream
  const streamMatch = pathname.match(/^\/frames\/device\/([^/]+)\/stream$/);
  if (method === "GET" && streamMatch) {
    const result = handleStream(streamMatch[1], req);
    return sendJson(res, result.status, result.body);
  }

  // GET /frames/device/:id/feed
  const feedMatch = pathname.match(/^\/frames\/device\/([^/]+)\/feed$/);
  if (method === "GET" && feedMatch) {
    const result = handleFeed(feedMatch[1], req);
    return sendJson(res, result.status, result.body);
  }

  // POST /frames/device/:id/commands/:cmdId/ack
  const cmdAckMatch = pathname.match(/^\/frames\/device\/([^/]+)\/commands\/([^/]+)\/ack$/);
  if (method === "POST" && cmdAckMatch) {
    const body = JSON.parse((await readBody(req)) || "{}");
    const result = handleCommandAck(cmdAckMatch[1], cmdAckMatch[2], body, req);
    return sendJson(res, result.status, result.body);
  }

  // GET /frames/device/:id/release
  const releaseMatch = pathname.match(/^\/frames\/device\/([^/]+)\/release$/);
  if (method === "GET" && releaseMatch) {
    const result = handleRelease(releaseMatch[1], req);
    return sendJson(res, result.status, result.body);
  }

  // POST /frames/artworks/:id/like
  const likeMatch = pathname.match(/^\/frames\/artworks\/([^/]+)\/like$/);
  if (method === "POST" && likeMatch) {
    const body = JSON.parse((await readBody(req)) || "{}");
    const result = handleLikeArtwork(likeMatch[1], body, req);
    return sendJson(res, result.status, result.body);
  }

  // ── Fallback ────────────────────────────────────────────────────────────

  sendJson(res, 404, { ok: false, error: "Not found", path: pathname });
}

const server = http.createServer(handle);
server.listen(PORT, "127.0.0.1", () => {
  process.stdout.write(
    JSON.stringify({ ok: true, message: "Mock hosted API listening", port: PORT }) + "\n"
  );
});

// Graceful shutdown
process.on("SIGTERM", () => server.close());
process.on("SIGINT", () => server.close());
