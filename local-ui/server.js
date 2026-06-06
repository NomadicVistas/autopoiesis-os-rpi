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
const RELEASE_LOG_LIMIT = Number(process.env.AUTOPOIESIS_RELEASE_LOG_LIMIT || 100);
const HEARTBEAT_EVENT_LIMIT = Number(process.env.AUTOPOIESIS_HEARTBEAT_EVENT_LIMIT || 10);
const FEED_QUEUE_LIMIT = Number(process.env.AUTOPOIESIS_FEED_QUEUE_LIMIT || 100);
const EVENT_CURSOR_OVERLAP_MS = Number(process.env.AUTOPOIESIS_EVENT_CURSOR_OVERLAP_MS || 1000);

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
  eventCursor: path.join(DATA_DIR, "event-cursor.json")
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
  return { device, preferences, state, network, pairing, version: version() };
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
  if (!Object.keys(remoteSettings).length) return { applied: false, skipped: true, reason: "No settings in response" };

  const now = new Date().toISOString();
  const preferences = readJson(paths.preferences, {});
  const device = readJson(paths.device, {});
  const remoteUpdatedAt = settingsUpdatedAt(remoteSettings, result.updatedAt || result.settingsUpdatedAt || result.settings_updated_at);
  const localUpdatedAt = settingsUpdatedAt(
    preferences,
    device.settingsUpdatedAt || (device.settingsSync || {}).localUpdatedAt || (device.settingsSync || {}).remoteUpdatedAt
  );

  if (remoteUpdatedAt && localUpdatedAt && parseTimestamp(remoteUpdatedAt) < parseTimestamp(localUpdatedAt)) {
    writeSettingsSyncStatus({
      status: "local_newer",
      source,
      conflict: true,
      reason: "remote_settings_stale",
      localUpdatedAt,
      remoteUpdatedAt,
      checkedAt: now
    });
    return {
      applied: false,
      conflict: true,
      reason: "remote_settings_stale",
      localUpdatedAt,
      remoteUpdatedAt
    };
  }

  const appliedUpdatedAt = remoteUpdatedAt || now;
  writeJson(paths.preferences, {
    ...preferences,
    ...remoteSettings,
    updatedAt: appliedUpdatedAt
  });
  writeSettingsSyncStatus({
    status: remoteUpdatedAt ? "remote_applied" : "remote_applied_untimestamped",
    source,
    conflict: false,
    localUpdatedAt: appliedUpdatedAt,
    remoteUpdatedAt,
    checkedAt: now
  });
  return {
    applied: true,
    conflict: false,
    localUpdatedAt: appliedUpdatedAt,
    remoteUpdatedAt
  };
}

function isExpired(value, now = Date.now()) {
  const timestamp = parseTimestamp(value);
  return timestamp !== null && timestamp <= now;
}

function priorityRank(value) {
  const priority = String(value || "normal").toLowerCase();
  return {
    emergency: 500,
    critical: 400,
    high: 300,
    normal: 200,
    low: 100
  }[priority] || 200;
}

function feedItemTypeAllowed(item, preferences) {
  const type = String(item.type || "").toLowerCase();
  if (!preferences.allowImages && (type.includes("image") || type === "artwork")) return false;
  if (!preferences.allowVideos && type.includes("video")) return false;
  if (!preferences.allowSoundWorks && (type.includes("audio") || type.includes("sound"))) return false;
  if (!preferences.allowGenerativeWorks && type.includes("generative")) return false;
  return true;
}

