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

const paths = {
  device: path.join(DATA_DIR, "device.json"),
  preferences: path.join(DATA_DIR, "preferences.json"),
  state: path.join(DATA_DIR, "state.json"),
  pairing: path.join(DATA_DIR, "pairing.json")
};

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
  return { device, preferences, state, version: version() };
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

function renderSetup() {
  const data = status();
  const paired = data.device.paired ? "Paired" : "Not paired";
  return page(
    "Autopoiesis Setup",
    `<main class="screen">
      <section class="panel">
        <p class="kicker">Autopoiesis Frame</p>
        <h1>Setup</h1>
        <p class="muted">Prepare this frame for Wi-Fi, pairing, and display mode.</p>
        <dl class="status">
          <div><dt>Device</dt><dd>${escapeHtml(data.device.deviceId)}</dd></div>
          <div><dt>Pairing</dt><dd>${paired}</dd></div>
          <div><dt>Mode</dt><dd>${escapeHtml(data.state.currentMode || "setup")}</dd></div>
        </dl>
        <div class="actions">
          <a class="button" href="/settings">Settings</a>
          <a class="button" href="/local/wifi/scan">Scan Wi-Fi</a>
          <button data-start-pairing>Start pairing</button>
          <a class="button primary" href="/launch">Launch frame</a>
        </div>
        <p class="note">Wi-Fi and pairing use local mock flows until the production API is available.</p>
      </section>
    </main>`,
    `document.querySelector("[data-start-pairing]").addEventListener("click", async () => {
      await fetch("/local/pairing/start", { method: "POST" });
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

function renderOffline() {
  return page(
    "Autopoiesis Offline",
    `<main class="screen fallback">
      <section>
        <p class="kicker">Autopoiesis Frame</p>
        <h1>Offline mode</h1>
        <p>The frame is keeping a calm local fallback ready while the network is unavailable.</p>
      </section>
    </main>`
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

function renderLaunch(res) {
  const data = status();
  if (data.state.remoteDisabled || data.device.remoteEnabled === false) {
    redirect(res, "/disabled");
    return;
  }
  if (!data.device.firstRunComplete || !data.device.paired) {
    redirect(res, "/setup");
    return;
  }
  redirect(res, data.device.framesUrl || "https://autopoiesis.art/frames");
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
        const [ssid, signal, security] = line.split(":");
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

function startPairing() {
  const code = Math.random().toString(36).slice(2, 6).toUpperCase() + "-" + Math.floor(1000 + Math.random() * 9000);
  const device = readJson(paths.device, {});
  const pairing = {
    pairingCode: code,
    expiresAt: new Date(Date.now() + 15 * 60 * 1000).toISOString(),
    mock: true
  };
  writeJson(paths.pairing, pairing);
  writeJson(paths.device, { ...device, pairingCode: code, paired: false });
  return pairing;
}

async function handle(req, res) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  try {
    if ((req.method === "GET" || req.method === "HEAD") && url.pathname === "/") return redirect(res, "/launch");
    if ((req.method === "GET" || req.method === "HEAD") && url.pathname === "/launch") return renderLaunch(res);
    if (req.method === "GET" && url.pathname === "/setup") return html(res, renderSetup());
    if (req.method === "GET" && url.pathname === "/settings") return html(res, renderSettings());
    if (req.method === "GET" && url.pathname === "/offline") return html(res, renderOffline());
    if (req.method === "GET" && url.pathname === "/disabled") return html(res, renderDisabled());
    if (req.method === "GET" && url.pathname === "/style.css") return css(res);
    if (req.method === "GET" && url.pathname === "/local/status") return sendJson(res, status());
    if (req.method === "GET" && url.pathname === "/local/wifi/scan") {
      return scanWifi((_, value) => sendJson(res, value));
    }
    if (req.method === "POST" && url.pathname === "/local/wifi/connect") {
      const body = JSON.parse(await readBody(req) || "{}");
      return connectWifi(body.ssid, body.password, (_, value) => sendJson(res, value, value.ok ? 200 : 400));
    }
    if (req.method === "POST" && url.pathname === "/local/settings") {
      const body = JSON.parse(await readBody(req) || "{}");
      const device = { ...readJson(paths.device, {}), ...(body.device || {}) };
      const preferences = { ...readJson(paths.preferences, {}), ...(body.preferences || {}) };
      writeJson(paths.device, device);
      writeJson(paths.preferences, preferences);
      return sendJson(res, { ok: true });
    }
    if (req.method === "POST" && url.pathname === "/local/pairing/start") {
      return sendJson(res, { ok: true, ...startPairing() });
    }
    if (req.method === "GET" && url.pathname === "/local/pairing/status") {
      return sendJson(res, {
        ok: true,
        device: readJson(paths.device, {}),
        pairing: readJson(paths.pairing, {})
      });
    }
    if (req.method === "POST" && url.pathname === "/local/system/restart") {
      return sendJson(res, { ok: false, error: "Restart requires privileged systemd wiring in a later milestone." }, 501);
    }
    if (req.method === "POST" && url.pathname === "/local/system/factory-reset") {
      return sendJson(res, { ok: false, error: "Factory reset endpoint is reserved until confirmation and privilege handling are implemented." }, 501);
    }
    if (req.method === "POST" && url.pathname === "/local/system/update-now") {
      return sendJson(res, { ok: false, error: "Manual update endpoint is reserved until update rollback is implemented." }, 501);
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
`);
}

ensureState();
http.createServer(handle).listen(PORT, "127.0.0.1", () => {
  console.log(`Autopoiesis local UI listening on http://127.0.0.1:${PORT}`);
});
