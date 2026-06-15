const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFile } = require("child_process");

const PORT = Number(process.env.AUTOPOIESIS_PORT || 3030);
const DATA_DIR = process.env.AUTOPOIESIS_DATA_DIR || "/var/lib/autopoiesis-os";
const DEFAULTS_PATH =
  process.env.AUTOPOIESIS_DEFAULTS_PATH ||
  path.resolve(__dirname, "../config/defaults.json");
const API_TIMEOUT_MS = Number(process.env.AUTOPOIESIS_API_TIMEOUT_MS || 8000);
const LAUNCH_PROBE_TIMEOUT_MS = Number(process.env.AUTOPOIESIS_LAUNCH_PROBE_TIMEOUT_MS || 2500);
const OFFLINE_RETRY_SECONDS = Number(process.env.AUTOPOIESIS_OFFLINE_RETRY_SECONDS || 30);
const CACHE_DIR = process.env.AUTOPOIESIS_CACHE_DIR || path.join(DATA_DIR, "cache");
const LOG_DIR = process.env.AUTOPOIESIS_LOG_DIR || "/var/log/autopoiesis-os";
const UPDATE_SCRIPT =
  process.env.AUTOPOIESIS_RELEASE_UPDATE_SCRIPT ||
  path.resolve(__dirname, "../scripts/update-from-release.sh");
const REMOTE_AUTH_WINDOW_MS = Number(process.env.AUTOPOIESIS_REMOTE_AUTH_WINDOW_MS || 24 * 60 * 60 * 1000);
const COMMAND_AUDIT_LIMIT = Number(process.env.AUTOPOIESIS_COMMAND_AUDIT_LIMIT || 100);
const DELIVERY_LOG_LIMIT = Number(process.env.AUTOPOIESIS_DELIVERY_LOG_LIMIT || 200);

// Preference fields that cascade from owner profile to all owned devices.
// Device-level preferences (brightness, volume, nightMode, imageDuration, displayMode)
// are NOT cascaded — they are per-device physical settings.
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
const RELEASE_LOG_LIMIT = Number(process.env.AUTOPOIESIS_RELEASE_LOG_LIMIT || 100);
const HEARTBEAT_EVENT_LIMIT = Number(process.env.AUTOPOIESIS_HEARTBEAT_EVENT_LIMIT || 10);
const FEED_QUEUE_LIMIT = Number(process.env.AUTOPOIESIS_FEED_QUEUE_LIMIT || 100);
const EVENT_CURSOR_OVERLAP_MS = Number(process.env.AUTOPOIESIS_EVENT_CURSOR_OVERLAP_MS || 1000);
const INPUT_DEVICES_PATH = process.env.AUTOPOIESIS_INPUT_DEVICES_PATH || "/proc/bus/input/devices";
const TIMEDATECTL_BIN = process.env.AUTOPOIESIS_TIMEDATECTL_BIN || "timedatectl";
const DEVICE_TREE_MODEL_PATH =
  process.env.AUTOPOIESIS_DEVICE_TREE_MODEL_PATH || "/proc/device-tree/model";
const VCGENCMD_BIN = process.env.AUTOPOIESIS_VCGENCMD_BIN || "vcgencmd";

const COMMAND_POLICIES = {
  sync_settings: { risk: "low", requiresAuthorization: false },
  clear_cache: { risk: "medium", requiresAuthorization: true },
  restart_display: { risk: "medium", requiresAuthorization: true },
  restart_device: { risk: "high", requiresAuthorization: true },
  update_device: { risk: "high", requiresAuthorization: true },
  disable_device: { risk: "high", requiresAuthorization: true },
  enable_device: { risk: "medium", requiresAuthorization: true },
  show_broadcast: { risk: "medium", requiresAuthorization: true },
  factory_reset_request: { risk: "critical", requiresAuthorization: true, requiresLocalConfirmation: true }
};

const COMMAND_AUTH_ROLES = new Set(["admin", "owner", "support", "ops", "maintainer", "super_admin"]);

const paths = {
  device: path.join(DATA_DIR, "device.json"),
  preferences: path.join(DATA_DIR, "preferences.json"),
  state: path.join(DATA_DIR, "state.json"),
  pairing: path.join(DATA_DIR, "pairing.json"),
  commands: path.join(DATA_DIR, "commands.json"),
  release: path.join(DATA_DIR, "release.json"),
  releaseState: path.join(DATA_DIR, "release-state.json"),
  feed: path.join(DATA_DIR, "feed.json"),
  feedCache: path.join(DATA_DIR, "feed-cache.json"),
  cacheIndex: path.join(DATA_DIR, "cache-index.json"),
  broadcast: path.join(DATA_DIR, "current-broadcast.json"),
  diagnostics: path.join(DATA_DIR, "diagnostics.json"),
  commandAudit: path.join(DATA_DIR, "command-audit.json"),
  deliveryLog: path.join(DATA_DIR, "delivery-log.json"),
  releaseLog: path.join(DATA_DIR, "release-log.json"),
  eventCursor: path.join(DATA_DIR, "event-cursor.json"),
  feedCursor: path.join(DATA_DIR, "feed-cursor.json")
};

const DIAGNOSTIC_SERVICES = [
  "autopoiesis-setup.service",
  "autopoiesis-kiosk.service",
  "autopoiesis-heartbeat.service",
  "autopoiesis-command-executor.service",
  "autopoiesis-cache.service",
  "autopoiesis-updater.service",
  "autopoiesis-watchdog.service"
];

const DIAGNOSTIC_TIMERS = [
  "autopoiesis-heartbeat.timer",
  "autopoiesis-command-executor.timer",
  "autopoiesis-cache.timer",
  "autopoiesis-updater.timer",
  "autopoiesis-watchdog.timer"
];

function readJson(filePath, fallback) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    return fallback;
  }
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, {
    mode: 0o600
  });
}

function appendLog(name, message) {
  try {
    fs.mkdirSync(LOG_DIR, { recursive: true });
    fs.appendFileSync(path.join(LOG_DIR, name), new Date().toISOString() + " " + message + "\n");
  } catch {
    // Logging must never break command execution.
  }
}

function apiBase(device = readJson(paths.device, {})) {
  return String(
    process.env.AUTOPOIESIS_API_BASE_URL ||
      device.apiBaseUrl ||
      "https://autopoiesis.art/api"
  ).replace(/\/+$/, "");
}

function apiEndpoint(apiPath, device) {
  const cleanPath = apiPath.startsWith("/") ? apiPath : "/" + apiPath;
  return apiBase(device) + cleanPath;
}

async function apiRequest(apiPath, options = {}) {
  const device = readJson(paths.device, {});
  const deviceKey = device.deviceApiKey || device.device_api_key;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), API_TIMEOUT_MS);
  try {
    const response = await fetch(apiEndpoint(apiPath, device), {
      ...options,
      signal: controller.signal,
      headers: {
        "content-type": "application/json",
        ...(deviceKey ? { "x-frame-device-key": deviceKey } : {}),
        ...(options.headers || {})
      }
    });
    const text = await response.text();
    const body = text ? JSON.parse(text) : {};
    if (!response.ok) {
      throw new Error(body.error || `HTTP ${response.status}`);
    }
    return body;
  } finally {
    clearTimeout(timeout);
  }
}

async function ackCommand(deviceId, commandId, statusValue, extra = {}) {
  return apiRequest(
    "/frames/device/" + encodeURIComponent(deviceId) + "/commands/" + encodeURIComponent(commandId) + "/ack",
    {
      method: "POST",
      body: JSON.stringify({ status: statusValue, ...extra })
    }
  );
}

function execFilePromise(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    execFile(command, args, options, (error, stdout, stderr) => {
      if (error) {
        error.stdout = stdout;
        error.stderr = stderr;
        reject(error);
        return;
      }
      resolve({ stdout, stderr });
    });
  });
}

function defaults() {
  return readJson(DEFAULTS_PATH, { device: {}, preferences: {}, state: {} });
}

function ensureState() {
  const base = defaults();
  const device = readJson(paths.device, null);
  if (!device) {
    writeJson(paths.device, {
      ...base.device,
      deviceId: createDeviceId(),
      softwareVersion: version()
    });
  } else if (device.framesUrl === "https://autopoiesis.art/frames") {
    writeJson(paths.device, {
      ...device,
      framesUrl: base.device.framesUrl || "https://autopoiesis.art/display?shuffle=1"
    });
  }
  if (!fs.existsSync(paths.preferences)) {
    writeJson(paths.preferences, base.preferences);
  }
  if (!fs.existsSync(paths.state)) {
    writeJson(paths.state, {
      ...base.state,
      lastBootAt: new Date().toISOString()
    });
  }
}

let VERSION;
try {
  VERSION = fs.readFileSync(path.resolve(__dirname, "../VERSION"), "utf8").trim();
} catch {
  VERSION = "0.1.0";
}

function version() {
  return VERSION;
}

function createDeviceId() {
  const machineIdPaths = ["/etc/machine-id", "/var/lib/dbus/machine-id"];
  for (const machineIdPath of machineIdPaths) {
    try {
      const id = fs.readFileSync(machineIdPath, "utf8").trim();
      if (id) return `rpi-${id}`;
    } catch {
      // Try the next stable source.
    }
  }
  return `rpi-${os.hostname()}-${Date.now()}`;
}

function status() {
  ensureState();
  const device = readJson(paths.device, {});
  const preferences = readJson(paths.preferences, {});
  const state = readJson(paths.state, {});
  const network = readJson(path.join(DATA_DIR, "network.json"), null);
  const pairing = readJson(paths.pairing, null);
  const services = {};
  const timers = {};
  
  // Collect service and timer status if systemctl is available
  if (typeof process !== "undefined" && process.versions && process.versions.node) {
    // Note: In the browser environment, we can't access systemctl
    // This will only work when running in Node.js context (local UI server)
    try {
      const { execSync } = require("child_process");
      const hasSystemctl = !!execSync("which systemctl", { stdio: "ignore" });
      
      if (hasSystemctl) {
        // Get autopoiesis.target status
        try {
          const targetStatus = execSync("systemctl is-active autopoiesis.target", { encoding: "utf8" }).trim();
          services.autopoiesisTarget = targetStatus;
        } catch (e) {
          services.autopoiesisTarget = "not_found";
        }
        
        // Get key service statuses
        const keyServices = [
          "autopoiesis-setup.service",
          "autopoiesis-kiosk.service",
          "autopoiesis-heartbeat.service",
          "autopoiesis-cache.service",
          "autopoiesis-command-executor.service",
          "autopoiesis-updater.service",
          "autopoiesis-watchdog.service",
          "autopoiesis-night-mode.service"
        ];
        
        for (const service of keyServices) {
          try {
            const status = execSync(`systemctl is-active ${service}`, { encoding: "utf8" }).trim();
            services[service.replace(".service", "")] = status;
          } catch (e) {
            services[service.replace(".service", "")] = "not_found";
          }
        }
        
        // Get key timer statuses
        const keyTimers = [
          "autopoiesis-heartbeat.timer",
          "autopoiesis-command-executor.timer",
          "autopoiesis-updater.timer",
          "autopoiesis-cache.timer",
          "autopoiesis-watchdog.timer",
          "autopoiesis-night-mode.timer"
        ];
        
        for (const timer of keyTimers) {
          try {
            const status = execSync(`systemctl is-active ${timer}`, { encoding: "utf8" }).trim();
            timers[timer.replace(".timer", "")] = status;
          } catch (e) {
            timers[timer.replace(".timer", "")] = "not_found";
          }
        }
      }
    } catch (e) {
      // If we can't check systemctl status, leave services/timers empty
      console.warn("Could not check systemctl status:", e.message);
    }
  }

  return { device, preferences, state, network, pairing, version: version(), services, timers };
}

function updateState(patch) {
  const state = readJson(paths.state, {});
  writeJson(paths.state, { ...state, ...patch });
}

function parseTimestamp(value) {
  if (!value) return null;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? timestamp : null;
}

function timestampString(value) {
  const timestamp = parseTimestamp(value);
  return timestamp === null ? null : new Date(timestamp).toISOString();
}

function commandTypeOf(command = {}) {
  return command.commandType || command.command_type || null;
}

function commandIdOf(command = {}) {
  return command.id || command.commandId || command.command_id || null;
}

function commandPolicy(commandType) {
  return COMMAND_POLICIES[commandType] || { risk: "unknown", requiresAuthorization: true };
}

function commandRequiresAuditId(policy = {}) {
  return policy.risk === "high" || policy.risk === "critical";
}

function commandExecutionState(commandType, policy = commandPolicy(commandType)) {
  if (commandType === "factory_reset_request") {
    return {
      status: "blocked_until_local_confirmation",
      reason: "Factory reset requests require local device confirmation before execution."
    };
  }
  if (commandType === "restart_device" && process.env.AUTOPOIESIS_ALLOW_REBOOT !== "1") {
    return {
      status: "requires_runtime_opt_in",
      runtimeOptIn: "AUTOPOIESIS_ALLOW_REBOOT=1",
      reason: "Device reboot is refused unless reboot execution is explicitly enabled."
    };
  }
  return {
    status: "available",
    requiresLocalConfirmation: Boolean(policy.requiresLocalConfirmation)
  };
}

function publicAdminCapabilities() {
  const data = status();
  const device = data.device || {};
  const commands = Object.entries(COMMAND_POLICIES)
    .map(([commandType, policy]) => ({
      commandType,
      risk: policy.risk,
      requiresAuthorization: Boolean(policy.requiresAuthorization),
      requiresAuditId: commandRequiresAuditId(policy),
      requiresLocalConfirmation: Boolean(policy.requiresLocalConfirmation),
      acceptedActorRoles: policy.requiresAuthorization ? Array.from(COMMAND_AUTH_ROLES).sort() : [],
      execution: commandExecutionState(commandType, policy)
    }))
    .sort((a, b) => a.commandType.localeCompare(b.commandType));
  const commandQueue = readJson(paths.commands, []);
  return {
    ok: true,
    kind: "autopoiesis_frame_admin_capabilities",
    schemaVersion: 1,
    redacted: true,
    generatedAt: new Date().toISOString(),
    device: {
      deviceId: device.deviceId || null,
      deviceName: device.deviceName || null,
      softwareVersion: version(),
      paired: Boolean(device.paired),
      deviceKeyPresent: Boolean(device.deviceApiKey || device.device_api_key),
      remoteEnabled: device.remoteEnabled !== false,
      mode: (data.state || {}).currentMode || "setup"
    },
    authorization: {
      acceptedActorRoles: Array.from(COMMAND_AUTH_ROLES).sort(),
      authorizationWindowSeconds: Math.round(REMOTE_AUTH_WINDOW_MS / 1000),
      timestampSkewAllowanceSeconds: 300,
      highRiskRequiresAuditId: true,
      criticalRiskRequiresAuditId: true
    },
    commands,
    pendingCommands: Array.isArray(commandQueue) ? commandQueue.length : 0,
    commandAudit: commandAuditSummary()
  };
}

function commandAuthorization(command = {}) {
  const payload = command.payload && typeof command.payload === "object" ? command.payload : {};
  const authorization =
    command.authorization ||
    command.authorisation ||
    command.remoteAuthorization ||
    payload.authorization ||
    payload.remoteAuthorization ||
    {};
  return authorization && typeof authorization === "object" ? authorization : {};
}

function validateCommandAuthorization(command, commandType, policy = commandPolicy(commandType)) {
  if (!policy.requiresAuthorization) return { ok: true, policy };
  const authorization = commandAuthorization(command);
  const approved = authorization.approved === true || authorization.authorized === true || authorization.confirmed === true;
  if (!approved) {
    return { ok: false, policy, error: "Remote command denied: missing authorization.approved" };
  }

  const action = authorization.action || authorization.commandType || authorization.command_type;
  if (action && action !== commandType) {
    return { ok: false, policy, error: "Remote command denied: authorization action mismatch" };
  }

  const actorId = authorization.actorId || authorization.adminId || authorization.userId || authorization.requestedBy;
  if (!actorId) {
    return { ok: false, policy, error: "Remote command denied: missing authorization actor" };
  }

  const actorRole = String(authorization.actorRole || authorization.role || authorization.adminRole || "").toLowerCase();
  if (!COMMAND_AUTH_ROLES.has(actorRole)) {
    return { ok: false, policy, error: "Remote command denied: unauthorized actor role" };
  }

  const authorizedAt = parseTimestamp(authorization.authorizedAt || authorization.approvedAt || authorization.confirmedAt);
  if (authorizedAt === null) {
    return { ok: false, policy, error: "Remote command denied: missing authorization timestamp" };
  }
  const now = Date.now();
  if (authorizedAt > now + 5 * 60 * 1000) {
    return { ok: false, policy, error: "Remote command denied: authorization timestamp is in the future" };
  }
  if (now - authorizedAt > REMOTE_AUTH_WINDOW_MS) {
    return { ok: false, policy, error: "Remote command denied: authorization expired" };
  }

  const auditId = authorization.auditId || authorization.actionId || authorization.requestId || authorization.commandId;
  if (commandRequiresAuditId(policy) && !auditId) {
    return { ok: false, policy, error: "Remote command denied: missing admin audit id" };
  }

  return {
    ok: true,
    policy,
    authorization: {
      actorId,
      actorRole,
      authorizedAt: new Date(authorizedAt).toISOString(),
      auditId: auditId || null
    }
  };
}

function commandAuditEntries() {
  const audit = readJson(paths.commandAudit, []);
  if (Array.isArray(audit)) return audit;
  if (Array.isArray(audit.entries)) return audit.entries;
  return [];
}

function commandAuditSubject(command, commandType = commandTypeOf(command), policy = commandPolicy(commandType)) {
  const authorization = commandAuthorization(command);
  const actorId = authorization.actorId || authorization.adminId || authorization.userId || authorization.requestedBy || null;
  const actorRole = authorization.actorRole || authorization.role || authorization.adminRole || null;
  const auditId = authorization.auditId || authorization.actionId || authorization.requestId || authorization.commandId || null;
  return {
    commandId: command.id || null,
    commandType: commandType || "unknown",
    risk: policy.risk || "unknown",
    actorId,
    actorRole: actorRole ? String(actorRole).toLowerCase() : null,
    auditId,
    authorizedAt: timestampString(authorization.authorizedAt || authorization.approvedAt || authorization.confirmedAt),
    approved: authorization.approved === true || authorization.authorized === true || authorization.confirmed === true
  };
}

function appendCommandAudit(entry) {
  const entries = commandAuditEntries();
  entries.push({
    observedAt: new Date().toISOString(),
    ...entry
  });
  const limit = Number.isFinite(COMMAND_AUDIT_LIMIT) && COMMAND_AUDIT_LIMIT > 0 ? COMMAND_AUDIT_LIMIT : 100;
  writeJson(paths.commandAudit, entries.slice(-limit));
}

function safeLimit(value, fallback = 25, max = 100) {
  return Math.max(1, Math.min(Number(value) || fallback, max));
}

function publicCommandAudit(limit = 25) {
  const entries = commandAuditEntries();
  const safeEntryLimit = safeLimit(limit);
  const recent = entries.slice(-safeEntryLimit).reverse();
  return {
    ok: true,
    count: entries.length,
    limit: safeEntryLimit,
    entries: recent
  };
}

function commandAuditSummary() {
  const entries = commandAuditEntries();
  const last = entries[entries.length - 1] || null;
  const recent = entries.slice(-10);
  const errorStatuses = new Set(["error", "ack_failed", "ack_retry_failed"]);
  return {
    totalEntries: entries.length,
    lastCommandId: last ? last.commandId || null : null,
    lastCommandType: last ? last.commandType || null : null,
    lastStatus: last ? last.status || null : null,
    lastObservedAt: last ? last.observedAt || null : null,
    recentErrors: recent.filter(entry => errorStatuses.has(entry.status)).length
  };
}

function localCommandAck(command = {}) {
  const ack = command.localAck || command.localAckRetry || null;
  return ack && typeof ack === "object" ? ack : null;
}

function commandForStorage(command = {}, ack = null) {
  const stored = { ...command };
  delete stored.localAckRetry;
  if (ack) stored.localAck = ack;
  else delete stored.localAck;
  if (!stored.id && commandIdOf(stored)) stored.id = commandIdOf(stored);
  return stored;
}

function ackRetry(command, phase, statusValue, extra = {}, error = null) {
  const previous = localCommandAck(command);
  return {
    phase,
    status: statusValue,
    extra,
    attempts: previous && Number(previous.attempts) ? Number(previous.attempts) + 1 : 1,
    firstFailedAt: (previous && previous.firstFailedAt) || new Date().toISOString(),
    lastFailedAt: new Date().toISOString(),
    lastError: error || null
  };
}

function normalizeCommandsPayload(commands) {
  if (!commands) return [];
  if (Array.isArray(commands)) return commands;
  if (commands.items && Array.isArray(commands.items)) return commands.items;
  return [];
}

function mergeCommandQueues(remoteCommands = [], localCommands = []) {
  const byId = new Map();
  for (const command of Array.isArray(localCommands) ? localCommands : []) {
    const commandId = commandIdOf(command);
    if (!commandId) continue;
    byId.set(String(commandId), commandForStorage({ ...command, id: commandId }, localCommandAck(command)));
  }
  for (const command of Array.isArray(remoteCommands) ? remoteCommands : []) {
    const commandId = commandIdOf(command);
    if (!commandId) continue;
    const existing = byId.get(String(commandId));
    byId.set(
      String(commandId),
      commandForStorage({ ...(existing || {}), ...command, id: commandId }, existing ? localCommandAck(existing) : null)
    );
  }
  return Array.from(byId.values());
}

function deliveryEntries() {
  const log = readJson(paths.deliveryLog, []);
  if (Array.isArray(log)) return log;
  if (Array.isArray(log.entries)) return log.entries;
  return [];
}

function deliverySubject(item = {}) {
  return {
    itemId: item.id || item.broadcastId || item.feedItemId || null,
    source: item.source || null,
    type: item.type || null,
    title: item.title || null,
    priority: item.priority || null,
    startsAt: item.startsAt || null,
    expiresAt: item.expiresAt || null
  };
}

function broadcastIdOf(broadcast = {}) {
  return broadcast.broadcastId || broadcast.id || broadcast.feedItemId || null;
}

function appendDeliveryEvent(entry) {
  const entries = deliveryEntries();
  const observedAt = new Date().toISOString();
  entries.push({
    eventId: observedAt + "-" + String(entries.length + 1),
    observedAt,
    ...entry
  });
  const limit = Number.isFinite(DELIVERY_LOG_LIMIT) && DELIVERY_LOG_LIMIT > 0 ? DELIVERY_LOG_LIMIT : 200;
  writeJson(paths.deliveryLog, entries.slice(-limit));
}

function publicDeliveryLog(limit = 25) {
  const entries = deliveryEntries();
  const safeEntryLimit = safeLimit(limit);
  return {
    ok: true,
    count: entries.length,
    limit: safeEntryLimit,
    entries: entries.slice(-safeEntryLimit).reverse()
  };
}

function deliverySummary() {
  const entries = deliveryEntries();
  const last = entries[entries.length - 1] || null;
  const recent = entries.slice(-25);
  return {
    totalEntries: entries.length,
    lastEventId: last ? last.eventId || null : null,
    lastEventType: last ? last.eventType || null : null,
    lastItemId: last ? last.itemId || null : null,
    lastObservedAt: last ? last.observedAt || null : null,
    recentBroadcastEvents: recent.filter(entry => String(entry.eventType || "").startsWith("broadcast_")).length,
    recentFeedEvents: recent.filter(entry => String(entry.eventType || "").startsWith("feed_")).length
  };
}

function deliveryStatusSummary() {
  const entries = deliveryEntries();
  const itemStatus = new Map();
  const broadcastIds = new Set();

  for (const entry of entries) {
    const itemId = entry.itemId;
    if (!itemId) continue;
    const type = entry.eventType || "";

    if (!itemStatus.has(itemId)) {
      itemStatus.set(itemId, {
        itemId,
        source: entry.source || null,
        type: entry.type || null,
        title: entry.title || null,
        priority: entry.priority || null,
        receivedAt: null,
        shownAt: null,
        dismissedAt: null,
        expiredAt: null,
        skippedAt: null,
        likedAt: null,
        status: "unknown",
        eventCount: 0
      });
    }

    const status = itemStatus.get(itemId);
    status.eventCount++;

    if (type === "broadcast_received") {
      status.receivedAt = entry.observedAt;
      status.status = entry.scheduled ? "scheduled" : "received";
      if (entry.commandId) status.commandId = entry.commandId;
    } else if (type === "broadcast_shown" || type === "feed_item_shown") {
      status.shownAt = entry.observedAt;
      status.status = "shown";
      if (entry.displayCategory) status.displayCategory = entry.displayCategory;
    } else if (type === "broadcast_dismissed") {
      status.dismissedAt = entry.observedAt;
      status.status = "dismissed";
      if (entry.reason) status.dismissReason = entry.reason;
    } else if (type === "broadcast_expired") {
      status.expiredAt = entry.observedAt;
      status.status = "expired";
    } else if (type === "broadcast_skipped") {
      status.skippedAt = entry.observedAt;
      status.status = "skipped";
      if (entry.reason) status.skipReason = entry.reason;
    } else if (type === "feed_item_liked") {
      status.likedAt = entry.observedAt;
    } else if (type === "feed_synced") {
      continue;
    }

    if (type.startsWith("broadcast_")) broadcastIds.add(itemId);
  }

  const items = Array.from(itemStatus.values());
  const broadcasts = items.filter(item => broadcastIds.has(item.itemId));
  const feedItems = items.filter(item => !broadcastIds.has(item.itemId));

  return {
    ok: true,
    totalItems: items.length,
    broadcastItems: broadcasts.length,
    feedItems: feedItems.length,
    statusCounts: {
      received: items.filter(i => i.status === "received").length,
      scheduled: items.filter(i => i.status === "scheduled").length,
      shown: items.filter(i => i.status === "shown").length,
      dismissed: items.filter(i => i.status === "dismissed").length,
      expired: items.filter(i => i.status === "expired").length,
      skipped: items.filter(i => i.status === "skipped").length,
      unknown: items.filter(i => i.status === "unknown").length
    },
    items: items.slice(-50).reverse()
  };
}

function broadcastDeliveriesPayload() {
  const summary = deliveryStatusSummary();
  if (!summary.ok || !summary.items) return { ok: true, broadcastCount: 0, deliveries: [] };
  const broadcasts = summary.items.filter(item =>
    item.source === "broadcast" ||
    item.source === "admin" ||
    item.source === "command" ||
    (item.itemId && item.itemId.startsWith("broadcast-"))
  );
  const deliveries = broadcasts.map(b => ({
    broadcastId: b.itemId,
    status: b.status,
    commandId: b.commandId || null,
    eventCount: b.eventCount,
    receivedAt: b.receivedAt,
    shownAt: b.shownAt,
    dismissedAt: b.dismissedAt,
    expiredAt: b.expiredAt,
    skippedAt: b.skippedAt,
    scheduled: b.status === "scheduled" || null
  }));
  return {
    ok: true,
    broadcastCount: deliveries.length,
    statusCounts: {
      received: deliveries.filter(d => d.status === "received").length,
      scheduled: deliveries.filter(d => d.status === "scheduled").length,
      shown: deliveries.filter(d => d.status === "shown").length,
      dismissed: deliveries.filter(d => d.status === "dismissed").length,
      expired: deliveries.filter(d => d.status === "expired").length,
      skipped: deliveries.filter(d => d.status === "skipped").length
    },
    deliveries
  };
}

const FEED_CURSOR_MAX_SHOWN = Number(process.env.AUTOPOIESIS_FEED_CURSOR_MAX_SHOWN || 500);

function feedCursor() {
  const cursor = readJson(paths.feedCursor, null);
  return cursor && typeof cursor === "object" ? cursor : { syncedAt: null, shownItemIds: [], updatedAt: null };
}

function feedCursorMarkShown(itemId) {
  if (!itemId) return;
  const cursor = feedCursor();
  const id = String(itemId);
  if (cursor.shownItemIds.includes(id)) return;
  cursor.shownItemIds.push(id);
  if (cursor.shownItemIds.length > FEED_CURSOR_MAX_SHOWN) {
    cursor.shownItemIds = cursor.shownItemIds.slice(-FEED_CURSOR_MAX_SHOWN);
  }
  cursor.updatedAt = new Date().toISOString();
  writeJson(paths.feedCursor, cursor);
}

function feedCursorReset(syncedAt) {
  const cursor = {
    syncedAt: syncedAt || new Date().toISOString(),
    shownItemIds: [],
    updatedAt: new Date().toISOString()
  };
  writeJson(paths.feedCursor, cursor);
  return cursor;
}

function feedCursorSummary() {
  const cursor = feedCursor();
  return {
    syncedAt: cursor.syncedAt || null,
    shownCount: (cursor.shownItemIds || []).length,
    updatedAt: cursor.updatedAt || null
  };
}

function releaseEntries() {
  const log = readJson(paths.releaseLog, []);
  if (Array.isArray(log)) return log;
  if (Array.isArray(log.entries)) return log.entries;
  return [];
}

function releaseSubject(release = {}) {
  return {
    releaseId: release.id || release.releaseId || null,
    version: release.version || release.targetVersion || null,
    channel: release.channel || release.updateChannel || release.update_channel || null,
    tag: release.tagName || release.tag_name || release.tag || null,
    rolloutId: release.rolloutId || release.rollout_id || null
  };
}

function appendReleaseEvent(entry) {
  const entries = releaseEntries();
  const observedAt = new Date().toISOString();
  const cleanEntry = {
    eventId: observedAt + "-" + String(entries.length + 1),
    observedAt,
    ...entry
  };
  if (cleanEntry.error) cleanEntry.error = String(cleanEntry.error).slice(0, 500);
  entries.push(cleanEntry);
  const limit = Number.isFinite(RELEASE_LOG_LIMIT) && RELEASE_LOG_LIMIT > 0 ? RELEASE_LOG_LIMIT : 100;
  writeJson(paths.releaseLog, entries.slice(-limit));
}

function publicReleaseHistory(limit = 25) {
  const entries = releaseEntries();
  const safeEntryLimit = safeLimit(limit);
  return {
    ok: true,
    count: entries.length,
    limit: safeEntryLimit,
    entries: entries.slice(-safeEntryLimit).reverse()
  };
}

function releaseHistorySummary() {
  const entries = releaseEntries();
  const last = entries[entries.length - 1] || null;
  const recent = entries.slice(-10);
  const failureStatuses = new Set(["error", "failed"]);
  return {
    totalEntries: entries.length,
    lastEventId: last ? last.eventId || null : null,
    lastEventType: last ? last.eventType || null : null,
    lastStatus: last ? last.status || null : null,
    lastVersion: last ? last.version || null : null,
    lastObservedAt: last ? last.observedAt || null : null,
    recentFailures: recent.filter(entry => failureStatuses.has(entry.status) || String(entry.eventType || "").includes("failed")).length
  };
}

function eventTimestamp(entry = {}) {
  return timestampString(entry.observedAt || entry.completedAt || entry.startedAt || entry.syncedAt || entry.checkedAt);
}

function eventAfterSince(event, sinceTimestamp) {
  if (sinceTimestamp === null) return true;
  const observedAt = parseTimestamp(event.observedAt);
  return observedAt !== null && observedAt > sinceTimestamp;
}

function eventCursor(events, source, totalEntries, limit) {
  const sourceEvents = events.filter(event => event.source === source);
  const latest = sourceEvents[0] || null;
  const oldest = sourceEvents[sourceEvents.length - 1] || null;
  return {
    totalEntries,
    exported: sourceEvents.length,
    limit,
    hasMore: totalEntries > sourceEvents.length,
    latestObservedAt: latest ? latest.observedAt || null : null,
    latestEventKey: latest ? latest.eventKey || null : null,
    oldestObservedAt: oldest ? oldest.observedAt || null : null,
    oldestEventKey: oldest ? oldest.eventKey || null : null
  };
}