function feedItemCategory(item = {}) {
  const source = String(item.source || "").toLowerCase();
  const type = String(item.type || "").toLowerCase();
  if (source === "broadcast" || type.includes("broadcast")) return "broadcast";
  if (type.includes("curatorial") || type.includes("announcement") || type.includes("notice")) return "curatorial";
  if (type.includes("blog") || type.includes("essay") || type.includes("post")) return "blog";
  if (type.includes("news") || type.includes("update")) return "news";
  if (type.includes("artwork") || type.includes("artist_drop")) return "artwork";
  if (
    type.includes("image") ||
    type.includes("video") ||
    type.includes("audio") ||
    type.includes("sound") ||
    type.includes("generative")
  ) {
    return "artwork";
  }
  return "content";
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
  const type = raw.type || (source === "broadcast" ? "broadcast_message" : "artwork_image");
  return {
    id: String(id),
    source,
    type,
    title: raw.title || raw.name || null,
    artist: raw.artist || raw.artistName || raw.artist_name || null,
    body: raw.body || raw.description || raw.message || null,
    url: raw.url || raw.href || null,
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
    items
  };
}

function eligibleFeedItems(feed = readJson(paths.feed, {}), preferences = readJson(paths.preferences, {})) {
  const now = Date.now();
  return (feed.items || [])
    .filter(item => !isExpired(item.expiresAt, now))
    .filter(item => {
      const startsAt = parseTimestamp(item.startsAt);
      return startsAt === null || startsAt <= now;
    })
    .filter(item => feedItemTypeAllowed(item, preferences))
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
  const priorityGroups = new Map();

  for (const item of eligibleItems) {
    const rank = priorityRank(item.priority);
    if (!priorityGroups.has(rank)) priorityGroups.set(rank, []);
    priorityGroups.get(rank).push(item);
  }

  const queue = [];
  const ranks = Array.from(priorityGroups.keys()).sort((a, b) => b - a);
  for (const rank of ranks) {
    const buckets = new Map(categoryOrder.map(category => [category, []]));
    for (const item of priorityGroups.get(rank) || []) {
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
  writeJson(paths.feed, feed);
  const displayQueue = mixedFeedQueue(feed);
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
    syncedAt: feed.syncedAt || null
  });
}

