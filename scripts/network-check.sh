#!/usr/bin/env bash
set -euo pipefail

LOCAL_URL="${AUTOPOIESIS_LOCAL_URL:-http://127.0.0.1:3030}"
NETWORK_URL="${LOCAL_URL%/}/local/network/status"
TMP_JSON="$(mktemp)"

cleanup() {
  rm -f "$TMP_JSON"
}
trap cleanup EXIT

if [[ "${AUTOPOIESIS_ALLOW_NETWORK_UNAVAILABLE:-0}" == "1" ]]; then
  curl -sS "$NETWORK_URL" >"$TMP_JSON"
else
  curl -fsS "$NETWORK_URL" >"$TMP_JSON"
fi

node - "$TMP_JSON" <<'NODE'
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const requireOnline = process.env.AUTOPOIESIS_REQUIRE_NETWORK_ONLINE === "1";
const requireDevice = process.env.AUTOPOIESIS_REQUIRE_NETWORK_DEVICE !== "0";
const allowUnavailable = process.env.AUTOPOIESIS_ALLOW_NETWORK_UNAVAILABLE === "1";
const raw = JSON.stringify(payload);

function fail(message, code = 3) {
  console.error(message);
  process.exit(code);
}

if (/deviceApiKey|apiKey|secret|token/i.test(raw)) {
  fail("Network status payload contains sensitive-looking key material.", 4);
}

if (!payload || typeof payload !== "object") fail("Network status payload is not an object.");
if (!payload.network || typeof payload.network !== "object") fail("Network status payload is missing network.");
if (payload.ok !== true && !allowUnavailable) {
  fail("Network status unavailable: " + (payload.error || "unknown error"), 2);
}

const network = payload.network;
const lan = network.lan || {};
const wifi = network.wifi || {};
const devices = Array.isArray(payload.devices) ? payload.devices : [];
const availableLinks = [lan.available ? "lan" : null, wifi.available ? "wifi" : null].filter(Boolean);
const connectedLinks = [lan.connected ? "lan" : null, wifi.connected ? "wifi" : null].filter(Boolean);

if (typeof network.online !== "boolean") fail("network.online must be a boolean.");
if (![null, "lan", "wifi"].includes(network.primary)) fail("network.primary must be lan, wifi, or null.");
for (const [name, link] of [["lan", lan], ["wifi", wifi]]) {
  if (typeof link.available !== "boolean") fail(name + ".available must be a boolean.");
  if (link.available) {
    if (!link.device || typeof link.device !== "string") fail(name + ".device is required when available.");
    if (typeof link.connected !== "boolean") fail(name + ".connected must be a boolean when available.");
  }
}

if (requireDevice && !availableLinks.length) fail("No LAN or Wi-Fi device is visible to NetworkManager.", 2);
if (requireOnline && !network.online) fail("Network is not online.", 2);
if (network.online) {
  if (!network.primary) fail("Network is online but no primary link is reported.");
  if (!connectedLinks.includes(network.primary)) fail("Primary network link is not marked connected.");
}

const summary = [
  "Autopoiesis Frame network",
  "ok=" + (payload.ok === true ? "true" : "false"),
  "online=" + network.online,
  "primary=" + (network.primary || "none"),
  "lan=" + (lan.available ? ((lan.connected ? "connected" : "available") + ":" + lan.device) : "unavailable"),
  "wifi=" + (wifi.available ? ((wifi.connected ? "connected" : "available") + ":" + wifi.device) : "unavailable"),
  "devices=" + devices.length
];

if (payload.error) summary.push("error=" + JSON.stringify(payload.error));
console.log(summary.join(" "));
NODE