function publicDeviceEvents(options = {}) {
  const limit = safeLimit(options.limit, 25, 100);
  const commandLimit = safeLimit(options.commandLimit || limit, limit, 100);
  const deliveryLimit = safeLimit(options.deliveryLimit || limit, limit, 100);
  const releaseLimit = safeLimit(options.releaseLimit || limit, limit, 100);
  const since = timestampString(options.since);
  const sinceTimestamp = parseTimestamp(since);
  const data = status();

  const commandEvents = commandAuditEntries().slice(-commandLimit).map(entry => {
    const observedAt = eventTimestamp(entry);
    return {
      source: "command_audit",
      eventKey: [
        "command",
        observedAt || "unknown",
        entry.commandId || "unknown",
        entry.commandType || "unknown",
        entry.status || "unknown"
      ].join(":"),
      observedAt,
      commandId: entry.commandId || null,
      commandType: entry.commandType || null,
      status: entry.status || null,
      risk: entry.risk || null,
      actorRole: entry.actorRole || null,
      auditId: entry.auditId || null,
      authorizedAt: entry.authorizedAt || null,
      startedAt: entry.startedAt || null,
      completedAt: entry.completedAt || null,
      approved: entry.approved === true
    };
  });

  const deliveryEvents = deliveryEntries().slice(-deliveryLimit).map(entry => {
    const observedAt = eventTimestamp(entry);
    return {
      source: "display_delivery",
      eventKey: "delivery:" + (entry.eventId || [observedAt, entry.eventType, entry.itemId].join(":")),
      eventId: entry.eventId || null,
      observedAt,
      eventType: entry.eventType || null,
      itemId: entry.itemId || null,
      itemType: entry.type || null,
      itemSource: entry.source || null,
      priority: entry.priority || null,
      status: entry.status || null,
      reason: entry.reason || null,
      totalItems: Number.isFinite(Number(entry.totalItems)) ? Number(entry.totalItems) : null,
      eligibleItems: Number.isFinite(Number(entry.eligibleItems)) ? Number(entry.eligibleItems) : null,
      cacheEligibleItems: Number.isFinite(Number(entry.cacheEligibleItems)) ? Number(entry.cacheEligibleItems) : null,
      syncedAt: entry.syncedAt || null
    };
  });

  const releaseEvents = releaseEntries().slice(-releaseLimit).map(entry => {
    const observedAt = eventTimestamp(entry);
    return {
      source: "release_history",
      eventKey: "release:" + (entry.eventId || [observedAt, entry.eventType, entry.version].join(":")),
      eventId: entry.eventId || null,
      observedAt,
      eventType: entry.eventType || null,
      status: entry.status || null,
      releaseId: entry.releaseId || null,
      rolloutId: entry.rolloutId || null,
      version: entry.version || null,
      channel: entry.channel || null,
      tag: entry.tag || null,
      currentVersion: entry.currentVersion || null,
      targetVersion: entry.targetVersion || null,
      updateAvailable: entry.updateAvailable === true,
      reason: entry.reason || null
    };
  });

  const events = [...commandEvents, ...deliveryEvents, ...releaseEvents]
    .filter(event => eventAfterSince(event, sinceTimestamp))
    .sort((a, b) => (parseTimestamp(b.observedAt) || 0) - (parseTimestamp(a.observedAt) || 0));
  const latest = events[0] || null;
  const oldest = events[events.length - 1] || null;
  const counts = {
    commandAudit: commandAuditEntries().length,
    deliveryLog: deliveryEntries().length,
    releaseHistory: releaseEntries().length,
    exported: events.length
  };
  const sourceCursors = {
    command_audit: eventCursor(events, "command_audit", counts.commandAudit, commandLimit),
    display_delivery: eventCursor(events, "display_delivery", counts.deliveryLog, deliveryLimit),
    release_history: eventCursor(events, "release_history", counts.releaseHistory, releaseLimit)
  };

  return {
    ok: true,
    kind: "autopoiesis_frame_event_export",
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    redacted: true,
    since,
    device: {
      deviceId: data.device.deviceId || null,
      deviceName: data.device.deviceName || null,
      softwareVersion: version()
    },
    counts,
    limits: {
      commandAudit: commandLimit,
      deliveryLog: deliveryLimit,
      releaseHistory: releaseLimit
    },
    cursor: {
      latestObservedAt: latest ? latest.observedAt || null : null,
      latestEventKey: latest ? latest.eventKey || null : null,
      oldestObservedAt: oldest ? oldest.observedAt || null : null,
      oldestEventKey: oldest ? oldest.eventKey || null : null,
      hasMore: Object.values(sourceCursors).some(cursorValue => cursorValue.hasMore)
    },
    sourceCursors,
    ingestionCursor: eventIngestionSummary(),
    events
  };
}

function eventIngestionCursor() {
  const cursor = readJson(paths.eventCursor, null);
  return cursor && typeof cursor === "object" ? cursor : null;
}

function eventCursorReplaySince(cursor = eventIngestionCursor()) {
  if (!cursor) return null;
  const acceptedThroughObservedAt = timestampString(
    cursor.acceptedThroughObservedAt ||
      cursor.latestObservedAt ||
      (cursor.cursor || {}).latestObservedAt
  );
  const acceptedTimestamp = parseTimestamp(acceptedThroughObservedAt);
  if (acceptedTimestamp === null) return null;
  const overlap = Number.isFinite(EVENT_CURSOR_OVERLAP_MS) && EVENT_CURSOR_OVERLAP_MS >= 0
    ? EVENT_CURSOR_OVERLAP_MS
    : 1000;
  return new Date(Math.max(0, acceptedTimestamp - overlap)).toISOString();
}

function normalizeEventIngestionAck(result = {}) {
  const raw =
    result.eventsAck ||
    result.eventAck ||
    result.deviceEventsAck ||
    result.device_events_ack ||
    result.eventIngestionCursor ||
    result.ingestionCursor ||
    null;
  if (!raw || typeof raw !== "object") return null;
  const cursor = raw.cursor && typeof raw.cursor === "object" ? raw.cursor : {};
  const acceptedThroughObservedAt = timestampString(
    raw.acceptedThroughObservedAt ||
      raw.latestObservedAt ||
      raw.observedAt ||
      cursor.latestObservedAt ||
      cursor.oldestObservedAt
  );
  const acceptedThroughEventKey =
    raw.acceptedThroughEventKey ||
    raw.latestEventKey ||
    raw.eventKey ||
    cursor.latestEventKey ||
    cursor.oldestEventKey ||
    null;
  const acceptedAt = timestampString(raw.acceptedAt || raw.ingestedAt || raw.updatedAt) || new Date().toISOString();
  const statusValue = raw.status || (acceptedThroughObservedAt || acceptedThroughEventKey ? "accepted" : "acknowledged");
  if (!statusValue && !acceptedThroughObservedAt && !acceptedThroughEventKey) return null;
  return {
    status: String(statusValue),
    acceptedAt,
    acceptedThroughObservedAt,
    acceptedThroughEventKey,
    sourceCursors: raw.sourceCursors && typeof raw.sourceCursors === "object" ? raw.sourceCursors : null,
    counts: raw.counts && typeof raw.counts === "object" ? raw.counts : null
  };
}

function writeEventIngestionCursor(ack, exportedEvents = {}) {
  if (!ack) return { applied: false, skipped: true, reason: "No event ingestion ack" };
  const current = eventIngestionCursor();
  const currentTimestamp = parseTimestamp(current && current.acceptedThroughObservedAt);
  const nextTimestamp = parseTimestamp(ack.acceptedThroughObservedAt);
  if (currentTimestamp !== null && nextTimestamp !== null && nextTimestamp < currentTimestamp) {
    return {
      applied: false,
      conflict: true,
      reason: "stale_event_ingestion_ack",
      cursor: current
    };
  }

  const now = new Date().toISOString();
  const cursor = {
    ok: true,
    kind: "autopoiesis_frame_event_ingestion_cursor",
    schemaVersion: 1,
    redacted: true,
    status: ack.status || "accepted",
    updatedAt: now,
    acceptedAt: ack.acceptedAt || now,
    acceptedThroughObservedAt: ack.acceptedThroughObservedAt || null,
    acceptedThroughEventKey: ack.acceptedThroughEventKey || null,
    replaySince: eventCursorReplaySince(ack),
    sourceCursors: ack.sourceCursors || null,
    counts: ack.counts || null,
    lastExport: {
      generatedAt: exportedEvents.generatedAt || null,
      exported: exportedEvents.counts ? exportedEvents.counts.exported || 0 : 0,
      cursor: exportedEvents.cursor || null
    }
  };
  writeJson(paths.eventCursor, cursor);
  return { applied: true, cursor };
}

function eventIngestionSummary() {
  const cursor = eventIngestionCursor();
  if (!cursor) {
    return {
      status: "not_acknowledged",
      acceptedThroughObservedAt: null,
      acceptedThroughEventKey: null,
      replaySince: null,
      updatedAt: null
    };
  }
  return {
    status: cursor.status || "unknown",
    acceptedAt: cursor.acceptedAt || null,
    acceptedThroughObservedAt: cursor.acceptedThroughObservedAt || null,
    acceptedThroughEventKey: cursor.acceptedThroughEventKey || null,
    replaySince: eventCursorReplaySince(cursor),
    updatedAt: cursor.updatedAt || null,
    lastExported: cursor.lastExport ? cursor.lastExport.exported || 0 : 0
  };
}

function normalizeSettings(settings = {}) {
  if (!settings || typeof settings !== "object") return {};
  const normalized = { ...settings };
  if (!normalized.updatedAt && normalized.updated_at) normalized.updatedAt = normalized.updated_at;
  delete normalized.updated_at;
  return normalized;
}

// Merge owner-level preferences into local preferences.
// Only OWNER_CASCADE_FIELDS are applied; device-level prefs are preserved.
// Returns { preferences, cascadedFields[], applied: boolean }.
function applyOwnerCascade(localPrefs = {}, ownerPrefs = {}) {
  if (!ownerPrefs || typeof ownerPrefs !== "object") return { preferences: localPrefs, cascadedFields: [], applied: false };
  const cascadedFields = [];
  const merged = { ...localPrefs };
  for (const field of OWNER_CASCADE_FIELDS) {
    if (ownerPrefs[field] !== undefined) {
      merged[field] = ownerPrefs[field];
      cascadedFields.push(field);
    }
  }
  return { preferences: merged, cascadedFields, applied: cascadedFields.length > 0 };
}

function settingsUpdatedAt(settings = {}, fallback = null) {
  return timestampString(settings.updatedAt || settings.updated_at || settings.modifiedAt || settings.modified_at || fallback);
}

function writeSettingsSyncStatus(patch) {
  const device = readJson(paths.device, {});
  const syncedAt =
    patch.syncedAt ||
    (!patch.conflict && patch.status !== "local_changed" ? patch.checkedAt : device.lastSettingsSyncAt || null);
  writeJson(paths.device, {
    ...device,
    lastSettingsSyncAt: syncedAt,
    lastSettingsConflictAt: patch.conflict ? patch.checkedAt || new Date().toISOString() : device.lastSettingsConflictAt || null,
    settingsUpdatedAt: patch.localUpdatedAt || patch.remoteUpdatedAt || device.settingsUpdatedAt || null,
    settingsSync: {
      ...(device.settingsSync || {}),
      ...patch
    }
  });
}


function applyRemoteSettingsPayload(result = {}, source = "settings_sync") {
  const remoteSettings = normalizeSettings(result.settings || result.preferences || {});
  const ownerPrefs = result.ownerPreferences || result.owner_preferences || null;
  if (!Object.keys(remoteSettings).length && !ownerPrefs) return { applied: false, skipped: true, reason: "No settings in response" };

  const now = new Date().toISOString();
  const initialPreferences = readJson(paths.preferences, {});
  const preferences = readJson(paths.preferences, {});
  const device = readJson(paths.device, {});
  const remoteUpdatedAt = settingsUpdatedAt(remoteSettings, result.updatedAt || result.settingsUpdatedAt || result.settings_updated_at);
  const localUpdatedAt = settingsUpdatedAt(
    preferences,
    device.settingsUpdatedAt || (device.settingsSync || {}).localUpdatedAt || (device.settingsSync || {}).remoteUpdatedAt
  );

  // Function to check if we should trigger feed sync and do it if needed
  const maybeTriggerFeedSync = () => {
    const currentPreferences = readJson(paths.preferences, {});
    if (settingsAffectFeedEligibility(currentPreferences, initialPreferences)) {
      // Check if device is ready for feed sync
      if (device.deviceId && device.paired) {
        try {
          // Trigger feed sync but don't wait for it to avoid blocking settings response
          syncFeedFromRemote().then(syncResult => {
            // Log the result for debugging but don't let it affect settings response
            if (!syncResult.ok) {
              appendLog("settings-sync", `Feed sync triggered after settings change failed: ${syncResult.error || syncResult.reason}`);
            } else {
              appendLog("settings-sync", "Feed sync triggered after settings change");
            }
          }).catch(err => {
            appendLog("settings-sync", `Feed sync triggered after settings change threw error: ${err.message}`);
          });
          return { feedSyncTriggered: true };
        } catch (err) {
          appendLog("settings-sync", `Error triggering feed sync: ${err.message}`);
          return { feedSyncTriggered: false, feedSyncError: err.message };
        }
      }
    }
    return { feedSyncTriggered: false };
  };

  if (remoteUpdatedAt && localUpdatedAt && parseTimestamp(remoteUpdatedAt) < parseTimestamp(localUpdatedAt)) {
    // Remote device settings are stale, but owner preferences still cascade.
    // Owner cascade always applies — it reflects owner intent, not device state.
    if (ownerPrefs) {
      const cascade = applyOwnerCascade(preferences, ownerPrefs);
      if (cascade.applied) {
        writeJson(paths.preferences, { ...cascade.preferences, updatedAt: preferences.updatedAt });
        const cascadeDevice = readJson(paths.device, {});
        writeJson(paths.device, {
          ...cascadeDevice,
          ownerCascadeFields: cascade.cascadedFields,
          ownerCascadeAt: now,
          settingsSync: {
            ...(cascadeDevice.settingsSync || {}),
            status: "local_newer_owner_cascaded",
            source,
            conflict: true,
            reason: "remote_settings_stale_owner_cascade_applied",
            localUpdatedAt,
            remoteUpdatedAt,
            ownerCascadeFields: cascade.cascadedFields,
            checkedAt: now
          }
        });
      }
    }
    if (!ownerPrefs) {
      writeSettingsSyncStatus({
        status: "local_newer",
        source,
        conflict: true,
        reason: "remote_settings_stale",
        localUpdatedAt,
        remoteUpdatedAt,
        checkedAt: now
      });
    }
    const feedSyncInfo = maybeTriggerFeedSync();
    return {
      applied: false,
      conflict: true,
      reason: "remote_settings_stale",
      localUpdatedAt,
      remoteUpdatedAt,
      ownerCascadeApplied: Boolean(ownerPrefs),
      ...feedSyncInfo
    };
  }

  // Owner-only path: no remote settings, just owner cascade
  if (!Object.keys(remoteSettings).length && ownerPrefs) {
    const cascade = applyOwnerCascade(preferences, ownerPrefs);
    if (cascade.applied) {
      writeJson(paths.preferences, { ...cascade.preferences, updatedAt: preferences.updatedAt });
      const cascadeDevice = readJson(paths.device, {});
      writeJson(paths.device, {
        ...cascadeDevice,
        ownerCascadeFields: cascade.cascadedFields,
        ownerCascadeAt: now
      });
      writeSettingsSyncStatus({
        status: "owner_cascade_only",
        source,
        conflict: false,
        localUpdatedAt: settingsUpdatedAt(preferences),
        remoteUpdatedAt: null,
        ownerCascadeFields: cascade.cascadedFields,
        checkedAt: now
      });
    }
    const feedSyncInfo = maybeTriggerFeedSync();
    return {
      applied: cascade.applied,
      conflict: false,
      localUpdatedAt: settingsUpdatedAt(preferences),
      remoteUpdatedAt: null,
      ownerCascadeApplied: cascade.applied,
      ownerCascadeFields: cascade.cascadedFields,
      ...feedSyncInfo
    };
  }

  const appliedUpdatedAt = remoteUpdatedAt || now;
  let mergedPrefs = { ...preferences, ...remoteSettings, updatedAt: appliedUpdatedAt };
  let cascadeResult = null;

  // Apply owner cascade on top of merged settings
  if (ownerPrefs) {
    cascadeResult = applyOwnerCascade(mergedPrefs, ownerPrefs);
    if (cascadeResult.applied) {
      mergedPrefs = cascadeResult.preferences;
    }
  }

  writeJson(paths.preferences, mergedPrefs);
  writeSettingsSyncStatus({
    status: remoteUpdatedAt ? "remote_applied" : "remote_applied_untimestamped",
    source,
    conflict: false,
    localUpdatedAt: appliedUpdatedAt,
    remoteUpdatedAt,
    checkedAt: now
  });

  // Track cascade fields on device
  if (cascadeResult && cascadeResult.applied) {
    const cascadeDevice = readJson(paths.device, {});
    writeJson(paths.device, {
      ...cascadeDevice,
      ownerCascadeFields: cascadeResult.cascadedFields,
      ownerCascadeAt: now
    });
  }

  const feedSyncInfo = maybeTriggerFeedSync();
  return {
    applied: true,
    conflict: false,
    localUpdatedAt: appliedUpdatedAt,
    remoteUpdatedAt,
    ownerCascadeApplied: cascadeResult ? cascadeResult.applied : false,
    ownerCascadeFields: cascadeResult ? cascadeResult.cascadedFields : [],
    ...feedSyncInfo
  };
}
function feedItemTargetAllowed(item = {}, device = readJson(paths.device, {})) {
  const targeting = item.visibility || (item.raw || {}).targeting || (item.raw || {}).visibility || null;
  if (!targeting) return true;

  if (typeof targeting === "string") {
    const value = targeting.trim().toLowerCase();
    if (!value || ["all", "everyone", "public", "fleet", "active_subscribers", "subscribers"].includes(value)) return true;
    return true;
  }

  if (Array.isArray(targeting)) {
    const scopedTargets = targeting.filter(target => target && typeof target === "object");
    if (!scopedTargets.length) return true;
    return scopedTargets.some(target => feedItemTargetAllowed({ ...item, visibility: target }, device));
  }

  if (typeof targeting !== "object") return true;

  const excluded = [
    ["deviceIds", [targeting.excludeDeviceIds, targeting.excludedDeviceIds, targeting.blockedDeviceIds], [device.deviceId, device.id]],
    ["userIds", [targeting.excludeUserIds, targeting.excludedUserIds, targeting.blockedUserIds], [device.ownerUserId, device.userId]]
  ];
  for (const [, values, candidates] of excluded) {
    if (targetMatches(values, candidates)) return false;
  }

  const explicitTargetType = targeting.type || targeting.targetType || targeting.scope || targeting.kind;
  if (explicitTargetType) {
    return targetedByType(
      explicitTargetType,
      targeting.value || targeting.targetValue || targeting.values || targeting.ids || targeting.id,
      device
    );
  }

  const allowChecks = [
    { values: [targeting.deviceId, targeting.deviceIds, targeting.devices, targeting.targetDeviceIds], candidates: [device.deviceId, device.id] },
    { values: [targeting.userId, targeting.userIds, targeting.ownerUserId, targeting.ownerUserIds, targeting.users, targeting.owners, targeting.targetUserIds], candidates: [device.ownerUserId, device.userId] },
    { values: [targeting.subscriptionStatus, targeting.subscriptionStatuses, targeting.subscriberStatus, targeting.subscriberStatuses], candidates: [device.subscriptionStatus, device.subscriberStatus] },
    { values: [targeting.subscriptionTier, targeting.subscriptionTiers, targeting.tier, targeting.tiers], candidates: [device.subscriptionTier, device.tier, device.plan] },
    { values: [targeting.region, targeting.regions, targeting.country, targeting.countries], candidates: [device.region, device.country, device.locale] }
  ];
  const explicitAllowChecks = allowChecks.filter(check => normalizedTargetValues(check.values).length > 0);
  if (!explicitAllowChecks.length) return true;
  return explicitAllowChecks.some(check => targetMatches(check.values, check.candidates));
}

function itemIdentityCandidates(item = {}) {
  const raw = item.raw || {};
  return [
    item.artistId,
    item.artist_id,
    item.agentId,
    item.agent_id,
    item.artist,
    raw.artistId,
    raw.artist_id,
    raw.agentId,
    raw.agent_id,
    raw.artist,
    raw.artistName,
    raw.artist_name
  ].filter(Boolean).map(value => String(value).toLowerCase());
}

function feedItemArtistAllowed(item, preferences = {}) {
  const selectedArtists = normalizedList(preferences.activeArtists);
  if (!selectedArtists.length) return true;
  const candidates = itemIdentityCandidates(item);
  return selectedArtists.some(selected =>
    candidates.includes(selected) ||
    candidates.some(candidate => candidate.includes(selected) || selected.includes(candidate))
  );
}

function feedItemStreamAllowed(item, preferences = {}) {
  const selectedStreams = normalizedList(preferences.streamCategories || preferences.activeStreams || preferences.streams);
  if (!selectedStreams.length || selectedStreams.includes("all") || selectedStreams.includes("living-stream")) return true;
  const category = feedItemCategory(item);
  const type = String(item.type || "").toLowerCase();
  const source = String(item.source || "").toLowerCase();
  return selectedStreams.includes(category) || selectedStreams.includes(type) || selectedStreams.includes(source);
}

function feedCategoryCounts(items = []) {
  return items.reduce((counts, item) => {
    const category = feedItemCategory(item);
    counts[category] = (counts[category] || 0) + 1;
    return counts;
  }, {});
}

function normalizeFeedItem(raw, source, index = 0) {
  if (!raw || typeof raw !== "object") return null;
  const id = raw.id || raw.feedItemId || raw.feed_item_id || raw.artworkId || raw.broadcastId || raw.broadcast_id;
  if (!id) return null;
  const effectiveSource = raw.source || source;
  const type = raw.type || (effectiveSource === "broadcast" ? "broadcast_message" : "artwork_image");
  return {
    id: String(id),
    source: effectiveSource,
    type,
    title: raw.title || raw.name || null,
    artist: raw.artist || raw.artistName || raw.artist_name || null,
    artistId: raw.artistId || raw.artist_id || raw.agentId || raw.agent_id || null,
    body: raw.body || raw.description || raw.message || null,
    url: raw.url || raw.href || null,
    infoUrl: raw.infoUrl || raw.info_url || raw.artworkUrl || raw.artwork_url || raw.url || raw.href || null,
    dashboardUrl: raw.dashboardUrl || raw.dashboard_url || null,
    exhibitionUrl: raw.exhibitionUrl || raw.exhibition_url || null,
    blogUrl: raw.blogUrl || raw.blog_url || null,
    likeUrl: raw.likeUrl || raw.like_url || null,
    mediaUrl: raw.mediaUrl || raw.media_url || raw.imageUrl || raw.videoUrl || raw.audioUrl || null,
    thumbnailUrl: raw.thumbnailUrl || raw.thumbnail_url || null,
    duration: Number(raw.duration || raw.durationSeconds || raw.duration_seconds || 0) || null,
    soundRequired: Boolean(raw.soundRequired || raw.sound_required),
    cacheAllowed: raw.cacheAllowed !== false && raw.cache_allowed !== false,
    priority: String(raw.priority || "normal").toLowerCase(),
    visibility: raw.visibility || raw.targeting || null,
    createdAt: raw.createdAt || raw.created_at || null,
    startsAt: raw.startsAt || raw.starts_at || raw.scheduledAt || raw.scheduled_at || null,
    expiresAt: raw.expiresAt || raw.expires_at || null,
    dismissible: raw.dismissible !== false,
    order: Number(raw.order || raw.position || index) || index,
    raw
  };
}

function arrayValue(value) {
  if (Array.isArray(value)) return value;
  if (value && Array.isArray(value.items)) return value.items;
  return [];
}

