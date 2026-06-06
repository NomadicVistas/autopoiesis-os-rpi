#!/usr/bin/env bash
set -euo pipefail

INPUT_DEVICES_PATH="${AUTOPOIESIS_INPUT_DEVICES_PATH:-/proc/bus/input/devices}"
REQUIRE_TOUCHSCREEN="${AUTOPOIESIS_REQUIRE_TOUCHSCREEN:-0}"
TMP_JSON="$(mktemp)"

cleanup() {
  rm -f "$TMP_JSON"
}
trap cleanup EXIT

node - "$INPUT_DEVICES_PATH" >"$TMP_JSON" <<'NODE'
const fs = require("fs");
const inputPath = process.argv[2];

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
        eventHandlers: handlers.match(/\bevent\d+\b/g) || [],
        touchscreen,
        pointer,
        keyboard
      };
    })
    .filter(Boolean);
}

try {
  const devices = parseInputDevices(fs.readFileSync(inputPath, "utf8"));
  const touchscreenPresent = devices.some(device => device.touchscreen);
  const pointerPresent = devices.some(device => device.pointer);
  const keyboardPresent = devices.some(device => device.keyboard);
  process.stdout.write(JSON.stringify({
    ok: true,
    source: inputPath,
    status: touchscreenPresent ? "touchscreen_ready" : pointerPresent ? "pointer_only" : "input_missing",
    totalDevices: devices.length,
    touchscreenPresent,
    pointerPresent,
    keyboardPresent,
    devices: devices.slice(0, 20)
  }, null, 2) + "\n");
} catch (error) {
  process.stdout.write(JSON.stringify({
    ok: false,
    source: inputPath,
    status: "unavailable",
    error: error.message
  }, null, 2) + "\n");
}
NODE

node - "$TMP_JSON" "$REQUIRE_TOUCHSCREEN" <<'NODE'
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const requireTouchscreen = process.argv[3] === "1";
const touchNames = (payload.devices || [])
  .filter(device => device.touchscreen)
  .map(device => device.name)
  .join(",");
const pointerNames = (payload.devices || [])
  .filter(device => device.pointer && !device.touchscreen)
  .map(device => device.name)
  .join(",");

console.log([
  "Autopoiesis Frame touchscreen/input",
  "status=" + (payload.status || "unknown"),
  "touchscreen=" + (payload.touchscreenPresent ? "yes" : "no"),
  "pointer=" + (payload.pointerPresent ? "yes" : "no"),
  "keyboard=" + (payload.keyboardPresent ? "yes" : "no"),
  "devices=" + (payload.totalDevices || 0),
  touchNames ? "touchDevices=" + touchNames : "",
  pointerNames ? "pointerDevices=" + pointerNames : ""
].filter(Boolean).join(" "));

if (!payload.ok) process.exit(requireTouchscreen ? 2 : 0);
if (requireTouchscreen && !payload.touchscreenPresent) process.exit(2);
if (!payload.touchscreenPresent && !payload.pointerPresent) process.exit(3);
NODE
