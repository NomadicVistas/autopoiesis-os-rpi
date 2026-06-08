#!/usr/bin/env node
/**
 * release-state-heartbeat-check.mjs
 *
 * Validates that release-state.json data flows through the heartbeat pipeline
 * to the hosted API and admin dashboard.
 *
 * Steps:
 *  1. Syntax + schema contract
 *  2. Schema bootstrap with release columns
 *  3. Hosted API server startup + device lifecycle
 *  4. Heartbeat without releaseState → default idle + networkOnline
 *  5. Heartbeat with releaseState (in_progress)
 *  6. Heartbeat with releaseState (failed + error)
 *  7. Heartbeat with releaseState (completed)
 *  8. Admin snapshot includes release state
 *  9. Admin bundle fleet devices include release state
 * 10. Network-online fix verification
 * 11. Regression: existing endpoints work
 */

import { spawn } from "child_process";
import { mkdtempSync, rmSync, readFileSync, writeFileSync, existsSync } from "fs";
import { join, resolve } from "path";
import http from "http";
import { createRequire } from "module";

const require = createRequire(import.meta.url);

const REPO_ROOT = resolve(import.meta.dirname, "..");
const PASS = { count: 0 };
const FAIL = { count: 0 };
let STEP = 0;

function ok(msg) { PASS.count++; console.log(`\x1b[32m  ✓ ${msg}\x1b[0m`); }
function fail(msg) { FAIL.count++; console.log(`\x1b[31m  ✗ ${msg}\x1b[0m`); }
function step(msg) { STEP++; console.log(`\n\x1b[33mStep ${STEP}: ${msg}\x1b[0m`); }
function assert(condition, msg) { condition ? ok(msg) : fail(msg); }

const tmp = mkdtempSync("/tmp/aos-release-state-");
let serverProc = null;

async function cleanup() {
  if (serverProc) { serverProc.kill("SIGTERM"); await new Promise(r => setTimeout(r, 500)); }
  try { rmSync(tmp, { recursive: true }); } catch {}
}

// HTTP helpers
function request(method, path, body, headers = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(path, `http://127.0.0.1:${serverProc.port}`);
    const opts = {
      hostname: "127.0.0.1", port: serverProc.port,
      path: url.pathname + url.search, method, headers: { "Content-Type": "application/json", ...headers }
    };
    const req = http.request(opts, res => {
      let d = "";
      res.on("data", c => d += c);
      res.on("end", () => resolve({ status: res.statusCode, body: d }));
    });
    req.on("error", reject);
    if (body) req.end(typeof body === "string" ? body : JSON.stringify(body));
    else req.end();
  });
}
const POST = (path, body, h) => request("POST", path, body, h);
const GET = (path, h) => request("GET", path, null, h);

async function startServer() {
  // Find a free port and start server, with retry on EADDRINUSE
  for (let attempt = 0; attempt < 5; attempt++) {
    const port = await new Promise(res => {
      const s = http.createServer();
      s.listen(0, () => { res(s.address().port); s.close(); });
    });
    const dbPath = join(tmp, "server.db");
    
    let crashed = false;
    serverProc = spawn("node", [join(REPO_ROOT, "hosted-api/server.js")], {
      cwd: REPO_ROOT,
      env: {
        ...process.env,
        AOS_DB: dbPath, AOS_PORT: String(port), AOS_HOST: "127.0.0.1",
        AUTOPOIESIS_FRAMES_ADMIN_TOKEN: "test-admin-token"
      },
      stdio: ["pipe", "pipe", "pipe"]
    });
    serverProc.port = port;
    serverProc.dbPath = dbPath;
    serverProc.on("error", () => { crashed = true; });
    serverProc.on("exit", () => { crashed = true; });
    
    // Wait for server to start
    await new Promise(r => setTimeout(r, 2000));
    
    if (crashed) {
      // Port was taken, retry with different port
      await new Promise(r => setTimeout(r, 200));
      continue;
    }
    
    // Verify it's actually running
    try {
      const h = await GET("/health");
      if (h.status === 200) return port;
    } catch {}
    
    serverProc.kill("SIGTERM");
    await new Promise(r => setTimeout(r, 500));
  }
  throw new Error("Failed to start server after 5 attempts");
}

// ── Step 1: Syntax + schema contract ─────────────────────────────────────────
step("Syntax + schema contract");