function numberOrNull(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function pollingSeconds(...values) {
  for (const value of values) {
    const number = numberOrNull(value);
    if (number === null || number <= 0) continue;
    return Math.round(Math.min(Math.max(number, 5), 86400));
  }
  return null;
}

function normalizePollingPayload(payload = {}) {
  const stream = payload.stream && typeof payload.stream === "object" ? payload.stream : {};
  const polling = payload.polling || payload.poll || payload.refresh || stream.polling || stream.poll || stream.refresh || {};
  const pollAfterSeconds = pollingSeconds(
    payload.pollAfterSeconds,
    payload.poll_after_seconds,
    payload.refreshAfterSeconds,
    payload.refresh_after_seconds,
    stream.pollAfterSeconds,
    stream.poll_after_seconds,
    stream.refreshAfterSeconds,
    stream.refresh_after_seconds,
    stream.pollIntervalSeconds,
    stream.poll_interval_seconds,
    polling.pollAfterSeconds,
    polling.poll_after_seconds,
    polling.refreshAfterSeconds,
    polling.refresh_after_seconds,
    polling.intervalSeconds,
    polling.interval_seconds,
    polling.seconds,
    polling.ms ? Number(polling.ms) / 1000 : null,
    polling.intervalMs ? Number(polling.intervalMs) / 1000 : null,
    polling.interval_ms ? Number(polling.interval_ms) / 1000 : null
  );
  const minPollSeconds = pollingSeconds(
    polling.minPollSeconds,
    polling.min_poll_seconds,
    polling.minSeconds,
    polling.min_seconds,
    stream.minPollSeconds,
    stream.min_poll_seconds
  );
  const maxPollSeconds = pollingSeconds(
    polling.maxPollSeconds,
    polling.max_poll_seconds,
    polling.maxSeconds,
    polling.max_seconds,
    stream.maxPollSeconds,
    stream.max_poll_seconds
  );
  const nextPollAt = [
    payload.nextPollAt,
    payload.next_poll_at,
    stream.nextPollAt,
    stream.next_poll_at,
    polling.nextPollAt,
    polling.next_poll_at,
    polling.at
  ].find(value => parseTimestamp(value) !== null) || null;
  const staleAfter = [
    payload.staleAfter,
    payload.stale_after,
    stream.staleAfter,
    stream.stale_after,
    polling.staleAfter,
    polling.stale_after
  ].find(value => parseTimestamp(value) !== null) || null;
  const reason = typeof polling.reason === "string" && polling.reason.trim() ? polling.reason.trim().slice(0, 80) : null;

  if (!pollAfterSeconds && !minPollSeconds && !maxPollSeconds && !nextPollAt && !staleAfter && !reason) return null;
  return {
    pollAfterSeconds,
    minPollSeconds,
    maxPollSeconds,
    nextPollAt,
    staleAfter,
    reason
  };
}

function isoFromMs(value) {
  return Number.isFinite(value) ? new Date(value).toISOString() : null;
function settingsAffectFeedEligibility(newPrefs, oldPrefs) {
  if (!newPrefs && !oldPrefs) return false;
  if (!newPrefs) return !!oldPrefs;
  if (!oldPrefs) return !!newPrefs;
  const feedAffectingFields = [
    "streamCategories",
    "activeArtists",
    "allowImages",
    "allowVideos",
    "allowSoundWorks",
    "allowGenerativeWorks"
  ];
  for (const field of feedAffectingFields) {
    const newVal = newPrefs[field];
    const oldVal = oldPrefs[field];
    if (Array.isArray(newVal) && Array.isArray(oldVal)) {
      if (JSON.stringify(newVal.sort()) !== JSON.stringify(oldVal.sort())) {
        return true;
      }
    } else if (newVal !== oldVal) {
      return true;
    }
  }
  return false;
}
}

function feedPollingSummary(feed = readJson(paths.feed, { syncedAt: null, items: [] }), device = readJson(paths.device, {}), now = Date.now()) {
  const polling = feed && feed.polling && typeof feed.polling === "object" ? feed.polling : null;
  const syncedAtMs = parseTimestamp(feed ? feed.syncedAt : null);
  const lastPollAt = device.lastFeedPollAt || null;
  const lastStatus = device.lastFeedPollStatus || null;
  const lastError = device.lastFeedPollError || null;

  if (syncedAtMs === null) {
    return {
      status: "waiting_for_initial_sync",
      due: true,
      stale: false,
      reason: "no_feed_sync",
      syncedAt: feed ? feed.syncedAt || null : null,
      lastPollAt,
      lastStatus,
      lastError
    };
  }

  if (!polling) {
    return {
      status: "polling_unset",
      due: false,
      stale: false,
      reason: "no_polling_policy",
      syncedAt: feed.syncedAt || null,
      ageSeconds: Math.max(0, Math.round((now - syncedAtMs) / 1000)),
      lastPollAt,
      lastStatus,
      lastError
    };
  }

  const pollAfterSeconds = numberOrNull(polling.pollAfterSeconds);
  const minPollSeconds = numberOrNull(polling.minPollSeconds);
  const maxPollSeconds = numberOrNull(polling.maxPollSeconds);
  const explicitNextPollMs = parseTimestamp(polling.nextPollAt);
  const staleAfterMs = parseTimestamp(polling.staleAfter);
  const pollAfterDueMs = pollAfterSeconds && pollAfterSeconds > 0 ? syncedAtMs + pollAfterSeconds * 1000 : null;
  const maxPollDueMs = maxPollSeconds && maxPollSeconds > 0 ? syncedAtMs + maxPollSeconds * 1000 : null;
  const minPollDueMs = minPollSeconds && minPollSeconds > 0 ? syncedAtMs + minPollSeconds * 1000 : null;
  const dueCandidates = [explicitNextPollMs, pollAfterDueMs, maxPollDueMs].filter(Number.isFinite);
  const naturalDueMs = dueCandidates.length ? Math.min(...dueCandidates) : null;
  const dueAtMs = naturalDueMs !== null && minPollDueMs !== null ? Math.max(naturalDueMs, minPollDueMs) : naturalDueMs;
  const stale = staleAfterMs !== null && staleAfterMs <= now;
  const due = stale || (dueAtMs !== null && dueAtMs <= now);
  const waitingForMinimum = !due && minPollDueMs !== null && minPollDueMs > now && naturalDueMs !== null && naturalDueMs < minPollDueMs;
  const statusValue = stale
    ? "stale"
    : due
      ? "due"
      : waitingForMinimum
        ? "waiting_min_poll_interval"
        : "fresh";

  return {
    status: statusValue,
    due,
    stale,
    reason: polling.reason || (stale ? "stale_after_elapsed" : due ? "poll_due" : "poll_not_due"),
    syncedAt: feed.syncedAt || null,
    ageSeconds: Math.max(0, Math.round((now - syncedAtMs) / 1000)),
    pollAfterSeconds: pollAfterSeconds || null,
    minPollSeconds: minPollSeconds || null,
    maxPollSeconds: maxPollSeconds || null,
    nextPollAt: polling.nextPollAt || null,
    staleAfter: polling.staleAfter || null,
    dueAt: isoFromMs(dueAtMs),
    minimumPollAt: isoFromMs(minPollDueMs),
    lastPollAt,
    lastStatus,
    lastError
  };
}

function normalizeFeedPayload(payload = {}) {
  const now = new Date().toISOString();
  const feedItems = arrayValue(payload.feed || payload.items || payload.artworks);
  const broadcastItems = arrayValue(payload.broadcasts);
  const items = [
    ...feedItems.map((item, index) => normalizeFeedItem(item, "feed", index)),
    ...broadcastItems.map((item, index) => normalizeFeedItem(item, "broadcast", index))
  ].filter(Boolean);
  return {
    syncedAt: now,
    source: payload.source || "remote",
    polling: normalizePollingPayload(payload),
    items
  };
}

function eligibleFeedItems(feed = readJson(paths.feed, {}), preferences = readJson(paths.preferences, {})) {
  const now = Date.now();
  const device = readJson(paths.device, {});
  return (feed.items || [])
    .filter(item => !isExpired(item.expiresAt, now))
    .filter(item => {
      const startsAt = parseTimestamp(item.startsAt);
      return startsAt === null || startsAt <= now;
    })
    .filter(item => feedItemTargetAllowed(item, device))
    .filter(item => feedItemTypeAllowed(item, preferences))
    .filter(item => feedItemArtistAllowed(item, preferences))
    .filter(item => feedItemStreamAllowed(item, preferences))
    .sort((a, b) => {
      const priorityDelta = priorityRank(b.priority) - priorityRank(a.priority);
      if (priorityDelta !== 0) return priorityDelta;
      const createdDelta = (parseTimestamp(b.createdAt) || 0) - (parseTimestamp(a.createdAt) || 0);
      if (createdDelta !== 0) return createdDelta;
      return (a.order || 0) - (b.order || 0);
    });
}

function mixedFeedQueue(feed = readJson(paths.feed, {}), preferences = readJson(paths.preferences, {}), limit = FEED_QUEUE_LIMIT) {
  const eligibleItems = eligibleFeedItems(feed, preferences);
  const queueLimit = safeLimit(limit, 100, 500);
  const categoryOrder = ["broadcast", "curatorial", "artwork", "blog", "news", "content"];
  const shownIds = new Set((feedCursor().shownItemIds || []).map(id => String(id)));
  const priorityGroups = new Map();

  for (const item of eligibleItems) {
    const rank = priorityRank(item.priority);
    if (!priorityGroups.has(rank)) priorityGroups.set(rank, []);
    priorityGroups.get(rank).push(item);
  }

  const queue = [];
  const ranks = Array.from(priorityGroups.keys()).sort((a, b) => b - a);
  for (const rank of ranks) {
    const items = priorityGroups.get(rank) || [];
    const fresh = items.filter(item => !shownIds.has(String(item.id)));
    const replay = items.filter(item => shownIds.has(String(item.id)));
    const ordered = [...fresh, ...replay];

    const buckets = new Map(categoryOrder.map(category => [category, []]));
    for (const item of ordered) {
      const category = feedItemCategory(item);
      if (!buckets.has(category)) buckets.set(category, []);
      buckets.get(category).push(item);
    }

    let added = true;
    while (added && queue.length < queueLimit) {
      added = false;
      for (const category of categoryOrder) {
        const bucket = buckets.get(category) || [];
        const next = bucket.shift();
        if (!next) continue;
        queue.push(next);
        added = true;
        if (queue.length >= queueLimit) break;
      }
    }
  }

  return queue.map((item, index) => ({
    ...item,
    displayCategory: feedItemCategory(item),
    displayPosition: index + 1
  }));
}

function writeFeedState(feed) {
  const prevFeed = readJson(paths.feed, { syncedAt: null, items: [] });
  const prevSyncedAt = prevFeed.syncedAt || null;
  const newSyncedAt = feed.syncedAt || null;
  writeJson(paths.feed, feed);
  if (newSyncedAt && newSyncedAt !== prevSyncedAt) {
    feedCursorReset(newSyncedAt);
  }
  const preferences = readJson(paths.preferences, {});
  const displayQueue = mixedFeedQueue(feed, preferences);
  const pollingStatus = feedPollingSummary(feed);
  const cacheItems = displayQueue
    .filter(item => item.cacheAllowed && (item.mediaUrl || item.thumbnailUrl))
    .map(item => ({
      id: item.id,
      source: item.source,
      type: item.type,
      displayCategory: item.displayCategory,
      displayPosition: item.displayPosition,
      mediaUrl: item.mediaUrl,
      thumbnailUrl: item.thumbnailUrl,
      priority: item.priority,
      expiresAt: item.expiresAt || null
    }));
  writeJson(paths.feedCache, {
    generatedAt: new Date().toISOString(),
    count: cacheItems.length,
    items: cacheItems
  });
  appendDeliveryEvent({
    eventType: "feed_synced",
    source: feed.source || "remote",
    totalItems: Array.isArray(feed.items) ? feed.items.length : 0,
    eligibleItems: displayQueue.length,
    cacheEligibleItems: cacheItems.length,
    categories: feedCategoryCounts(displayQueue),
    pollAfterSeconds: feed.polling ? feed.polling.pollAfterSeconds || null : null,
    nextPollAt: feed.polling ? feed.polling.nextPollAt || null : null,
    pollingStatus: pollingStatus.status,
    pollDueAt: pollingStatus.dueAt || null,
    staleAfter: pollingStatus.staleAfter || null,
    syncedAt: feed.syncedAt || null
  });
}

function publicFeed() {
  const feed = readJson(paths.feed, { syncedAt: null, items: [] });
  const preferences = readJson(paths.preferences, {});
  const items = eligibleFeedItems(feed, preferences).map(({ raw, visibility, ...item }) => item);
  const displayQueue = mixedFeedQueue(feed, preferences).map(({ raw, visibility, ...item }) => item);
  const cache = readJson(paths.feedCache, { generatedAt: null, count: 0, items: [] });
  const offlineState = (readJson(paths.state, {}).offline || {});
  return {
    ok: true,
    syncedAt: feed.syncedAt || null,
    source: feed.source || null,
    offline: Boolean(feed.offline),
    offlineState: offlineState.active ? { active: true, since: offlineState.since || null, cachedItemsUsed: offlineState.cachedItemsUsed || 0 } : { active: false },
    polling: feed.polling || null,
    pollingStatus: feedPollingSummary(feed),
    totalItems: (feed.items || []).length,
    eligibleItems: items.length,
    cacheEligibleItems: cache.count || 0,
    categories: feedCategoryCounts(items),
    displayQueueItems: displayQueue.length,
    displayCursor: feedCursorSummary(),
    displayQueue,
    items
  };
}

function cacheAssetUsable(asset) {
  return Boolean(
    asset &&
      ["cached", "downloaded"].includes(asset.status) &&
      asset.path &&
      fs.existsSync(asset.path)
  );
}

function cachedOfflineItems() {
  const feed = readJson(paths.feed, { syncedAt: null, items: [] });
  const preferences = readJson(paths.preferences, {});
  const feedById = new Map(eligibleFeedItems(feed, preferences).map(item => [String(item.id), item]));
  const cacheIndex = readJson(paths.cacheIndex, { generatedAt: null, cachedCount: 0, failedCount: 0, items: [] });
  const now = Date.now();
  return (cacheIndex.items || [])
    .filter(item => item && item.id && !isExpired(item.expiresAt, now))
    .filter(item => cacheAssetUsable(item.media) || cacheAssetUsable(item.thumbnail))
    .map((item, index) => {
      const feedItem = feedById.get(String(item.id)) || {};
      const mediaAvailable = cacheAssetUsable(item.media);
      const thumbnailAvailable = cacheAssetUsable(item.thumbnail);
      const cacheBase = "/local/cache/assets/" + encodeURIComponent(String(item.id));
      return {
        id: String(item.id),
        source: item.source || feedItem.source || null,
        type: item.type || feedItem.type || "cached_media",
        title: feedItem.title || null,
        artist: feedItem.artist || null,
        body: feedItem.body || null,
        priority: item.priority || feedItem.priority || "normal",
        expiresAt: item.expiresAt || feedItem.expiresAt || null,
        order: Number(feedItem.order || index) || index,
        media: mediaAvailable
          ? { available: true, url: cacheBase + "/media", status: item.media.status, bytes: item.media.bytes || 0 }
          : { available: false },
        thumbnail: thumbnailAvailable
          ? { available: true, url: cacheBase + "/thumbnail", status: item.thumbnail.status, bytes: item.thumbnail.bytes || 0 }
          : { available: false }
      };
    });
}

function publicOfflineCache() {
  const cacheIndex = readJson(paths.cacheIndex, { generatedAt: null, cachedCount: 0, failedCount: 0, items: [] });
  const items = cachedOfflineItems();
  return {
    ok: true,
    generatedAt: cacheIndex.generatedAt || null,
    indexedItems: Array.isArray(cacheIndex.items) ? cacheIndex.items.length : 0,
    cachedItems: cacheIndex.cachedCount || 0,
    failedItems: cacheIndex.failedCount || 0,
    playableItems: items.length,
    items
  };
}

function mediaRoleForUrl(item = {}, url = "") {
  if (!url) return null;
  const type = String(item.type || "").toLowerCase();
  if (type.includes("audio") || /\.(mp3|wav|ogg|m4a)(\?|$)/i.test(url)) return "audio";
  if (type.includes("video") || /\.(mp4|webm|mov)(\?|$)/i.test(url)) return "video";
  if (/\.(jpg|jpeg|png|gif|webp|svg|avif)(\?|$)/i.test(url)) return "image";
  return "image";
}

function frameItemDisplayMs(item = {}, preferences = {}) {
  const role = item.media ? item.media.role : mediaRoleForUrl(item, item.mediaUrl || item.thumbnailUrl || "");
  const duration = Number(item.duration || item.durationSeconds || 0);
  if ((role === "video" || role === "audio") && Number.isFinite(duration) && duration > 0) {
    return Math.round(Math.min(Math.max(duration, 2), 86400) * 1000);
  }
  const category = item.displayCategory || feedItemCategory(item);
  const categorySeconds = categoryDisplaySeconds(category, preferences);
  if (category === "broadcast" && categorySeconds === 0) {
    const broadcastMax = Number(preferences.broadcastMaxDuration) || BROADCAST_MAX_DISPLAY_SECONDS;
    return Math.round(Math.min(Math.max(broadcastMax, 10), 3600) * 1000);
  }
  if (categorySeconds === 0) return Math.round(60 * 1000);
  const imageSeconds = Number(preferences.imageDuration || preferences.staticDuration || 0);
  const fallbackSeconds = Number.isFinite(imageSeconds) && imageSeconds > 0
    ? Math.min(Math.max(imageSeconds, 5), 3600)
    : 0;
  const seconds = categorySeconds || fallbackSeconds || 60;
  return Math.round(seconds * 1000);
}

function publicFrameState() {
  const feed = readJson(paths.feed, { syncedAt: null, items: [] });
  const preferences = readJson(paths.preferences, {});
  const localState = readJson(paths.state, {});
  const likedArtworkIds = new Set((localState.likedArtworkIds || []).map(id => String(id)));
  const cacheItems = new Map(cachedOfflineItems().map(item => [String(item.id), item]));
  const displayQueue = mixedFeedQueue(feed, preferences).map(({ raw, ...item }) => item);
  const items = displayQueue.map(item => {
    const cached = cacheItems.get(String(item.id));
    const cachedMedia = cached && cached.media && cached.media.available ? cached.media : null;
    const cachedThumbnail = cached && cached.thumbnail && cached.thumbnail.available ? cached.thumbnail : null;
    const localAsset = cachedMedia || cachedThumbnail;
    const remoteUrl = item.mediaUrl || item.thumbnailUrl || null;
    const mediaUrl = localAsset ? localAsset.url : remoteUrl;
    const publicItem = {
      id: item.id,
      source: item.source || null,
      type: item.type || null,
      title: item.title || null,
      artist: item.artist || null,
      artistId: item.artistId || null,
      body: item.body || null,
      url: item.url || null,
      infoUrl: item.infoUrl || item.url || null,
      dashboardUrl: item.dashboardUrl || null,
      exhibitionUrl: item.exhibitionUrl || null,
      blogUrl: item.blogUrl || null,
      likeUrl: item.likeUrl || null,
      priority: item.priority || "normal",
      displayCategory: item.displayCategory || feedItemCategory(item),
      displayPosition: item.displayPosition || null,
      duration: item.duration || null,
      soundRequired: Boolean(item.soundRequired),
      expiresAt: item.expiresAt || null,
      liked: likedArtworkIds.has(String(item.id)),
      media: {
        url: mediaUrl,
        role: mediaRoleForUrl(item, mediaUrl),
        cached: Boolean(localAsset),
        source: localAsset ? "cache" : (remoteUrl ? "remote" : null)
      },
      displayMs: 0
    };
    publicItem.displayMs = frameItemDisplayMs(publicItem, preferences);
    return publicItem;
  });
  const playableItems = items.filter(item => item.media.url || item.title || item.body);
  const frame = {
    ok: true,
    kind: "autopoiesis_frame_state",
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    syncedAt: feed.syncedAt || null,
    pollingStatus: feedPollingSummary(feed),
    totalItems: Array.isArray(feed.items) ? feed.items.length : 0,
    displayQueueItems: displayQueue.length,
    playableItems: playableItems.length,
    cachedPlayableItems: playableItems.filter(item => item.media.cached).length,
    categories: feedCategoryCounts(displayQueue),
    categoryDisplay: {
      defaults: { ...CATEGORY_DISPLAY_SECONDS },
      overrides: preferences.categoryDurations || {},
      broadcastMaxSeconds: Number(preferences.broadcastMaxDuration) || BROADCAST_MAX_DISPLAY_SECONDS
    },
    displayCursor: feedCursorSummary(),
    items: playableItems
  };
  frame.playback = framePlaybackSummary(frame);
  return frame;
}

function recordFrameItemDisplay(body = {}) {
  const itemId = body.itemId || body.id;
  if (!itemId) return { ok: false, error: "Missing frame item id" };
  const item = publicFrameState().items.find(candidate => String(candidate.id) === String(itemId));
  if (!item) return { ok: false, error: "Frame item is not currently display eligible", itemId: String(itemId) };
  const observedAt = new Date().toISOString();
  const displayCategory = item.displayCategory || feedItemCategory(item);
  const eventType = displayCategory === "broadcast" ? "broadcast_shown" : "feed_item_shown";
  appendDeliveryEvent({
    eventType,
    itemId: item.id,
    source: item.source || "feed",
    type: item.type || null,
    title: item.title || null,
    priority: item.priority || "normal",
    displayCategory,
    displayPosition: item.displayPosition || null,
    mediaRole: item.media ? item.media.role || null : null,
    mediaCached: item.media ? Boolean(item.media.cached) : false,
    status: "shown",
    observedAt
  });
  updateState({
    currentMode: "frame",
    currentFeedItemId: item.id,
    currentArtworkId: item.displayCategory === "artwork" ? item.id : null,
    lastFrameItemShownAt: observedAt
  });
  feedCursorMarkShown(item.id);
  return {
    ok: true,
    itemId: item.id,
    eventType,
    displayCategory,
    displayPosition: item.displayPosition || null,
    observedAt
  };
}

async function likeFrameItem(body = {}) {
  const itemId = body.itemId || body.id;
  if (!itemId) return { ok: false, error: "Missing frame item id" };
  const item = publicFrameState().items.find(candidate => String(candidate.id) === String(itemId));
  if (!item) return { ok: false, error: "Frame item is not currently display eligible", itemId: String(itemId) };

  const observedAt = new Date().toISOString();
  const stateValue = readJson(paths.state, {});
  const likedArtworkIds = Array.from(new Set([...(stateValue.likedArtworkIds || []).map(id => String(id)), String(item.id)]));
  writeJson(paths.state, {
    ...stateValue,
    likedArtworkIds,
    lastLikedArtworkId: item.id,
    lastLikedAt: observedAt
  });

  appendDeliveryEvent({
    eventType: "feed_item_liked",
    itemId: item.id,
    source: item.source || "feed",
    type: item.type || null,
    title: item.title || null,
    displayCategory: item.displayCategory || null,
    mediaRole: item.media ? item.media.role || null : null,
    status: "liked",
    observedAt
  });

  let remote = { ok: false, skipped: true };
  const device = readJson(paths.device, {});
  if (device.deviceId && device.paired) {
    try {
      remote = await apiRequest("/frames/artworks/" + encodeURIComponent(String(item.id)) + "/like", {
        method: "POST",
        body: JSON.stringify({
          deviceId: device.deviceId,
          source: "autopoiesis-os",
          observedAt
        })
      });
    } catch (error) {
      remote = { ok: false, error: error.message };
    }
  }

  return {
    ok: true,
    itemId: item.id,
    liked: true,
    observedAt,
    remote
  };
}

function framePlaybackSummary(frame = {}, state = readJson(paths.state, {})) {
  const totalItems = Number(frame.totalItems || 0);
  const displayQueueItems = Number(frame.displayQueueItems || 0);
  const playableItems = Number(frame.playableItems || 0);
  const cachedPlayableItems = Number(frame.cachedPlayableItems || 0);
  let statusValue = "waiting_for_feed";
  let summary = "No local feed sync has completed yet.";

  if (playableItems > 0) {
    statusValue = cachedPlayableItems > 0 ? "ready_with_cache" : "ready_remote";
    summary = cachedPlayableItems > 0
      ? "The local frame queue has playable items and at least one cached asset."
      : "The local frame queue has playable items using remote media or text.";
  } else if (frame.syncedAt && displayQueueItems > 0) {
    statusValue = "no_playable_items";
    summary = "The local display queue exists, but no item has media, title, or body content to render.";
  } else if (frame.syncedAt || totalItems > 0) {
    statusValue = "empty_queue";
    summary = "Feed data exists, but no item is currently eligible for local frame playback.";
  }

  const firstItem = Array.isArray(frame.items) && frame.items.length
    ? {
        id: frame.items[0].id || null,
        type: frame.items[0].type || null,
        displayCategory: frame.items[0].displayCategory || null,
        mediaRole: frame.items[0].media ? frame.items[0].media.role || null : null,
        cached: frame.items[0].media ? Boolean(frame.items[0].media.cached) : false
      }
    : null;

  return {
    ready: playableItems > 0,
    status: statusValue,
    summary,
    syncedAt: frame.syncedAt || null,
    totalItems,
    displayQueueItems,
    playableItems,
    cachedPlayableItems,
    categories: frame.categories || {},
    firstItem,
    localFrameActive: Boolean(state.localFrameActive),
    lastLocalFrameAt: state.lastLocalFrameAt || null
  };
}

function cachedAssetPath(id, role) {
  const cacheIndex = readJson(paths.cacheIndex, { items: [] });
  const item = (cacheIndex.items || []).find(candidate => String(candidate.id) === String(id));
  const asset = item && (role === "thumbnail" ? item.thumbnail : item.media);
  if (!cacheAssetUsable(asset)) return null;
  const root = path.resolve(CACHE_DIR);
  const assetPath = path.resolve(asset.path);
  if (assetPath !== root && !assetPath.startsWith(root + path.sep)) return null;
  return assetPath;
}

function contentTypeForPath(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  return {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".gif": "image/gif",
    ".webp": "image/webp",
    ".svg": "image/svg+xml",
    ".mp4": "video/mp4",
    ".webm": "video/webm",
    ".mov": "video/quicktime",
    ".mp3": "audio/mpeg",
    ".wav": "audio/wav",
    ".ogg": "audio/ogg"
  }[ext] || "application/octet-stream";
}

function buildOfflineFeed() {
  const cachedItems = cachedOfflineItems();
  const preferences = readJson(paths.preferences, {});
  const now = new Date().toISOString();
  const items = cachedItems.map((cached, index) => ({
    id: cached.id,
    source: cached.source || "offline_cache",
    type: cached.type || "cached_media",
    title: cached.title || null,
    artist: cached.artist || null,
    body: cached.body || null,
    priority: cached.priority || "normal",
    expiresAt: cached.expiresAt || null,
    order: cached.order != null ? cached.order : index,
    cacheAllowed: true,
    displayCategory: "artwork",
    mediaUrl: cached.media && cached.media.available ? cached.media.url : null,
    thumbnailUrl: cached.thumbnail && cached.thumbnail.available ? cached.thumbnail.url : null,
    media: cached.media || { available: false },
    thumbnail: cached.thumbnail || { available: false }
  }));
  return {
    syncedAt: now,
    source: "offline_cache",
    polling: null,
    items,
    offline: true,
    offlineCachedItems: items.length
  };
}

function isOfflineEligibleError(error) {
  const msg = String(error.message || "").toLowerCase();
  const isNetwork = (
    error.name === "AbortError" ||
    msg.includes("econnrefused") ||
    msg.includes("enotfound") ||
    msg.includes("econnreset") ||
    msg.includes("etimedout") ||
    msg.includes("ehostunreach") ||
    msg.includes("enetunreach") ||
    msg.includes("fetch failed") ||
    msg.includes("network") ||
    msg.includes("timeout") ||
    msg.includes("aborted") ||
    error.code === "ECONNREFUSED" ||
    error.code === "ENOTFOUND" ||
    error.code === "ECONNRESET" ||
    error.code === "ETIMEDOUT" ||
    error.code === "EHOSTUNREACH" ||
    error.code === "ENETUNREACH"
  );
  if (isNetwork) return true;
  // HTTP-level errors that indicate server-side unavailability
  if (msg.includes("unavailable") || msg.includes("503") || msg.includes("502") || msg.includes("504")) return true;
  if (msg.startsWith("http 5") || /^http \d{3}$/.test(msg)) return true;
  // Connection refused at HTTP level
  if (msg.includes("service unavailable") || msg.includes("bad gateway") || msg.includes("gateway timeout")) return true;
  return false;
}

function writeOfflineState(patch) {
  const state = readJson(paths.state, {});
  state.offline = {
    ...(state.offline || {}),
    ...patch,
    updatedAt: new Date().toISOString()
  };
  writeJson(paths.state, state);
}

// ─── Cache Eviction ─────────────────────────────────────────────────────────

const CACHE_QUOTA_MB = Math.max(50, Number(process.env.AUTOPOIESIS_CACHE_QUOTA_MB || 500));
const CACHE_QUOTA_HIGH_WATER = 0.9; // Evict when cache exceeds 90% of quota
const CACHE_QUOTA_LOW_WATER = 0.7;  // Evict down to 70% of quota

/**
 * Returns cache quota information: total bytes used, quota in bytes, usage ratio,
 * and whether eviction is needed.
 */
function cacheQuotaStatus() {
  const stats = directoryStats(CACHE_DIR);
  const quotaBytes = CACHE_QUOTA_MB * 1024 * 1024;
  const usageRatio = stats.bytes / quotaBytes;
  return {
    usedBytes: stats.bytes,
    usedMb: stats.mb,
    quotaMb: CACHE_QUOTA_MB,
    quotaBytes,
    usageRatio: Math.round(usageRatio * 1000) / 1000,
    fileCount: stats.files,
    evictionNeeded: usageRatio > CACHE_QUOTA_HIGH_WATER,
    highWaterMark: CACHE_QUOTA_HIGH_WATER,
    lowWaterMark: CACHE_QUOTA_LOW_WATER
  };
}

/**
 * Ranks cache index items by eviction priority (first = evict first).
 * Items are evicted in this order:
 *   1. Expired items (oldest expiry first)
 *   2. Non-liked, non-recent items by cache age (oldest first)
 *   3. Recent but non-liked items by cache age
 *   4. Liked items (evicted last resort, oldest first)
 */
function cacheEvictionCandidates() {
  const cacheIndex = readJson(paths.cacheIndex, { items: [] });
  const items = (cacheIndex.items || []).filter(item => item && item.id);
  const state = readJson(paths.state, {});
  const likedIds = new Set((state.likedArtworkIds || []).map(id => String(id)));
  const now = Date.now();

  return items
    .map(item => {
      const isLiked = likedIds.has(String(item.id));
      const isExpired = item.expiresAt && new Date(item.expiresAt).getTime() < now;
      const mediaBytes = (item.media && item.media.bytes) || 0;
      const thumbBytes = (item.thumbnail && item.thumbnail.bytes) || 0;
      const totalBytes = mediaBytes + thumbBytes;
      const cachedAt = (item.media && item.media.cachedAt) || (item.thumbnail && item.thumbnail.cachedAt) || cacheIndex.generatedAt || "";
      // Priority: 0 = expired (evict first), 1 = non-liked non-recent, 2 = recent, 3 = liked
      let priority = 1;
      if (isExpired) priority = 0;
      else if (isLiked) priority = 3;
      return {
        id: String(item.id),
        isLiked,
        isExpired,
        totalBytes,
        cachedAt,
        evictionPriority: priority,
        media: item.media || null,
        thumbnail: item.thumbnail || null
      };
    })
    .sort((a, b) => {
      // Lower priority number = evict first
      if (a.evictionPriority !== b.evictionPriority) return a.evictionPriority - b.evictionPriority;
      // Within same priority, older items first
      return String(a.cachedAt).localeCompare(String(b.cachedAt));
    });
}

/**
 * Removes a single cached item's files from disk.
 * Returns the number of bytes freed.
 */
function removeCachedItemFiles(item) {
  let freedBytes = 0;
  for (const asset of [item.media, item.thumbnail]) {
    if (asset && asset.path && typeof asset.path === "string") {
      try {
        const resolved = path.resolve(asset.path);
        const cacheRoot = path.resolve(CACHE_DIR);
        if (resolved !== cacheRoot && resolved.startsWith(cacheRoot + path.sep)) {
          const stat = fs.statSync(resolved);
          fs.unlinkSync(resolved);
          freedBytes += stat.size;
        }
      } catch {
        // File already gone or inaccessible
      }
    }
  }
  return freedBytes;
}

/**
 * Enforces the cache quota by evicting items until usage drops below the
 * low-water mark. Returns a summary of what was evicted.
 */
function enforceCacheQuota() {
  const quota = cacheQuotaStatus();
  if (!quota.evictionNeeded) {
    return { ok: true, evictionNeeded: false, quota };
  }

  const targetBytes = quota.quotaBytes * CACHE_QUOTA_LOW_WATER;
  const candidates = cacheEvictionCandidates();
  const evictedItems = [];
  let freedBytes = 0;

  for (const candidate of candidates) {
    if (quota.usedBytes - freedBytes <= targetBytes) break;
    const bytesFreed = removeCachedItemFiles(candidate);
    if (bytesFreed > 0) {
      freedBytes += bytesFreed;
      evictedItems.push({
        id: candidate.id,
        isLiked: candidate.isLiked,
        isExpired: candidate.isExpired,
        bytesFreed
      });
    }
  }

  // Rebuild cache index without evicted items
  if (evictedItems.length > 0) {
    const cacheIndex = readJson(paths.cacheIndex, { items: [] });
    const evictedIds = new Set(evictedItems.map(e => e.id));
    const remainingItems = (cacheIndex.items || []).filter(item => !evictedIds.has(String(item.id)));
    const cachedCount = remainingItems.filter(item =>
      cacheAssetUsable(item.media) || cacheAssetUsable(item.thumbnail)
    ).length;
    const failedCount = remainingItems.filter(item =>
      (item.media && item.media.status === "failed") || (item.thumbnail && item.thumbnail.status === "failed")
    ).length;
    writeJson(paths.cacheIndex, {
      ...cacheIndex,
      generatedAt: new Date().toISOString(),
      cachedCount,
      failedCount,
      items: remainingItems
    });
  }

  const postQuota = cacheQuotaStatus();
  return {
    ok: true,
    evictionNeeded: true,
    evictedCount: evictedItems.length,
    freedBytes,
    freedMb: Math.round((freedBytes / 1024 / 1024) * 10) / 10,
    evictedLiked: evictedItems.filter(e => e.isLiked).length,
    evictedExpired: evictedItems.filter(e => e.isExpired).length,
    before: quota,
    after: postQuota
  };
}

async function syncFeedFromRemote() {
  const device = readJson(paths.device, {});
  if (!device.deviceId || !device.paired) return { ok: false, skipped: true, reason: "Device is not paired" };
  const preferences = readJson(paths.preferences, {});
  const encodedDeviceId = encodeURIComponent(device.deviceId);
  let result;
  let endpoint = "stream";
  let fallbackReason = null;
  let offline = false;
  try {
    result = await apiRequest("/frames/device/" + encodedDeviceId + "/stream");
  } catch (error) {
    endpoint = "feed";
    fallbackReason = error.message;
    try {
      result = await apiRequest("/frames/device/" + encodedDeviceId + "/feed");
    } catch (secondError) {
      fallbackReason = secondError.message;
      const cachedItems = cachedOfflineItems();
      if (isOfflineEligibleError(secondError) && cachedItems.length > 0) {
        const offlineFeed = buildOfflineFeed();
        writeFeedState(offlineFeed);
        writeOfflineState({
          active: true,
          reason: "hosted_api_unreachable",
          lastError: secondError.message,
          cachedItemsUsed: offlineFeed.items.length,
          since: new Date().toISOString()
        });
        writeJson(paths.device, { ...device, lastFeedSyncAt: offlineFeed.syncedAt });
        return {
          ok: true,
          endpoint: "offline_cache",
          offline: true,
          fallbackReason,
          syncedAt: offlineFeed.syncedAt,
          totalItems: offlineFeed.items.length,
          eligibleItems: offlineFeed.items.length
        };
      }
      writeOfflineState({
        active: cachedItems.length === 0,
        reason: "hosted_api_unreachable_no_cache",
        lastError: secondError.message,
        cachedItemsUsed: 0,
        since: new Date().toISOString()
      });
      return {
        ok: false,
        error: secondError.message,
        offline: true,
        cachedItemsAvailable: cachedItems.length
      };
    }
  }
  if (result.settings || result.preferences) applyRemoteSettingsPayload(result, "stream_sync");
  const feed = normalizeFeedPayload({ ...result, source: result.source || endpoint });
  writeFeedState(feed);
  const prevOffline = readJson(paths.state, {}).offline;
  if (prevOffline && prevOffline.active) {
    writeOfflineState({
      active: false,
      reason: "recovered",
      recoveredAt: new Date().toISOString(),
      lastError: null,
      cachedItemsUsed: 0
    });
  }
  writeJson(paths.device, { ...device, lastFeedSyncAt: feed.syncedAt });
  // Enforce cache quota after successful sync
  const evictionResult = enforceCacheQuota();
  return {
    ok: true,
    endpoint,
    fallbackReason,
    syncedAt: feed.syncedAt,
    pollingStatus: feedPollingSummary(feed),
    polling: feed.polling || null,
    totalItems: feed.items.length,
    eligibleItems: eligibleFeedItems(feed, preferences).length,
    cacheEviction: evictionResult.evictionNeeded ? evictionResult : undefined
  };
}

async function maybeSyncFeedForPolling(source = "heartbeat") {
  const device = readJson(paths.device, {});
  const feed = readJson(paths.feed, { syncedAt: null, items: [] });
  const pollingStatus = feedPollingSummary(feed, device);
  if (!pollingStatus.due) {
    return { ok: true, skipped: true, source, reason: pollingStatus.status, pollingStatus };
  }

  const startedAt = new Date().toISOString();
  writeJson(paths.device, {
    ...device,
    lastFeedPollAt: startedAt,
    lastFeedPollStatus: "started",
    lastFeedPollReason: pollingStatus.reason || pollingStatus.status,
    lastFeedPollError: null
  });

  try {
    const synced = await syncFeedFromRemote();
    const updatedDevice = readJson(paths.device, {});
    writeJson(paths.device, {
      ...updatedDevice,
      lastFeedPollAt: new Date().toISOString(),
      lastFeedPollStatus: synced.ok ? "synced" : "skipped",
      lastFeedPollReason: synced.reason || pollingStatus.reason || pollingStatus.status,
      lastFeedPollError: synced.error || null
    });
    return { ok: Boolean(synced.ok), skipped: Boolean(synced.skipped), source, reason: pollingStatus.reason || pollingStatus.status, pollingStatus, synced };
  } catch (error) {
    const updatedDevice = readJson(paths.device, {});
    writeJson(paths.device, {
      ...updatedDevice,
      lastFeedPollAt: new Date().toISOString(),
      lastFeedPollStatus: "error",
      lastFeedPollReason: pollingStatus.reason || pollingStatus.status,
      lastFeedPollError: error.message
    });
    return { ok: false, skipped: false, source, reason: pollingStatus.reason || pollingStatus.status, pollingStatus, error: error.message };
  }
}

function activeBroadcast(now = Date.now()) {
  const broadcast = readJson(paths.broadcast, null);
  if (!broadcast) return null;
  if (broadcast.dismissedAt) return null;
  if (!feedItemTargetAllowed(broadcast, readJson(paths.device, {}))) {
    updateState({ currentMode: "frame", currentBroadcastId: null, lastBroadcastSkippedAt: new Date().toISOString() });
    if (!broadcast.skippedEventAt) {
      const skippedAt = new Date().toISOString();
      appendDeliveryEvent({
        eventType: "broadcast_skipped",
        ...deliverySubject(broadcast),
        itemId: broadcastIdOf(broadcast),
        reason: "ineligible_target"
      });
      writeJson(paths.broadcast, { ...broadcast, skippedEventAt: skippedAt, skipReason: "ineligible_target" });
    }
    return null;
  }
  if (isExpired(broadcast.expiresAt, now)) {
    updateState({ currentMode: "frame", currentBroadcastId: null, lastBroadcastExpiredAt: new Date().toISOString() });
    if (!broadcast.expiredEventAt) {
      appendDeliveryEvent({
        eventType: "broadcast_expired",
        ...deliverySubject(broadcast),
        itemId: broadcast.broadcastId || broadcast.id || null
      });
      writeJson(paths.broadcast, { ...broadcast, expiredEventAt: new Date().toISOString() });
    }
    return null;
  }
  const startsAt = parseTimestamp(broadcast.startsAt);
  if (startsAt !== null && startsAt > now) return null;
  return broadcast;
}

function recordBroadcastShown(broadcast = {}) {
  if (!broadcast || broadcast.shownEventAt) return broadcast;
  const shownAt = new Date().toISOString();
  const broadcastId = broadcastIdOf(broadcast);
  const updated = {
    ...broadcast,
    broadcastId,
    shownAt: broadcast.shownAt || shownAt,
    shownEventAt: shownAt
  };
  writeJson(paths.broadcast, updated);
  appendDeliveryEvent({
    eventType: "broadcast_shown",
    ...deliverySubject(updated),
    itemId: broadcastId,
    commandId: updated.commandId || null
  });
  updateState({
    currentMode: "broadcast",
    currentBroadcastId: broadcastId,
    lastBroadcastShownAt: shownAt
  });
  return updated;
}

function dismissBroadcast(reason = "duration_elapsed") {
  const broadcast = readJson(paths.broadcast, null);
  updateState({
    currentMode: "frame",
    currentBroadcastId: null,
    lastBroadcastDismissedAt: new Date().toISOString(),
    lastBroadcastDismissReason: reason
  });
  if (broadcast) {
    writeJson(paths.broadcast, { ...broadcast, dismissedAt: new Date().toISOString(), dismissReason: reason });
    appendDeliveryEvent({
      eventType: "broadcast_dismissed",
      ...deliverySubject(broadcast),
      itemId: broadcast.broadcastId || broadcast.id || null,
      reason
    });
  }
  return { ok: true, broadcastId: broadcast ? broadcast.broadcastId || broadcast.id || null : null, reason };
}

function redactDevice(device) {
  const { deviceApiKey, device_api_key, ...publicDevice } = device || {};
  if (deviceApiKey || device_api_key) publicDevice.hasDeviceApiKey = true;
  return publicDevice;
}

function publicStatus() {
  const data = status();
  return { ...data, device: redactDevice(data.device) };
}

function readTemperatureC() {
  try {
    const raw = fs.readFileSync("/sys/class/thermal/thermal_zone0/temp", "utf8").trim();
    const value = Number(raw);
    return Number.isFinite(value) ? Math.round((value / 1000) * 10) / 10 : null;
  } catch {
    return null;
  }
}

function raspberryPiGeneration(modelText) {
  const model = String(modelText || "").toLowerCase();
  if (!model.includes("raspberry pi")) return null;
  if (/raspberry pi\s*5\b/.test(model)) return 5;
  if (/raspberry pi\s*4\b/.test(model) || /compute module\s*4\b/.test(model)) return 4;
  if (/raspberry pi\s*3\b/.test(model) || /compute module\s*3\b/.test(model)) return 3;
  if (/raspberry pi\s*2\b/.test(model)) return 2;
  if (/raspberry pi\s*(zero|1\b)/.test(model)) return 1;
  return 0;
}

function hardwareStatusFromProfile(profile) {
  const ramMb = profile.ramMb;
  if (profile.family === "raspberry_pi") {
    if (profile.piGeneration >= 5) {
      return {
        status: "recommended",
        supported: true,
        recommended: true,
        summary: "Raspberry Pi 5 class hardware is recommended for the Chromium kiosk appliance."
      };
    }
    if (profile.piGeneration === 4) {
      return {
        status: "supported_baseline",
        supported: true,
        recommended: false,
        summary: "Raspberry Pi 4 class hardware is the supported baseline for the Chromium kiosk appliance."
      };
    }
    if (profile.piGeneration > 0 && profile.piGeneration < 4) {
      return {
        status: "underpowered",
        supported: false,
        recommended: false,
        summary: "Raspberry Pi 3 and older boards are underpowered for the Chromium kiosk appliance."
      };
    }
    return {
      status: ramMb >= 2048 ? "unknown_pi_supported_ram" : "unknown_pi_low_ram",
      supported: ramMb >= 2048,
      recommended: false,
      summary:
        ramMb >= 2048
          ? "Unknown Raspberry Pi model has enough RAM for cautious validation."
          : "Unknown Raspberry Pi model has less than 2 GB RAM and may be underpowered."
    };
  }
  if (profile.arch === "x64" || profile.arch === "x86_64") {
    return {
      status: "development_host",
      supported: true,
      recommended: false,
      summary: "x86_64 hardware is suitable for development and mini-PC deployments, but is not the primary Pi appliance target."
    };
  }
  if (ramMb < 1024) {
    return {
      status: "low_ram",
      supported: false,
      recommended: false,
      summary: "Device has less than 1 GB RAM and is not suitable for the kiosk appliance."
    };
  }
  return {
    status: "unknown",
    supported: true,
    recommended: false,
    summary: "Hardware model is unknown; validate the kiosk manually before rollout."
  };
}

async function throttledStatus() {
  try {
    const { stdout } = await execFilePromise(VCGENCMD_BIN, ["get_throttled"], { timeout: 2000 });
    const match = stdout.match(/throttled=([^\s]+)/);
    if (!match) return { available: true, raw: stdout.trim(), throttled: null, underVoltage: null };
    const value = Number.parseInt(match[1], 16);
    if (!Number.isFinite(value)) return { available: true, raw: stdout.trim(), throttled: null, underVoltage: null };
    return {
      available: true,
      raw: stdout.trim(),
      valueHex: "0x" + value.toString(16),
      throttled: Boolean((value & 0x4) || (value & 0x40000)),
      underVoltage: Boolean((value & 0x1) || (value & 0x10000)),
      frequencyCapped: Boolean((value & 0x2) || (value & 0x20000)),
      softTemperatureLimit: Boolean((value & 0x8) || (value & 0x80000))
    };
  } catch (error) {
    return { available: false, error: error.code || error.message };
  }
}

async function hardwareProfileDiagnostics() {
  let model = null;
  try {
    model = fs.readFileSync(DEVICE_TREE_MODEL_PATH, "utf8").replace(/\0/g, "").trim() || null;
  } catch {
    model = null;
  }
  const ramMb = Math.round(os.totalmem() / 1024 / 1024);
  const arch = os.arch();
  const piGeneration = raspberryPiGeneration(model);
  const family = piGeneration === null ? (arch === "x64" ? "x86_64" : "unknown") : "raspberry_pi";
  const profile = {
    model,
    family,
    piGeneration,
    arch,
    platform: os.platform(),
    kernel: os.release(),
    ramMb,
    ramGbApprox: Math.round((ramMb / 1024) * 10) / 10,
    recommendedDevice: "Raspberry Pi 5, 4GB or 8GB",
    supportedBaseline: "Raspberry Pi 4, 4GB",
    underpoweredBelow: "Raspberry Pi 4 or 2GB RAM",
    throttling: await throttledStatus()
  };
  return {
    ...profile,
    ...hardwareStatusFromProfile(profile)
  };
}

function parseInputDevices(raw) {
  return String(raw || "")
    .split(/\n\s*\n/)
    .map(block => {
      const name = ((block.match(/^N:\s+Name="([^"]+)"/m) || [])[1] || "").trim();
      const handlers = ((block.match(/^H:\s+Handlers=(.*)$/m) || [])[1] || "").trim();
      const bus = ((block.match(/^I:\s+Bus=([^\s]+)/m) || [])[1] || "").trim();
      if (!name && !handlers) return null;
      const fingerprint = (name + " " + handlers).toLowerCase();
      const touchscreen = /touchscreen|\btouch\b|goodix|ads7846|edt[-_ ]?ft|ft5x|waveshare|raspberrypi[-_ ]?ts|ilitek/.test(fingerprint);
      const pointer = touchscreen || /\bmouse\d*\b|pointer|touchpad|trackpad/.test(fingerprint);
      const keyboard = /\bkbd\b|keyboard/.test(fingerprint);
      return {
        name: name || "unknown",
        handlers,
        bus: bus || null,
        eventHandlers: (handlers.match(/\bevent\d+\b/g) || []),
        touchscreen,
        pointer,
        keyboard
      };
    })
    .filter(Boolean);
}

function inputDiagnostics() {
  try {
    const raw = fs.readFileSync(INPUT_DEVICES_PATH, "utf8");
    const devices = parseInputDevices(raw);
    const touchscreenPresent = devices.some(device => device.touchscreen);
    const pointerPresent = devices.some(device => device.pointer);
    const keyboardPresent = devices.some(device => device.keyboard);
    return {
      ok: true,
      status: touchscreenPresent ? "touchscreen_ready" : pointerPresent ? "pointer_only" : "input_missing",
      source: INPUT_DEVICES_PATH,
      totalDevices: devices.length,
      touchscreenPresent,
      pointerPresent,
      keyboardPresent,
      devices: devices.slice(0, 20)
    };
  } catch (error) {
    return {
      ok: false,
      status: "unavailable",
      source: INPUT_DEVICES_PATH,
      error: error.message
    };
  }
}

function displayDiagnostics() {
  const display = process.env.DISPLAY || null;
  const waylandDisplay = process.env.WAYLAND_DISPLAY || null;
  const xdgSessionType = process.env.XDG_SESSION_TYPE || null;
  const displayServer = xdgSessionType === "wayland" ? "wayland" : xdgSessionType === "x11" ? "x11" : display ? "x11" : waylandDisplay ? "wayland" : "none";
  const result = {
    ok: true,
    status: display ? "display_ready" : "no_display_env",
    display,
    waylandDisplay,
    xdgSessionType,
    displayServer
  };

  // Check X11 socket
  if (display) {
    const displayNum = display.replace(/^:/, "").replace(/\..*$/, "");
    const xSocket = `/tmp/.X11-unix/X${displayNum}`;
    try {
      const stat = fs.statSync(xSocket);
    result.xSocket = xSocket;
      result.xSocketPresent = true;
    } catch {
      result.xSocket = xSocket;
      result.xSocketPresent = false;
      result.status = "x_socket_missing";
    }
  }

  // Check Wayland socket
  if (waylandDisplay && !display) {
    const runtimeDir = process.env.XDG_RUNTIME_DIR || `/run/user/${process.getuid()}`;
    const waylandSocket = `${runtimeDir}/${waylandDisplay}`;
    try {
      fs.statSync(waylandSocket);
      result.waylandSocket = waylandSocket;
      result.waylandSocketPresent = true;
      result.status = "display_ready";
    } catch {
      result.waylandSocket = waylandSocket;
      result.waylandSocketPresent = false;
      result.status = "wayland_socket_missing";
    }
  }

  // Check graphical.target default via symlink
  try {
    const defaultTarget = fs.readlinkSync("/etc/systemd/system/default.target");
    result.graphicalTarget = defaultTarget.includes("graphical.target");
    if (!result.graphicalTarget) {
      result.defaultTarget = defaultTarget;
    }
  } catch {
    result.graphicalTarget = null;
  }

  // Check auto-login configuration (lightdm)
  try {
    const lightdmConf = fs.readFileSync("/etc/lightdm/lightdm.conf", "utf8");
    const match = lightdmConf.match(/^autologin-user=(.+)$/m);
    result.lightdmAutologinUser = match ? match[1].trim() : null;
  } catch {
    result.lightdmAutologinUser = null;
  }

  // Check auto-login configuration (gdm3)
  try {
    const gdm3Conf = fs.readFileSync("/etc/gdm3/custom.conf", "utf8");
    const enabled = gdm3Conf.match(/^AutomaticLoginEnable=true$/m);
    const user = gdm3Conf.match(/^AutomaticLogin=(.+)$/m);
    result.gdm3Autologin = Boolean(enabled);
    result.gdm3AutologinUser = user ? user[1].trim() : null;
  } catch {
    result.gdm3Autologin = null;
  }

  // Check getty autologin override
  try {
    const gettyOverride = fs.readFileSync("/etc/systemd/system/getty@tty1.service.d/autologin.conf", "utf8");
    const autologinUser = gettyOverride.match(/autologin=(\S+)/);
    result.gettyAutologinUser = autologinUser ? autologinUser[1] : null;
  } catch {
    result.gettyAutologinUser = null;
  }

  // Check X11 screen blanking drop-in
  try {
    fs.statSync("/etc/X11/Xsession.d/99-autopoiesis-disable-blanking");
    result.screenBlankingDisabled = true;
  } catch {
    result.screenBlankingDisabled = false;
  }

  // Check unclutter
  try {
    const stat = fs.statSync("/usr/bin/unclutter");
    result.unclutterInstalled = true;
  } catch {
    result.unclutterInstalled = false;
  }

  // Overall kiosk readiness
  const hasAutologin = Boolean(result.lightdmAutologinUser || result.gdm3Autologin || result.gettyAutologinUser);
  const displayReady = result.status === "display_ready";
  result.kioskReadiness = {
    displayReady,
    graphicalTarget: result.graphicalTarget,
    autoLogin: hasAutologin,
    screenBlankingDisabled: result.screenBlankingDisabled,
    cursorHidden: result.unclutterInstalled
  };

  return result;
}

function parseSystemdBoolean(value) {
  if (value === true || value === false) return value;
  const normalized = String(value || "").trim().toLowerCase();
  if (["yes", "true", "1"].includes(normalized)) return true;
  if (["no", "false", "0"].includes(normalized)) return false;
  return null;
}

function parseTimedatectlShow(raw) {
  const values = {};
  for (const line of String(raw || "").split(/\r?\n/)) {
    const index = line.indexOf("=");
    if (index <= 0) continue;
    values[line.slice(0, index)] = line.slice(index + 1);
  }
  return values;
}

async function clockDiagnostics() {
  const collectedAt = new Date();
  const base = {
    ok: true,
    status: "unknown",
    source: TIMEDATECTL_BIN,
    systemTime: collectedAt.toISOString(),
    epochSeconds: Math.floor(collectedAt.getTime() / 1000),
    timezone: null,
    ntpEnabled: null,
    ntpSynchronized: null,
    systemClockSynchronized: null,
    localRtc: null
  };

  try {
    const { stdout } = await execFilePromise(
      TIMEDATECTL_BIN,
      [
        "show",
        "--property=Timezone",
        "--property=LocalRTC",
        "--property=NTP",
        "--property=NTPSynchronized",
        "--property=SystemClockSynchronized"
      ],
      { timeout: 2000 }
    );
    const values = parseTimedatectlShow(stdout);
    const systemClockSynchronized = parseSystemdBoolean(values.SystemClockSynchronized);
    const ntpSynchronized = parseSystemdBoolean(values.NTPSynchronized);
    const synchronized =
      systemClockSynchronized !== null
        ? systemClockSynchronized
        : ntpSynchronized !== null
          ? ntpSynchronized
          : null;
    return {
      ...base,
      ok: synchronized !== false,
      status: synchronized === true ? "synchronized" : synchronized === false ? "unsynchronized" : "unknown",
      timezone: values.Timezone || null,
      ntpEnabled: parseSystemdBoolean(values.NTP),
      ntpSynchronized,
      systemClockSynchronized,
      localRtc: parseSystemdBoolean(values.LocalRTC)
    };
  } catch (error) {
    return {
      ...base,
      ok: false,
      status: "unavailable",
      error: error.message
    };
  }
}

function directoryStats(dirPath) {
  const stats = { exists: false, files: 0, bytes: 0 };
  function walk(currentPath) {
    let entries;
    try {
      entries = fs.readdirSync(currentPath, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const entryPath = path.join(currentPath, entry.name);
      if (entry.isDirectory()) {
        walk(entryPath);
      } else if (entry.isFile()) {
        try {
          const fileStats = fs.statSync(entryPath);
          stats.files += 1;
          stats.bytes += fileStats.size;
        } catch {
          // Ignore files that disappear while diagnostics are collected.
        }
      }
    }
  }
  try {
    if (!fs.existsSync(dirPath)) return stats;
  } catch {
    return stats;
  }
  stats.exists = true;
  walk(dirPath);
  stats.mb = Math.round((stats.bytes / 1024 / 1024) * 10) / 10;
  return stats;
}

async function diskStatus(targetPath) {
  try {
    fs.mkdirSync(targetPath, { recursive: true });
  } catch {
    // df can still report the parent filesystem if the directory exists later.
  }
  try {
    const { stdout } = await execFilePromise("df", ["-Pk", targetPath], { timeout: 3000 });
    const line = stdout.trim().split("\n")[1];
    if (!line) return { ok: false, error: "df returned no filesystem row" };
    const parts = line.trim().split(/\s+/);
    const totalKb = Number(parts[1]);
    const usedKb = Number(parts[2]);
    const availableKb = Number(parts[3]);
    const capacity = parts[4] || null;
    return {
      ok: true,
      filesystem: parts[0],
      totalMb: Math.round(totalKb / 1024),
      usedMb: Math.round(usedKb / 1024),
      availableMb: Math.round(availableKb / 1024),
      capacity,
      mountpoint: parts.slice(5).join(" ")
    };
  } catch (error) {
    return { ok: false, error: error.message };
  }
}

function runtimePathStatus(name, dirPath, options = {}) {
  const result = {
    name,
    path: dirPath,
    exists: false,
    directory: false,
    readable: false,
    writable: false,
    writeProbe: false,
    ok: false,
    error: null
  };
  let probePath = null;

  try {
    if (options.ensureDirectory) {
      fs.mkdirSync(dirPath, { recursive: true });
    }
    const stat = fs.statSync(dirPath);
    result.exists = true;
    result.directory = stat.isDirectory();
    if (!result.directory) {
      result.error = "not_directory";
      return result;
    }

    try {
      fs.accessSync(dirPath, fs.constants.R_OK);
      result.readable = true;
    } catch {
      result.readable = false;
    }
    try {
      fs.accessSync(dirPath, fs.constants.W_OK);
      result.writable = true;
    } catch {
      result.writable = false;
    }

    probePath = path.join(
      dirPath,
      ".aos-write-check-" + process.pid + "-" + Date.now() + "-" + Math.random().toString(16).slice(2)
    );
    fs.writeFileSync(probePath, "ok\n", { flag: "wx", mode: 0o600 });
    fs.unlinkSync(probePath);
    probePath = null;
    result.writeProbe = true;
  } catch (error) {
    result.error = error.code || error.message;
  } finally {
    if (probePath) {
      try {
        fs.unlinkSync(probePath);
      } catch {
        // A failed write probe should not leave diagnostics unable to respond.
      }
    }
  }

  result.ok = Boolean(result.exists && result.directory && result.readable && result.writable && result.writeProbe);
  return result;
}

function logDiagnostics() {
  const logFiles = [
    "heartbeat.log",
    "heartbeat-error.log",
    "update.log",
    "commands.log",
    "commands-error.log"
  ];
  const files = [];
  let totalBytes = 0;
  for (const name of logFiles) {
    const fullPath = path.join(LOG_DIR, name);
    try {
      const stat = fs.statSync(fullPath);
      totalBytes += stat.size;
      files.push({ name, sizeBytes: stat.size, modifiedAt: stat.mtime.toISOString() });
    } catch {
      files.push({ name, sizeBytes: 0, modifiedAt: null });
    }
  }
  // Check logrotate config
  let logrotateConfigured = false;
  try {
    fs.statSync("/etc/logrotate.d/autopoiesis-os");
    logrotateConfigured = true;
  } catch {
    logrotateConfigured = false;
  }
  return {
    ok: true,
    status: totalBytes > 50 * 1024 * 1024 ? "logs_large" : "ok",
    logDir: LOG_DIR,
    totalBytes,
    totalMb: Math.round(totalBytes / 1024 / 1024 * 10) / 10,
    fileCount: logFiles.length,
    files,
    logrotateConfigured
  };
}

function runtimeStorageDiagnostics() {
  const entries = {
    dataDir: runtimePathStatus("dataDir", DATA_DIR, { ensureDirectory: true }),
    cacheDir: runtimePathStatus("cacheDir", CACHE_DIR, { ensureDirectory: true }),
    logDir: runtimePathStatus("logDir", LOG_DIR, { ensureDirectory: true })
  };
  const blocked = Object.values(entries)
    .filter(entry => !entry.ok)
    .map(entry => ({
      name: entry.name,
      path: entry.path,
      exists: entry.exists,
      directory: entry.directory,
      readable: entry.readable,
      writable: entry.writable,
      writeProbe: entry.writeProbe,
      error: entry.error
    }));
  return {
    ok: blocked.length === 0,
    status: blocked.length === 0 ? "ready" : "blocked",
    paths: entries,
    blocked
  };
}

async function systemdUnitStatus(unitName) {
  const status = {};
  try {
    const { stdout } = await execFilePromise("systemctl", ["is-active", unitName], { timeout: 2000 });
    status.active = stdout.trim() || "unknown";
  } catch (error) {
    status.active = (error.stdout || error.stderr || "unavailable").trim();
  }
  try {
    const { stdout } = await execFilePromise("systemctl", ["is-enabled", unitName], { timeout: 2000 });
    status.enabled = stdout.trim() || "unknown";
  } catch (error) {
    status.enabled = (error.stdout || error.stderr || "unavailable").trim();
  }
  return status;
}

async function serviceDiagnostics() {
  const services = {};
  for (const serviceName of DIAGNOSTIC_SERVICES) {
    try {
      const { stdout } = await execFilePromise("systemctl", ["is-active", serviceName], { timeout: 2000 });
      services[serviceName] = stdout.trim() || "unknown";
    } catch (error) {
      services[serviceName] = (error.stdout || error.stderr || "unavailable").trim();
    }
  }
  return services;
}

async function timerDiagnostics() {
  const timers = {};
  for (const timerName of DIAGNOSTIC_TIMERS) {
    timers[timerName] = await systemdUnitStatus(timerName);
  }
  return timers;
}

function timerStatusSummary(timers) {
  const entries = Object.entries(timers || {});
  const failed = [];
  const disabled = [];
  const unavailable = [];
  for (const [timerName, timerStatus] of entries) {
    const active = String((timerStatus || {}).active || "");
    const enabled = String((timerStatus || {}).enabled || "");
    if (active === "failed") failed.push(timerName);
    if (["disabled", "masked"].includes(enabled)) disabled.push(timerName);
    if (
      active.includes("System has not been booted") ||
      enabled.includes("System has not been booted") ||
      active.includes("unavailable") ||
      enabled.includes("unavailable")
    ) {
      unavailable.push(timerName);
    }
  }
  return {
    checked: entries.length,
    ready: entries.length > 0 && failed.length === 0 && disabled.length === 0,
    failed,
    disabled,
    unavailable
  };
}

function percentNumber(value) {
  const match = String(value || "").match(/^(\d+(?:\.\d+)?)%$/);
  return match ? Number(match[1]) : null;
}

function diagnosticsHealth(diagnostics, data) {
  const issues = [];
  function add(level, code, message) {
    issues.push({ level, code, message });
  }

  const paired = Boolean(data.device.paired);
  const deviceKeyPresent = Boolean(data.device.deviceApiKey || data.device.device_api_key);
  if (!paired) {
    add("warning", "device_unpaired", "Device is not paired to an online Frames profile.");
  } else if (!deviceKeyPresent) {
    add("warning", "device_key_missing", "Paired device has no stored API key.");
  }

  const networkOnline = Boolean(data.network && data.network.online);
  if (!networkOnline) {
    add("warning", "network_offline", "No LAN or Wi-Fi connection is currently recorded.");
  }
  if (diagnostics.mode === "offline") {
    add("warning", "offline_fallback", "Kiosk is using the local offline fallback.");
  }

  const disk = diagnostics.storage && diagnostics.storage.dataDisk;
  if (disk && disk.ok) {
    const capacity = percentNumber(disk.capacity);
    if (capacity !== null && capacity >= 95) {
      add("error", "storage_critical", "Data filesystem is at or above 95% capacity.");
    } else if (capacity !== null && capacity >= 85) {
      add("warning", "storage_high", "Data filesystem is at or above 85% capacity.");
    }
    if (Number.isFinite(disk.availableMb) && disk.availableMb < 256) {
      add("error", "storage_low", "Less than 256 MB is available for device data.");
    }
  } else if (disk && disk.ok === false) {
    add("warning", "storage_unknown", "Data filesystem status could not be collected.");
  }
  const runtimeStorage = diagnostics.storage && diagnostics.storage.runtime;
  if (runtimeStorage && runtimeStorage.ok === false) {
    const names = Array.isArray(runtimeStorage.blocked)
      ? runtimeStorage.blocked.map(item => item.name).filter(Boolean).join(", ")
      : "runtime paths";
    add("error", "runtime_storage_unavailable", "One or more runtime storage paths are not writable: " + names + ".");
  }

  if (diagnostics.memory && Number.isFinite(diagnostics.memory.freeMb) && diagnostics.memory.freeMb < 128) {
    add("warning", "memory_low", "Less than 128 MB of system memory is free.");
  }

  if (diagnostics.hardware) {
    if (diagnostics.hardware.status === "underpowered" || diagnostics.hardware.status === "low_ram") {
      add("warning", "hardware_underpowered", diagnostics.hardware.summary);
    } else if (diagnostics.hardware.status === "unknown_pi_low_ram") {
      add("warning", "hardware_low_ram", diagnostics.hardware.summary);
    } else if (diagnostics.hardware.status === "unknown") {
      add("warning", "hardware_unknown", diagnostics.hardware.summary);
    }
    const throttling = diagnostics.hardware.throttling || {};
    if (throttling.underVoltage) {
      add("warning", "hardware_undervoltage", "Device reports current or historical under-voltage throttling.");
    }
    if (throttling.throttled || throttling.frequencyCapped || throttling.softTemperatureLimit) {
      add("warning", "hardware_throttled", "Device reports current or historical CPU throttling.");
    }
  }

  if (Number.isFinite(diagnostics.temperatureC)) {
    if (diagnostics.temperatureC >= 85) {
      add("error", "temperature_critical", "Device temperature is at or above 85 C.");
    } else if (diagnostics.temperatureC >= 75) {
      add("warning", "temperature_high", "Device temperature is at or above 75 C.");
    }
  }

  if (diagnostics.input) {
    if (diagnostics.input.ok === false) {
      add("warning", "input_unknown", "Touchscreen/input device metadata could not be collected.");
    } else if (!diagnostics.input.pointerPresent) {
      add("warning", "input_missing", "No touchscreen or pointer input device is visible to the OS.");
    } else if (!diagnostics.input.touchscreenPresent) {
      add("warning", "touchscreen_missing", "Pointer input is available, but no touchscreen-class device is visible.");
    }
  }

  if (diagnostics.clock) {
    if (diagnostics.clock.status === "unsynchronized") {
      add("warning", "clock_unsynchronized", "System clock is not synchronized; TLS, scheduling, expiry, and release windows may be unreliable.");
    } else if (diagnostics.clock.status === "unavailable" || diagnostics.clock.ok === false) {
      add("warning", "clock_unknown", "System clock synchronization status could not be collected.");
    } else if (diagnostics.clock.ntpEnabled === false) {
      add("warning", "clock_ntp_disabled", "NTP/system time synchronization is disabled.");
    }
  }

  if (diagnostics.display) {
    const display = diagnostics.display;
    if (display.status === "no_display_env") {
      add("warning", "display_no_env", "DISPLAY environment variable is not set; Chromium kiosk may not be able to open a window.");
    } else if (display.status === "x_socket_missing") {
      add("warning", "display_x_socket_missing", "DISPLAY is set but the X11 socket is not present; the X server may not be running yet.");
    } else if (display.status === "wayland_socket_missing") {
      add("warning", "display_wayland_socket_missing", "WAYLAND_DISPLAY is set but the Wayland socket is not present; the compositor may not be running yet.");
    }
    if (display.graphicalTarget === false) {
      add("warning", "display_not_graphical_target", "systemd default target is not graphical.target; the Pi may not boot into a graphical session.");
    }
    if (display.kioskReadiness) {
      const kr = display.kioskReadiness;
      if (!kr.autoLogin && kr.graphicalTarget !== false) {
        add("warning", "display_no_autologin", "No graphical auto-login is configured for the appliance user; the kiosk may show a login screen on boot.");
      }
      if (!kr.screenBlankingDisabled) {
        add("warning", "display_blanking_enabled", "Screen blanking is not disabled; the display may turn off during idle periods.");
      }
    }
  }

  if (diagnostics.logs) {
    if (!diagnostics.logs.logrotateConfigured) {
      add("warning", "logs_no_rotation", "Log rotation is not configured; log files will grow without bound. Install config/autopoiesis-os.logrotate into /etc/logrotate.d/." );
    }
    if (diagnostics.logs.totalBytes > 50 * 1024 * 1024) {
      add("warning", "logs_large", "Combined log files exceed 50 MB (" + diagnostics.logs.totalMb + " MB). Consider rotating or trimming old logs." );
    }
  }

  if (diagnostics.release && diagnostics.release.status === "error") {
    add("error", "release_error", "Last release/update attempt failed.");
  } else if (diagnostics.release && diagnostics.release.status === "in_progress") {
    add("warning", "release_in_progress", "A release/update attempt is in progress.");
  }

  if (diagnostics.settingsSync && diagnostics.settingsSync.conflict) {
    add("warning", "settings_conflict", "Local settings are newer than the remote settings payload.");
  }

  if (diagnostics.pendingCommands > 0) {
    add("warning", "commands_pending", "Remote commands are waiting to be processed.");
  }

  if (diagnostics.feed) {
    if (diagnostics.feed.pollingStatus && diagnostics.feed.pollingStatus.stale) {
      add("warning", "feed_stale", "The local feed polling policy marks the stream as stale.");
    }
    if (diagnostics.feed.cacheFailedItems > 0) {
      add("warning", "cache_failures", "One or more eligible feed cache assets failed to download.");
    }
    if (
      diagnostics.feed.cacheEligibleItems > 0 &&
      diagnostics.feed.cacheIndexedItems === 0 &&
      diagnostics.feed.cacheIndexGeneratedAt
    ) {
      add("warning", "cache_empty", "The cache worker ran but did not cache any eligible feed assets.");
    }
  }

  // Cache quota warnings
  if (diagnostics.storage && diagnostics.storage.cacheQuota) {
    const q = diagnostics.storage.cacheQuota;
    if (q.evictionNeeded) {
      add("warning", "cache_near_quota", "Cache is near quota (" + q.usedMb + "/" + q.quotaMb + " MB, " + Math.round(q.usageRatio * 100) + "%). Eviction will run on next feed sync.");
    }
    if (q.usageRatio >= 0.75 && !q.evictionNeeded) {
      add("info", "cache_usage_moderate", "Cache usage is moderate (" + q.usedMb + "/" + q.quotaMb + " MB, " + Math.round(q.usageRatio * 100) + "%).");
    }
  }

  if (diagnostics.offline && diagnostics.offline.active) {
    add("warning", "offline_mode", "Device is operating in offline mode using cached artwork. The hosted API is unreachable.");
  }

  if (diagnostics.framePlayback) {
    if (diagnostics.framePlayback.status === "no_playable_items") {
      add("warning", "frame_no_playable_items", "The local frame queue exists, but no item has renderable media or text.");
    } else if (diagnostics.framePlayback.status === "empty_queue" && diagnostics.framePlayback.totalItems > 0) {
      add("warning", "frame_queue_empty", "Feed data exists, but no item is eligible for local frame playback.");
    }
  }

  if (diagnostics.services) {
    for (const [serviceName, serviceStatus] of Object.entries(diagnostics.services)) {
      if (serviceStatus === "failed") {
        add("error", "service_failed", serviceName + " is failed.");
      }
    }
  }

  const timers = timerStatusSummary(diagnostics.timers);
  for (const timerName of timers.failed) {
    add("error", "timer_failed", timerName + " is failed.");
  }
  for (const timerName of timers.disabled) {
    add("warning", "timer_disabled", timerName + " is disabled.");
  }

  const hasError = issues.some(issue => issue.level === "error");
  const hasWarning = issues.some(issue => issue.level === "warning");
  return {
    status: hasError ? "error" : hasWarning ? "warning" : "ok",
    issues,
    paired,
    networkOnline,
    deviceKeyPresent,
    checkedAt: diagnostics.collectedAt
  };
}

async function collectDiagnostics(options = {}) {
  const data = status();
  const commands = readJson(paths.commands, []);
  const release = readJson(paths.releaseState, null);
  const broadcast = readJson(paths.broadcast, null);
  const feed = readJson(paths.feed, { syncedAt: null, items: [] });
  const cacheManifest = readJson(paths.feedCache, { generatedAt: null, count: 0 });
  const cacheIndex = readJson(paths.cacheIndex, { generatedAt: null, cachedCount: 0, failedCount: 0, items: [] });
  const commandAudit = commandAuditSummary();
  const displayDelivery = deliverySummary();
  const deliveryStatus = deliveryStatusSummary();
  const releaseHistory = releaseHistorySummary();
  const frameState = publicFrameState();
  const disk = await diskStatus(DATA_DIR);
  const runtimeStorage = runtimeStorageDiagnostics();
  const clock = await clockDiagnostics();
  const hardware = await hardwareProfileDiagnostics();
  const diagnostics = {
    collectedAt: new Date().toISOString(),
    deviceId: data.device.deviceId || null,
    deviceName: data.device.deviceName || null,
    softwareVersion: version(),
    hostname: os.hostname(),
    platform: os.platform(),
    arch: os.arch(),
    kernel: os.release(),
    uptimeSeconds: Math.round(os.uptime()),
    loadAverage: os.loadavg().map(value => Math.round(value * 100) / 100),
    memory: {
      totalMb: Math.round(os.totalmem() / 1024 / 1024),
      freeMb: Math.round(os.freemem() / 1024 / 1024)
    },
    hardware,
    clock,
    temperatureC: readTemperatureC(),
    input: inputDiagnostics(),
    display: displayDiagnostics(),
    logs: logDiagnostics(),
    mode: data.state.currentMode || "setup",
    services: services || null,
    timers: timers || null,
    network: data.network || null,
    pairing: {
      paired: Boolean(data.device.paired),
      pairingCodePresent: Boolean((data.pairing || {}).pairingCode || data.device.pairingCode),
      pairingMock: Boolean((data.pairing || {}).mock),
      pairingStatus: (data.pairing || {}).status || null,
      pairingExpiresAt: (data.pairing || {}).expiresAt || null
    },
    storage: {
      dataDir: DATA_DIR,
      cacheDir: CACHE_DIR,
      logDir: LOG_DIR,
      dataDisk: disk,
      runtime: runtimeStorage,
      cache: directoryStats(CACHE_DIR),
      cacheQuota: cacheQuotaStatus()
    },
    release: release
      ? {
          status: release.status || null,
          targetVersion: release.targetVersion || null,
          releaseId: release.releaseId || null,
          previousVersion: release.previousVersion || null,
          completedAt: release.completedAt || null,
          failedAt: release.failedAt || null,
          error: release.error || null
        }
      : null,
    settingsSync: data.device.settingsSync
      ? {
          status: data.device.settingsSync.status || null,
          source: data.device.settingsSync.source || null,
          conflict: Boolean(data.device.settingsSync.conflict),
          reason: data.device.settingsSync.reason || null,
          localUpdatedAt: data.device.settingsSync.localUpdatedAt || null,
          remoteUpdatedAt: data.device.settingsSync.remoteUpdatedAt || null,
          checkedAt: data.device.settingsSync.checkedAt || null
        }
      : null,
    pendingCommands: Array.isArray(commands) ? commands.length : 0,
    commandAudit,
    displayDelivery,
    deliveryStatus: {
      totalItems: deliveryStatus.totalItems || 0,
      broadcastItems: deliveryStatus.broadcastItems || 0,
      feedItems: deliveryStatus.feedItems || 0,
      statusCounts: deliveryStatus.statusCounts || {}
    },
    broadcastDeliveries: broadcastDeliveriesPayload(),
    releaseHistory,
    eventIngestion: eventIngestionSummary(),
    framePlayback: frameState.playback,
    feed: {
      syncedAt: feed.syncedAt || null,
      polling: feed.polling || null,
      pollingStatus: feedPollingSummary(feed, data.device),
      totalItems: Array.isArray(feed.items) ? feed.items.length : 0,
      eligibleItems: eligibleFeedItems(feed, data.preferences).length,
      displayQueueItems: mixedFeedQueue(feed, data.preferences).length,
      categories: feedCategoryCounts(eligibleFeedItems(feed, data.preferences)),
      cacheEligibleItems: cacheManifest.count || 0,
      cacheManifestGeneratedAt: cacheManifest.generatedAt || null,
      cacheIndexGeneratedAt: cacheIndex.generatedAt || null,
      cacheIndexedItems: Array.isArray(cacheIndex.items) ? cacheIndex.items.length : 0,
      cacheCachedItems: cacheIndex.cachedCount || 0,
      cacheFailedItems: cacheIndex.failedCount || 0,
      offlinePlayableItems: cachedOfflineItems().length,
      displayCursor: feedCursorSummary(),
      categoryDisplay: {
        defaults: { ...CATEGORY_DISPLAY_SECONDS },
        overrides: data.preferences.categoryDurations || {},
        broadcastMaxSeconds: Number(data.preferences.broadcastMaxDuration) || BROADCAST_MAX_DISPLAY_SECONDS
      }
    },
    broadcast: broadcast
      ? {
          broadcastId: broadcast.broadcastId || broadcast.id || null,
          shownAt: broadcast.shownAt || null,
          title: broadcast.title || null,
          priority: broadcast.priority || null,
          expiresAt: broadcast.expiresAt || null
        }
      : null,
    nightMode: nightModeState(data.preferences),
    offline: (readJson(paths.state, {}).offline || { active: false })
  };
  if (options.includeServices) {
    diagnostics.services = await serviceDiagnostics();
    diagnostics.timers = await timerDiagnostics();
  }
  diagnostics.health = diagnosticsHealth(diagnostics, data);
  try {
    writeJson(paths.diagnostics, diagnostics);
  } catch (error) {
    diagnostics.diagnosticsPersisted = false;
    diagnostics.diagnosticsPersistError = error.code || error.message;
  }
  return diagnostics;
}

function phase(ready, statusValue, summary, details = {}) {
  return { ready: Boolean(ready), status: statusValue, summary, ...details };
}

function serviceActive(services, serviceName) {
  if (!services || !Object.prototype.hasOwnProperty.call(services, serviceName)) return null;
  return services[serviceName] === "active";
}

function timerActive(timers, timerName) {
  if (!timers || !Object.prototype.hasOwnProperty.call(timers, timerName)) return null;
  return (timers[timerName] || {}).active === "active";
}

function readinessSummary(diagnostics) {
  const health = diagnostics.health || {};
  const networkOnline = Boolean(health.networkOnline);
  const paired = Boolean(health.paired);
  const deviceKeyPresent = Boolean(health.deviceKeyPresent);
  const feed = diagnostics.feed || {};
  const framePlayback = diagnostics.framePlayback || {};
  const release = diagnostics.release || null;
  const services = diagnostics.services || null;
  const timers = diagnostics.timers || null;
  const timerSummary = timerStatusSummary(timers);
  const commandAudit = diagnostics.commandAudit || {};
  const input = diagnostics.input || {};
  const hardware = diagnostics.hardware || {};
  const clock = diagnostics.clock || {};
  const runtimeStorage = diagnostics.storage && diagnostics.storage.runtime ? diagnostics.storage.runtime : null;
  const commandExecutorActive = serviceActive(services, "autopoiesis-command-executor.service");
  const cacheServiceActive = serviceActive(services, "autopoiesis-cache.service");
  const heartbeatServiceActive = serviceActive(services, "autopoiesis-heartbeat.service");

  const phases = {
    localUi: phase(true, "ready", "Local UI responded and produced diagnostics."),
    hardware: phase(
      hardware.supported !== false,
      hardware.status || "unknown",
      hardware.summary || "Hardware profile was not collected.",
      { hardware }
    ),
    storage: phase(
      !runtimeStorage || runtimeStorage.ok !== false,
      runtimeStorage ? runtimeStorage.status || "unknown" : "not_checked",
      !runtimeStorage
        ? "Runtime storage path checks were not collected."
        : runtimeStorage.ok
          ? "Data, cache, and log directories are writable by the local UI process."
          : "One or more data, cache, or log directories are not writable by the local UI process.",
      { runtime: runtimeStorage }
    ),
    clock: phase(
      clock.ok !== false && clock.status !== "unsynchronized",
      clock.status || "unknown",
      clock.status === "synchronized"
        ? "System clock is synchronized."
        : clock.status === "unsynchronized"
          ? "System clock is not synchronized; TLS, scheduling, expiry, and release windows may be unreliable."
          : clock.status === "unavailable"
            ? "System clock synchronization status could not be collected."
            : "System clock synchronization status is unknown.",
      {
        systemTime: clock.systemTime || null,
        timezone: clock.timezone || null,
        ntpEnabled: clock.ntpEnabled,
        ntpSynchronized: clock.ntpSynchronized,
        systemClockSynchronized: clock.systemClockSynchronized
      }
    ),
    input: phase(
      Boolean(input.ok && input.pointerPresent),
      input.ok
        ? input.touchscreenPresent
          ? "touchscreen_ready"
          : input.pointerPresent
            ? "pointer_only"
            : "input_missing"
        : "unknown",
      input.ok
        ? input.touchscreenPresent
          ? "A touchscreen-class input device is visible to the OS."
          : input.pointerPresent
            ? "Pointer input is visible, but no touchscreen-class device was detected."
            : "No touchscreen or pointer input device is visible to the OS."
        : "Touchscreen/input device metadata could not be collected.",
      {
        touchscreenPresent: Boolean(input.touchscreenPresent),
        pointerPresent: Boolean(input.pointerPresent),
        keyboardPresent: Boolean(input.keyboardPresent),
        totalDevices: input.totalDevices || 0
      }
    ),
    display: (() => {
      const d = diagnostics.display || {};
      const kr = d.kioskReadiness || {};
      const ready = d.status === "display_ready" || d.status === "no_display_env";
      const issues = [];
      if (d.status === "x_socket_missing") issues.push("X11 socket not present");
      if (d.status === "wayland_socket_missing") issues.push("Wayland socket not present");
      if (d.graphicalTarget === false) issues.push("default target is not graphical.target");
      if (!kr.autoLogin) issues.push("no graphical auto-login");
      if (!kr.screenBlankingDisabled) issues.push("screen blanking not disabled");
      const statusLabel = d.status === "display_ready" ? "ready" : issues.length ? "kiosk_config_incomplete" : d.status || "unknown";
      const summary = issues.length
        ? "Display server checks: " + issues.join(", ") + "."
        : d.status === "display_ready"
          ? "Display server is accessible and kiosk OS configuration looks complete."
          : d.status === "no_display_env"
            ? "DISPLAY is not set (may be a development host or non-kiosk deployment)."
            : "Display server status: " + (d.status || "unknown");
      return phase(ready, statusLabel, summary, {
        displayServer: d.displayServer || null,
        graphicalTarget: d.graphicalTarget,
        autoLogin: kr.autoLogin || false,
        screenBlankingDisabled: kr.screenBlankingDisabled || false
      });
    })(),
    network: phase(
      networkOnline,
      networkOnline ? "ready" : "needs_network",
      networkOnline ? "LAN or Wi-Fi is online." : "No LAN or Wi-Fi connection is recorded.",
      { primary: diagnostics.network ? diagnostics.network.primary || null : null }
    ),
    pairing: phase(
      paired && deviceKeyPresent,
      paired ? (deviceKeyPresent ? "ready" : "missing_device_key") : "unpaired",
      paired
        ? (deviceKeyPresent ? "Device is paired and has a stored API key." : "Device is paired but no API key is stored.")
        : "Device is not paired to an online Frames profile.",
      { paired, deviceKeyPresent }
    ),
    sync: phase(
      paired && deviceKeyPresent && !((diagnostics.settingsSync || {}).conflict),
      (diagnostics.settingsSync || {}).conflict ? "conflict" : paired && deviceKeyPresent ? "ready" : "waiting_for_pairing",
      (diagnostics.settingsSync || {}).conflict
        ? "Local settings are newer than the latest remote payload."
        : paired && deviceKeyPresent
          ? "Settings sync is available."
          : "Settings sync waits for pairing and device key storage.",
      { settingsSync: diagnostics.settingsSync || null, heartbeatServiceActive }
    ),
    timers: phase(
      !timers || timerSummary.ready || timerSummary.unavailable.length === timerSummary.checked,
      !timers
        ? "not_checked"
        : timerSummary.failed.length
          ? "failed"
          : timerSummary.disabled.length
            ? "disabled"
            : timerSummary.unavailable.length === timerSummary.checked
              ? "unavailable"
              : "ready",
      !timers
        ? "Systemd timer state was not requested."
        : timerSummary.failed.length
          ? "One or more appliance timer units are failed."
          : timerSummary.disabled.length
            ? "One or more appliance timer units are disabled."
            : timerSummary.unavailable.length === timerSummary.checked
              ? "Systemd timer state is unavailable in this environment."
              : "Appliance sync, command, cache, update, and watchdog timers are enabled and active.",
      {
        timers,
        heartbeatTimerActive: timerActive(timers, "autopoiesis-heartbeat.timer"),
        commandExecutorTimerActive: timerActive(timers, "autopoiesis-command-executor.timer"),
        cacheTimerActive: timerActive(timers, "autopoiesis-cache.timer"),
        updaterTimerActive: timerActive(timers, "autopoiesis-updater.timer"),
        watchdogTimerActive: timerActive(timers, "autopoiesis-watchdog.timer")
      }
    ),
    content: phase(
      Boolean(feed.syncedAt || feed.totalItems || feed.eligibleItems),
      feed.pollingStatus && feed.pollingStatus.stale ? "stale" : feed.syncedAt ? "ready" : "waiting_for_feed",
      feed.pollingStatus && feed.pollingStatus.stale
        ? "A feed has been synced locally, but the stream polling policy marks it stale."
        : feed.syncedAt
          ? "A feed has been synced locally."
          : "No local feed sync has completed yet.",
      { feed }
    ),
    playback: phase(
      Boolean(framePlayback.ready),
      framePlayback.status || "unknown",
      framePlayback.summary || "Local frame playback status is unavailable.",
      { framePlayback }
    ),
    cache: phase(
      feed.cacheEligibleItems === 0 || feed.cacheCachedItems > 0,
      feed.cacheEligibleItems === 0
        ? "no_cache_needed"
        : feed.cacheCachedItems > 0
          ? "ready"
          : feed.cacheIndexGeneratedAt
            ? "empty_or_failed"
            : "waiting_for_cache_worker",
      feed.cacheEligibleItems === 0
        ? "No current feed items require cache."
        : feed.cacheCachedItems > 0
          ? "At least one eligible feed asset is cached."
          : feed.cacheIndexGeneratedAt
            ? "Cache worker ran but no eligible assets are cached."
            : "Cache worker has not indexed the current feed manifest yet.",
      { cacheServiceActive }
    ),
    commands: phase(
      paired && deviceKeyPresent && diagnostics.pendingCommands === 0,
      diagnostics.pendingCommands > 0 ? "pending_commands" : paired && deviceKeyPresent ? "ready" : "waiting_for_pairing",
      diagnostics.pendingCommands > 0
        ? "Remote commands are queued for processing."
        : paired && deviceKeyPresent
          ? "Remote command processing is available."
          : "Command processing waits for pairing and device key storage.",
      { pendingCommands: diagnostics.pendingCommands || 0, commandExecutorActive, commandAudit }
    ),
    release: phase(
      !release || release.status !== "error",
      release && release.status ? release.status : "idle",
      release && release.status === "error"
        ? "Last release/update attempt failed."
        : release && release.status === "in_progress"
          ? "A release/update attempt is in progress."
          : "No release blocker is recorded.",
      { release, releaseHistory: diagnostics.releaseHistory || null }
    )
  };

  const blockers = [];
  for (const [name, value] of Object.entries(phases)) {
    if (!value.ready && value.status !== "no_cache_needed") blockers.push({ phase: name, status: value.status, summary: value.summary });
  }
  const hasError = health.status === "error" || blockers.some(item => ["blocked", "missing_device_key", "conflict", "empty_or_failed", "pending_commands", "error"].includes(item.status));
  const statusValue = hasError ? "blocked" : blockers.length ? "not_ready" : "ready";
  return {
    ok: statusValue === "ready",
    status: statusValue,
    healthStatus: health.status || "unknown",
    device: {
      deviceId: diagnostics.deviceId || null,
      deviceName: diagnostics.deviceName || null,
      softwareVersion: diagnostics.softwareVersion || null
    },
    phases,
    blockers,
    collectedAt: diagnostics.collectedAt || null
  };
}

function boolOption(value) {
  return value === true || value === "1" || value === "true" || value === "yes";
}

function rolloutProfileName(value) {
  const profile = String(value || "staged").toLowerCase();
  return ["setup", "staged", "production"].includes(profile) ? profile : "staged";
}

function rolloutAcceptance(diagnostics, options = {}) {
  const profile = rolloutProfileName(options.profile);
  const strictContent = boolOption(options.strictContent) || profile === "production";
  const readiness = readinessSummary(diagnostics);
  const health = healthSummary(diagnostics);
  const adminCapabilities = publicAdminCapabilities();
  const events = publicDeviceEvents({ limit: options.eventLimit || 10 });
  const phases = readiness.phases || {};
  const framePlayback = diagnostics.framePlayback || {};
  const input = diagnostics.input || {};
  const clockPhase = ((readiness.phases || {}).clock) || {};

  const checks = [];
  function addCheck(id, label, passed, required, summary, details = {}) {
    checks.push({
      id,
      label,
      passed: Boolean(passed),
      required: Boolean(required),
      summary,
      ...details
    });
  }

  const profileRequiresManagedDevice = profile !== "setup";
  const requireTouchscreen = profile !== "setup";
  const requireNoWarnings = profile === "production";
  const contentRequired = strictContent;

  addCheck(
    "health",
    "Health has no blocking errors",
    health.status !== "error" && (!requireNoWarnings || health.status === "ok"),
    true,
    requireNoWarnings
      ? "Production rollout requires an all-clear compact health status."
      : "Rollout acceptance blocks on compact health errors.",
    { status: health.status }
  );
  addCheck(
    "local_ui",
    "Local UI readiness",
    Boolean((phases.localUi || {}).ready),
    true,
    (phases.localUi || {}).summary || "Local UI must respond with diagnostics.",
    { status: (phases.localUi || {}).status || "unknown" }
  );
  addCheck(
    "clock",
    "System clock synchronized",
    Boolean(clockPhase.ready),
    profileRequiresManagedDevice,
    clockPhase.summary || "Managed rollout requires synchronized system time for TLS, scheduling, feed expiry, and release windows.",
    { status: clockPhase.status || "unknown" }
  );
  addCheck(
    "input",
    requireTouchscreen ? "Touchscreen detected" : "Pointer input detected",
    requireTouchscreen ? Boolean(input.touchscreenPresent) : Boolean(input.pointerPresent),
    true,
    requireTouchscreen
      ? "Staged and production frames require touchscreen-class input."
      : "Setup acceptance requires at least pointer input.",
    {
      status: input.status || "unknown",
      touchscreenPresent: Boolean(input.touchscreenPresent),
      pointerPresent: Boolean(input.pointerPresent)
    }
  );
  addCheck(
    "network",
    "Network online",
    Boolean((phases.network || {}).ready),
    profileRequiresManagedDevice,
    (phases.network || {}).summary || "Managed rollout requires LAN or Wi-Fi.",
    { status: (phases.network || {}).status || "unknown" }
  );
  addCheck(
    "pairing",
    "Paired with device key",
    Boolean((phases.pairing || {}).ready),
    profileRequiresManagedDevice,
    (phases.pairing || {}).summary || "Managed rollout requires online pairing and a stored device API key.",
    { status: (phases.pairing || {}).status || "unknown" }
  );
  addCheck(
    "settings_sync",
    "Settings sync available",
    Boolean((phases.sync || {}).ready),
    profileRequiresManagedDevice,
    (phases.sync || {}).summary || "Settings sync must be ready for managed rollout.",
    { status: (phases.sync || {}).status || "unknown" }
  );
  addCheck(
    "remote_admin",
    "Remote admin actions can be authorized",
    Boolean(
      adminCapabilities.device &&
        adminCapabilities.device.paired &&
        adminCapabilities.device.deviceKeyPresent &&
        adminCapabilities.device.remoteEnabled
    ),
    profileRequiresManagedDevice,
    "Admin command queueing requires pairing, a stored device key, and remoteEnabled=true.",
    {
      remoteEnabled: Boolean(adminCapabilities.device && adminCapabilities.device.remoteEnabled),
      pendingCommands: adminCapabilities.pendingCommands || 0
    }
  );
  addCheck(
    "commands",
    "Command queue clear",
    Boolean((phases.commands || {}).ready),
    profileRequiresManagedDevice,
    (phases.commands || {}).summary || "Remote command handling must not have stale pending commands.",
    { status: (phases.commands || {}).status || "unknown" }
  );
  addCheck(
    "release",
    "Release state not failed",
    Boolean((phases.release || {}).ready),
    true,
    (phases.release || {}).summary || "Last release/update attempt must not be failed.",
    { status: (phases.release || {}).status || "unknown" }
  );
  addCheck(
    "content",
    "Feed content synced",
    Boolean((phases.content || {}).ready),
    contentRequired,
    (phases.content || {}).summary || "Content is optional for setup but required for strict rollout acceptance.",
    { status: (phases.content || {}).status || "unknown" }
  );
  addCheck(
    "playback",
    "Local playback renderable",
    Boolean((phases.playback || {}).ready),
    contentRequired,
    (phases.playback || {}).summary || "Strict rollout acceptance requires a renderable local queue.",
    {
      status: (phases.playback || {}).status || "unknown",
      playableItems: framePlayback.playableItems || 0,
      cachedPlayableItems: framePlayback.cachedPlayableItems || 0
    }
  );
  addCheck(
    "cache",
    "Offline cache acceptable",
    Boolean((phases.cache || {}).ready),
    profile === "production" || strictContent,
    (phases.cache || {}).summary || "Strict rollout acceptance requires cache state to be ready or unnecessary.",
    { status: (phases.cache || {}).status || "unknown" }
  );
  addCheck(
    "event_export",
    "Device event export contract",
    Boolean(events.ok && events.kind === "autopoiesis_frame_event_export"),
    true,
    "The device must expose the unified redacted event export for backend ingestion.",
    { exportedEvents: (events.counts || {}).exported || 0, hasMore: Boolean((events.cursor || {}).hasMore) }
  );

  const blockers = checks.filter(check => check.required && !check.passed);
  const warnings = checks.filter(check => !check.required && !check.passed);
  const statusValue = blockers.length ? "blocked" : warnings.length ? "warning" : "accepted";

  return {
    ok: statusValue !== "blocked",
    kind: "autopoiesis_frame_rollout_acceptance",
    schemaVersion: 1,
    redacted: true,
    generatedAt: new Date().toISOString(),
    profile,
    strictContent,
    status: statusValue,
    device: health.device,
    healthStatus: health.status || "unknown",
    readinessStatus: readiness.status || "unknown",
    checks,
    blockers,
    warnings,
    summary: {
      requiredPassed: checks.filter(check => check.required && check.passed).length,
      requiredTotal: checks.filter(check => check.required).length,
      optionalWarnings: warnings.length,
      issueCodes: ((health.health || {}).issues || []).map(issue => issue.code).filter(Boolean),
      readinessBlockers: readiness.blockers || [],
      remoteAdminReady: Boolean(
        adminCapabilities.device &&
          adminCapabilities.device.paired &&
          adminCapabilities.device.deviceKeyPresent &&
          adminCapabilities.device.remoteEnabled
      ),
      exportedEvents: (events.counts || {}).exported || 0
    },
    readiness,
    adminCapabilities,
    eventExport: {
      kind: events.kind,
      schemaVersion: events.schemaVersion,
      redacted: events.redacted,
      generatedAt: events.generatedAt,
      counts: events.counts,
      cursor: events.cursor,
      sourceCursors: events.sourceCursors
    }
  };
}

function healthSummary(diagnostics) {
  const health = diagnostics.health || {};
  return {
    ok: health.status !== "error",
    status: health.status || "unknown",
    health,
    device: {
      deviceId: diagnostics.deviceId || null,
      deviceName: diagnostics.deviceName || null,
      softwareVersion: diagnostics.softwareVersion || null
    },
    mode: diagnostics.mode || null,
    network: {
      online: Boolean(health.networkOnline),
      primary: diagnostics.network ? diagnostics.network.primary || null : null
    },
    hardware: diagnostics.hardware || null,
    clock: diagnostics.clock || null,
    pairing: {
      paired: Boolean(health.paired)
    },
    input: diagnostics.input || null,
    display: diagnostics.display || null,
    logs: diagnostics.logs || null,
    storage: diagnostics.storage
      ? {
          runtime: diagnostics.storage.runtime || null,
          dataDisk: diagnostics.storage.dataDisk || null
        }
      : null,
    timers: diagnostics.timers || null,
    release: diagnostics.release
      ? {
          status: diagnostics.release.status || null,
          targetVersion: diagnostics.release.targetVersion || null,
          releaseId: diagnostics.release.releaseId || null
        }
      : null,
    releaseHistory: diagnostics.releaseHistory || null,
    pendingCommands: diagnostics.pendingCommands || 0,
    commandAudit: diagnostics.commandAudit || null,
    displayDelivery: diagnostics.displayDelivery || null,
    framePlayback: diagnostics.framePlayback || null,
    feed: diagnostics.feed || null,
    broadcast: diagnostics.broadcast || null,
    nightMode: diagnostics.nightMode || null,
    collectedAt: diagnostics.collectedAt || null
  };
}

async function supportBundle(options = {}) {
  const diagnostics = await collectDiagnostics({ includeServices: options.includeServices });
  const health = healthSummary(diagnostics);
  const readiness = readinessSummary(diagnostics);
  const feed = publicFeed();
  const frameState = publicFrameState();
  const offlineCache = publicOfflineCache();
  const commandAudit = publicCommandAudit(options.auditLimit);
  const deliveryLog = publicDeliveryLog(options.deliveryLimit);
  const releaseHistory = publicReleaseHistory(options.releaseLimit);
  const deviceEvents = publicDeviceEvents({
    commandLimit: options.eventLimit || options.auditLimit,
    deliveryLimit: options.eventLimit || options.deliveryLimit,
    releaseLimit: options.eventLimit || options.releaseLimit
  });
  const adminCapabilities = publicAdminCapabilities();
  const issueCodes = ((health.health || {}).issues || []).map(issue => issue.code).filter(Boolean);
  const blockers = Array.isArray(readiness.blockers) ? readiness.blockers : [];

  return {
    ok: true,
    kind: "autopoiesis_frame_support_bundle",
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    redacted: true,
    device: health.device,
    summary: {
      healthStatus: health.status || "unknown",
      readinessStatus: readiness.status || "unknown",
      issueCodes,
      blockers: blockers.map(item => ({
        phase: item.phase,
        status: item.status,
        summary: item.summary
      })),
      input: {
        status: diagnostics.input ? diagnostics.input.status || null : null,
        touchscreenPresent: diagnostics.input ? Boolean(diagnostics.input.touchscreenPresent) : false,
        pointerPresent: diagnostics.input ? Boolean(diagnostics.input.pointerPresent) : false,
        keyboardPresent: diagnostics.input ? Boolean(diagnostics.input.keyboardPresent) : false,
        totalDevices: diagnostics.input ? diagnostics.input.totalDevices || 0 : 0
      },
      display: diagnostics.display
        ? {
            status: diagnostics.display.status || null,
            displayServer: diagnostics.display.displayServer || null,
            graphicalTarget: diagnostics.display.graphicalTarget,
            kioskReadiness: diagnostics.display.kioskReadiness || null
          }
        : null,
      logs: diagnostics.logs
        ? {
            status: diagnostics.logs.status || null,
            totalMb: diagnostics.logs.totalMb || 0,
            fileCount: diagnostics.logs.fileCount || 0,
            logrotateConfigured: diagnostics.logs.logrotateConfigured || false
          }
        : null,
      hardware: diagnostics.hardware
        ? {
            status: diagnostics.hardware.status || null,
            supported: diagnostics.hardware.supported === true,
            recommended: diagnostics.hardware.recommended === true,
            model: diagnostics.hardware.model || null,
            family: diagnostics.hardware.family || null,
            piGeneration: diagnostics.hardware.piGeneration,
            arch: diagnostics.hardware.arch || null,
            ramMb: diagnostics.hardware.ramMb || null,
            summary: diagnostics.hardware.summary || null,
            throttling: diagnostics.hardware.throttling || null
          }
        : null,
      clock: diagnostics.clock
        ? {
            status: diagnostics.clock.status || null,
            systemTime: diagnostics.clock.systemTime || null,
            timezone: diagnostics.clock.timezone || null,
            ntpEnabled: diagnostics.clock.ntpEnabled,
            ntpSynchronized: diagnostics.clock.ntpSynchronized,
            systemClockSynchronized: diagnostics.clock.systemClockSynchronized
          }
        : null,
      storage: diagnostics.storage
        ? {
            runtime: diagnostics.storage.runtime || null,
            dataDisk: diagnostics.storage.dataDisk || null
          }
        : null,
      timers: diagnostics.timers || null,
      pendingCommands: health.pendingCommands || 0,
      feedPolling: diagnostics.feed ? diagnostics.feed.pollingStatus || null : null,
      feedCursor: diagnostics.feed ? diagnostics.feed.displayCursor || null : null,
      framePlayback: diagnostics.framePlayback || null,
      offlinePlayableItems: offlineCache.playableItems || 0,
      offline: diagnostics.offline || { active: false },
      commandAudit: {
        totalEntries: commandAudit.count || 0,
        lastStatus: diagnostics.commandAudit ? diagnostics.commandAudit.lastStatus || null : null,
        recentErrors: diagnostics.commandAudit ? diagnostics.commandAudit.recentErrors || 0 : 0
      },
      displayDelivery: {
        totalEntries: deliveryLog.count || 0,
        lastEventType: diagnostics.displayDelivery ? diagnostics.displayDelivery.lastEventType || null : null,
        recentBroadcastEvents: diagnostics.displayDelivery ? diagnostics.displayDelivery.recentBroadcastEvents || 0 : 0
      },
      deliveryStatus: diagnostics.deliveryStatus || { totalItems: 0, broadcastItems: 0, feedItems: 0, statusCounts: {} },
      broadcastDeliveries: diagnostics.broadcastDeliveries || { broadcastCount: 0, statusCounts: {}, deliveries: [] },
      releaseHistory: {
        totalEntries: releaseHistory.count || 0,
        lastStatus: diagnostics.releaseHistory ? diagnostics.releaseHistory.lastStatus || null : null,
        lastVersion: diagnostics.releaseHistory ? diagnostics.releaseHistory.lastVersion || null : null,
        recentFailures: diagnostics.releaseHistory ? diagnostics.releaseHistory.recentFailures || 0 : 0
      },
      eventIngestion: {
        status: diagnostics.eventIngestion ? diagnostics.eventIngestion.status || null : null,
        acceptedThroughObservedAt: diagnostics.eventIngestion ? diagnostics.eventIngestion.acceptedThroughObservedAt || null : null,
        replaySince: diagnostics.eventIngestion ? diagnostics.eventIngestion.replaySince || null : null
      }
    },
    diagnostics,
    health,
    readiness,
    feed,
    frameState,
    offlineCache,
    commandAudit,
    deliveryLog,
    releaseHistory,
    deviceEvents,
    adminCapabilities
  };
}

function page(title, body, script = "") {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(title)}</title>
  <link rel="stylesheet" href="/style.css">
</head>
<body>
  ${body}
  ${script ? `<script>${script}</script>` : ""}
</body>
</html>`;
}

function scriptJson(value) {
  return JSON.stringify(value).replace(/</g, "\\u003c");
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function splitNmcliLine(line) {
  const values = [];
  let current = "";
  let escaped = false;
  for (const char of line) {
    if (escaped) {
      current += char;
      escaped = false;
    } else if (char === "\\") {
      escaped = true;
    } else if (char === ":") {
      values.push(current);
      current = "";
    } else {
      current += char;
    }
  }
  values.push(current);
  return values;
}

function writeNetworkState(network) {
  writeJson(path.join(DATA_DIR, "network.json"), network);
  const state = readJson(paths.state, {});
  writeJson(paths.state, {
    ...state,
    networkOnline: Boolean(network.online),
    networkType: network.primary || null
  });
  if (network.lan && network.lan.connected) {
    const device = readJson(paths.device, {});
    writeJson(paths.device, { ...device, lanConfigured: true });
  }
}

/**
 * Query detailed connection properties for the active Wi-Fi device.
 * Returns ssid, signal, signalQuality, securityType, frequency, channel,
 * bitrate, ip4Address, and ip6Address when available.
 * Safe to call even if nmcli is absent — returns null.
 */
function wifiConnectionDetails(callback) {
  execFile("nmcli", ["-t", "-f", "GENERAL.DEVICE,GENERAL.TYPE,GENERAL.STATE,GENERAL.CONNECTION," +
    "GENERAL.IP4-ADDRESS,GENERAL.IP6-ADDRESS," +
    "IP4.ADDRESS,IP6.ADDRESS," +
    "802-11-wireless.ssid,802-11-wireless-security.key-mgmt," +
    "GENERAL.WIFI-HW-ADDRESS"], "device", "show", (error, stdout) => {
    // Fallback: use simpler approach with nmcli -t -f active fields
    wifiConnectionDetailsFallback(callback);
  });
}

/**
 * Fallback Wi-Fi connection details using 'nmcli -t -f SSID,SIGNAL,SECURITY dev wifi list --rescan no'
 * plus 'nmcli -t -f DEVICE,TYPE,STATE dev status' and IP lookup.
 */
function wifiConnectionDetailsFallback(callback) {
  // Gather signal/security info for currently connected Wi-Fi
  execFile("nmcli", ["-t", "-f", "ACTIVE,SIGNAL,SSID,SECURITY,FREQ,RATE", "device", "wifi", "list", "--rescan", "no"], (error, stdout) => {
    if (error) {
      callback(null);
      return;
    }
    const lines = (stdout || "").split("\n").filter(Boolean);
    const activeLine = lines.find(line => line.startsWith("yes:"));
    if (!activeLine) {
      callback(null);
      return;
    }
    // nmcli -t output format: active:signal:ssid:security:freq:rate
    const parts = splitNmcliLine(activeLine);
    const ssid = parts[2] || null;
    const signal = Number(parts[1]) || 0;
    const security = parts[3] || "";
    const frequency = parts[4] || null;
    const bitrate = parts[5] || null;

    // Get IP address
    execFile("nmcli", ["-t", "-f", "IP4.ADDRESS", "device", "show"], (ipError, ipStdout) => {
      let ip4Address = null;
      if (!ipError && ipStdout) {
        const ipMatch = ipStdout.match(/IP4\.ADDRESS[^:]*:([^/\n]+)/);
        if (ipMatch) ip4Address = ipMatch[1];
      }
      execFile("nmcli", ["-t", "-f", "IP6.ADDRESS", "device", "show"], (ip6Error, ip6Stdout) => {
        let ip6Address = null;
        if (!ip6Error && ip6Stdout) {
          const ip6Match = ip6Stdout.match(/IP6\.ADDRESS[^:]*:([^/\n]+)/);
          if (ip6Match) ip6Address = ip6Match[1];
        }
        callback({
          ssid,
          signal,
          signalQuality: signalQuality(signal),
          securityType: classifySecurity(security),
          security,
          frequency,
          bitrate,
          ip4Address,
          ip6Address
        });
      });
    });
  });
}

function networkStatus(callback) {
  execFile("nmcli", ["-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status"], (error, stdout) => {
    if (error) {
      const network = { online: false, primary: null, lan: { available: false }, wifi: { available: false } };
      writeNetworkState(network);
      callback(null, {
        ok: false,
        error: "Network status unavailable. NetworkManager/nmcli may not be installed or accessible.",
        network
      });
      return;
    }
    const devices = stdout
      .split("\n")
      .filter(Boolean)
      .map(line => {
        const [device, type, state, connection] = splitNmcliLine(line);
        return { device, type, state, connection };
      });
    const ethernet = devices.find(item => item.type === "ethernet");
    const wifi = devices.find(item => item.type === "wifi");
    const connected = devices.find(item => item.state === "connected" && (item.type === "ethernet" || item.type === "wifi"));
    const network = {
      online: Boolean(connected),
      primary: connected ? (connected.type === "ethernet" ? "lan" : "wifi") : null,
      lan: ethernet
        ? {
            available: true,
            connected: ethernet.state === "connected",
            device: ethernet.device,
            connection: ethernet.connection || null
          }
        : { available: false },
      wifi: wifi
        ? {
            available: true,
            connected: wifi.state === "connected",
            device: wifi.device,
            connection: wifi.connection || null
          }
        : { available: false }
    };

    // Enrich Wi-Fi entry with signal quality, SSID, IP, frequency when connected
    if (network.wifi.connected) {
      wifiConnectionDetailsFallback((_, details) => {
        if (details) {
          network.wifi = {
            ...network.wifi,
            ssid: details.ssid,
            signal: details.signal,
            signalQuality: details.signalQuality,
            securityType: details.securityType,
            frequency: details.frequency,
            bitrate: details.bitrate,
            ip4Address: details.ip4Address,
            ip6Address: details.ip6Address
          };
        }
        writeNetworkState(network);
        callback(null, { ok: true, network, devices });
      });
    } else {
      writeNetworkState(network);
      callback(null, { ok: true, network, devices });
    }
  });
}

function renderSetup() {
  const data = status();
  const network = data.network || {};
  const pairing = data.pairing || {};
  const networkOnline = Boolean(network.online);
  const paired = Boolean(data.device.paired);
  const settingsReady = Boolean(data.preferences && Number.isFinite(Number(data.preferences.imageDuration)));
  const networkLabel = network.online
    ? `${network.primary || "network"} online`
    : "Offline";
  const pairingDetail = pairing.mock
    ? "Web pairing required"
    : pairing.pairingCode
    ? `${pairing.pairingCode}${pairing.mock ? " (local fallback)" : ""}`
    : (paired ? "Paired" : "Waiting");
  const launchDisabled = !networkOnline || !paired ? " disabled aria-disabled=\"true\"" : "";
  return page(
    "Autopoiesis Onboarding",
    `<main class="screen">
      <section class="panel wide onboarding">
        <p class="kicker">Autopoiesis Frame</p>
        <h1>Set up your frame</h1>
        <p class="muted">Connect this device, pair it to your account, choose the basic display behavior, then start the living stream.</p>

        <ol class="steps">
          <li class="step ${networkOnline ? "done" : "active"}">
            <div class="step-index">1</div>
            <div>
              <h2>Connect to the internet</h2>
              <p>${escapeHtml(networkOnline ? `Connected through ${network.primary || "network"}.` : "Use Ethernet or Wi-Fi before pairing.")}</p>
              <dl class="status compact">
                <div><dt>Status</dt><dd id="network-state">${escapeHtml(networkLabel)}</dd></div>
              </dl>
              <div class="actions">
                <button data-refresh-network>Check connection</button>
                <button data-connect-lan>Use Ethernet</button>
                <a class="button" href="/local/wifi/scan">Choose Wi-Fi</a>
              </div>
            </div>
          </li>

          <li class="step ${paired ? "done" : networkOnline ? "active" : ""}">
            <div class="step-index">2</div>
            <div>
              <h2>Pair with your account</h2>
              <p>${paired ? "This frame is paired." : "Start pairing, then enter this code on autopoiesis.art/profile/frames."}</p>
              <div class="pairing-code ${pairing.error || pairing.mock ? "error" : ""}">${escapeHtml(pairing.error || pairingDetail)}</div>
              ${pairing.error || pairing.mock ? `<p class="setup-error">${escapeHtml(pairing.error || "This local fallback code cannot pair with the web app. Request a real web pairing code.")}</p>` : ""}
              <div class="actions">
                <button data-start-pairing ${networkOnline ? "" : "disabled"}>${pairing.pairingCode && !paired ? "Refresh pairing code" : "Start pairing"}</button>
                <button data-check-pairing ${networkOnline ? "" : "disabled"}>I paired it</button>
              </div>
            </div>
          </li>

          <li class="step ${settingsReady && paired ? "done" : paired ? "active" : ""}">
            <div class="step-index">3</div>
            <div>
              <h2>Choose display settings</h2>
              <form id="settings-form" class="grid compact-form">
                <label>Device name <input name="deviceName" value="${escapeHtml(data.device.deviceName || "")}"></label>
                <label>Image duration <input name="imageDuration" type="number" min="15" max="300" step="15" value="${escapeHtml(data.preferences.imageDuration ?? 60)}"></label>
                <label>Volume <input name="volume" type="number" min="0" max="100" step="5" value="${escapeHtml(data.preferences.volume ?? 50)}"></label>
                <label class="check"><input name="soundEnabled" type="checkbox" ${data.preferences.soundEnabled ? "checked" : ""}> Sound enabled</label>
                <div class="welcome-night-toggle">
                  <label class="check"><input name="nightMode" type="checkbox" ${data.preferences.nightMode ? "checked" : ""}> Night mode</label>
                  <div class="welcome-night-times" ${data.preferences.nightMode ? "" : "hidden"}>
                    <label>Turn off at <input name="nightModeStart" type="time" value="${escapeHtml(data.preferences.nightModeStart || "22:00")}"></label>
                    <label>Turn on at <input name="nightModeEnd" type="time" value="${escapeHtml(data.preferences.nightModeEnd || "08:00")}"></label>
                  </div>
                </div>
                <button class="primary" type="submit" ${paired ? "" : "disabled"}>Save settings</button>
              </form>
            </div>
          </li>

          <li class="step ${networkOnline && paired ? "active" : ""}">
            <div class="step-index">4</div>
            <div>
              <h2>Start the stream</h2>
              <p>The frame will open the fullscreen living display and keep local setup available at port 3030.</p>
              <a class="button primary launch${launchDisabled ? " disabled" : ""}" href="${networkOnline && paired ? "/launch?completeOnboarding=1" : "#"}"${launchDisabled}>Launch stream</a>
            </div>
          </li>
        </ol>

        <p class="note">Device: ${escapeHtml(data.device.deviceId || "unknown")} · Mode: ${escapeHtml(data.state.currentMode || "setup")}</p>
      </section>
    </main>`,
    `const steps = Array.from(document.querySelectorAll(".step"));
    const stepsList = document.querySelector(".steps");
    const setupPanel = document.querySelector(".onboarding");
    let currentStep = steps.findIndex(step => step.classList.contains("active") && !step.classList.contains("done"));
    if (currentStep < 0) currentStep = steps.findIndex(step => !step.classList.contains("done"));
    if (currentStep < 0) currentStep = steps.length - 1;
    const controls = document.createElement("div");
    controls.className = "setup-controls";
    controls.innerHTML = "<button type=\"button\" data-setup-prev>Back</button><div class=\"setup-dots\">" +
      steps.map((_, index) => "<button type=\"button\" data-setup-dot=\"" + index + "\">" + (index + 1) + "</button>").join("") +
      "</div><button class=\"primary\" type=\"button\" data-setup-next>Next</button>";
    setupPanel.appendChild(controls);
    function showSetupStep(index) {
      currentStep = Math.max(0, Math.min(steps.length - 1, Number(index) || 0));
      steps.forEach((step, stepIndex) => step.classList.toggle("current", stepIndex === currentStep));
      document.querySelectorAll("[data-setup-dot]").forEach(dot => {
        dot.classList.toggle("current", Number(dot.dataset.setupDot) === currentStep);
      });
      if (stepsList) stepsList.style.setProperty("--setup-step", String(currentStep));
    }
    document.querySelector("[data-setup-prev]").addEventListener("click", () => showSetupStep(currentStep - 1));
    document.querySelector("[data-setup-next]").addEventListener("click", () => showSetupStep(currentStep + 1));
    document.querySelectorAll("[data-setup-dot]").forEach(dot => {
      dot.addEventListener("click", () => showSetupStep(dot.dataset.setupDot));
    });
    steps.forEach((step, index) => {
      step.querySelector(".step-index").addEventListener("click", () => showSetupStep(index));
    });
    showSetupStep(currentStep);
    async function refreshNetwork() {
      const response = await fetch("/local/network/status");
      const data = await response.json();
      const network = data.network || {};
      document.getElementById("network-state").textContent = network.online ? ((network.primary || "network") + " online") : "Offline";
      if (network.online) location.reload();
    }
    document.querySelector("[data-refresh-network]").addEventListener("click", refreshNetwork);
    document.querySelector("[data-connect-lan]").addEventListener("click", async () => {
      await fetch("/local/lan/connect", { method: "POST" });
      await refreshNetwork();
    });
    document.querySelector("[data-start-pairing]").addEventListener("click", async () => {
      const codeEl = document.querySelector(".pairing-code");
      const button = document.querySelector("[data-start-pairing]");
      button.disabled = true;
      if (codeEl) {
        codeEl.textContent = "Contacting autopoiesis.art...";
        codeEl.classList.remove("error");
      }
      const response = await fetch("/local/pairing/start", { method: "POST" });
      const data = await response.json().catch(() => ({}));
      if (!response.ok || !data.ok) {
        if (codeEl) {
          codeEl.textContent = data.error || "Could not get a web pairing code.";
          codeEl.classList.add("error");
        }
        button.disabled = false;
        return;
      }
      location.reload();
    });
    document.querySelector("[data-check-pairing]").addEventListener("click", async () => {
      await fetch("/local/pairing/check", { method: "POST" });
      location.reload();
    });
    document.getElementById("settings-form").addEventListener("submit", async (event) => {
      event.preventDefault();
      const form = new FormData(event.currentTarget);
      await fetch("/local/settings", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          device: { deviceName: form.get("deviceName") },
          preferences: {
            volume: Number(form.get("volume")),
            imageDuration: Number(form.get("imageDuration")),
            soundEnabled: form.has("soundEnabled"),
            nightMode: form.has("nightMode"),
            nightModeStart: form.get("nightModeStart") || "22:00",
            nightModeEnd: form.get("nightModeEnd") || "08:00"
          }
        })
      });
      location.reload();
    });
    const setupNightCb = document.querySelector("#settings-form [name=\"nightMode\"]");
    const setupNightTimes = document.querySelector("#settings-form .welcome-night-times");
    if (setupNightCb && setupNightTimes) setupNightCb.addEventListener("change", () => setupNightTimes.hidden = !setupNightCb.checked);`
  );
}

function renderSettings() {
  const data = status();
  const feed = readJson(paths.feed, { items: [] });
  const knownArtists = [
    ["sandman", "Sandman"],
    ["vessel", "Vessel"],
    ["jessy", "Jessy"],
    ["kinema", "Kinema"],
    ["spool", "Spool"],
    ["link", "Link"],
    ["typo", "Typo"]
  ];
  const feedArtists = Array.from(new Set((feed.items || [])
    .map(item => item.artistId || item.artist || item.raw && (item.raw.artistId || item.raw.artist || item.raw.artistName))
    .filter(Boolean)
    .map(value => String(value))));
  for (const artist of feedArtists) {
    const key = artist.toLowerCase();
    if (!knownArtists.some(([id]) => id === key)) knownArtists.push([key, artist]);
  }
  const activeArtists = new Set(normalizedList(data.preferences.activeArtists));
  const streamCategories = new Set(normalizedList(data.preferences.streamCategories || ["artwork", "broadcast", "curatorial", "blog", "news"]));
  const artistControls = knownArtists.map(([id, label]) =>
    '<label class="check"><input name="activeArtists" type="checkbox" value="' + escapeHtml(id) + '" ' + (activeArtists.has(id) ? "checked" : "") + '> ' + escapeHtml(label) + '</label>'
  ).join("");
  const categoryControls = [
    ["artwork", "Artworks"],
    ["broadcast", "Broadcasts"],
    ["curatorial", "Curatorial notes"],
    ["blog", "Blogs"],
    ["news", "System news"]
  ].map(([id, label]) =>
    '<label class="check"><input name="streamCategories" type="checkbox" value="' + escapeHtml(id) + '" ' + (streamCategories.has(id) ? "checked" : "") + '> ' + escapeHtml(label) + '</label>'
  ).join("");
  return page(
    "Autopoiesis Settings",
    `<main class="screen">
      <section class="panel wide">
        <p class="kicker">Local settings</p>
        <h1>Frame preferences</h1>
        <form id="settings-form" class="grid">
          <label>Device name <input name="deviceName" value="${escapeHtml(data.device.deviceName || "")}"></label>
          <label>Display mode
            <select name="displayMode">
              <option value="living-stream" ${data.preferences.displayMode === "living-stream" ? "selected" : ""}>Living stream</option>
              <option value="local-feed" ${data.preferences.displayMode === "local-feed" ? "selected" : ""}>Local device stream</option>
              <option value="dashboard" ${data.preferences.displayMode === "dashboard" ? "selected" : ""}>Dashboard</option>
            </select>
          </label>
          <label>Stream profile
            <select name="streamProfile">
              <option value="living-stream" ${data.preferences.streamProfile === "living-stream" ? "selected" : ""}>Living stream</option>
              <option value="artist-focus" ${data.preferences.streamProfile === "artist-focus" ? "selected" : ""}>Artist focus</option>
              <option value="exhibition" ${data.preferences.streamProfile === "exhibition" ? "selected" : ""}>Exhibition gateway</option>
              <option value="system-dashboard" ${data.preferences.streamProfile === "system-dashboard" ? "selected" : ""}>System dashboard</option>
            </select>
          </label>
          <label>Volume <input name="volume" type="number" min="0" max="100" value="${escapeHtml(data.preferences.volume ?? 50)}"></label>
          <label>Image duration <input name="imageDuration" type="number" min="5" max="3600" value="${escapeHtml(data.preferences.imageDuration ?? 60)}"></label>
          <fieldset class="setting-group">
            <legend>Artists</legend>
            <p class="note">Leave all artists off to use the full ecosystem stream.</p>
            <div class="check-grid">${artistControls}</div>
          </fieldset>
          <fieldset class="setting-group">
            <legend>Stream content</legend>
            <div class="check-grid">${categoryControls}</div>
          </fieldset>
          <fieldset class="setting-group">
            <legend>Media behavior</legend>
            <div class="check-grid">
              <label class="check"><input name="allowImages" type="checkbox" ${data.preferences.allowImages !== false ? "checked" : ""}> Images</label>
              <label class="check"><input name="allowVideos" type="checkbox" ${data.preferences.allowVideos !== false ? "checked" : ""}> Videos</label>
              <label class="check"><input name="allowSoundWorks" type="checkbox" ${data.preferences.allowSoundWorks !== false ? "checked" : ""}> Sound works</label>
              <label class="check"><input name="allowGenerativeWorks" type="checkbox" ${data.preferences.allowGenerativeWorks !== false ? "checked" : ""}> Generative works</label>
              <label class="check"><input name="autoplay" type="checkbox" ${data.preferences.autoplay !== false ? "checked" : ""}> Autoplay stream</label>
              <label class="check"><input name="videoAutoplay" type="checkbox" ${data.preferences.videoAutoplay !== false ? "checked" : ""}> Autoplay video</label>
              <label class="check"><input name="soundAutoplay" type="checkbox" ${data.preferences.soundAutoplay ? "checked" : ""}> Autoplay sound</label>
              <label class="check"><input name="showArtworkInfoOnTap" type="checkbox" ${data.preferences.showArtworkInfoOnTap !== false ? "checked" : ""}> Tap for artwork info</label>
            </div>
          </fieldset>
          <label class="check"><input name="soundEnabled" type="checkbox" ${data.preferences.soundEnabled ? "checked" : ""}> Sound enabled</label>
          <div class="welcome-night-toggle">
            <label class="check"><input name="nightMode" type="checkbox" ${data.preferences.nightMode ? "checked" : ""}> Night mode (turn off display at night)</label>
            <div class="welcome-night-times" ${data.preferences.nightMode ? "" : "hidden"}>
              <label>Turn off at <input name="nightModeStart" type="time" value="${escapeHtml(data.preferences.nightModeStart || "22:00")}"></label>
              <label>Turn on at <input name="nightModeEnd" type="time" value="${escapeHtml(data.preferences.nightModeEnd || "08:00")}"></label>
            </div>
          </div>
          <button class="primary" type="submit">Save</button>
          <a class="button" href="/dashboard">Dashboard</a>
          <a class="button" href="/frame">Frame</a>
        </form>
      </section>
    </main>`,
    `document.getElementById("settings-form").addEventListener("submit", async (event) => {
      event.preventDefault();
      const form = new FormData(event.currentTarget);
      await fetch("/local/settings", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          device: { deviceName: form.get("deviceName") },
          preferences: {
            displayMode: form.get("displayMode"),
            streamProfile: form.get("streamProfile"),
            activeArtists: form.getAll("activeArtists"),
            streamCategories: form.getAll("streamCategories"),
            volume: Number(form.get("volume")),
            imageDuration: Number(form.get("imageDuration")),
            allowImages: form.has("allowImages"),
            allowVideos: form.has("allowVideos"),
            allowSoundWorks: form.has("allowSoundWorks"),
            allowGenerativeWorks: form.has("allowGenerativeWorks"),
            autoplay: form.has("autoplay"),
            videoAutoplay: form.has("videoAutoplay"),
            soundAutoplay: form.has("soundAutoplay"),
            showArtworkInfoOnTap: form.has("showArtworkInfoOnTap"),
            soundEnabled: form.has("soundEnabled"),
            nightMode: form.has("nightMode"),
            nightModeStart: form.get("nightModeStart") || "22:00",
            nightModeEnd: form.get("nightModeEnd") || "08:00"
          }
        })
      });
      location.href = "/dashboard";
    });
    const settingsNightCb = document.querySelector("#settings-form [name=\"nightMode\"]");
    const settingsNightTimes = document.querySelector("#settings-form .welcome-night-times");
    if (settingsNightCb && settingsNightTimes) settingsNightCb.addEventListener("change", () => settingsNightTimes.hidden = !settingsNightCb.checked);`
  );
}

function renderDashboard() {
  const data = status();
  const frame = publicFrameState();
  const cache = publicOfflineCache();
  const playback = frame.playback || {};
  const sync = data.device.settingsSync || {};
  const serverUrl = String(data.device.serverUrl || "https://autopoiesis.art").replace(/\/$/, "");
  return page(
    "Autopoiesis Dashboard",
    `<main class="screen dashboard-screen">
      <section class="panel wide dashboard-panel">
        <p class="kicker">Autopoiesis OS</p>
        <h1>Dashboard</h1>
        <p class="muted">A local gateway into the ecosystem: display state, device health, stream progress, exhibitions, and writing.</p>
        <div class="dashboard-grid">
          <article class="dash-tile"><strong>${escapeHtml(frame.playableItems)}</strong><span>Playable stream items</span></article>
          <article class="dash-tile"><strong>${escapeHtml(cache.playableItems)}</strong><span>Cached works available offline</span></article>
          <article class="dash-tile"><strong>${escapeHtml(data.network && data.network.online ? "online" : "offline")}</strong><span>Network</span></article>
          <article class="dash-tile"><strong>${escapeHtml(playback.status || "unknown")}</strong><span>Playback readiness</span></article>
        </div>
        <dl class="status compact">
          <div><dt>Device</dt><dd>${escapeHtml(data.device.deviceName || data.device.deviceId || "unknown")}</dd></div>
          <div><dt>Mode</dt><dd>${escapeHtml(data.preferences.displayMode || data.state.currentMode || "living-stream")}</dd></div>
          <div><dt>Stream</dt><dd>${escapeHtml(data.preferences.streamProfile || "living-stream")}</dd></div>
          <div><dt>Artists</dt><dd>${escapeHtml((data.preferences.activeArtists || []).length ? data.preferences.activeArtists.join(", ") : "All artists")}</dd></div>
          <div><dt>Feed sync</dt><dd>${escapeHtml(frame.syncedAt || "never")}</dd></div>
          <div><dt>Settings sync</dt><dd>${escapeHtml(sync.status || "local")}</dd></div>
        </dl>
        <div class="actions gateway-actions">
          <a class="button primary" href="/frame">Open frame</a>
          <a class="button" href="/settings">Settings</a>
          <a class="button" href="${escapeHtml(serverUrl)}/blog">Blogs</a>
          <a class="button" href="${escapeHtml(serverUrl)}/exhibitions">Exhibitions</a>
          <a class="button" href="${escapeHtml(serverUrl)}">Gallery</a>
        </div>
      </section>
    </main>`
  );
}

function renderNetwork() {
  return page(
    "Autopoiesis Network",
    `<main class="screen">
      <section class="panel wide">
        <p class="kicker">Local network</p>
        <h1>Network</h1>
        <div id="network-status" class="status"></div>
        <div class="actions">
          <button data-refresh-network>Refresh</button>
          <button data-connect-lan>Use LAN</button>
          <a class="button" href="/local/wifi/scan">Scan Wi-Fi</a>
          <a class="button primary" href="/setup">Back</a>
        </div>
        <p class="note">LAN uses Ethernet with DHCP through NetworkManager when available.</p>
      </section>
    </main>`,
    `const statusEl = document.getElementById("network-status");
