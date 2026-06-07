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
  }
  return {
    status: 200,
    body: {
      ok: true,
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

function handleMockPairDevice(deviceId) {
  const record = devices.get(deviceId);
  if (!record) return { status: 404, body: { ok: false, error: "Device not found" } };
  record.paired = true;
  record.ownerUserId = "user_mock_001";
  record.pairingCode = null;
  record.pairingCodeExpiresAt = null;
  return { status: 200, body: { ok: true, deviceId, paired: true } };
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
  return { status: 200, body: { ok: true, devices: state } };
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
    return sendJson(res, ...Object.values(handleMockPairDevice(deviceId)));
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
