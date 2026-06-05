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
  broadcast: path.join(DATA_DIR, "current-broadcast.json"),
  diagnostics: path.join(DATA_DIR, "diagnostics.json")
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

function writeFeedState(feed) {
  writeJson(paths.feed, feed);
  const cacheItems = eligibleFeedItems(feed)
    .filter(item => item.cacheAllowed && (item.mediaUrl || item.thumbnailUrl))
    .map(item => ({
      id: item.id,
      source: item.source,
      type: item.type,
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
}

function publicFeed() {
  const feed = readJson(paths.feed, { syncedAt: null, items: [] });
  const items = eligibleFeedItems(feed).map(({ raw, ...item }) => item);
  const cache = readJson(paths.feedCache, { generatedAt: null, count: 0, items: [] });
  return {
    ok: true,
    syncedAt: feed.syncedAt || null,
    totalItems: (feed.items || []).length,
    eligibleItems: items.length,
    cacheEligibleItems: cache.count || 0,
    items
  };
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
    feed: {
      syncedAt: feed.syncedAt || null,
      totalItems: Array.isArray(feed.items) ? feed.items.length : 0,
      eligibleItems: eligibleFeedItems(feed, data.preferences).length,
      cacheEligibleItems: cacheManifest.count || 0,
      cacheManifestGeneratedAt: cacheManifest.generatedAt || null
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
    pendingCommands: diagnostics.pendingCommands || 0,
    feed: diagnostics.feed || null,
    broadcast: diagnostics.broadcast || null,
    collectedAt: diagnostics.collectedAt || null
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
  const paired = data.device.paired ? "Paired" : "Not paired";
  const network = data.network || {};
  const pairing = data.pairing || {};
  const networkLabel = network.online
    ? `${network.primary || "network"} online`
    : "Offline";
  const pairingDetail = pairing.pairingCode
    ? `${pairing.pairingCode}${pairing.mock ? " (local fallback)" : ""}`
    : paired;
  return page(
    "Autopoiesis Setup",
    `<main class="screen">
      <section class="panel">
        <p class="kicker">Autopoiesis Frame</p>
        <h1>Setup</h1>
        <p class="muted">Prepare this frame for network, pairing, and display mode.</p>
        <dl class="status">
          <div><dt>Device</dt><dd>${escapeHtml(data.device.deviceId)}</dd></div>
          <div><dt>Network</dt><dd>${escapeHtml(networkLabel)}</dd></div>
          <div><dt>Pairing</dt><dd>${escapeHtml(pairingDetail)}</dd></div>
          <div><dt>Mode</dt><dd>${escapeHtml(data.state.currentMode || "setup")}</dd></div>
        </dl>
        <div class="actions">
          <a class="button" href="/settings">Settings</a>
          <a class="button" href="/network">Network</a>
          <button data-start-pairing>Start pairing</button>
          <button data-check-pairing>Check pairing</button>
          <a class="button primary" href="/launch">Launch frame</a>
        </div>
        <p class="note">Online pairing is used when the Frames API is reachable; local fallback remains available for offline setup.</p>
      </section>
    </main>`,
    `document.querySelector("[data-start-pairing]").addEventListener("click", async () => {
      await fetch("/local/pairing/start", { method: "POST" });
      location.reload();
    });
    document.querySelector("[data-check-pairing]").addEventListener("click", async () => {
      await fetch("/local/pairing/check", { method: "POST" });
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
  const retrySeconds = Number.isFinite(OFFLINE_RETRY_SECONDS) && OFFLINE_RETRY_SECONDS > 0
    ? OFFLINE_RETRY_SECONDS
    : 30;
  return page(
    "Autopoiesis Offline",
    `<main class="screen fallback">
      <section>
        <p class="kicker">Autopoiesis Frame</p>
        <h1>Offline mode</h1>
        <p>The frame is keeping a calm local fallback ready while the network is unavailable.</p>
        <dl class="status">
          <div><dt>Device</dt><dd>${escapeHtml(data.device.deviceId || "unknown")}</dd></div>
          <div><dt>Last check</dt><dd>${escapeHtml(data.state.lastOfflineFallbackAt || "pending")}</dd></div>
          <div><dt>Retry</dt><dd>${escapeHtml(retrySeconds)} seconds</dd></div>
        </dl>
      </section>
    </main>`,
    `setTimeout(() => { location.href = "/launch"; }, ${Math.round(retrySeconds * 1000)});`
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

async function renderLaunch(res) {
  const data = status();
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
  const launchUrl = data.device.framesUrl || "https://autopoiesis.art/frames";
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
  const result = await apiRequest(`/frames/device/${encodeURIComponent(data.device.deviceId)}/heartbeat`, {
    method: "POST",
    body: JSON.stringify({
      softwareVersion: version(),
      currentMode: data.state.currentMode || "setup",
      currentArtworkId: data.state.currentArtworkId || null,
      networkOnline: Boolean(data.state.networkOnline),
      networkType: data.state.networkType || null,
      storageStatus: data.state.storageStatus || diagnostics.storage,
      diagnostics
    })
  });
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
  return { ok: true, release, currentVersion: version() };
}

async function applyRelease(release) {
  if (!release) return { ok: false, skipped: true, reason: "No release available" };
  const targetVersion = release.version;
  if (!targetVersion) return { ok: false, error: "Release has no version" };
  if (targetVersion === version()) return { ok: true, skipped: true, reason: "Already on target version", version: targetVersion };
  writeJson(paths.release, { checkedAt: new Date().toISOString(), release });
  writeJson(paths.releaseState, {
    status: "in_progress",
    targetVersion,
    releaseId: release.id || null,
    startedAt: new Date().toISOString(),
    previousVersion: version()
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
  const commandType = command.commandType || command.command_type;
  const payload = command.payload || {};
  appendLog("commands.log", "execute " + command.id + " " + commandType);
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
  const heartbeat = await sendHeartbeat();
  const commands = heartbeat.commands || readJson(paths.commands, []);
  const results = [];
  for (const command of commands) {
    if (!command.id) continue;
    try {
      await ackCommand(device.deviceId, command.id, "acknowledged");
      const result = await executeCommand(command);
      if (result && result.ok === false) {
        await ackCommand(device.deviceId, command.id, "error", { error: result.error || "Command failed" });
      } else {
        await ackCommand(device.deviceId, command.id, "completed");
      }
      results.push({ commandId: command.id, commandType: command.commandType, result });
    } catch (error) {
      const message = error.stderr || error.message;
      appendLog("commands-error.log", command.id + " " + message);
      try {
        await ackCommand(device.deviceId, command.id, "error", { error: message });
      } catch (ackError) {
        appendLog("commands-error.log", command.id + " ack failed " + ackError.message);
      }
      results.push({ commandId: command.id, commandType: command.commandType, error: message });
    }
  }
  writeJson(paths.commands, []);
  return { ok: true, processed: results.length, results };
}

async function handle(req, res) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  try {
    if ((req.method === "GET" || req.method === "HEAD") && url.pathname === "/") return redirect(res, "/launch");
    if ((req.method === "GET" || req.method === "HEAD") && url.pathname === "/launch") return renderLaunch(res);
    if (req.method === "GET" && url.pathname === "/setup") return html(res, renderSetup());
    if (req.method === "GET" && url.pathname === "/network") return html(res, renderNetwork());
    if (req.method === "GET" && url.pathname === "/settings") return html(res, renderSettings());
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
    if (req.method === "GET" && url.pathname === "/local/feed") {
      return sendJson(res, publicFeed());
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
dt { color: #9ad0bb; }
dd { margin: 0; overflow-wrap: anywhere; }
.actions, .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 14px; }
button, .button, input { min-height: 56px; border-radius: 8px; border: 1px solid #607069; background: #202b27; color: #f4f1e8; font: inherit; font-size: 18px; padding: 14px 16px; }
.button { display: inline-grid; place-items: center; text-decoration: none; text-align: center; }
.primary { background: #d8f3dc; color: #122018; border-color: #d8f3dc; }
label { display: grid; gap: 8px; color: #c8c6bb; font-size: 18px; }
.check { display: flex; align-items: center; gap: 12px; }
.check input { min-height: auto; width: 24px; height: 24px; }
.network-list { display: grid; gap: 10px; margin: 24px 0; }
.network-row { display: grid; grid-template-columns: minmax(0, 1fr) auto; align-items: center; text-align: left; width: 100%; }
.network-row span { overflow-wrap: anywhere; }
.broadcast-screen { background: #121417; }
.broadcast-panel { width: min(1100px, 100%); }
.broadcast-panel h1 { font-size: clamp(42px, 7vw, 110px); }
.broadcast-media { margin: 26px 0; }
.broadcast-media img { display: block; width: 100%; max-height: 55vh; object-fit: contain; border-radius: 8px; }
.compact { width: min(620px, 100%); }
`);
}

ensureState();
http.createServer(handle).listen(PORT, "127.0.0.1", () => {
  console.log(`Autopoiesis local UI listening on http://127.0.0.1:${PORT}`);
});