function row(label, value) {
  return "<div><dt>" + label + "</dt><dd>" + value + "</dd></div>";
}
async function refreshNetwork() {
  statusEl.innerHTML = row("Status", "Checking...");
  const response = await fetch("/local/network/status");
  const data = await response.json();
  const network = data.network || {};
  const lan = network.lan || {};
  const wifi = network.wifi || {};
  statusEl.innerHTML = [
    row("Status", network.online ? "Online" : "Offline"),
    row("Primary", network.primary || "none"),
    row("LAN", lan.available ? ((lan.connected ? "Connected" : "Available") + (lan.device ? " on " + lan.device : "")) : "Unavailable"),
    row("Wi-Fi", wifi.available ? ((wifi.connected ? "Connected" : "Available") + (wifi.device ? " on " + wifi.device : "")) : "Unavailable")
  ].join("");
}
document.querySelector("[data-refresh-network]").addEventListener("click", refreshNetwork);
document.querySelector("[data-connect-lan]").addEventListener("click", async () => {
  await fetch("/local/lan/connect", { method: "POST" });
  await refreshNetwork();
});
refreshNetwork();`
  );
}

function renderWifiScan() {
  return page(
    "Autopoiesis Wi-Fi",
    `<style>
      .network-list .network-row {
        display: flex; justify-content: space-between; align-items: center;
        width: 100%; padding: 14px 16px; margin: 4px 0; text-align: left;
        border: 1px solid rgba(255,255,255,0.08); border-radius: 8px;
        background: rgba(255,255,255,0.03); cursor: pointer;
        transition: background 0.15s, border-color 0.15s; font-size: 1rem;
      }
      .network-list .network-row:hover,
      .network-list .network-row:active { background: rgba(255,255,255,0.08); border-color: rgba(255,255,255,0.16); }
      .network-row .ssid { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .network-row .meta { display: flex; align-items: center; gap: 8px; flex-shrink: 0; margin-left: 12px; }
      .signal-bars { display: inline-flex; align-items: flex-end; gap: 2px; height: 16px; }
      .signal-bars .bar { width: 4px; border-radius: 1px; background: rgba(255,255,255,0.18); }
      .signal-bars.excellent .bar:nth-child(-n+4) { background: rgba(255,255,255,0.7); }
      .signal-bars.good .bar:nth-child(-n+3) { background: rgba(255,255,255,0.7); }
      .signal-bars.fair .bar:nth-child(-n+2) { background: rgba(255,255,255,0.7); }
      .signal-bars.weak .bar:nth-child(1) { background: rgba(255,255,255,0.7); }
      .security-badge { font-size: 0.8rem; opacity: 0.5; }
      .hidden-network-note { margin: 12px 0; padding: 12px; border-radius: 8px; background: rgba(255,255,255,0.04); }
    </style>
    <main class="screen">
      <section class="panel wide">
        <p class="kicker">Local network</p>
        <h1>Wi-Fi</h1>
        <div id="wifi-list" class="network-list"></div>
        <form id="wifi-form" class="grid">
          <label>Network name <input name="ssid" autocomplete="off" required></label>
          <label>Password <input name="password" type="password" autocomplete="current-password"></label>
          <button class="primary" type="submit">Connect</button>
          <a class="button" href="/network">Back</a>
        </form>
      </section>
    </main>`,
    `const list = document.getElementById("wifi-list");
const form = document.getElementById("wifi-form");
function escapeText(value) {
  return String(value).replace(/[&<>"]/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[char]));
}
function signalBarsHTML(quality) {
  const heights = [4, 7, 11, 16];
  return '<span class="signal-bars ' + quality + '">' +
    heights.map(h => '<span class="bar" style="height:' + h + 'px"></span>').join('') +
    '</span>';
}
async function scanWifi() {
  list.textContent = "Scanning...";
  const response = await fetch("/local/wifi/scan.json");
  const data = await response.json();
  if (!data.ok) {
    list.textContent = data.error || "Wi-Fi scan unavailable.";
    return;
  }
  if (data.networks.length === 0) {
    list.innerHTML = '<p>No Wi-Fi networks found.</p>' +
      '<p class="hidden-network-note">If your network is hidden, enter the name manually below.</p>';
    return;
  }
  list.innerHTML = data.networks.map(network => {
    const quality = network.signalQuality || 'weak';
    const secType = network.securityType || 'open';
    return '<button type="button" class="network-row" data-ssid="' + escapeText(network.ssid) + '">' +
      '<span class="ssid">' + escapeText(network.ssid) + '</span>' +
      '<span class="meta">' +
        signalBarsHTML(quality) +
        '<span class="security-badge">' + escapeText(secType) + '</span>' +
      '</span>' +
    '</button>';
  }).join('');
  list.querySelectorAll('[data-ssid]').forEach(button => {
    button.addEventListener('click', () => {
      form.elements.ssid.value = button.dataset.ssid;
      form.elements.password.focus();
    });
  });
}
form.addEventListener('submit', async event => {
  event.preventDefault();
  const submitBtn = form.querySelector('button[type=submit]');
  submitBtn.textContent = 'Connecting...';
  submitBtn.disabled = true;
  const body = {
    ssid: form.elements.ssid.value,
    password: form.elements.password.value
  };
  const response = await fetch('/local/wifi/connect', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body)
  });
  const data = await response.json();
  if (data.ok) {
    list.innerHTML = '<p>Connected. Returning to network status...</p>';
    setTimeout(() => { location.href = '/network'; }, 900);
  } else {
    list.innerHTML = '<p>' + escapeText(data.error || 'Connection failed. Check password and try again.') + '</p>';
    submitBtn.textContent = 'Connect';
    submitBtn.disabled = false;
  }
});
scanWifi();`
  );
}

function renderOffline() {
  const data = status();
  const cache = publicOfflineCache();
  const retrySeconds = Number.isFinite(OFFLINE_RETRY_SECONDS) && OFFLINE_RETRY_SECONDS > 0
    ? OFFLINE_RETRY_SECONDS
    : 30;
  const durationSeconds = Number(data.preferences.imageDuration || 30);
  const rotationSeconds = Number.isFinite(durationSeconds) && durationSeconds > 0
    ? Math.min(Math.max(durationSeconds, 8), 300)
    : 30;
  const hasCachedMedia = cache.playableItems > 0;
  return page(
    "Autopoiesis Offline",
    `<main class="screen fallback offline-screen">
      <section class="${hasCachedMedia ? "offline-gallery" : "offline-empty"}">
        <p class="kicker">Autopoiesis Frame</p>
        <h1>${hasCachedMedia ? "Offline cache" : "Offline mode"}</h1>
        <p>${hasCachedMedia ? "The frame is showing cached Autopoiesis work while the network is unavailable." : "The frame is keeping a calm local fallback ready while the network is unavailable."}</p>
        ${hasCachedMedia ? `<div id="offline-stage" class="offline-stage" aria-live="polite"></div>` : ""}
        <dl class="status">
          <div><dt>Device</dt><dd>${escapeHtml(data.device.deviceId || "unknown")}</dd></div>
          <div><dt>Last check</dt><dd>${escapeHtml(data.state.lastOfflineFallbackAt || "pending")}</dd></div>
          <div><dt>Cached</dt><dd>${escapeHtml(cache.playableItems)} playable / ${escapeHtml(cache.indexedItems)} indexed</dd></div>
          <div><dt>Retry</dt><dd>${escapeHtml(retrySeconds)} seconds</dd></div>
        </dl>
      </section>
    </main>`,
    `const offlineItems = ${scriptJson(cache.items)};
    let offlineIndex = 0;
    const stage = document.getElementById("offline-stage");
    function escapeText(value) {
      return String(value || "").replace(/[&<>"]/g, char => {
        if (char === "&") return "&amp;";
        if (char === "<") return "&lt;";
        if (char === ">") return "&gt;";
        return "&quot;";
      });
    }
    function isVideo(item, url) {
      return /video/i.test(item.type || "") || /\\.(mp4|webm|mov)(\\?|$)/i.test(url || "");
    }
    function renderCachedItem() {
      if (!stage || !offlineItems.length) return;
      const item = offlineItems[offlineIndex % offlineItems.length];
      const asset = item.media && item.media.available ? item.media : item.thumbnail;
      const media = isVideo(item, asset.url)
        ? "<video src=\"" + asset.url + "\" autoplay muted loop playsinline></video>"
        : "<img src=\"" + asset.url + "\" alt=\"\">";
      const meta = [item.artist, item.type].filter(Boolean).map(escapeText).join(" / ");
      stage.innerHTML = media + "<div class=\"offline-caption\"><strong>" + escapeText(item.title || item.id) + "</strong>" + (meta ? "<span>" + meta + "</span>" : "") + "</div>";
      offlineIndex += 1;
    }
    renderCachedItem();
    if (offlineItems.length > 1) setInterval(renderCachedItem, ${Math.round(rotationSeconds * 1000)});
    setTimeout(() => { location.href = "/launch"; }, ${Math.round(retrySeconds * 1000)});`
  );
}

function renderFrame() {
  const data = status();
  const frame = publicFrameState();
  const preferences = data.preferences || {};
  const imageDurationMs = frameItemDisplayMs({}, preferences);
  updateState({
    currentMode: "frame",
    localFrameActive: true,
    lastLocalFrameAt: new Date().toISOString()
  });
  const hasItems = frame.playableItems > 0;
  const frameBody = hasItems
    ? '<div id="frame-stage" class="frame-stage" aria-live="polite"></div>'
    : [
        "<h1>Waiting for the living stream.</h1>",
        "<p>The local display queue is empty. The frame will try to sync feed items and check again.</p>",
        '<dl class="status compact">',
        "<div><dt>Synced</dt><dd>" + escapeHtml(frame.syncedAt || "never") + "</dd></div>",
        "<div><dt>Device</dt><dd>" + escapeHtml(data.device.deviceId || "unknown") + "</dd></div>",
        "</dl>"
      ].join("");
  return page(
    "Autopoiesis Frame",
    `<main class="screen frame-screen">
      <section class="${hasItems ? "frame-gallery" : "frame-empty"}">
        <div class="frame-topline">
          <p class="kicker">Autopoiesis Frame</p>
          <p class="frame-count">${escapeHtml(frame.playableItems)} items</p>
        </div>
        ${frameBody}
      </section>
      <aside id="frame-overlay" class="frame-overlay" hidden></aside>
    </main>`,
    `const frameItems = ${scriptJson(frame.items)};
    const frameSettings = ${scriptJson({
      soundEnabled: Boolean(preferences.soundEnabled),
      autoplay: preferences.autoplay !== false,
      videoAutoplay: preferences.videoAutoplay !== false,
      soundAutoplay: Boolean(preferences.soundAutoplay),
      showArtworkInfoOnTap: preferences.showArtworkInfoOnTap !== false,
      imageDurationMs,
      pollAfterSeconds: frame.pollingStatus && frame.pollingStatus.pollAfterSeconds ? frame.pollingStatus.pollAfterSeconds : 900,
      offlineRetrySeconds: OFFLINE_RETRY_SECONDS,
      currentItemCount: frame.playableItems || 0
    })};
    const FADE_MS = 600;
    let frameIndex = 0;
    let currentItem = null;
    let frameTimer = null;
    let isFirstFrame = true;
    const stage = document.getElementById("frame-stage");
    const overlay = document.getElementById("frame-overlay");
    function escapeText(value) {
      return String(value || "").replace(/[&<>"]/g, char => {
        if (char === "&") return "&amp;";
        if (char === "<") return "&lt;";
        if (char === ">") return "&gt;";
        return "&quot;";
      });
    }
    function escapeAttr(value) {
      return escapeText(value).replace(/'/g, "&#39;");
    }
    function itemDisplayMs(item) {
      const value = Number(item && item.displayMs);
      return Number.isFinite(value) && value > 0 ? Math.min(Math.max(value, 2000), 86400000) : frameSettings.imageDurationMs;
    }
    function mediaMarkup(item) {
      const media = item.media || {};
      const url = media.url || "";
      if (!url) return "";
      if (media.role === "video") {
        const muted = frameSettings.soundEnabled ? "" : " muted";
        const autoplay = frameSettings.autoplay && frameSettings.videoAutoplay ? " autoplay" : "";
        return "<video src=\\\"" + escapeAttr(url) + "\\\"" + autoplay + muted + " playsinline></video>";
      }
      if (media.role === "audio") {
        const muted = frameSettings.soundEnabled ? "" : " muted";
        const autoplay = frameSettings.autoplay && frameSettings.soundAutoplay ? " autoplay" : "";
        return "<div class=\\\"frame-audio-work\\\"><audio src=\\\"" + escapeAttr(url) + "\\\"" + autoplay + muted + " playsinline></audio><strong>" + escapeText(item.title || "Sound work") + "</strong><span>" + escapeText(item.artist || "Autopoiesis") + "</span></div>";
      }
      return "<img src=\\\"" + escapeAttr(url) + "\\\" alt=\\\"\\\">";
    }
    function linkButton(url, label) {
      return url ? "<a class=\\\"button\\\" href=\\\"" + escapeAttr(url) + "\\\">" + escapeText(label) + "</a>" : "";
    }
    function renderOverlay(item, liked) {
      if (!overlay || !item) return;
      const meta = [item.artist, item.displayCategory, item.media && item.media.cached ? "cached" : ""].filter(Boolean).map(escapeText).join(" / ");
      overlay.innerHTML =
        "<div class=\\\"overlay-card\\\">" +
        "<button class=\\\"overlay-close\\\" type=\\\"button\\\" data-close-overlay>Close</button>" +
        "<p class=\\\"kicker\\\">" + (meta || "Autopoiesis artwork") + "</p>" +
        "<h2>" + escapeText(item.title || item.id) + "</h2>" +
        (item.body ? "<p>" + escapeText(item.body) + "</p>" : "") +
        "<div class=\\\"actions overlay-actions\\\">" +
        "<button class=\\\"primary\\\" type=\\\"button\\\" data-like-item>" + (liked || item.liked ? "Liked" : "Like") + "</button>" +
        "<a class=\\\"button\\\" href=\\\"/settings\\\">Settings</a>" +
        "<a class=\\\"button\\\" href=\\\"/dashboard\\\">Dashboard</a>" +
        linkButton(item.infoUrl || item.url, "Artwork") +
        linkButton(item.blogUrl, "Blog") +
        linkButton(item.exhibitionUrl, "Exhibition") +
        "</div></div>";
      overlay.querySelector("[data-close-overlay]").addEventListener("click", () => { overlay.hidden = true; });
      overlay.querySelector("[data-like-item]").addEventListener("click", async event => {
        event.currentTarget.textContent = "Liked";
        const response = await fetch("/local/frame/like", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ itemId: item.id })
        }).catch(() => null);
        item.liked = true;
        if (!response || !response.ok) event.currentTarget.textContent = "Liked locally";
      });
    }
    function scheduleNext(item) {
      clearTimeout(frameTimer);
      const media = stage ? stage.querySelector("video,audio") : null;
      let advanced = false;
      const advance = () => {
        if (advanced) return;
        advanced = true;
        transitionToNext();
      };
      if (media) media.addEventListener("ended", advance, { once: true });
      frameTimer = setTimeout(advance, itemDisplayMs(item));
    }
    function transitionToNext() {
      if (overlay) overlay.hidden = true;
      if (isFirstFrame || !stage) {
        isFirstFrame = false;
        renderFrameItem();
        return;
      }
      stage.classList.add("fading");
      setTimeout(() => {
        renderFrameItem();
        requestAnimationFrame(() => {
          requestAnimationFrame(() => {
            stage.classList.remove("fading");
          });
        });
      }, FADE_MS);
    }
    function renderFrameItem() {
      if (!stage || !frameItems.length) {
        if (!frameItems.length) {
          const emptyRetryMs = Math.max(frameSettings.offlineRetrySeconds * 1000, 10000);
          fetch("/local/feed/sync", { method: "POST" }).finally(() => {
            setTimeout(() => { location.reload(); }, emptyRetryMs);
          });
        }
        return;
      }
      const item = frameItems[frameIndex % frameItems.length];
      currentItem = item;
      const media = mediaMarkup(item);
      stage.innerHTML = media ? "<figure class=\\"frame-media\\">" + media + "</figure>" : "<div class=\\"frame-media text-only\\"><strong>" + escapeText(item.title || item.id) + "</strong></div>";
      renderOverlay(item, item.liked);
      fetch("/local/frame/display", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ itemId: item.id })
      }).catch(() => {});
      frameIndex += 1;
      scheduleNext(item);
    }
    if (stage && overlay) {
      stage.addEventListener("click", () => {
        if (!frameSettings.showArtworkInfoOnTap || !currentItem) return;
        renderOverlay(currentItem, currentItem.liked);
        overlay.hidden = !overlay.hidden;
      });
      overlay.addEventListener("click", event => {
        if (event.target === overlay) overlay.hidden = true;
      });
    }
    transitionToNext();
    const pollIntervalMs = Math.max(60, frameSettings.pollAfterSeconds) * 1000;
    let lastKnownItemCount = frameSettings.currentItemCount;
    function kioskFeedSync() {
      fetch("/local/feed/sync", { method: "POST" })
        .then(r => r.json().catch(() => null))
        .then(result => {
          if (!result) return;
          const newItemCount = Number(result.eligibleItems || result.totalItems || 0);
          if (result.ok && newItemCount > 0 && newItemCount !== lastKnownItemCount) {
            lastKnownItemCount = newItemCount;
            setTimeout(() => location.reload(), FADE_MS);
          }
        })
        .catch(() => {});
    }
    setInterval(kioskFeedSync, pollIntervalMs);`
  );
}

function nightModeState(preferences) {
  const prefs = preferences || readJson(paths.preferences, {});
  const enabled = Boolean(prefs.nightMode);
  if (!enabled) return { active: false, enabled: false };
  const start = prefs.nightModeStart || "22:00";
  const end = prefs.nightModeEnd || "08:00";
  const now = new Date();
  const startMin = parseTimeToMinutes(start);
  const endMin = parseTimeToMinutes(end);
  if (startMin === null || endMin === null) return { active: false, enabled, start, end };
  const nowMin = now.getHours() * 60 + now.getMinutes();
  const active = startMin <= endMin
    ? (nowMin >= startMin && nowMin < endMin)
    : (nowMin >= startMin || nowMin < endMin);
  return { active, enabled, start, end, nowMin, startMin, endMin };
}

function parseTimeToMinutes(value) {
  if (!value) return null;
  const match = String(value).match(/^(\d{1,2}):(\d{2})$/);
  if (!match) return null;
  const h = Number(match[1]);
  const m = Number(match[2]);
  if (h > 23 || m > 59) return null;
  return h * 60 + m;
}

function displayPowerCommand(on) {
  const onOrOff = on ? "1" : "0";
  return { cmd: VCGENCMD_BIN, args: ["display_power", onOrOff] };
}

function applyNightMode() {
  const prefs = readJson(paths.preferences, {});
  const nm = nightModeState(prefs);
  if (!nm.enabled) return;
  if (nm.active && prefs._nightModeDisplayOn !== false) {
    const { cmd, args } = displayPowerCommand(false);
    execFile(cmd, args, () => {});
    writeJson(paths.preferences, { ...prefs, _nightModeDisplayOn: false });
  } else if (!nm.active && prefs._nightModeDisplayOn === false) {
    const { cmd, args } = displayPowerCommand(true);
    execFile(cmd, args, () => {});
    writeJson(paths.preferences, { ...prefs, _nightModeDisplayOn: true });
  }
}

function renderWelcome() {
  const data = status();
  const network = data.network || {};
  const pairing = data.pairing || {};
  const networkOnline = Boolean(network.online);
  const paired = Boolean(data.device.paired);
  const hasName = Boolean(data.device.deviceName && data.device.deviceName !== "Autopoiesis Frame");
  const preferences = data.preferences || {};
  const nightEnabled = Boolean(preferences.nightMode);
  const nightStart = preferences.nightModeStart || "22:00";
  const nightEnd = preferences.nightModeEnd || "08:00";
  const allDone = networkOnline && paired;
  const stepsCompleted = [networkOnline, paired].filter(Boolean).length;
  const currentStep = !networkOnline ? 0 : !paired ? 1 : 2;
  const stepLabels = ["Connect", "Pair", "Enjoy"];
  const dots = stepLabels.map((label, i) => {
    const cls = i < currentStep ? "done" : i === currentStep ? "current" : "";
    return `<button type="button" class="welcome-dot ${cls}" data-welcome-dot="${i}">${label}</button>`;
  }).join("");
  const pairingCode = pairing.pairingCode || "";
  const pairingError = pairing.error || "";
  const pairingMock = pairing.mock || false;
  return page(
    "Welcome — Autopoiesis Frame",
    `<main class="screen welcome-screen">
      <section class="panel wide welcome-panel">
        <div class="welcome-header">
          <p class="kicker">Welcome to</p>
          <h1>Autopoiesis Frame</h1>
          <p class="muted">Let\u2019s get your frame set up. This takes about two minutes.</p>
        </div>

        <div class="welcome-progress">${dots}</div>

        <div class="welcome-steps" data-step="${currentStep}">

          <div class="welcome-step" data-welcome-step="0" ${currentStep !== 0 ? "hidden" : ""}>
            <h2>Connect to the internet</h2>
            <p>Your frame needs internet to receive art from the Autopoiesis ecosystem.</p>
            <dl class="status compact">
              <div><dt>Status</dt><dd id="welcome-network-state">${escapeHtml(networkOnline ? (network.primary || "network") + " connected" : "Not connected")}</dd></div>
            </dl>
            <div class="actions">
              <button data-welcome-check-network>Check again</button>
              <a class="button" href="/local/wifi/scan">Choose Wi-Fi</a>
            </div>
          </div>

          <div class="welcome-step" data-welcome-step="1" ${currentStep !== 1 ? "hidden" : ""}>
            <h2>Pair your frame</h2>
            <p>Go to <strong>autopoiesis.art/profile/frames</strong> and enter this pairing code:</p>
            <div class="pairing-code ${pairingError || pairingMock ? "error" : ""}">${escapeHtml(pairingError || pairingCode || "Loading...")}</div>
            ${pairingError || pairingMock ? `<p class="setup-error">${escapeHtml(pairingError || "This local fallback code cannot pair with the web app. Request a real web pairing code.")}</p>` : ""}
            <div class="actions">
              <button data-welcome-start-pairing ${networkOnline ? "" : "disabled"}>Get pairing code</button>
              <button data-welcome-check-pairing ${networkOnline ? "" : "disabled"}>I entered the code</button>
            </div>
          </div>

          <div class="welcome-step" data-welcome-step="2" ${currentStep !== 2 ? "hidden" : ""}>
            <h2>Your frame is ready</h2>
            <p>The living stream is about to start. You can always adjust settings later.</p>
            <form id="welcome-final-form" class="grid compact-form">
              <label>Device name <input name="deviceName" value="${escapeHtml(data.device.deviceName || "")}" placeholder="Living Room Frame"></label>
              <label>Image duration (seconds) <input name="imageDuration" type="number" min="15" max="300" step="15" value="${preferences.imageDuration ?? 60}"></label>
              <label>Volume <input name="volume" type="number" min="0" max="100" step="5" value="${preferences.volume ?? 50}"></label>
              <label class="check"><input name="soundEnabled" type="checkbox" ${preferences.soundEnabled ? "checked" : ""}> Sound enabled</label>
              <div class="welcome-night-toggle">
                <label class="check"><input name="nightMode" type="checkbox" ${nightEnabled ? "checked" : ""}> Night mode (turn off display at night)</label>
                <div class="welcome-night-times" ${nightEnabled ? "" : "hidden"}>
                  <label>Turn off at <input name="nightModeStart" type="time" value="${escapeHtml(nightStart)}"></label>
                  <label>Turn on at <input name="nightModeEnd" type="time" value="${escapeHtml(nightEnd)}"></label>
                </div>
              </div>
              <button class="primary launch" type="submit">Start the living stream \u2192</button>
            </form>
          </div>

        </div>

        <p class="note welcome-footer">Device: ${escapeHtml(data.device.deviceId || "unknown")}</p>
      </section>
    </main>`,
    `const currentStep = ${currentStep};
    const steps = document.querySelectorAll("[data-welcome-step]");
    const dots = document.querySelectorAll("[data-welcome-dot]");
    function showStep(index) {
      steps.forEach((step, i) => step.hidden = i !== index);
      dots.forEach((dot, i) => {
        dot.classList.toggle("current", i === index);
        dot.classList.toggle("done", i < index);
      });
      document.querySelector(".welcome-steps").dataset.step = index;
    }
    dots.forEach(dot => dot.addEventListener("click", () => showStep(Number(dot.dataset.welcomeDot))));

    // Network refresh
    const checkBtn = document.querySelector("[data-welcome-check-network]");
    if (checkBtn) checkBtn.addEventListener("click", async () => {
      checkBtn.disabled = true;
      checkBtn.textContent = "Checking...";
      const resp = await fetch("/local/network/status");
      const data = await resp.json().catch(() => ({}));
      const online = data.network && data.network.online;
      document.getElementById("welcome-network-state").textContent = online ? (data.network.primary || "network") + " connected" : "Not connected";
      if (online) location.reload();
      else checkBtn.disabled = false;
    });

    // Pairing
    const startPairBtn = document.querySelector("[data-welcome-start-pairing]");
    if (startPairBtn) startPairBtn.addEventListener("click", async () => {
      startPairBtn.disabled = true;
      const codeEl = document.querySelector(".pairing-code");
      if (codeEl) { codeEl.textContent = "Getting code..."; codeEl.classList.remove("error"); }
      const resp = await fetch("/local/pairing/start", { method: "POST" });
      const data = await resp.json().catch(() => ({}));
      if (!resp.ok || !data.ok) {
        if (codeEl) { codeEl.textContent = data.error || "Could not get a pairing code."; codeEl.classList.add("error"); }
        startPairBtn.disabled = false;
        return;
      }
      location.reload();
    });

    const checkPairBtn = document.querySelector("[data-welcome-check-pairing]");
    if (checkPairBtn) checkPairBtn.addEventListener("click", async () => {
      checkPairBtn.disabled = true;
      await fetch("/local/pairing/check", { method: "POST" });
      location.reload();
    });

    // Night mode toggle
    const nightCheckbox = document.querySelector("#welcome-final-form [name=\"nightMode\"]");
    const nightTimes = document.querySelector(".welcome-night-times");
    if (nightCheckbox && nightTimes) {
      nightCheckbox.addEventListener("change", () => nightTimes.hidden = !nightCheckbox.checked);
    }

    // Final form submit
    const form = document.getElementById("welcome-final-form");
    if (form) form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const fd = new FormData(form);
      await fetch("/local/settings", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          device: { deviceName: fd.get("deviceName") },
          preferences: {
            volume: Number(fd.get("volume")),
            imageDuration: Number(fd.get("imageDuration")),
            soundEnabled: fd.has("soundEnabled"),
            nightMode: fd.has("nightMode"),
            nightModeStart: fd.get("nightModeStart") || "22:00",
            nightModeEnd: fd.get("nightModeEnd") || "08:00"
          }
        })
      });
      location.href = "/launch?completeOnboarding=1";
    });`
  );
}

function renderDisabled() {
  return page(
    "Autopoiesis Inactive",
    `<main class="screen fallback">
      <section>
        <p class="kicker">Autopoiesis Frame</p>
        <h1>This Autopoiesis Frame is currently inactive.</h1>
        <p>Please check your account or contact support.</p>
      </section>
    </main>`
  );
}

function renderBroadcast() {
  const broadcast = recordBroadcastShown(activeBroadcast());
  if (!broadcast) {
    return page(
      "Autopoiesis Broadcast",
      `<main class="screen fallback">
        <section>
          <p class="kicker">Autopoiesis Broadcast</p>
          <h1>No active broadcast.</h1>
          <p>The frame will return to the living stream.</p>
        </section>
      </main>`,
      `setTimeout(() => { location.href = "/launch"; }, 1200);`
    );
  }
  const duration = Number(broadcast.duration || broadcast.durationSeconds || 20);
  const safeDuration = Number.isFinite(duration) && duration > 0 ? Math.min(duration, 3600) : 20;
  const body = broadcast.body || broadcast.message || "";
  const mediaUrl = broadcast.mediaUrl || broadcast.media_url || broadcast.imageUrl || null;
  const media = mediaUrl
    ? `<figure class="broadcast-media"><img src="${escapeHtml(mediaUrl)}" alt=""></figure>`
    : "";
  const expiry = broadcast.expiresAt
    ? `<div><dt>Expires</dt><dd>${escapeHtml(broadcast.expiresAt)}</dd></div>`
    : "";
  return page(
    "Autopoiesis Broadcast",
    `<main class="screen broadcast-screen">
      <section class="broadcast-panel">
        <p class="kicker">${escapeHtml(broadcast.type || "broadcast")}</p>
        <h1>${escapeHtml(broadcast.title || "Autopoiesis Broadcast")}</h1>
        ${media}
        ${body ? `<p>${escapeHtml(body)}</p>` : ""}
        <dl class="status compact">
          <div><dt>Priority</dt><dd>${escapeHtml(broadcast.priority || "normal")}</dd></div>
          ${expiry}
        </dl>
      </section>
    </main>`,
    `setTimeout(() => {
      fetch("/local/broadcast/dismiss", { method: "POST" }).finally(() => { location.href = "/launch"; });
    }, ${Math.round(safeDuration * 1000)});`
  );
}

async function remoteLaunchReachable(targetUrl) {
  async function probe(method) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), LAUNCH_PROBE_TIMEOUT_MS);
    try {
      const response = await fetch(targetUrl, {
        method,
        redirect: "manual",
        signal: controller.signal
      });
      return response.status >= 200 && response.status < 500;
    } finally {
      clearTimeout(timeout);
    }
  }
  try {
    if (await probe("HEAD")) return true;
    return probe("GET");
  } catch {
    return false;
  }
}

async function renderLaunch(res, url = new URL("http://localhost/launch")) {
  const data = status();
  const completingOnboarding = url.searchParams.get("completeOnboarding") === "1";
  const localFrameRequested =
    url.searchParams.get("local") === "1" ||
    data.preferences.displayMode === "local-feed" ||
    data.preferences.displayMode === "local_frame";
  const dashboardRequested =
    url.searchParams.get("dashboard") === "1" ||
    data.preferences.displayMode === "dashboard" ||
    data.preferences.streamProfile === "system-dashboard";
  if (data.state.remoteDisabled || data.device.remoteEnabled === false) {
    updateState({ currentMode: "disabled" });
    redirect(res, "/disabled");
    return;
  }
  if (activeBroadcast()) {
    redirect(res, "/broadcast");
    return;
  }
  if (!data.device.firstRunComplete || !data.device.paired) {
    updateState({ currentMode: "setup" });
    redirect(res, "/welcome");
    return;
  }
  if (!data.device.onboardingComplete && !completingOnboarding) {
    updateState({ currentMode: "setup" });
    redirect(res, "/welcome");
    return;
  }
  if (completingOnboarding && !data.device.onboardingComplete) {
    writeJson(paths.device, {
      ...data.device,
      onboardingComplete: true,
      firstRunComplete: true
    });
  }
  if (dashboardRequested) {
    updateState({
      currentMode: "dashboard",
      lastLaunchAt: new Date().toISOString()
    });
    redirect(res, "/dashboard");
    return;
  }
  if (localFrameRequested) {
    updateState({
      currentMode: "frame",
      localFrameActive: true,
      lastLaunchAt: new Date().toISOString()
    });
    redirect(res, "/frame");
    return;
  }
  const launchUrl = data.device.framesUrl || "https://autopoiesis.art/display?shuffle=1";
  if (!(await remoteLaunchReachable(launchUrl))) {
    updateState({
      currentMode: "offline",
      networkOnline: false,
      lastOfflineFallbackAt: new Date().toISOString(),
      lastRemoteLaunchUrl: launchUrl
    });
    redirect(res, "/offline");
    return;
  }
  updateState({
    currentMode: "frame",
    networkOnline: true,
    lastLaunchAt: new Date().toISOString(),
    lastRemoteLaunchUrl: launchUrl
  });
  redirect(res, launchUrl);
}

function redirect(res, location) {
  res.writeHead(302, { location });
  res.end();
}

function sendJson(res, value, statusCode = 200) {
  res.writeHead(statusCode, { "content-type": "application/json" });
  res.end(`${JSON.stringify(value, null, 2)}\n`);
}

function sendCachedAsset(req, res, id, role) {
  const filePath = cachedAssetPath(decodeURIComponent(id), role);
  if (!filePath) return sendJson(res, { ok: false, error: "Cached asset not found" }, 404);
  const stats = fs.statSync(filePath);
  res.writeHead(200, {
    "content-type": contentTypeForPath(filePath),
    "content-length": stats.size,
    "cache-control": "private, max-age=3600"
  });
  if (req.method === "HEAD") {
    res.end();
    return;
  }
  fs.createReadStream(filePath).pipe(res);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", chunk => {
      body += chunk;
      if (body.length > 1_000_000) req.destroy();
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

/**
 * Classify signal strength into a human-readable quality label.
 * 80+ = excellent, 60+ = good, 40+ = fair, below = weak.
 */
function signalQuality(signal) {
  const s = Number(signal) || 0;
  if (s >= 80) return "excellent";
  if (s >= 60) return "good";
  if (s >= 40) return "fair";
  return "weak";
}

/**
 * Normalize nmcli security strings into a concise classification.
 * WPA3, WPA2, WPA, WEP, or open.
 */
function classifySecurity(security) {
  const raw = String(security || "").toUpperCase();
  if (raw.includes("WPA3")) return "WPA3";
  if (raw.includes("WPA2")) return "WPA2";
  if (raw.includes("WPA")) return "WPA";
  if (raw.includes("WEP")) return "WEP";
  return "open";
}

/**
 * Deduplicate raw nmcli scan results by SSID, keeping the entry with the
 * strongest signal per SSID, then sort by signal strength descending.
 * Returns a new array with signalQuality and securityType added.
 */
function deduplicateWifiNetworks(raw) {
  const bySsid = Object.create(null);
  for (const entry of raw) {
    if (!entry || !entry.ssid) continue;
    const existing = bySsid[entry.ssid];
    if (!existing || entry.signal > existing.signal) {
      bySsid[entry.ssid] = entry;
    }
  }
  return Object.values(bySsid)
    .map(n => ({
      ssid: n.ssid,
      signal: n.signal,
      security: n.security || "",
      securityType: classifySecurity(n.security),
      signalQuality: signalQuality(n.signal)
    }))
    .sort((a, b) => b.signal - a.signal);
}

function scanWifi(callback) {
  execFile("nmcli", ["-t", "-f", "SSID,SIGNAL,SECURITY", "device", "wifi", "list"], (error, stdout) => {
    if (error) {
      callback(null, {
        ok: false,
        error: "Wi-Fi scan unavailable. NetworkManager/nmcli may not be installed or accessible.",
        networks: []
      });
      return;
    }
    const raw = stdout
      .split("\n")
      .filter(Boolean)
      .map(line => {
        const [ssid, signal, security] = splitNmcliLine(line);
        return { ssid, signal: Number(signal), security };
      });
    const networks = deduplicateWifiNetworks(raw);
    callback(null, { ok: true, networks });
  });
}

function connectWifi(ssid, password, callback) {
  if (!ssid) {
    callback(null, { ok: false, error: "Missing SSID" });
    return;
  }
  const args = ["device", "wifi", "connect", ssid];
  if (password) args.push("password", password);
  execFile("nmcli", args, (error, stdout, stderr) => {
    if (error) {
      callback(null, { ok: false, error: stderr.trim() || error.message });
      return;
    }
    const device = readJson(paths.device, {});
    writeJson(paths.device, { ...device, wifiConfigured: true });
    callback(null, { ok: true, message: stdout.trim() });
  });
}

function connectLan(callback) {
  networkStatus((_, statusValue) => {
    const lan = statusValue.network && statusValue.network.lan;
    if (!lan || !lan.available || !lan.device) {
      callback(null, { ok: false, error: "No Ethernet/LAN device is available." });
      return;
    }
    if (lan.connected) {
      callback(null, { ok: true, message: "LAN is already connected.", network: statusValue.network });
      return;
    }
    execFile("nmcli", ["device", "connect", lan.device], (error, stdout, stderr) => {
      if (error) {
        callback(null, { ok: false, error: stderr.trim() || error.message });
        return;
      }
      networkStatus((__, refreshed) => callback(null, { ok: true, message: stdout.trim(), network: refreshed.network }));
    });
  });
}

function localPairingFallback(error) {
  const code = Math.random().toString(36).slice(2, 6).toUpperCase() + "-" + Math.floor(1000 + Math.random() * 9000);
  const device = readJson(paths.device, {});
  const pairing = {
    pairingCode: code,
    expiresAt: new Date(Date.now() + 15 * 60 * 1000).toISOString(),
    mock: true,
    error: error ? error.message : null
  };
  writeJson(paths.pairing, pairing);
  writeJson(paths.device, { ...device, pairingCode: code, paired: false });
  return pairing;
}

async function startPairing() {
  const device = readJson(paths.device, {});
  try {
    const result = await apiRequest("/frames/device/register", {
      method: "POST",
      body: JSON.stringify({
        deviceId: device.deviceId,
        deviceName: device.deviceName || "Autopoiesis Frame",
        softwareVersion: version(),
        metadata: {
          hostname: os.hostname(),
          platform: os.platform(),
          release: os.release()
        }
      })
    });
    const remoteDevice = result.device || {};
    const pairing = {
      pairingCode: result.pairingCode,
      expiresAt: result.expiresAt,
      mock: false,
      registeredAt: new Date().toISOString()
    };
    writeJson(paths.pairing, pairing);
    writeJson(paths.device, {
      ...device,
      ...remoteDevice,
      deviceId: remoteDevice.deviceId || device.deviceId,
      deviceApiKey: result.deviceApiKey || remoteDevice.deviceApiKey || device.deviceApiKey,
      pairingCode: result.pairingCode,
      paired: Boolean(remoteDevice.paired)
    });
    return pairing;
  } catch (error) {
    const pairing = {
      pairingCode: null,
      expiresAt: null,
      mock: false,
      status: "error",
      error: error ? error.message : "Unable to register with the web app"
    };
    writeJson(paths.pairing, pairing);
    writeJson(paths.device, { ...device, pairingCode: null, paired: false });
    return pairing;
  }
}

async function checkPairing() {
  const device = readJson(paths.device, {});
  if (!device.deviceId) return { ok: false, error: "Missing device ID" };
  try {
    const result = await apiRequest(`/frames/device/${encodeURIComponent(device.deviceId)}/pairing-status`);
    writeJson(paths.device, {
      ...device,
      paired: Boolean(result.paired),
      ownerUserId: result.ownerUserId || device.ownerUserId || null,
      firstRunComplete: Boolean(result.paired) || device.firstRunComplete
    });
    if (result.pairing) {
      writeJson(paths.pairing, {
        pairingCode: result.pairing.pairingCode || result.pairing.pairing_code || device.pairingCode || null,
        expiresAt: result.pairing.expiresAt || result.pairing.expires_at || null,
        mock: false,
        status: result.pairing.status || null
      });
    }
    if (result.paired) await syncSettingsFromRemote();
    return result;
  } catch (error) {
    return { ok: false, error: error.message, pairing: readJson(paths.pairing, {}) };
  }
}

async function syncSettingsFromRemote() {
  const device = readJson(paths.device, {});
  if (!device.deviceId || !device.paired) return { ok: false, error: "Device is not paired" };
  const result = await apiRequest(`/frames/device/${encodeURIComponent(device.deviceId)}/settings`);
  const sync = applyRemoteSettingsPayload(result, "settings_sync");
  return { ...result, sync };
}

async function pushSettingsToRemote(device, preferences) {
  if (!device.deviceId || !device.paired) return { ok: false, skipped: true, reason: "Device is not paired" };
  const submittedUpdatedAt = settingsUpdatedAt(preferences) || new Date().toISOString();
  const result = await apiRequest(`/frames/device/${encodeURIComponent(device.deviceId)}/settings`, {
    method: "POST",
    body: JSON.stringify({ settings: { ...preferences, updatedAt: submittedUpdatedAt } })
  });
  writeSettingsSyncStatus({
    status: "synced",
    source: "settings_push",
    conflict: false,
    localUpdatedAt: submittedUpdatedAt,
    remoteUpdatedAt: settingsUpdatedAt(result.settings || {}, result.updatedAt || submittedUpdatedAt),
    checkedAt: new Date().toISOString()
  });
  const sync = result.settings ? applyRemoteSettingsPayload(result, "settings_push_response") : null;
  return { ...result, sync };
}

async function sendHeartbeat() {
  const data = status();
  if (!data.device.deviceId || !data.device.paired) return { ok: false, skipped: true, reason: "Device is not paired" };
  const localFeedSync = await maybeSyncFeedForPolling("heartbeat");
  const diagnostics = await collectDiagnostics();
  const eventCursor = eventIngestionCursor();
  const eventReplaySince = eventCursorReplaySince(eventCursor);
  const events = publicDeviceEvents({ limit: HEARTBEAT_EVENT_LIMIT, since: eventReplaySince });
  const releaseState = readJson(paths.releaseState, null);
  const result = await apiRequest(`/frames/device/${encodeURIComponent(data.device.deviceId)}/heartbeat`, {
    method: "POST",
    body: JSON.stringify({
      softwareVersion: version(),
      currentMode: data.state.currentMode || "setup",
      currentArtworkId: data.state.currentArtworkId || null,
      networkOnline: Boolean(data.state.networkOnline),
      networkType: data.state.networkType || null,
      storageStatus: data.state.storageStatus || diagnostics.storage,
      diagnostics,
      releaseState,
      eventIngestionCursor: eventCursor
        ? {
            status: eventCursor.status || null,
            acceptedAt: eventCursor.acceptedAt || null,
            acceptedThroughObservedAt: eventCursor.acceptedThroughObservedAt || null,
            acceptedThroughEventKey: eventCursor.acceptedThroughEventKey || null,
            replaySince: eventReplaySince
          }
        : null,
      broadcastDeliveries: broadcastDeliveriesPayload(),
      events
    })
  });
  const eventAck = normalizeEventIngestionAck(result);
  if (eventAck) {
    const ackResult = writeEventIngestionCursor(eventAck, events);
    const deviceAfterAck = readJson(paths.device, {});
    writeJson(paths.device, {
      ...deviceAfterAck,
      lastEventIngestionAckAt: ackResult.cursor ? ackResult.cursor.updatedAt : new Date().toISOString(),
      lastEventIngestionAckStatus: ackResult.applied && ackResult.cursor
        ? ackResult.cursor.status
        : ackResult.reason || "skipped"
    });
  }
  const normalizedCommands = normalizeCommandsPayload(result.commands);
  if (result.settings) applyRemoteSettingsPayload(result, "heartbeat");
  // Owner preferences can arrive via heartbeat even without full settings payload
  if (!result.settings && (result.ownerPreferences || result.owner_preferences)) {
    applyRemoteSettingsPayload({ ownerPreferences: result.ownerPreferences || result.owner_preferences }, "heartbeat_owner_cascade");
  }
  if (normalizedCommands.length > 0) writeJson(paths.commands, normalizedCommands);
  if (result.feed || result.items || result.artworks || result.broadcasts) {
    writeFeedState(normalizeFeedPayload(result));
  }
  writeJson(paths.device, { ...readJson(paths.device, {}), lastHeartbeatAt: new Date().toISOString() });
  return { ...result, commands: normalizedCommands, localFeedSync };
}

async function checkRelease() {
  const device = readJson(paths.device, {});
  if (!device.deviceId || !device.paired) return { ok: false, skipped: true, reason: "Device is not paired" };
  const result = await apiRequest("/frames/device/" + encodeURIComponent(device.deviceId) + "/release");
  const release = result.release || null;
  writeJson(paths.release, {
    checkedAt: new Date().toISOString(),
    release
  });
  appendReleaseEvent({
    eventType: "release_checked",
    status: release ? "available" : "current",
    currentVersion: version(),
    updateAvailable: Boolean(release),
    ...releaseSubject(release || {})
  });
  return { ok: true, release, currentVersion: version() };
}

async function applyRelease(release) {
  if (!release) return { ok: false, skipped: true, reason: "No release available" };
  const targetVersion = release.version;
  if (!targetVersion) return { ok: false, error: "Release has no version" };
  const releaseMetadata = releaseSubject(release);
  if (targetVersion === version()) {
    appendReleaseEvent({
      eventType: "release_skipped",
      status: "current",
      reason: "Already on target version",
      currentVersion: version(),
      ...releaseMetadata
    });
    return { ok: true, skipped: true, reason: "Already on target version", version: targetVersion };
  }
  writeJson(paths.release, { checkedAt: new Date().toISOString(), release });
  const startedAt = new Date().toISOString();
  writeJson(paths.releaseState, {
    status: "in_progress",
    targetVersion,
    releaseId: release.id || null,
    releaseChannel: releaseMetadata.channel,
    releaseTag: releaseMetadata.tag,
    startedAt,
    previousVersion: version()
  });
  appendReleaseEvent({
    eventType: "release_apply_started",
    status: "in_progress",
    previousVersion: version(),
    startedAt,
    ...releaseMetadata
  });
  try {
    const execution = await execFilePromise(UPDATE_SCRIPT, [paths.release], {
      env: {
        ...process.env,
        AUTOPOIESIS_DATA_DIR: DATA_DIR,
        AUTOPOIESIS_LOG_DIR: LOG_DIR
      },
      timeout: Number(process.env.AUTOPOIESIS_UPDATE_TIMEOUT_MS || 300000)
    });
    try {
      VERSION = fs.readFileSync(path.resolve(__dirname, "../VERSION"), "utf8").trim();
    } catch {
      VERSION = targetVersion;
    }
    const stateValue = {
      status: "completed",
      targetVersion,
      releaseId: release.id || null,
      releaseChannel: releaseMetadata.channel,
      releaseTag: releaseMetadata.tag,
      previousVersion: readJson(paths.releaseState, {}).previousVersion || null,
      completedAt: new Date().toISOString(),
      stdout: execution.stdout.trim(),
      stderr: execution.stderr.trim()
    };
    writeJson(paths.releaseState, stateValue);
    appendReleaseEvent({
      eventType: "release_apply_completed",
      status: "completed",
      previousVersion: stateValue.previousVersion || null,
      completedAt: stateValue.completedAt,
      ...releaseMetadata
    });
    return { ok: true, release, version: version(), update: stateValue };
  } catch (error) {
    const stateValue = {
      status: "error",
      targetVersion,
      releaseId: release.id || null,
      releaseChannel: releaseMetadata.channel,
      releaseTag: releaseMetadata.tag,
      previousVersion: readJson(paths.releaseState, {}).previousVersion || null,
      failedAt: new Date().toISOString(),
      error: error.stderr || error.message
    };
    writeJson(paths.releaseState, stateValue);
    appendReleaseEvent({
      eventType: "release_apply_failed",
      status: "error",
      previousVersion: stateValue.previousVersion || null,
      failedAt: stateValue.failedAt,
      error: stateValue.error,
      ...releaseMetadata
    });
    return { ok: false, release, error: stateValue.error, update: stateValue };
  }
}

async function checkAndApplyRelease(payload = {}) {
  if (payload.release && payload.release.version) return applyRelease(payload.release);
  if (payload.version) return applyRelease(payload);
  const checked = await checkRelease();
  if (!checked.ok || !checked.release) return checked;
  return applyRelease(checked.release);
}

async function executeCommand(command) {
  const commandType = commandTypeOf(command);
  const payload = command.payload || {};
  const policy = commandPolicy(commandType);
  const authorization = validateCommandAuthorization(command, commandType, policy);
  if (!authorization.ok) {
    appendLog("commands.log", "refuse " + command.id + " " + commandType + " " + authorization.error);
    return { ok: false, error: authorization.error, policy };
  }
  const actor = authorization.authorization ? " actor=" + authorization.authorization.actorId : "";
  appendLog("commands.log", "execute " + command.id + " " + commandType + " risk=" + policy.risk + actor);
  if (commandType === "sync_settings") {
    return syncSettingsFromRemote();
  }
  if (commandType === "clear_cache") {
    fs.rmSync(CACHE_DIR, { recursive: true, force: true });
    fs.mkdirSync(CACHE_DIR, { recursive: true });
    return { ok: true, cleared: CACHE_DIR };
  }
  if (commandType === "restart_display") {
    await execFilePromise("systemctl", ["restart", "autopoiesis-kiosk.service"]);
    return { ok: true, restarted: "autopoiesis-kiosk.service" };
  }
  if (commandType === "restart_device") {
    if (process.env.AUTOPOIESIS_ALLOW_REBOOT !== "1") {
      return { ok: false, error: "Reboot command refused unless AUTOPOIESIS_ALLOW_REBOOT=1" };
    }
    await execFilePromise("systemctl", ["reboot"]);
    return { ok: true, rebooting: true };
  }
  if (commandType === "update_device") {
    return checkAndApplyRelease(payload);
  }
  if (commandType === "disable_device") {
    const device = readJson(paths.device, {});
    const stateValue = readJson(paths.state, {});
    writeJson(paths.device, { ...device, remoteEnabled: false });
    writeJson(paths.state, { ...stateValue, remoteDisabled: true });
    return { ok: true, remoteEnabled: false };
  }
  if (commandType === "enable_device") {
    const device = readJson(paths.device, {});
    const stateValue = readJson(paths.state, {});
    writeJson(paths.device, { ...device, remoteEnabled: true });
    writeJson(paths.state, { ...stateValue, remoteDisabled: false });
    return { ok: true, remoteEnabled: true };
  }
  if (commandType === "show_broadcast") {
    const stateValue = readJson(paths.state, {});
    const broadcast = normalizeFeedItem(payload, "broadcast") || {
      id: payload.broadcastId || payload.id || "broadcast-" + Date.now(),
      source: "broadcast",
      type: payload.type || "broadcast_message",
      title: payload.title || null,
      body: payload.body || payload.message || null,
      priority: payload.priority || "normal",
      expiresAt: payload.expiresAt || payload.expires_at || null,
      duration: payload.duration || payload.durationSeconds || 20,
      cacheAllowed: payload.cacheAllowed !== false && payload.cache_allowed !== false,
      raw: payload
    };
    const broadcastId = payload.broadcastId || payload.id || broadcast.id;
    if (!feedItemTargetAllowed(broadcast, readJson(paths.device, {}))) {
      return { ok: false, error: "Broadcast target does not include this device", broadcastId };
    }
    if (isExpired(broadcast.expiresAt)) {
      return { ok: false, error: "Broadcast is expired", broadcastId };
    }
    const startsAt = parseTimestamp(broadcast.startsAt);
    const scheduled = startsAt !== null && startsAt > Date.now();
    const acceptedAt = new Date().toISOString();
    writeJson(paths.broadcast, {
      ...broadcast,
      broadcastId,
      commandId: command.id || null,
      acceptedAt
    });
    writeJson(paths.state, {
      ...stateValue,
      currentMode: scheduled ? stateValue.currentMode || "frame" : "broadcast",
      currentBroadcastId: scheduled ? null : broadcastId,
      scheduledBroadcastId: scheduled ? broadcastId : null
    });
    appendDeliveryEvent({
      eventType: "broadcast_received",
      ...deliverySubject(broadcast),
      itemId: broadcastId,
      commandId: command.id || null,
      scheduled,
      startsAt: broadcast.startsAt || null,
      status: scheduled ? "scheduled" : "active"
    });
    return { ok: true, broadcastId, scheduled };
  }
  if (commandType === "factory_reset_request") {
    return { ok: false, error: "Factory reset requires local confirmation on the device" };
  }
  return { ok: false, error: "Unknown command type: " + commandType };
}

async function processCommands() {
  const device = readJson(paths.device, {});
  if (!device.deviceId || !device.paired) return { ok: false, skipped: true, reason: "Device is not paired" };
  const localCommands = readJson(paths.commands, []);
  const heartbeat = await sendHeartbeat();
  const commands = mergeCommandQueues(heartbeat.commands || [], localCommands);
  const results = [];
  const retained = [];
  for (const command of commands) {
    const commandId = commandIdOf(command);
    if (!commandId) continue;
    const normalizedCommand = { ...command, id: commandId };
    const commandType = commandTypeOf(command);
    const policy = commandPolicy(commandType);
    const auditBase = commandAuditSubject(normalizedCommand, commandType, policy);
    const startedAt = new Date().toISOString();
    const pendingAck = localCommandAck(normalizedCommand);
    try {
      if (pendingAck && pendingAck.phase === "final") {
        try {
          await ackCommand(device.deviceId, commandId, pendingAck.status, pendingAck.extra || {});
          results.push({
            commandId,
            commandType,
            result: { ok: true, ackRetried: true, status: pendingAck.status }
          });
        } catch (error) {
          const message = error.stderr || error.message;
          appendLog("commands-error.log", commandId + " final ack retry failed " + message);
          retained.push(commandForStorage(normalizedCommand, ackRetry(normalizedCommand, "final", pendingAck.status, pendingAck.extra || {}, message)));
          appendCommandAudit({
            ...auditBase,
            status: "ack_retry_failed",
            startedAt,
            completedAt: new Date().toISOString(),
            error: message
          });
          results.push({ commandId, commandType, error: message, retained: true });
        }
        continue;
      }
      try {
        await ackCommand(device.deviceId, commandId, "acknowledged");
      } catch (error) {
        const message = error.stderr || error.message;
        appendLog("commands-error.log", commandId + " acknowledge failed " + message);
        retained.push(commandForStorage(normalizedCommand, ackRetry(normalizedCommand, "acknowledge", "acknowledged", {}, message)));
        appendCommandAudit({
          ...auditBase,
          status: "ack_failed",
          startedAt,
          completedAt: new Date().toISOString(),
          error: message
        });
        results.push({ commandId, commandType, error: message, retained: true });
        continue;
      }

      const result = await executeCommand(normalizedCommand);
      if (result && result.ok === false) {
        const finalAck = {
          error: result.error || "Command failed",
          policy: result.policy || null
        };
        let finalAckError = null;
        try {
          await ackCommand(device.deviceId, commandId, "error", finalAck);
        } catch (error) {
          const message = error.stderr || error.message;
          finalAckError = message;
          appendLog("commands-error.log", commandId + " final error ack failed " + message);
          retained.push(commandForStorage(normalizedCommand, ackRetry(normalizedCommand, "final", "error", finalAck, message)));
        }
        appendCommandAudit({
          ...auditBase,
          status: finalAckError ? "ack_failed" : "error",
          startedAt,
          completedAt: new Date().toISOString(),
          error: finalAckError
            ? "Final error acknowledgement failed: " + finalAckError
            : result.error || "Command failed"
        });
      } else {
        let finalAckError = null;
        try {
          await ackCommand(device.deviceId, commandId, "completed");
        } catch (error) {
          const message = error.stderr || error.message;
          finalAckError = message;
          appendLog("commands-error.log", commandId + " final completed ack failed " + message);
          retained.push(commandForStorage(normalizedCommand, ackRetry(normalizedCommand, "final", "completed", {}, message)));
        }
        appendCommandAudit({
          ...auditBase,
          status: finalAckError ? "ack_failed" : "completed",
          startedAt,
          completedAt: new Date().toISOString(),
          error: finalAckError ? "Final completed acknowledgement failed: " + finalAckError : undefined
        });
      }
      results.push({ commandId, commandType, result });
    } catch (error) {
      const message = error.stderr || error.message;
      appendLog("commands-error.log", commandId + " " + message);
      try {
        await ackCommand(device.deviceId, commandId, "error", { error: message });
      } catch (ackError) {
        appendLog("commands-error.log", commandId + " ack failed " + ackError.message);
        retained.push(commandForStorage(normalizedCommand, ackRetry(normalizedCommand, "final", "error", { error: message }, ackError.message)));
      }
      appendCommandAudit({
        ...auditBase,
        status: "error",
        startedAt,
        completedAt: new Date().toISOString(),
        error: message
      });
      results.push({ commandId, commandType, error: message, retained: retained.some(item => commandIdOf(item) === commandId) });
    }
  }
  writeJson(paths.commands, retained);
  return { ok: true, processed: results.length, retained: retained.length, results };
}

async function handle(req, res) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  try {
    if ((req.method === "GET" || req.method === "HEAD") && url.pathname === "/") return redirect(res, "/launch");
    if ((req.method === "GET" || req.method === "HEAD") && url.pathname === "/launch") return renderLaunch(res, url);
    if (req.method === "GET" && url.pathname === "/welcome") return html(res, renderWelcome());
    if (req.method === "GET" && url.pathname === "/setup") return html(res, renderSetup());
    if (req.method === "GET" && url.pathname === "/network") return html(res, renderNetwork());
    if (req.method === "GET" && url.pathname === "/settings") return html(res, renderSettings());
    if (req.method === "GET" && url.pathname === "/dashboard") return html(res, renderDashboard());
    if (req.method === "GET" && url.pathname === "/frame") return html(res, renderFrame());
    if (req.method === "GET" && url.pathname === "/offline") return html(res, renderOffline());
    if (req.method === "GET" && url.pathname === "/broadcast") return html(res, renderBroadcast());
    if (req.method === "GET" && url.pathname === "/disabled") return html(res, renderDisabled());
    if (req.method === "GET" && url.pathname === "/style.css") return css(res);
    if (req.method === "GET" && (url.pathname === "/local/status" || url.pathname === "/local/status.json")) {
      return sendJson(res, publicStatus());
    }
    if (req.method === "GET" && url.pathname === "/local/diagnostics") {
      return sendJson(res, { ok: true, diagnostics: await collectDiagnostics({ includeServices: true }) });
    }
    if (req.method === "GET" && url.pathname === "/local/health") {
      const includeServices = url.searchParams.get("services") === "1";
      return sendJson(res, healthSummary(await collectDiagnostics({ includeServices })));
    }
    if (req.method === "GET" && url.pathname === "/local/readiness") {
      const includeServices = url.searchParams.get("services") !== "0";
      return sendJson(res, readinessSummary(await collectDiagnostics({ includeServices })));
    }
    if (req.method === "GET" && url.pathname === "/local/rollout/acceptance") {
      const includeServices = url.searchParams.get("services") !== "0";
      return sendJson(res, rolloutAcceptance(await collectDiagnostics({ includeServices }), {
        profile: url.searchParams.get("profile"),
        strictContent: url.searchParams.get("strictContent"),
        eventLimit: url.searchParams.get("eventLimit") || url.searchParams.get("limit")
      }));
    }
    if (req.method === "GET" && url.pathname === "/local/support-bundle") {
      const includeServices = url.searchParams.get("services") !== "0";
      return sendJson(res, await supportBundle({
        includeServices,
        auditLimit: url.searchParams.get("auditLimit") || url.searchParams.get("limit"),
        deliveryLimit: url.searchParams.get("deliveryLimit") || url.searchParams.get("limit"),
        releaseLimit: url.searchParams.get("releaseLimit") || url.searchParams.get("limit"),
        eventLimit: url.searchParams.get("eventLimit") || url.searchParams.get("limit")
      }));
    }
    if (req.method === "GET" && url.pathname === "/local/feed") {
      return sendJson(res, publicFeed());
    }
    if (req.method === "GET" && url.pathname === "/local/frame-state") {
      return sendJson(res, publicFrameState());
    }
    if (req.method === "GET" && url.pathname === "/local/feed/readiness") {
      return sendJson(res, publicFeedReadiness());
    }
    if (req.method === "GET" && url.pathname === "/local/offline-cache") {
      return sendJson(res, publicOfflineCache());
    }
    if (req.method === "GET" && url.pathname === "/local/cache/quota") {
      return sendJson(res, { ok: true, ...cacheQuotaStatus() });
    }
    if (req.method === "POST" && url.pathname === "/local/cache/evict") {
      return sendJson(res, enforceCacheQuota());
    }
    if (req.method === "GET" && url.pathname === "/local/commands/audit") {
      return sendJson(res, publicCommandAudit(url.searchParams.get("limit")));
    }
    if (req.method === "GET" && url.pathname === "/local/admin/capabilities") {
      return sendJson(res, publicAdminCapabilities());
    }
    if (req.method === "GET" && url.pathname === "/local/delivery-log") {
      return sendJson(res, publicDeliveryLog(url.searchParams.get("limit")));
    }
    if (req.method === "GET" && url.pathname === "/local/delivery-status") {
      return sendJson(res, deliveryStatusSummary());
    }
    if (req.method === "GET" && url.pathname === "/local/broadcast-deliveries") {
      return sendJson(res, broadcastDeliveriesPayload());
    }
    if (req.method === "GET" && url.pathname === "/local/release/history") {
      return sendJson(res, publicReleaseHistory(url.searchParams.get("limit")));
    }
    if (req.method === "GET" && url.pathname === "/local/events/export") {
      return sendJson(res, publicDeviceEvents({
        limit: url.searchParams.get("limit"),
        commandLimit: url.searchParams.get("commandLimit"),
        deliveryLimit: url.searchParams.get("deliveryLimit"),
        releaseLimit: url.searchParams.get("releaseLimit"),
        since: url.searchParams.get("since")
      }));
    }
    const cacheAssetMatch = url.pathname.match(/^\/local\/cache\/assets\/([^/]+)\/(media|thumbnail)$/);
    if ((req.method === "GET" || req.method === "HEAD") && cacheAssetMatch) {
      return sendCachedAsset(req, res, cacheAssetMatch[1], cacheAssetMatch[2]);
    }
    if (req.method === "GET" && (url.pathname === "/local/network/status" || url.pathname === "/local/network/status.json")) {
      return networkStatus((_, value) => sendJson(res, value, value.ok ? 200 : 503));
    }
    if (req.method === "GET" && url.pathname === "/local/wifi/scan") {
      return html(res, renderWifiScan());
    }
    if (req.method === "GET" && url.pathname === "/local/wifi/scan.json") {
      return scanWifi((_, value) => sendJson(res, value));
    }
    if (req.method === "POST" && url.pathname === "/local/wifi/connect") {
      const body = JSON.parse(await readBody(req) || "{}");
      return connectWifi(body.ssid, body.password, (_, value) => sendJson(res, value, value.ok ? 200 : 400));
    }
    if (req.method === "POST" && url.pathname === "/local/lan/connect") {
      return connectLan((_, value) => sendJson(res, value, value.ok ? 200 : 400));
    }
    if (req.method === "POST" && url.pathname === "/local/settings") {
      const body = JSON.parse(await readBody(req) || "{}");
      const device = { ...readJson(paths.device, {}), ...(body.device || {}) };
      const localUpdatedAt = settingsUpdatedAt(body.preferences || {}) || new Date().toISOString();
      const preferences = { ...readJson(paths.preferences, {}), ...(body.preferences || {}), updatedAt: localUpdatedAt };
      writeJson(paths.device, device);
      writeJson(paths.preferences, preferences);
      writeSettingsSyncStatus({
        status: "local_changed",
        source: "local_settings",
        conflict: false,
        localUpdatedAt,
        checkedAt: localUpdatedAt
      });
      let remote = { ok: false, skipped: true };
      try {
        remote = await pushSettingsToRemote(device, preferences);
      } catch (error) {
        remote = { ok: false, error: error.message };
      }
      return sendJson(res, { ok: true, remote });
    }
    if (req.method === "POST" && url.pathname === "/local/pairing/start") {
      const result = await startPairing();
      const ok = result.status !== "error";
      return sendJson(res, { ok, ...result }, ok ? 200 : 502);
    }
    if (req.method === "POST" && url.pathname === "/local/pairing/check") {
      return sendJson(res, { ok: true, ...(await checkPairing()) });
    }
    if (req.method === "GET" && url.pathname === "/local/pairing/status") {
      return sendJson(res, {
        ok: true,
        device: redactDevice(readJson(paths.device, {})),
        pairing: readJson(paths.pairing, {})
      });
    }
    if (req.method === "POST" && url.pathname === "/local/settings/sync") {
      return sendJson(res, await syncSettingsFromRemote());
    }
    if (req.method === "POST" && url.pathname === "/local/heartbeat") {
      return sendJson(res, await sendHeartbeat());
    }
    if (req.method === "POST" && url.pathname === "/local/feed/sync") {
      return sendJson(res, await syncFeedFromRemote());
    }
    if (req.method === "POST" && url.pathname === "/local/frame/display") {
      const body = JSON.parse(await readBody(req) || "{}");
      const result = recordFrameItemDisplay(body);
      return sendJson(res, result, result.ok ? 200 : 400);
    }
    if (req.method === "POST" && url.pathname === "/local/frame/like") {
      const body = JSON.parse(await readBody(req) || "{}");
      const result = await likeFrameItem(body);
      return sendJson(res, result, result.ok ? 200 : 400);
    }
    if (req.method === "POST" && url.pathname === "/local/broadcast/dismiss") {
      return sendJson(res, dismissBroadcast("duration_elapsed"));
    }
    if (req.method === "POST" && url.pathname === "/local/commands/process") {
      return sendJson(res, await processCommands());
    }
    if (req.method === "POST" && url.pathname === "/local/release/check") {
      return sendJson(res, await checkRelease());
    }
    if (req.method === "POST" && url.pathname === "/local/release/apply") {
      return sendJson(res, await checkAndApplyRelease());
    }
    if (req.method === "POST" && url.pathname === "/local/system/restart") {
      return sendJson(res, { ok: false, error: "Restart requires privileged systemd wiring in a later milestone." }, 501);
    }
    if (req.method === "POST" && url.pathname === "/local/night-mode/apply") {
      applyNightMode();
      const prefs = readJson(paths.preferences, {});
      return sendJson(res, { ok: true, nightMode: { ...nightModeState(), displayOn: prefs._nightModeDisplayOn !== false } });
    }
    if (req.method === "POST" && url.pathname === "/local/system/factory-reset") {
      return sendJson(res, { ok: false, error: "Factory reset endpoint is reserved until confirmation and privilege handling are implemented." }, 501);
    }
    if (req.method === "POST" && url.pathname === "/local/system/update-now") {
      return sendJson(res, await checkAndApplyRelease());
    }
    sendJson(res, { ok: false, error: "Not found" }, 404);
  } catch (error) {
    sendJson(res, { ok: false, error: error.message }, 500);
  }
}

function html(res, value) {
  res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
  res.end(value);
}

function css(res) {
  res.writeHead(200, { "content-type": "text/css; charset=utf-8" });
  res.end(`
