#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:-${AUTOPOIESIS_RELEASE_MANIFEST_SOURCE:-}}"
TMP_FILE=""

cleanup() {
  if [[ -n "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
  fi
}
trap cleanup EXIT

fail() {
  echo "release manifest check failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/release-manifest-check.sh <release.json>
  scripts/release-manifest-check.sh https://example/api/frames/device/rpi/release

Environment:
  AUTOPOIESIS_RELEASE_MANIFEST_SOURCE        default file or URL when no argument is passed
  AUTOPOIESIS_RELEASE_MANIFEST_TOKEN         optional bearer token for URL checks
  AUTOPOIESIS_RELEASE_CHANNEL                expected release channel when a manifest has channel/updateChannel
  AUTOPOIESIS_RELEASE_REQUIRE_CHANNEL        require channel/updateChannel, default 0
  AUTOPOIESIS_RELEASE_REQUIRE_TAG            require tagName/tag/tag_name, default 0
  AUTOPOIESIS_RELEASE_REQUIRE_ARTIFACT       require artifact_url/artifactUrl, default 0
  AUTOPOIESIS_RELEASE_REQUIRE_ROLLBACK_NOTES require rollbackNotes/rollback_notes, default 0
  AUTOPOIESIS_RELEASE_ALLOW_INSECURE_URLS    allow non-HTTPS artifact URLs, default 0

The checker validates a saved or live release manifest before a frame accepts
an update. It is intentionally read-only.
EOF
}

if [[ -z "$SOURCE" ]]; then
  usage
  exit 2
fi

if [[ "$SOURCE" =~ ^https?:// ]]; then
  TMP_FILE="$(mktemp)"
  CURL_ARGS=(-fsS)
  if [[ -n "${AUTOPOIESIS_RELEASE_MANIFEST_TOKEN:-}" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${AUTOPOIESIS_RELEASE_MANIFEST_TOKEN}")
  fi
  curl "${CURL_ARGS[@]}" "$SOURCE" >"$TMP_FILE" || fail "could not fetch release manifest URL"
  SOURCE="$TMP_FILE"
fi

[[ -f "$SOURCE" ]] || fail "release manifest file not found: $SOURCE"

node - "$SOURCE" <<'NODE'
const fs = require("fs");

const file = process.argv[2];
const expectedChannel = process.env.AUTOPOIESIS_RELEASE_CHANNEL || "";
const requireChannel = process.env.AUTOPOIESIS_RELEASE_REQUIRE_CHANNEL === "1";
const requireTag = process.env.AUTOPOIESIS_RELEASE_REQUIRE_TAG === "1";
const requireArtifact = process.env.AUTOPOIESIS_RELEASE_REQUIRE_ARTIFACT === "1";
const requireRollbackNotes = process.env.AUTOPOIESIS_RELEASE_REQUIRE_ROLLBACK_NOTES === "1";
const allowInsecureUrls = process.env.AUTOPOIESIS_RELEASE_ALLOW_INSECURE_URLS === "1";
const allowedChannels = new Set(["stable", "beta", "dev", "canary", "nightly", "staged", "test"]);
const forbiddenPatterns = [
  /deviceApiKey/i,
  /device_api_key/i,
  /pairingCodeHash/i,
  /pairing_code_hash/i,
  /accessToken/i,
  /refreshToken/i,
  /privateToken/i,
  /adminToken/i,
  /secret/i,
  /password/i,
  /\/var\/lib\/autopoiesis-os/i,
  /\/opt\/autopoiesis-os/i,
  /\/var\/log\/autopoiesis-os/i
];

function fail(message) {
  console.error(message);
  process.exit(1);
}

function isObject(value) {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function firstString(object, names) {
  for (const name of names) {
    const value = object[name];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return "";
}

function optionalIso(value, field) {
  if (value === undefined || value === null || value === "") return;
  if (typeof value !== "string" || !Number.isFinite(Date.parse(value))) {
    fail(field + " must be an ISO timestamp when present");
  }
}

function optionalVersion(value, field) {
  if (value === undefined || value === null || value === "") return;
  if (typeof value !== "string" || !/^[vV]?\d+\.\d+\.\d+([-.+][0-9A-Za-z.-]+)?$/.test(value.trim())) {
    fail(field + " must look like a semantic version when present");
  }
}

function optionalNumberRange(value, field, min, max) {
  if (value === undefined || value === null || value === "") return;
  const number = Number(value);
  if (!Number.isFinite(number) || number < min || number > max) {
    fail(field + " must be a number from " + min + " to " + max);
  }
}

function assertSafeUrl(value, field) {
  if (!value) return;
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    fail(field + " must be a valid URL");
  }
  if (!allowInsecureUrls && parsed.protocol !== "https:") {
    fail(field + " must use https unless AUTOPOIESIS_RELEASE_ALLOW_INSECURE_URLS=1");
  }
  if (/^(localhost|127\.0\.0\.1|0\.0\.0\.0|::1)$/i.test(parsed.hostname) && !allowInsecureUrls) {
    fail(field + " must not point at localhost unless insecure URLs are explicitly allowed");
  }
}

let payload;
try {
  payload = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (error) {
  fail("manifest is not valid JSON: " + error.message);
}

if (!isObject(payload)) fail("manifest root must be an object");
const release = payload.release && isObject(payload.release) ? payload.release : payload;
if (!isObject(release)) fail("release section must be an object");
if (payload.ok === false || release.ok === false) fail("manifest reports ok=false");

const serialized = JSON.stringify(payload);
for (const pattern of forbiddenPatterns) {
  if (pattern.test(serialized)) fail("manifest exposes forbidden sensitive or local-only data: " + pattern);
}

const version = firstString(release, ["version", "targetVersion", "target_version"]);
if (!version) fail("release.version is required");
optionalVersion(version, "release.version");

const channel = firstString(release, ["channel", "updateChannel", "update_channel"]);
if (requireChannel && !channel) fail("release channel is required");
if (channel) {
  if (!allowedChannels.has(channel)) fail("release channel is not recognized: " + channel);
  if (expectedChannel && channel !== expectedChannel) {
    fail("release channel " + channel + " does not match expected channel " + expectedChannel);
  }
}

const tag = firstString(release, ["tagName", "tag_name", "tag"]);
if (requireTag && !tag) fail("release tag is required");
if (tag && !/^[A-Za-z0-9][A-Za-z0-9._/-]{0,79}$/.test(tag)) {
  fail("release tag contains unsupported characters");
}
if (tag && !tag.includes(version) && tag !== version && tag !== "v" + version) {
  fail("release tag should include the target version");
}

const artifactUrl = firstString(release, ["artifact_url", "artifactUrl", "assetUrl", "downloadUrl"]);
if (requireArtifact && !artifactUrl) fail("artifact URL is required");
assertSafeUrl(artifactUrl, "release.artifact_url");

const checksum = firstString(release, ["checksum", "sha256", "artifactSha256", "artifact_sha256"]);
if (artifactUrl && !checksum) fail("artifact releases require a sha256 checksum");
if (checksum && !/^[a-fA-F0-9]{64}$/.test(checksum)) fail("release checksum must be a 64-character sha256 hex digest");
if (!artifactUrl && checksum) fail("checksum is only valid when an artifact URL is present");

const notesUrl = firstString(release, ["notesUrl", "releaseNotesUrl", "changelogUrl"]);
assertSafeUrl(notesUrl, "release notes URL");
const rollbackNotes = firstString(release, ["rollbackNotes", "rollback_notes", "rollback"]);
if (requireRollbackNotes && !rollbackNotes) fail("rollback notes are required");
if (rollbackNotes && rollbackNotes.length > 4000) fail("rollback notes are unexpectedly large");

optionalIso(firstString(release, ["createdAt", "created_at"]), "release.createdAt");
optionalIso(firstString(release, ["publishedAt", "published_at"]), "release.publishedAt");
optionalIso(firstString(release, ["expiresAt", "expires_at"]), "release.expiresAt");
optionalVersion(firstString(release, ["minVersion", "min_version"]), "release.minVersion");
optionalVersion(firstString(release, ["maxVersion", "max_version"]), "release.maxVersion");
optionalNumberRange(release.rolloutPercent ?? release.rollout_percent, "release.rolloutPercent", 0, 100);

if (Array.isArray(release.assets)) {
  for (const [index, asset] of release.assets.entries()) {
    if (!isObject(asset)) fail("release.assets[" + index + "] must be an object");
    const url = firstString(asset, ["url", "artifact_url", "artifactUrl", "downloadUrl"]);
    const assetChecksum = firstString(asset, ["checksum", "sha256"]);
    assertSafeUrl(url, "release.assets[" + index + "].url");
    if (url && !assetChecksum) fail("release.assets[" + index + "] has a URL without sha256 checksum");
    if (assetChecksum && !/^[a-fA-F0-9]{64}$/.test(assetChecksum)) fail("release.assets[" + index + "].checksum must be sha256 hex");
  }
}

console.log([
  "Autopoiesis release manifest",
  "version=" + version,
  "channel=" + (channel || "unspecified"),
  "tag=" + (tag || "unspecified"),
  "artifact=" + (artifactUrl ? "yes" : "git-fallback"),
  "checksum=" + (checksum ? "yes" : "none"),
  "rollbackNotes=" + (rollbackNotes ? "yes" : "no")
].join(" "));
NODE