function publicFeed() {
  const feed = readJson(paths.feed, { syncedAt: null, items: [] });
  const items = eligibleFeedItems(feed).map(({ raw, ...item }) => item);
  const displayQueue = mixedFeedQueue(feed).map(({ raw, ...item }) => item);
  const cache = readJson(paths.feedCache, { generatedAt: null, count: 0, items: [] });
  return {
    ok: true,
    syncedAt: feed.syncedAt || null,
    totalItems: (feed.items || []).length,
    eligibleItems: items.length,
    cacheEligibleItems: cache.count || 0,
    categories: feedCategoryCounts(items),
    displayQueueItems: displayQueue.length,
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
  const feedById = new Map(eligibleFeedItems(feed).map(item => [String(item.id), item]));
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

function publicFrameState() {
  const feed = readJson(paths.feed, { syncedAt: null, items: [] });
  const preferences = readJson(paths.preferences, {});
  const cacheItems = new Map(cachedOfflineItems().map(item => [String(item.id), item]));
  const displayQueue = mixedFeedQueue(feed, preferences).map(({ raw, ...item }) => item);
  const items = displayQueue.map(item => {
    const cached = cacheItems.get(String(item.id));
    const cachedMedia = cached && cached.media && cached.media.available ? cached.media : null;
    const cachedThumbnail = cached && cached.thumbnail && cached.thumbnail.available ? cached.thumbnail : null;
    const localAsset = cachedMedia || cachedThumbnail;
    const remoteUrl = item.mediaUrl || item.thumbnailUrl || null;
    const mediaUrl = localAsset ? localAsset.url : remoteUrl;
    return {
      id: item.id,
      source: item.source || null,
      type: item.type || null,
      title: item.title || null,
      artist: item.artist || null,
      body: item.body || null,
      url: item.url || null,
      priority: item.priority || "normal",
      displayCategory: item.displayCategory || feedItemCategory(item),
      displayPosition: item.displayPosition || null,
      duration: item.duration || null,
      soundRequired: Boolean(item.soundRequired),
      expiresAt: item.expiresAt || null,
      media: {
        url: mediaUrl,
        role: mediaRoleForUrl(item, mediaUrl),
        cached: Boolean(localAsset),
        source: localAsset ? "cache" : (remoteUrl ? "remote" : null)
      }
    };
  });
  const playableItems = items.filter(item => item.media.url || item.title || item.body);
  return {
    ok: true,
    kind: "autopoiesis_frame_state",
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    syncedAt: feed.syncedAt || null,
    totalItems: Array.isArray(feed.items) ? feed.items.length : 0,
    displayQueueItems: displayQueue.length,
    playableItems: playableItems.length,
    cachedPlayableItems: playableItems.filter(item => item.media.cached).length,
    categories: feedCategoryCounts(displayQueue),
    items: playableItems
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

async function syncFeedFromRemote() {
  const device = readJson(paths.device, {});
  if (!device.deviceId || !device.paired) return { ok: false, skipped: true, reason: "Device is not paired" };
  const result = await apiRequest("/frames/device/" + encodeURIComponent(device.deviceId) + "/feed");
  const feed = normalizeFeedPayload(result);
  writeFeedState(feed);
  writeJson(paths.device, { ...device, lastFeedSyncAt: feed.syncedAt });
  return {
    ok: true,
    syncedAt: feed.syncedAt,
    totalItems: feed.items.length,
    eligibleItems: eligibleFeedItems(feed).length
  };
}

function activeBroadcast(now = Date.now()) {
  const broadcast = readJson(paths.broadcast, null);
  if (!broadcast) return null;
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

  if (diagnostics.memory && Number.isFinite(diagnostics.memory.freeMb) && diagnostics.memory.freeMb < 128) {
    add("warning", "memory_low", "Less than 128 MB of system memory is free.");
  }

  if (Number.isFinite(diagnostics.temperatureC)) {
    if (diagnostics.temperatureC >= 85) {
      add("error", "temperature_critical", "Device temperature is at or above 85 C.");
    } else if (diagnostics.temperatureC >= 75) {
      add("warning", "temperature_high", "Device temperature is at or above 75 C.");
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

  if (diagnostics.services) {
    for (const [serviceName, serviceStatus] of Object.entries(diagnostics.services)) {
      if (serviceStatus === "failed") {
        add("error", "service_failed", serviceName + " is failed.");
      }
    }
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
  const releaseHistory = releaseHistorySummary();
  const disk = await diskStatus(DATA_DIR);
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
    temperatureC: readTemperatureC(),
    mode: data.state.currentMode || "setup",
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
      dataDisk: disk,
      cache: directoryStats(CACHE_DIR)
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
    releaseHistory,
    eventIngestion: eventIngestionSummary(),
    feed: {
      syncedAt: feed.syncedAt || null,
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
      offlinePlayableItems: cachedOfflineItems().length
    },
    broadcast: broadcast
      ? {
          broadcastId: broadcast.broadcastId || broadcast.id || null,
          shownAt: broadcast.shownAt || null,
          title: broadcast.title || null,
          priority: broadcast.priority || null,
          expiresAt: broadcast.expiresAt || null
        }
      : null
  };
  if (options.includeServices) diagnostics.services = await serviceDiagnostics();
  diagnostics.health = diagnosticsHealth(diagnostics, data);
  writeJson(paths.diagnostics, diagnostics);
  return diagnostics;
}

function phase(ready, statusValue, summary, details = {}) {
  return { ready: Boolean(ready), status: statusValue, summary, ...details };
}

function serviceActive(services, serviceName) {
  if (!services || !Object.prototype.hasOwnProperty.call(services, serviceName)) return null;
  return services[serviceName] === "active";
}

function readinessSummary(diagnostics) {
  const health = diagnostics.health || {};
  const networkOnline = Boolean(health.networkOnline);
  const paired = Boolean(health.paired);
  const deviceKeyPresent = Boolean(health.deviceKeyPresent);
  const feed = diagnostics.feed || {};
  const release = diagnostics.release || null;
  const services = diagnostics.services || null;
  const commandAudit = diagnostics.commandAudit || {};
  const commandExecutorActive = serviceActive(services, "autopoiesis-command-executor.service");
  const cacheServiceActive = serviceActive(services, "autopoiesis-cache.service");
  const heartbeatServiceActive = serviceActive(services, "autopoiesis-heartbeat.service");

  const phases = {
    localUi: phase(true, "ready", "Local UI responded and produced diagnostics."),
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
    content: phase(
      Boolean(feed.syncedAt || feed.totalItems || feed.eligibleItems),
      feed.syncedAt ? "ready" : "waiting_for_feed",
      feed.syncedAt ? "A feed has been synced locally." : "No local feed sync has completed yet.",
      { feed }
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
  const hasError = health.status === "error" || blockers.some(item => ["missing_device_key", "conflict", "empty_or_failed", "pending_commands", "error"].includes(item.status));
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
    pairing: {
      paired: Boolean(health.paired)
    },
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
    feed: diagnostics.feed || null,
    broadcast: diagnostics.broadcast || null,
    collectedAt: diagnostics.collectedAt || null
  };
}

async function supportBundle(options = {}) {
  const diagnostics = await collectDiagnostics({ includeServices: options.includeServices });
  const health = healthSummary(diagnostics);
  const readiness = readinessSummary(diagnostics);
  const feed = publicFeed();
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
      pendingCommands: health.pendingCommands || 0,
      offlinePlayableItems: offlineCache.playableItems || 0,
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
    writeNetworkState(network);
    callback(null, { ok: true, network, devices });
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
  const pairingDetail = pairing.pairingCode
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
              <div class="pairing-code">${escapeHtml(pairingDetail)}</div>
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
                <label class="check"><input name="nightMode" type="checkbox" ${data.preferences.nightMode ? "checked" : ""}> Night mode</label>
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
    `async function refreshNetwork() {
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
      await fetch("/local/pairing/start", { method: "POST" });
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
            nightMode: form.has("nightMode")
          }
        })
      });
      location.reload();
    });`
  );
}

function renderSettings() {
  const data = status();
  return page(
    "Autopoiesis Settings",
    `<main class="screen">
      <section class="panel wide">
        <p class="kicker">Local settings</p>
        <h1>Frame preferences</h1>
        <form id="settings-form" class="grid">
          <label>Device name <input name="deviceName" value="${escapeHtml(data.device.deviceName || "")}"></label>
          <label>Volume <input name="volume" type="number" min="0" max="100" value="${escapeHtml(data.preferences.volume ?? 50)}"></label>
          <label>Image duration <input name="imageDuration" type="number" min="5" max="3600" value="${escapeHtml(data.preferences.imageDuration ?? 60)}"></label>
          <label class="check"><input name="soundEnabled" type="checkbox" ${data.preferences.soundEnabled ? "checked" : ""}> Sound enabled</label>
          <label class="check"><input name="nightMode" type="checkbox" ${data.preferences.nightMode ? "checked" : ""}> Night mode</label>
          <button class="primary" type="submit">Save</button>
          <a class="button" href="/setup">Back</a>
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
            volume: Number(form.get("volume")),
            imageDuration: Number(form.get("imageDuration")),
            soundEnabled: form.has("soundEnabled"),
            nightMode: form.has("nightMode")
          }
        })
      });
      location.href = "/setup";
    });`
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
    `<main class="screen">
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
  return String(value).replace(/[&<>"]/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;" }[char]));
}
async function scanWifi() {
  list.textContent = "Scanning...";
  const response = await fetch("/local/wifi/scan.json");
  const data = await response.json();
  if (!data.ok) {
    list.textContent = data.error || "Wi-Fi scan unavailable.";
    return;
  }
  list.innerHTML = data.networks.map(network => (
    "<button type=\"button\" class=\"network-row\" data-ssid=\"" + escapeText(network.ssid) + "\">" +
    "<span>" + escapeText(network.ssid) + "</span>" +
    "<span>" + Number(network.signal || 0) + "% " + escapeText(network.security || "open") + "</span>" +
    "</button>"
  )).join("") || "No Wi-Fi networks found.";
  list.querySelectorAll("[data-ssid]").forEach(button => {
    button.addEventListener("click", () => {
      form.elements.ssid.value = button.dataset.ssid;
      form.elements.password.focus();
    });
  });
}
form.addEventListener("submit", async event => {
  event.preventDefault();
  const body = {
    ssid: form.elements.ssid.value,
    password: form.elements.password.value
  };
  const response = await fetch("/local/wifi/connect", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body)
  });
  const data = await response.json();
  list.textContent = data.ok ? "Connected. Returning to network status..." : (data.error || "Connection failed.");
  if (data.ok) setTimeout(() => { location.href = "/network"; }, 900);
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
  const durationSeconds = Number(data.preferences.imageDuration || 60);
  const rotationSeconds = Number.isFinite(durationSeconds) && durationSeconds > 0
    ? Math.min(Math.max(durationSeconds, 8), 300)
    : 60;
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
    </main>`,
    `const frameItems = ${scriptJson(frame.items)};
    const rotationMs = ${Math.round(rotationSeconds * 1000)};
    let frameIndex = 0;
    const stage = document.getElementById("frame-stage");
    function escapeText(value) {
      return String(value || "").replace(/[&<>"]/g, char => {
        if (char === "&") return "&amp;";
        if (char === "<") return "&lt;";
        if (char === ">") return "&gt;";
        return "&quot;";
      });
    }
    function mediaMarkup(item) {
      const media = item.media || {};
      const url = media.url || "";
      if (!url) return "";
      if (media.role === "video") return "<video src=\\"" + escapeText(url) + "\\" autoplay muted loop playsinline></video>";
      if (media.role === "audio") return "<audio src=\\"" + escapeText(url) + "\\" autoplay loop controls></audio>";
      return "<img src=\\"" + escapeText(url) + "\\" alt=\\"\\">";
    }
    function renderFrameItem() {
      if (!stage || !frameItems.length) {
        if (!frameItems.length) {
          fetch("/local/feed/sync", { method: "POST" }).finally(() => {
            setTimeout(() => { location.reload(); }, Math.max(rotationMs, 15000));
          });
        }
        return;
      }
      const item = frameItems[frameIndex % frameItems.length];
      const meta = [item.artist, item.displayCategory, item.media && item.media.cached ? "cached" : ""].filter(Boolean).map(escapeText).join(" / ");
      const body = item.body ? "<p>" + escapeText(item.body) + "</p>" : "";
      const media = mediaMarkup(item);
      stage.innerHTML = (media ? "<figure class=\\"frame-media\\">" + media + "</figure>" : "") +
        "<div class=\\"frame-caption\\"><div><strong>" + escapeText(item.title || item.id) + "</strong>" + body + "</div>" +
        (meta ? "<span>" + meta + "</span>" : "") + "</div>";
      frameIndex += 1;
    }
    renderFrameItem();
    setInterval(renderFrameItem, rotationMs);`
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
  const broadcast = activeBroadcast();
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
  if (data.state.remoteDisabled || data.device.remoteEnabled === false) {
    updateState({ currentMode: "disabled" });
    redirect(res, "/disabled");
    return;
  }
  if (data.state.currentMode === "broadcast" && activeBroadcast()) {
    redirect(res, "/broadcast");
    return;
  }
  if (!data.device.firstRunComplete || !data.device.paired) {
    updateState({ currentMode: "setup" });
    redirect(res, "/setup");
    return;
  }
  if (!data.device.onboardingComplete && !completingOnboarding) {
    updateState({ currentMode: "setup" });
    redirect(res, "/setup");
    return;
  }
  if (completingOnboarding && !data.device.onboardingComplete) {
    writeJson(paths.device, {
      ...data.device,
      onboardingComplete: true,
      firstRunComplete: true
    });
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
    const networks = stdout
      .split("\n")
      .filter(Boolean)
      .map(line => {
        const [ssid, signal, security] = splitNmcliLine(line);
        return { ssid, signal: Number(signal), security };
      })
      .filter(network => network.ssid);
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
    return localPairingFallback(error);
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
  const diagnostics = await collectDiagnostics();
  const eventCursor = eventIngestionCursor();
  const eventReplaySince = eventCursorReplaySince(eventCursor);
  const events = publicDeviceEvents({ limit: HEARTBEAT_EVENT_LIMIT, since: eventReplaySince });
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
      eventIngestionCursor: eventCursor
        ? {
            status: eventCursor.status || null,
            acceptedAt: eventCursor.acceptedAt || null,
            acceptedThroughObservedAt: eventCursor.acceptedThroughObservedAt || null,
            acceptedThroughEventKey: eventCursor.acceptedThroughEventKey || null,
            replaySince: eventReplaySince
          }
        : null,
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
  if (result.settings) applyRemoteSettingsPayload(result, "heartbeat");
  if (result.commands) writeJson(paths.commands, result.commands);
  if (result.feed || result.items || result.artworks || result.broadcasts) {
    writeFeedState(normalizeFeedPayload(result));
  }
  writeJson(paths.device, { ...readJson(paths.device, {}), lastHeartbeatAt: new Date().toISOString() });
  return result;
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
  if (targetVersion === version()) {
    appendReleaseEvent({
      eventType: "release_skipped",
      status: "current",
      reason: "Already on target version",
      currentVersion: version(),
      ...releaseSubject(release)
    });
    return { ok: true, skipped: true, reason: "Already on target version", version: targetVersion };
  }
  writeJson(paths.release, { checkedAt: new Date().toISOString(), release });
  const startedAt = new Date().toISOString();
  writeJson(paths.releaseState, {
    status: "in_progress",
    targetVersion,
    releaseId: release.id || null,
    startedAt,
    previousVersion: version()
  });
  appendReleaseEvent({
    eventType: "release_apply_started",
    status: "in_progress",
    previousVersion: version(),
    startedAt,
    ...releaseSubject(release)
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
      ...releaseSubject(release)
    });
    return { ok: true, release, version: version(), update: stateValue };
  } catch (error) {
    const stateValue = {
      status: "error",
      targetVersion,
      releaseId: release.id || null,
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
      ...releaseSubject(release)
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
    if (isExpired(broadcast.expiresAt)) {
      return { ok: false, error: "Broadcast is expired", broadcastId: broadcast.id };
    }
    writeJson(paths.broadcast, {
      ...broadcast,
      broadcastId: payload.broadcastId || payload.id || broadcast.id,
      shownAt: new Date().toISOString()
    });
    appendDeliveryEvent({
      eventType: "broadcast_shown",
      ...deliverySubject(broadcast),
      itemId: payload.broadcastId || payload.id || broadcast.id,
      commandId: command.id || null
    });
    writeJson(paths.state, {
      ...stateValue,
      currentMode: "broadcast",
      currentBroadcastId: payload.broadcastId || payload.id || broadcast.id
    });
    return { ok: true, broadcastId: payload.broadcastId || payload.id || broadcast.id };
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
        try {
          await ackCommand(device.deviceId, commandId, "error", finalAck);
        } catch (error) {
          const message = error.stderr || error.message;
          appendLog("commands-error.log", commandId + " final error ack failed " + message);
          retained.push(commandForStorage(normalizedCommand, ackRetry(normalizedCommand, "final", "error", finalAck, message)));
        }
        appendCommandAudit({
          ...auditBase,
          status: "error",
          startedAt,
          completedAt: new Date().toISOString(),
          error: result.error || "Command failed"
        });
      } else {
        try {
          await ackCommand(device.deviceId, commandId, "completed");
        } catch (error) {
          const message = error.stderr || error.message;
          appendLog("commands-error.log", commandId + " final completed ack failed " + message);
          retained.push(commandForStorage(normalizedCommand, ackRetry(normalizedCommand, "final", "completed", {}, message)));
        }
        appendCommandAudit({
          ...auditBase,
          status: "completed",
          startedAt,
          completedAt: new Date().toISOString()
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
    if (req.method === "GET" && url.pathname === "/setup") return html(res, renderSetup());
    if (req.method === "GET" && url.pathname === "/network") return html(res, renderNetwork());
    if (req.method === "GET" && url.pathname === "/settings") return html(res, renderSettings());
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
    if (req.method === "GET" && url.pathname === "/local/offline-cache") {
      return sendJson(res, publicOfflineCache());
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
      return sendJson(res, { ok: true, ...(await startPairing()) });
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
button, .button, input { min-height: 56px; border-radius: 8px; border: 1px solid #607069; background: #202b27; color: #f4f1e8; font: inherit; font-size: 18px; padding: 14px 16px; }
.button { display: inline-grid; place-items: center; text-decoration: none; text-align: center; }
.primary { background: #d8f3dc; color: #122018; border-color: #d8f3dc; }
button:disabled, .button.disabled { opacity: 0.45; pointer-events: none; }
label { display: grid; gap: 8px; color: #c8c6bb; font-size: 18px; }
.check { display: flex; align-items: center; gap: 12px; }
.check input { min-height: auto; width: 24px; height: 24px; }
.onboarding h1 { font-size: clamp(38px, 7vw, 78px); }
.onboarding h2 { margin: 0 0 8px; font-size: clamp(24px, 4vw, 38px); letter-spacing: 0; }
.onboarding p { margin: 0 0 14px; }
.steps { list-style: none; display: grid; gap: 18px; margin: 30px 0; padding: 0; }
.step { display: grid; grid-template-columns: 64px 1fr; gap: 18px; padding: 22px; border: 1px solid #343d39; border-radius: 8px; background: #141b18; }
.step.active { border-color: #9ad0bb; background: #18231f; }
.step.done { border-color: #6fae82; }
.step-index { width: 48px; height: 48px; display: grid; place-items: center; border-radius: 999px; border: 1px solid #607069; color: #9ad0bb; font-size: 22px; }
.step.done .step-index { background: #d8f3dc; border-color: #d8f3dc; color: #122018; }
.pairing-code { margin: 14px 0; padding: 18px; border: 1px solid #607069; border-radius: 8px; background: #101412; color: #d8f3dc; font-size: clamp(28px, 6vw, 56px); letter-spacing: 0.08em; text-align: center; overflow-wrap: anywhere; }
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
.frame-stage { display: grid; gap: 18px; }
.frame-media { margin: 0; display: grid; place-items: center; min-height: 68vh; background: #101412; border: 1px solid #2d3834; border-radius: 8px; overflow: hidden; }
.frame-media img, .frame-media video { display: block; width: 100%; height: 68vh; object-fit: contain; background: #0d1110; }
.frame-media audio { width: min(720px, 90%); }
.frame-caption { display: flex; justify-content: space-between; align-items: flex-start; gap: 20px; color: #c8c6bb; font-size: 18px; }
.frame-caption strong { display: block; color: #f4f1e8; font-size: clamp(24px, 4vw, 44px); overflow-wrap: anywhere; }
.frame-caption p { max-width: 820px; margin: 8px 0 0; color: #c8c6bb; font-size: 20px; }
.frame-caption span { text-align: right; overflow-wrap: anywhere; }
.offline-screen { align-items: stretch; justify-items: stretch; padding: 4vw; }
.offline-gallery, .offline-empty { width: min(1180px, 100%); margin: auto; }
.offline-gallery h1, .offline-empty h1 { font-size: clamp(42px, 7vw, 96px); }
.offline-stage { display: grid; gap: 18px; margin: 24px 0; }
.offline-stage img, .offline-stage video { width: 100%; max-height: 58vh; object-fit: contain; border-radius: 8px; background: #0d1110; border: 1px solid #343d39; }
.offline-caption { display: flex; justify-content: space-between; gap: 16px; align-items: baseline; color: #c8c6bb; font-size: 20px; }
.offline-caption strong { color: #f4f1e8; font-size: 24px; overflow-wrap: anywhere; }
.offline-caption span { text-align: right; overflow-wrap: anywhere; }
.compact { width: min(620px, 100%); }
`);
}

ensureState();
http.createServer(handle).listen(PORT, "127.0.0.1", () => {
  console.log(`Autopoiesis local UI listening on http://127.0.0.1:${PORT}`);
});