:root { color-scheme: dark; font-family: Inter, system-ui, sans-serif; background: #101412; color: #f4f1e8; }
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; background: #101412; }
.screen { min-height: 100vh; display: grid; place-items: center; padding: 5vw; }
.fallback { background: radial-gradient(circle at 50% 25%, #2e4940, #101412 55%); }
.panel { width: min(760px, 100%); padding: 40px; border: 1px solid #46534d; background: #18201d; border-radius: 8px; }
.panel.wide { width: min(900px, 100%); }
.kicker { margin: 0 0 10px; color: #9ad0bb; font-size: 18px; }
h1 { margin: 0 0 18px; font-size: clamp(42px, 8vw, 92px); line-height: 0.95; letter-spacing: 0; }
p { font-size: 22px; line-height: 1.35; }
.muted, .note { color: #c8c6bb; }
.status { display: grid; gap: 12px; margin: 28px 0; }
.status div { display: grid; grid-template-columns: 130px 1fr; gap: 18px; padding: 14px 0; border-top: 1px solid #343d39; }
.status.compact { margin: 16px 0; }
dt { color: #9ad0bb; }
dd { margin: 0; overflow-wrap: anywhere; }
.actions, .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 14px; }
button, .button, input, select { min-height: 56px; border-radius: 8px; border: 1px solid #607069; background: #202b27; color: #f4f1e8; font: inherit; font-size: 18px; padding: 14px 16px; }
.button { display: inline-grid; place-items: center; text-decoration: none; text-align: center; }
.primary { background: #d8f3dc; color: #122018; border-color: #d8f3dc; }
button:disabled, .button.disabled { opacity: 0.45; pointer-events: none; }
label { display: grid; gap: 8px; color: #c8c6bb; font-size: 18px; }
.check { display: flex; align-items: center; gap: 12px; }
.check input { min-height: auto; width: 24px; height: 24px; }
.setting-group { grid-column: 1 / -1; margin: 0; padding: 18px; border: 1px solid #343d39; border-radius: 8px; }
.setting-group legend { padding: 0 8px; color: #9ad0bb; font-size: 20px; }
.check-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 12px; }
.onboarding h1 { font-size: clamp(38px, 7vw, 78px); }
.onboarding h2 { margin: 0 0 8px; font-size: clamp(24px, 4vw, 38px); letter-spacing: 0; }
.onboarding p { margin: 0 0 14px; }
.onboarding { width: min(1180px, 100%); min-height: min(760px, calc(100vh - 10vw)); display: grid; grid-template-rows: auto minmax(0, 1fr) auto; overflow: hidden; }
.onboarding > .muted { max-width: 760px; }
.steps { --setup-step: 0; list-style: none; display: flex; gap: 0; width: 400%; min-height: 0; margin: 24px 0; padding: 0; transform: translateX(calc(var(--setup-step) * -25%)); transition: transform 420ms cubic-bezier(.2,.8,.2,1); }
.step { width: 25%; display: grid; grid-template-columns: 92px minmax(0, 1fr); align-content: center; gap: 28px; padding: clamp(22px, 5vw, 58px); border: 1px solid #343d39; border-radius: 8px; background: #141b18; opacity: 0.34; transform: scale(0.96); transition: opacity 260ms ease, transform 260ms ease, border-color 260ms ease; }
.step.current { opacity: 1; transform: scale(1); border-color: #9ad0bb; background: #18231f; }
.step.active { border-color: #9ad0bb; background: #18231f; }
.step.done { border-color: #6fae82; }
.step-index { width: 72px; height: 72px; display: grid; place-items: center; border-radius: 999px; border: 1px solid #607069; color: #9ad0bb; font-size: 28px; cursor: pointer; }
.step.done .step-index { background: #d8f3dc; border-color: #d8f3dc; color: #122018; }
.step.current h2 { font-size: clamp(44px, 7vw, 112px); line-height: 0.92; margin-bottom: 18px; }
.step.current p { max-width: 780px; font-size: clamp(22px, 3vw, 34px); }
.setup-controls { display: grid; grid-template-columns: 150px 1fr 150px; gap: 16px; align-items: center; }
.setup-dots { display: flex; justify-content: center; gap: 10px; }
.setup-dots button { width: 48px; min-height: 48px; padding: 0; border-radius: 999px; }
.setup-dots button.current { background: #d8f3dc; color: #122018; border-color: #d8f3dc; }
.pairing-code { margin: 18px 0; padding: 22px; border: 1px solid #607069; border-radius: 8px; background: #101412; color: #d8f3dc; font-size: clamp(30px, 8vw, 88px); letter-spacing: 0.08em; text-align: center; overflow-wrap: anywhere; }
.pairing-code.error { color: #ffd5c2; border-color: #fb923c; letter-spacing: 0; font-size: clamp(22px, 4vw, 44px); }
.setup-error { color: #ffd5c2; font-size: 18px !important; }
.compact-form { grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); }
.launch { min-height: 70px; font-size: 22px; }
.network-list { display: grid; gap: 10px; margin: 24px 0; }
.network-row { display: grid; grid-template-columns: minmax(0, 1fr) auto; align-items: center; text-align: left; width: 100%; }
.network-row span { overflow-wrap: anywhere; }
.broadcast-screen { background: #121417; }
.broadcast-panel { width: min(1100px, 100%); }
.broadcast-panel h1 { font-size: clamp(42px, 7vw, 110px); }
.broadcast-media { margin: 26px 0; }
.broadcast-media img { display: block; width: 100%; max-height: 55vh; object-fit: contain; border-radius: 8px; }
.frame-screen { align-items: stretch; justify-items: stretch; padding: 3vw; background: #0d1110; }
.frame-gallery, .frame-empty { width: min(1280px, 100%); margin: auto; }
.frame-topline { display: flex; justify-content: space-between; align-items: center; gap: 18px; color: #9ad0bb; }
.frame-count { margin: 0; color: #c8c6bb; font-size: 18px; }
.frame-stage { display: grid; gap: 18px; transition: opacity 600ms ease-in-out; } .frame-stage.fading { opacity: 0; }
.frame-media { margin: 0; display: grid; place-items: center; min-height: 68vh; background: #101412; border: 1px solid #2d3834; border-radius: 8px; overflow: hidden; }
.frame-media img, .frame-media video { display: block; width: 100%; height: 68vh; object-fit: contain; background: #0d1110; }
.frame-media audio { width: min(720px, 90%); }
.frame-audio-work { width: 100%; min-height: 68vh; display: grid; place-items: center; gap: 16px; text-align: center; background: #101412; }
.frame-audio-work strong { font-size: clamp(34px, 6vw, 92px); line-height: 1; overflow-wrap: anywhere; }
.frame-audio-work span { color: #9ad0bb; font-size: 24px; }
.text-only { padding: 6vw; font-size: clamp(34px, 6vw, 86px); text-align: center; overflow-wrap: anywhere; }
.frame-caption { display: flex; justify-content: space-between; align-items: flex-start; gap: 20px; color: #c8c6bb; font-size: 18px; }
.frame-caption strong { display: block; color: #f4f1e8; font-size: clamp(24px, 4vw, 44px); overflow-wrap: anywhere; }
.frame-caption p { max-width: 820px; margin: 8px 0 0; color: #c8c6bb; font-size: 20px; }
.frame-caption span { text-align: right; overflow-wrap: anywhere; }
.frame-overlay { position: fixed; inset: 0; z-index: 20; display: grid; place-items: end center; padding: 4vw; background: linear-gradient(180deg, rgba(13,17,16,0.1), rgba(13,17,16,0.88)); }
.frame-overlay[hidden] { display: none; }
.overlay-card { width: min(980px, 100%); padding: 28px; border: 1px solid #607069; border-radius: 8px; background: rgba(16, 20, 18, 0.96); box-shadow: 0 24px 80px rgba(0,0,0,0.45); }
.overlay-card h2 { margin: 0 0 12px; font-size: clamp(30px, 5vw, 58px); letter-spacing: 0; }
.overlay-card p { margin: 0 0 18px; font-size: 20px; }
.overlay-close { float: right; min-height: 44px; font-size: 16px; padding: 10px 14px; }
.overlay-actions { margin-top: 18px; }
.dashboard-screen { align-items: stretch; justify-items: stretch; background: #101412; }
.dashboard-panel { margin: auto; }
.dashboard-panel h1 { font-size: clamp(42px, 7vw, 84px); }
.dashboard-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 14px; margin: 26px 0; }
.dash-tile { min-height: 128px; display: grid; align-content: center; gap: 8px; padding: 20px; border: 1px solid #343d39; border-radius: 8px; background: #141b18; }
.dash-tile strong { font-size: clamp(30px, 5vw, 52px); color: #d8f3dc; overflow-wrap: anywhere; }
.dash-tile span { color: #c8c6bb; font-size: 18px; }
.gateway-actions { margin-top: 24px; }
.offline-screen { align-items: stretch; justify-items: stretch; padding: 4vw; }
.offline-gallery, .offline-empty { width: min(1180px, 100%); margin: auto; }
.offline-gallery h1, .offline-empty h1 { font-size: clamp(42px, 7vw, 96px); }
.offline-stage { display: grid; gap: 18px; margin: 24px 0; }
.offline-stage img, .offline-stage video { width: 100%; max-height: 58vh; object-fit: contain; border-radius: 8px; background: #0d1110; border: 1px solid #343d39; }
.offline-caption { display: flex; justify-content: space-between; gap: 16px; align-items: baseline; color: #c8c6bb; font-size: 20px; }
.offline-caption strong { color: #f4f1e8; font-size: 24px; overflow-wrap: anywhere; }
.offline-caption span { text-align: right; overflow-wrap: anywhere; }
.compact { width: min(620px, 100%); }
.welcome-screen { background: radial-gradient(ellipse at 50% 30%, #1e3a2f, #101412 70%); }
.welcome-panel { display: grid; grid-template-rows: auto auto auto 1fr auto; gap: 20px; }
.welcome-header { text-align: center; }
.welcome-header h1 { font-size: clamp(48px, 10vw, 120px); line-height: 0.9; }
.welcome-header p { max-width: 640px; margin: 8px auto; }
.welcome-progress { display: flex; justify-content: center; gap: 12px; margin: 8px 0; }
.welcome-dot { min-height: 48px; padding: 10px 20px; border-radius: 999px; font-size: 16px; transition: background 240ms, color 240ms, border-color 240ms; }
.welcome-dot.current { background: #d8f3dc; color: #122018; border-color: #d8f3dc; }
.welcome-dot.done { background: #6fae82; color: #122018; border-color: #6fae82; }
.welcome-steps { min-height: 420px; display: grid; align-content: start; }
.welcome-step { animation: fadeInUp 360ms ease; }
.welcome-step[hidden] { display: none; }
.welcome-step h2 { font-size: clamp(36px, 6vw, 72px); line-height: 0.95; margin: 0 0 16px; }
.welcome-step p { max-width: 720px; margin: 0 0 18px; }
.welcome-footer { text-align: center; margin-top: 16px; }
.welcome-night-toggle { grid-column: 1 / -1; }
.welcome-night-times { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; margin-top: 10px; }
.welcome-night-times[hidden] { display: none; }
@keyframes fadeInUp { from { opacity: 0; transform: translateY(16px); } to { opacity: 1; transform: translateY(0); } }
`);
}

ensureState();
http.createServer(handle).listen(PORT, "127.0.0.1", () => {
  console.log(`Autopoiesis local UI listening on http://127.0.0.1:${PORT}`);
});

function publicFeedReadiness() {
  const feed = readJson(paths.feed, { syncedAt: null, items: [] });
  const preferences = readJson(paths.preferences, {});
  const localState = readJson(paths.state, {});
  const feedCache = readJson(paths.feedCache, { generatedAt: null, count: 0, items: [], eligibility: {} });
  const device = readJson(paths.device, {});
  
  // Basic feed data
  const items = eligibleFeedItems(feed, preferences).map(({ raw, visibility, ...item }) => item);
  const displayQueue = mixedFeedQueue(feed, preferences).map(({ raw, visibility, ...item }) => item);
  
  // Totals from publicFeed and publicFrameState
  const totalItems = Array.isArray(feed.items) ? feed.items.length : 0;
  const eligibleItems = items.length;
  const cacheEligibleItems = feedCache.count || 0;
  const displayQueueItems = displayQueue.length;
  
  // Playable items calculation (from publicFrameState)
  const playableItems = displayQueue.filter(item => item.mediaUrl || item.thumbnailUrl || item.title || item.body).length;
  const cachedPlayableItems = displayQueue.filter(item => 
    (item.mediaUrl && fs.existsSync(path.join(CACHE_DIR, path.basename(item.mediaUrl)))) ||
    (item.thumbnailUrl && fs.existsSync(path.join(CACHE_DIR, path.basename(item.thumbnailUrl))))
  ).length;
  
  // Fresh and replay queue items
  const shownItemIds = new Set((feedCursor().shownItemIds || []).map(id => String(id)));
  const freshQueueItems = items.filter(item => !shownItemIds.has(String(item.id))).length;
  const replayQueueItems = items.filter(item => shownItemIds.has(String(item.id))).length;
  
  // Determine status
  let status = "needs_initial_sync";
  if (totalItems === 0) {
    status = "empty";
  } else if (feed.syncedAt === null) {
    status = "needs_initial_sync";
  } else {
    const polling = feedPollingSummary(feed, device);
    if (polling.status === "stale") {
      status = "stale";
    } else if (polling.status === "due" || polling.due === true) {
      status = "poll_due";
    } else if (replayQueueItems > 0 && freshQueueItems === 0) {
      status = "ready_replay_only";
    } else {
      status = "ready";
    }
  }
  
  // Blocker counts (simplified - in reality this would be more complex)
  const displayBlocked = items.filter(item => 
    !feedItemTargetAllowed(item, device) || 
    !feedItemTypeAllowed(item, preferences) || 
    !feedItemArtistAllowed(item, preferences) || 
    !feedItemStreamAllowed(item, preferences)
  ).length;
  
  const expiredItems = items.filter(item => isExpired(item.expiresAt, Date.now())).length;
  
  const cacheNotAllowed = items.filter(item => !item.cacheAllowed).length;
  
  // Display plan (next item to show)
  const nextItem = displayQueue[0] || null;
  const nextItemId = nextItem ? nextItem.id : null;
  
  // Media source counts
  const mediaSourceCounts = {
    cache: displayQueue.filter(item => 
      (item.mediaUrl && fs.existsSync(path.join(CACHE_DIR, path.basename(item.mediaUrl)))) ||
      (item.thumbnailUrl && fs.existsSync(path.join(CACHE_DIR, path.basename(item.thumbnailUrl))))
    ).length,
    remote: displayQueue.filter(item => 
      !((
        item.mediaUrl && fs.existsSync(path.join(CACHE_DIR, path.basename(item.mediaUrl)))) ||
        (item.thumbnailUrl && fs.existsSync(path.join(CACHE_DIR, path.basename(item.thumbnailUrl))))
      ) && 
      (item.mediaUrl || item.thumbnailUrl)
    ).length
  };
  
  // Total display seconds (simplified)
  let totalDisplaySeconds = 0;
  for (const item of displayQueue) {
    totalDisplaySeconds += frameItemDisplayMs(item, preferences) / 1000;
  }
  
  // Freshness status for display plan
  let freshnessStatus = "fresh";
  let freshnessRefreshRecommended = false;
  if (replayQueueItems > 0 && freshQueueItems === 0) {
    freshnessStatus = "replay_only";
    freshnessRefreshRecommended = true;
  } else if (freshQueueItems === 0) {
    freshnessStatus = "empty";
    freshnessRefreshRecommended = false;
  }
  
  // Refresh recommendation
  let refreshRecommended = false;
  let refreshImmediate = false;
  let refreshReason = [];
  let displayPressure = false;
  
  if (status === "poll_due" || status === "stale") {
    refreshRecommended = true;
    refreshImmediate = true;
    refreshReason = [status];
  } else if (freshnessStatus === "replay_only") {
    refreshRecommended = true;
    refreshImmediate = true;
    refreshReason = ["display_plan_replay_only"];
    displayPressure = true;
  }
  
  return {
    ok: true,
    kind: "autopoiesis_feed_readiness",
    redacted: true,
    status,
    pollingStatus: feedPollingSummary(feed, device),
    totals: {
      totalItems,
      eligibleItems,
      displayQueueItems,
      playableItems,
      cachedPlayableItems,
      cacheEligibleItems,
      freshQueueItems,
      replayQueueItems
    },
    cursor: {
      shownCount: (feedCursor().shownItemIds || []).length
    },
    blockers: {
      display: {
        artistBlocked: 0, // Simplified - would need actual artist blocking logic
        expired: expiredItems
      },
      cache: {
        cacheNotAllowed: cacheNotAllowed
      }
    },
    displayPlan: {
      nextItemId,
      firstItem: nextItem ? {
        priority: nextItem.priority || "normal",
        displayCategory: nextItem.displayCategory || feedItemCategory(nextItem)
      } : null,
      mediaSourceCounts,
      totalDisplaySeconds,
      freshness: {
        status: freshnessStatus,
        refreshRecommended: freshnessRefreshRecommended
      }
    },
    refreshRecommendation: {
      recommended: refreshRecommended,
      immediate: refreshImmediate,
      status: refreshReason.length > 0 ? refreshReason[0] : "none",
      reasons: refreshReason,
      displayPressure,
      displayPlan: {
        freshnessStatus,
        freshnessRefreshRecommended
      }
    }
  };
}

