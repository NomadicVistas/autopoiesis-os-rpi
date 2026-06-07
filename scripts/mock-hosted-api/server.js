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
 *   GET  /mock/online-admin-bundle                   – Online admin bundle (contract)
 *   POST /mock/add-user                              – Test helper: add admin user+subscription
 *   POST /mock/pair-device/:id                      – Test helper: force-pair a device
 *   POST /mock/queue-command/:id                    – Test helper: queue a command
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

// ── In-memory admin state ────────────────────────────────────────────────────

const adminUsers = new Map(); // userId -> user record
const adminSubscribers = new Map(); // userId -> subscriber record
const adminSubscriptions = new Map(); // subscriptionId -> subscription record

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
    release: null
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
  return {
    status: 200,
    body: {
      ok: true,
      settings: record.settings,
      updatedAt: record.settings.updatedAt
    }
  };
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

  // Return pending commands (non-terminal)
  const pendingCommands = record.commands.filter(
    (c) => c.status === "queued" || c.status === "sent"
  );

  // Build response
  const response = {
    ok: true,
    heartbeatAt: now(),
    eventAck,
    commands: pendingCommands.length > 0 ? { items: pendingCommands } : undefined,
    settings: undefined,
    feed: undefined
  };

  return { status: 200, body: response };
}

function handleStream(deviceId, req) {
  const auth = authenticateDevice(req, deviceId);
  if (!auth.ok) return { status: auth.status, body: { ok: false, error: auth.error } };

  return {
    status: 200,
    body: {
      ok: true,
      generatedAt: now(),
      items: [
        {
          id: "mock-art-001",
          type: "artwork",
          category: "artwork",
          title: "Mock Artwork One",
          artist: { name: "Mock Artist", id: "artist-001" },
          media: {
            image: {
              url: "https://autopoiesis.art/mock/artwork-001.jpg",
              thumbnailUrl: "https://autopoiesis.art/mock/artwork-001-thumb.jpg"
            }
          },
          cacheEligible: true,
          priority: 1,
          startsAt: new Date(Date.now() - 60000).toISOString(),
          expiresAt: new Date(Date.now() + 86400000).toISOString()
        },
        {
          id: "mock-bcast-001",
          type: "broadcast",
          category: "broadcast",
          title: "Mock Broadcast",
          body: "Welcome to Autopoiesis Frames!",
          cacheEligible: false,
          priority: 10,
          startsAt: new Date(Date.now() - 30000).toISOString(),
          expiresAt: new Date(Date.now() + 3600000).toISOString()
        }
      ],
      polling: {
        pollAfterSeconds: 300,
        minPollSeconds: 60,
        staleAfter: 900
      },
      settings: {
        displayMode: auth.record.settings.displayMode || "shuffle",
        shuffleInterval: auth.record.settings.shuffleInterval || 30
      }
    }
  };
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
    type: body.type || "sync_settings",
    status: "queued",
    createdAt: now(),
    updatedAt: now(),
    risk: body.risk || "low",
    requiresAuthorization: body.requiresAuthorization || false,
    requiresLocalConfirmation: body.requiresLocalConfirmation || false
  };
  if (body.payload) command.payload = body.payload;
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
  { commandType: "show_broadcast", risk: "low", requiresAuthorization: true, requiresAuditId: false, requiresLocalConfirmation: false, status: "available", acceptedActorRoles: ["admin", "owner", "maintainer"] },
  { commandType: "factory_reset_request", risk: "critical", requiresAuthorization: true, requiresAuditId: true, requiresLocalConfirmation: true, status: "available", acceptedActorRoles: ["admin"] }
];

const ROLE_ACTION_MATRIX = [
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
      remoteEnabled: true,
      disabled: false,
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
      remoteEnabled: true,
      disabled: false,
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
      devices: profileDevices
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
        acceptedActorRoles: ["admin", "owner", "maintainer", "support"],
        authorizationWindowSeconds: 300,
        highRiskRequiresAuditId: true,
        criticalRiskRequiresAuditId: true,
        commands: REMOTE_ACTION_COMMANDS,
        roleActionMatrix: ROLE_ACTION_MATRIX
      }
    }
  };
}

function buildActionAvailability(record, actorRole) {
  const generatedAt = now();
  const actions = {};
  const roleRow = ROLE_ACTION_MATRIX.find((r) => r.role === actorRole);
  if (!roleRow) return { generatedAt, actions: {} };

  for (const cmd of REMOTE_ACTION_COMMANDS) {
    const roleAction = roleRow.actions[cmd.commandType];
    if (!roleAction) {
      actions[cmd.commandType] = { allowed: false, reason: "No policy for action", reasonCode: "no_policy" };
    } else if (roleAction.allowed) {
      actions[cmd.commandType] = {
        allowed: true,
        requiresAuthorization: cmd.requiresAuthorization,
        requiresAuditId: cmd.requiresAuditId,
        requiresLocalConfirmation: cmd.requiresLocalConfirmation
      };
    } else {
      actions[cmd.commandType] = {
        allowed: false,
        reason: roleAction.reason,
        reasonCode: roleAction.reasonCode
      };
    }
  }

  return { generatedAt, evaluatedAt: generatedAt, actorRole, actions };
}

function handleMockOnlineAdminBundle(userId = null) {
  return { status: 200, body: buildOnlineAdminBundle(userId) };
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