const dbPath = join(REPO_ROOT, "hosted-api/db.js");
const serverPath = join(REPO_ROOT, "hosted-api/server.js");
const localUiPath = join(REPO_ROOT, "local-ui/server.js");
const sqliteSchema = join(REPO_ROOT, "scripts/aos-schema-sqlite-validation.sql");
const pgMigration = join(REPO_ROOT, "migrations/20260607000001_initial_aos_frames.sql");

// Syntax (strip shebang before new Function to avoid executing side effects)
for (const f of [serverPath, dbPath, localUiPath]) {
  try {
    const code = readFileSync(f, "utf-8").replace(/^#!.*\n?/, "");
    new Function(code);
    assert(true, `${f.split("/").pop()} parses`);
  } catch(e) { assert(false, `${f.split("/").pop()} syntax: ${e.message}`); }
}

// Schema columns
const schema = readFileSync(sqliteSchema, "utf-8");
for (const col of ["release_status", "release_target_version", "release_channel", "release_updated_at", "release_error"]) {
  assert(schema.includes(col), `schema has ${col} column`);
}

const pgMig = readFileSync(pgMigration, "utf-8");
for (const col of ["release_status", "release_target_version", "release_channel", "release_updated_at", "release_error"]) {
  assert(pgMig.includes(col), `pg migration has ${col} column`);
}

// Code contract
const dbJs = readFileSync(dbPath, "utf-8");
const serverJs = readFileSync(serverPath, "utf-8");
const localJs = readFileSync(localUiPath, "utf-8");

assert(dbJs.includes("payload.releaseState"), "db.js reads payload.releaseState");
assert(dbJs.includes("payload.networkOnline"), "db.js reads payload.networkOnline (fix)");
assert(!dbJs.includes("systemMetrics"), "db.js no longer references systemMetrics");
assert(localJs.includes("releaseState,"), "local-ui sends releaseState in heartbeat");
assert(serverJs.includes("releaseState: body.releaseState"), "server.js passes releaseState through");

for (const field of ["releaseStatus", "releaseTargetVersion", "releaseChannel", "releaseUpdatedAt", "releaseError"]) {
  assert(dbJs.includes(`${field}:`), `_mapDevice has ${field}`);
  assert(serverJs.includes(`${field}:`), `server exposes ${field}`);
}

// ── Step 2: Schema bootstrap ─────────────────────────────────────────────────
step("Schema bootstrap with release columns");

const AosDb = require(dbPath);
const bootstrapDb = new AosDb(join(tmp, "bootstrap.db"));
const sqlite3 = bootstrapDb.db;
// Run schema
const schemaSql = readFileSync(sqliteSchema, "utf-8");
for (const stmt of schemaSql.split(";").map(s => s.trim()).filter(s => s.length > 0)) {
  sqlite3.prepare(stmt).run();
}
const colInfo = sqlite3.pragma("table_info(aos_frame_devices)");
const colNames = colInfo.map(c => c.name);
for (const col of ["release_status", "release_target_version", "release_channel", "release_updated_at", "release_error"]) {
  assert(colNames.includes(col), `bootstrap has ${col}`);
}
bootstrapDb.close();
ok("schema bootstrap complete");

// ── Step 3: Server startup + device lifecycle ────────────────────────────────
step("Server startup + device registration + pairing");

const port = await startServer();
const health = await GET("/health");
assert(health.status === 200 && JSON.parse(health.body).ok, "health check passed");

const reg = await POST("/frames/device/register", { deviceName: "test-frame", deviceType: "raspberry_pi" });
const regData = JSON.parse(reg.body);
const deviceId = regData.device?.deviceId || regData.deviceId;
const apiKey = regData.device?.deviceApiKey || regData.deviceApiKey;
const pairingCode = regData.pairingCode;
assert(deviceId && apiKey, `device registered: ${deviceId}`);

// Pair via direct DB on the same file
const pairDb = new AosDb(serverProc.dbPath);
const pairResult = pairDb.claimPairingCode(pairingCode, "owner-alice");
assert(pairResult?.ok, "device paired to owner-alice");
pairDb.close();

// Verify pairing via API
const pairingStatus = await GET(`/frames/device/${deviceId}/pairing-status`);
const psData = JSON.parse(pairingStatus.body);
assert(psData.paired === true && psData.pairing?.status === "completed", "pairing status confirmed via API");

// ── Step 4: Heartbeat without releaseState → default idle + networkOnline ────
step("Heartbeat without releaseState → default idle + networkOnline=true");

const hb1 = await POST(`/frames/device/${deviceId}/heartbeat`, {
  softwareVersion: "0.1.1", currentMode: "display", networkOnline: true, networkType: "wifi"
}, { "x-frame-device-key": apiKey });
const hb1Data = JSON.parse(hb1.body);
assert(hb1Data.ok, "heartbeat accepted");

// Check via direct DB
const checkDb1 = new AosDb(serverProc.dbPath);
const dev1 = checkDb1.getDevice(deviceId);
assert(dev1?.releaseStatus === "idle", `releaseStatus=idle (got: ${dev1?.releaseStatus})`);
assert(dev1?.networkOnline === true, `networkOnline=true (got: ${dev1?.networkOnline})`);
assert(dev1?.networkType === "wifi", `networkType=wifi (got: ${dev1?.networkType})`);
checkDb1.close();

// ── Step 5: Heartbeat with releaseState (in_progress) ────────────────────────
step("Heartbeat with releaseState (in_progress)");

const hb2 = await POST(`/frames/device/${deviceId}/heartbeat`, {
  softwareVersion: "0.1.1", currentMode: "display", networkOnline: true,
  releaseState: { status: "in_progress", targetVersion: "0.2.0", previousVersion: "0.1.1", channel: "stable", tag: "v0.2.0", updatedAt: "2026-06-08T18:00:00Z" }
}, { "x-frame-device-key": apiKey });
assert(JSON.parse(hb2.body).ok, "heartbeat with releaseState accepted");

const checkDb2 = new AosDb(serverProc.dbPath);
const dev2 = checkDb2.getDevice(deviceId);
assert(dev2?.releaseStatus === "in_progress", `releaseStatus=in_progress (got: ${dev2?.releaseStatus})`);
assert(dev2?.releaseTargetVersion === "0.2.0", `target=0.2.0 (got: ${dev2?.releaseTargetVersion})`);
assert(dev2?.releaseChannel === "stable", `channel=stable (got: ${dev2?.releaseChannel})`);
assert(dev2?.releaseError === null, `error=null (got: ${dev2?.releaseError})`);
checkDb2.close();

// ── Step 6: Heartbeat with failed release + error ────────────────────────────
step("Heartbeat with releaseState (failed + error)");

const hb3 = await POST(`/frames/device/${deviceId}/heartbeat`, {
  softwareVersion: "0.1.1", currentMode: "display", networkOnline: true,
  releaseState: { status: "failed", targetVersion: "0.2.0", previousVersion: "0.1.1", channel: "stable", tag: "v0.2.0", updatedAt: "2026-06-08T18:05:00Z", error: "bootstrap failed: exit code 1" }
}, { "x-frame-device-key": apiKey });
assert(JSON.parse(hb3.body).ok, "heartbeat with failed releaseState accepted");

const checkDb3 = new AosDb(serverProc.dbPath);
const dev3 = checkDb3.getDevice(deviceId);
assert(dev3?.releaseStatus === "failed", `releaseStatus=failed (got: ${dev3?.releaseStatus})`);
assert(dev3?.releaseError === "bootstrap failed: exit code 1", `error captured (got: ${dev3?.releaseError})`);
assert(dev3?.releaseTargetVersion === "0.2.0", `target preserved (got: ${dev3?.releaseTargetVersion})`);
checkDb3.close();

// ── Step 7: Heartbeat with completed release ──────────────────────────────────
step("Heartbeat with releaseState (completed)");

const hb4 = await POST(`/frames/device/${deviceId}/heartbeat`, {
  softwareVersion: "0.2.0", currentMode: "display", networkOnline: true,
  releaseState: { status: "completed", targetVersion: "0.2.0", previousVersion: "0.1.1", channel: "stable", tag: "v0.2.0", updatedAt: "2026-06-08T18:10:00Z" }
}, { "x-frame-device-key": apiKey });

const checkDb4 = new AosDb(serverProc.dbPath);
const dev4 = checkDb4.getDevice(deviceId);
assert(dev4?.releaseStatus === "completed", `releaseStatus=completed (got: ${dev4?.releaseStatus})`);
assert(dev4?.releaseError === null, `error cleared (got: ${dev4?.releaseError})`);
assert(dev4?.softwareVersion === "0.2.0", `version=0.2.0 (got: ${dev4?.softwareVersion})`);
checkDb4.close();

// ── Step 8: Admin snapshot includes release state ─────────────────────────────
step("Admin device snapshot includes release state");

const snap = await GET(`/frames/device/${deviceId}/admin-snapshot`, { "x-admin-token": "test-admin-token" });
const snapData = JSON.parse(snap.body);
const snapDev = snapData.device;
assert(snap.status === 200, "snapshot 200 OK");
for (const field of ["releaseStatus", "releaseTargetVersion", "releaseChannel", "releaseUpdatedAt", "releaseError"]) {
  assert(snapDev[field] !== undefined, `snapshot has ${field}`);
}
assert(snapDev.releaseStatus === "completed", `snapshot releaseStatus=completed`);
assert(snapDev.releaseTargetVersion === "0.2.0", `snapshot target=0.2.0`);

// ── Step 9: Admin bundle fleet devices include release state ──────────────────
step("Admin bundle fleet devices include release state");

const bundle = await GET(`/frames/admin/bundle?userId=owner-alice`, { "x-admin-token": "test-admin-token" });
const bundleData = JSON.parse(bundle.body);
const fleetDev = bundleData.adminFrames?.devices?.items?.find(d => d.deviceId === deviceId);
assert(fleetDev, "device found in bundle fleet");
assert(fleetDev.releaseStatus === "completed", `bundle releaseStatus=completed`);
assert(fleetDev.releaseTargetVersion === "0.2.0", `bundle target=0.2.0`);
assert(fleetDev.releaseError === null, `bundle error=null`);

// ── Step 10: Network-online fix verification ──────────────────────────────────
step("Network-online fix: second device with networkOnline=false");

const reg2 = await POST("/frames/device/register", { deviceName: "test-frame-2", deviceType: "raspberry_pi" });
const reg2Data = JSON.parse(reg2.body);
const devId2 = reg2Data.device?.deviceId || reg2Data.deviceId;
const apiKey2 = reg2Data.device?.deviceApiKey || reg2Data.deviceApiKey;
const pairingCode2 = reg2Data.pairingCode;

// Pair the second device so heartbeat auth works
const pairDb2 = new AosDb(serverProc.dbPath);
pairDb2.claimPairingCode(pairingCode2, "owner-bob");
pairDb2.close();

const hbOffline = await POST(`/frames/device/${devId2}/heartbeat`, {
  softwareVersion: "0.1.1", currentMode: "setup", networkOnline: false, networkType: "ethernet"
}, { "x-frame-device-key": apiKey2 });
assert(JSON.parse(hbOffline.body).ok, "offline device heartbeat accepted");

const checkDb5 = new AosDb(serverProc.dbPath);
const dev5 = checkDb5.getDevice(devId2);
assert(dev5?.networkOnline === false, `networkOnline=false (got: ${dev5?.networkOnline})`);
assert(dev5?.networkType === "ethernet", `networkType=ethernet (got: ${dev5?.networkType})`);
checkDb5.close();

// ── Step 11: Regression ──────────────────────────────────────────────────────
step("Regression: existing endpoints still work");

const settings = await GET(`/frames/device/${deviceId}/settings`, { "x-frame-device-key": apiKey });
assert(JSON.parse(settings.body).ok, "settings endpoint works");

const stream = await GET(`/frames/device/${deviceId}/stream`, { "x-frame-device-key": apiKey });
assert(JSON.parse(stream.body).ok, "stream endpoint works");

const release = await GET(`/frames/device/${deviceId}/release`, { "x-frame-device-key": apiKey });
assert(JSON.parse(release.body).ok, "release endpoint works");

const health2 = await GET("/health");
assert(JSON.parse(health2.body).ok, "health endpoint works");

// ── Cleanup + Summary ────────────────────────────────────────────────────────
await cleanup();

const total = PASS.count + FAIL.count;
console.log("");
console.log("═══════════════════════════════════════════");
console.log(` release-state-heartbeat-check: ${PASS.count}/${total} passed, ${FAIL.count} failed`);
console.log("═══════════════════════════════════════════");

process.exit(FAIL.count > 0 ? 1 : 0);
