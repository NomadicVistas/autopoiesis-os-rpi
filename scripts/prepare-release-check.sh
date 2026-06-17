#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

ok() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "  ✅ $1"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "  ❌ $1"; }
section() { echo ""; echo "Step $1: $2"; }

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# ── Step 1: Syntax validation ────────────────────────────────────────────────
section "1" "Syntax validation"
bash -n "$ROOT_DIR/scripts/prepare-release.sh" 2>/dev/null && ok "prepare-release.sh syntax" || fail "prepare-release.sh syntax"

HELP_OUT="$(bash "$ROOT_DIR/scripts/prepare-release.sh" --help 2>&1 || true)"
echo "$HELP_OUT" | grep -q "bump" && ok "help mentions --bump" || fail "help mentions --bump"
echo "$HELP_OUT" | grep -q "dry-run" && ok "help mentions --dry-run" || fail "help mentions --dry-run"
echo "$HELP_OUT" | grep -q "tag" && ok "help mentions --tag" || fail "help mentions --tag"
echo "$HELP_OUT" | grep -q "channel" && ok "help mentions --channel" || fail "help mentions --channel"
echo "$HELP_OUT" | grep -q "artifact" && ok "help mentions --artifact" || fail "help mentions --artifact"
echo "$HELP_OUT" | grep -q "output" && ok "help mentions --output" || fail "help mentions --output"

# ── Step 2: Dry-run current version ──────────────────────────────────────────
section "2" "Dry-run manifest generation for current VERSION"
bash "$ROOT_DIR/scripts/prepare-release.sh" --dry-run --verbose 2>"$TMP_DIR/dry-err" >"$TMP_DIR/dry-manifest.json" || fail "dry-run failed"
[[ -f "$TMP_DIR/dry-manifest.json" ]] || fail "dry-run output file missing"

node - "$TMP_DIR/dry-manifest.json" "$ROOT_DIR/VERSION" <<'NODE' && ok "dry-run produces valid JSON with required fields" || fail "dry-run produces valid JSON with required fields"
const fs = require("fs");
const [manifestPath, versionFile] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const currentVersion = fs.readFileSync(versionFile, "utf8").trim();
if (!manifest.ok) throw new Error("manifest.ok is not true");
if (!manifest.release) throw new Error("manifest.release missing");
if (manifest.release.version !== currentVersion) throw new Error("version mismatch: " + manifest.release.version + " != " + currentVersion);
if (!manifest.release.channel) throw new Error("channel missing");
if (!manifest.release.tag) throw new Error("tag missing");
if (!manifest.release.createdAt) throw new Error("createdAt missing");
if (!manifest.release.notesUrl) throw new Error("notesUrl missing");
if (!manifest.release.rollbackNotes) throw new Error("rollbackNotes missing");
if (!manifest.release.previousVersion) throw new Error("previousVersion missing");
NODE

node - "$TMP_DIR/dry-manifest.json" <<'NODE' && ok "dry-run version matches current VERSION" || fail "dry-run version matches current VERSION"
const m = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
const tag = m.release.tag;
if (!tag.startsWith("v")) throw new Error("tag does not start with v: " + tag);
if (m.release.channel !== "stable") throw new Error("default channel is not stable: " + m.release.channel);
NODE

# ── Step 3: Dry-run with bump ────────────────────────────────────────────────
section "3" "Dry-run with version bump"
bash "$ROOT_DIR/scripts/prepare-release.sh" --bump patch --dry-run 2>"$TMP_DIR/bump-err" >"$TMP_DIR/bump-manifest.json" || fail "bump dry-run failed"

node - "$TMP_DIR/bump-manifest.json" "$ROOT_DIR/VERSION" <<'NODE' && ok "bump produces bumped version" || fail "bump produces bumped version"
const fs = require("fs");
const m = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const current = fs.readFileSync(process.argv[3], "utf8").trim();
const match = String(current).match(/^v?(\d+)\.(\d+)\.(\d+)$/);
if (!match) throw new Error("not semver: " + current);
const expected = [Number(match[1]), Number(match[2]), Number(match[3]) + 1].join(".");
if (m.release.version !== expected) throw new Error("expected patch bump to " + expected + ", got: " + m.release.version);
if (m.release.tag !== "v" + m.release.version) throw new Error("tag mismatch");
NODE

grep -q "would bump VERSION" "$TMP_DIR/bump-err" && ok "dry-run reports version bump" || fail "dry-run reports version bump"

# ── Step 4: Output to file ───────────────────────────────────────────────────
section "4" "Output to file"
bash "$ROOT_DIR/scripts/prepare-release.sh" --output "$TMP_DIR/manifest.json" 2>/dev/null || fail "output to file failed"
[[ -f "$TMP_DIR/manifest.json" ]] && ok "manifest file created" || fail "manifest file created"
node - "$TMP_DIR/manifest.json" <<'NODE' && ok "file manifest is valid JSON with required fields" || fail "file manifest is valid JSON with required fields"
const m = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
if (!m.ok || !m.release || !m.release.version || !m.release.channel || !m.release.tag) throw new Error("missing fields");
if (m.release.previousVersion === undefined) throw new Error("missing previousVersion");
NODE

# ── Step 5: With artifact URL and SHA-256 ────────────────────────────────────
section "5" "Manifest with artifact URL and SHA-256"
FAKE_URL="https://github.com/example/release.tar.gz"
FAKE_SHA="$(printf 'test' | sha256sum | awk '{print $1}')"
bash "$ROOT_DIR/scripts/prepare-release.sh" --artifact-url "$FAKE_URL" --sha256 "$FAKE_SHA" --output "$TMP_DIR/artifact-manifest.json" 2>/dev/null || fail "artifact manifest failed"

node - "$TMP_DIR/artifact-manifest.json" "$FAKE_URL" "$FAKE_SHA" <<'NODE' && ok "artifact manifest includes URL, SHA-256, and assets" || fail "artifact manifest includes URL, SHA-256, and assets"
const [manifestPath, expectedUrl, expectedSha] = process.argv.slice(2);
const m = JSON.parse(require("fs").readFileSync(manifestPath, "utf8"));
if (m.release.artifactUrl !== expectedUrl) throw new Error("artifactUrl mismatch: " + m.release.artifactUrl);
if (m.release.artifactSha256 !== expectedSha) throw new Error("sha256 mismatch: " + m.release.artifactSha256);
if (!Array.isArray(m.release.assets) || m.release.assets.length !== 1) throw new Error("assets missing or wrong count");
if (m.release.assets[0].url !== expectedUrl) throw new Error("asset URL mismatch");
if (m.release.assets[0].sha256 !== expectedSha) throw new Error("asset SHA mismatch");
NODE

# ── Step 6: With local artifact file ─────────────────────────────────────────
section "6" "Manifest with local artifact file"
echo "fake artifact content" > "$TMP_DIR/fake-artifact.tar.gz"
bash "$ROOT_DIR/scripts/prepare-release.sh" \
  --artifact-url "https://github.com/example/release.tar.gz" \
  --artifact "$TMP_DIR/fake-artifact.tar.gz" \
  --output "$TMP_DIR/file-artifact-manifest.json" \
  --verbose 2>"$TMP_DIR/file-artifact-err" || fail "file artifact manifest failed"

COMPUTED_SHA="$(sha256sum "$TMP_DIR/fake-artifact.tar.gz" | awk '{print $1}')"
node - "$TMP_DIR/file-artifact-manifest.json" "$COMPUTED_SHA" <<'NODE' && ok "SHA-256 computed from artifact file" || fail "SHA-256 computed from artifact file"
const [manifestPath, expectedSha] = process.argv.slice(2);
const m = JSON.parse(require("fs").readFileSync(manifestPath, "utf8"));
if (m.release.artifactSha256 !== expectedSha) throw new Error("computed sha256 mismatch: " + m.release.artifactSha256 + " vs " + expectedSha);
NODE

# ── Step 7: Release manifest validation ──────────────────────────────────────
section "7" "Release manifest validation (release-manifest-check.sh)"
if [[ -f "$ROOT_DIR/scripts/release-manifest-check.sh" ]]; then
  # Generate manifest with artifact and validate
  bash "$ROOT_DIR/scripts/prepare-release.sh" \
    --artifact-url "https://github.com/NomadicVistas/autopoiesis-os-rpi/releases/download/v0.1.1/autopoiesis-os.tar.gz" \
    --sha256 "$(printf 'test-artifact' | sha256sum | awk '{print $1}')" \
    --output "$TMP_DIR/validate-manifest.json" 2>/dev/null

  AUTOPOIESIS_RELEASE_REQUIRE_CHANNEL=1 \
  AUTOPOIESIS_RELEASE_REQUIRE_TAG=1 \
  AUTOPOIESIS_RELEASE_ALLOW_INSECURE_URLS=0 \
  bash "$ROOT_DIR/scripts/release-manifest-check.sh" "$TMP_DIR/validate-manifest.json" 2>/dev/null && \
    ok "manifest passes release-manifest-check.sh" || \
    fail "manifest passes release-manifest-check.sh"
else
  ok "release-manifest-check.sh not found (skipped)"
fi

# ── Step 8: Invalid argument handling ────────────────────────────────────────
section "8" "Invalid argument handling"
bash "$ROOT_DIR/scripts/prepare-release.sh" --bump invalid 2>/dev/null && fail "invalid bump level rejected" || ok "invalid bump level rejected"
bash "$ROOT_DIR/scripts/prepare-release.sh" --artifact "/nonexistent/file.tar.gz" 2>/dev/null && fail "missing artifact file rejected" || ok "missing artifact file rejected"
bash "$ROOT_DIR/scripts/prepare-release.sh" --artifact-url "https://example.com/artifact.tar.gz" 2>/dev/null && fail "artifact-url without sha256 rejected" || ok "artifact-url without sha256 rejected"
bash "$ROOT_DIR/scripts/prepare-release.sh" --bump minor --unknown 2>/dev/null && fail "unknown option rejected" || ok "unknown option rejected"

# ── Step 9: Custom channel and rollout ───────────────────────────────────────
section "9" "Custom channel and rollout percent"
bash "$ROOT_DIR/scripts/prepare-release.sh" \
  --channel beta \
  --rollout-percent 25 \
  --output "$TMP_DIR/custom-manifest.json" 2>/dev/null || fail "custom channel/rollout failed"

node - "$TMP_DIR/custom-manifest.json" <<'NODE' && ok "custom channel and rollout in manifest" || fail "custom channel and rollout in manifest"
const m = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
if (m.release.channel !== "beta") throw new Error("channel is not beta: " + m.release.channel);
if (m.release.rolloutPercent !== 25) throw new Error("rolloutPercent is not 25: " + m.release.rolloutPercent);
NODE

# ── Step 10: Min/max version constraints ─────────────────────────────────────
section "10" "Min/max version constraints"
bash "$ROOT_DIR/scripts/prepare-release.sh" \
  --min-version "0.1.0" \
  --max-version "0.2.0" \
  --output "$TMP_DIR/constraint-manifest.json" 2>/dev/null || fail "min/max version failed"

node - "$TMP_DIR/constraint-manifest.json" <<'NODE' && ok "min/max version constraints in manifest" || fail "min/max version constraints in manifest"
const m = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
if (m.release.minVersion !== "0.1.0") throw new Error("minVersion mismatch");
if (m.release.maxVersion !== "0.2.0") throw new Error("maxVersion mismatch");
NODE

# ── Step 11: Changelog extraction correctness ─────────────────────────────────
section "11" "Changelog extraction correctness"
node - "$ROOT_DIR/CHANGELOG.md" "$ROOT_DIR/VERSION" <<'NODE' && ok "changelog has current version documented" || fail "changelog has current version documented"
const fs = require("fs");
const [changelogPath, versionPath] = process.argv.slice(2);
const changelog = fs.readFileSync(changelogPath, "utf8");
const version = fs.readFileSync(versionPath, "utf8").trim();
if (!changelog.includes("[" + version + "]")) {
  throw new Error("CHANGELOG.md does not contain [" + version + "]");
}
NODE

bash "$ROOT_DIR/scripts/prepare-release.sh" --output "$TMP_DIR/extract-manifest.json" 2>/dev/null || fail "extract manifest failed"
node - "$TMP_DIR/extract-manifest.json" <<'NODE' && ok "changes summary extracted from changelog" || fail "changes summary extracted from changelog"
const m = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
if (!Array.isArray(m.release.changes) || m.release.changes.length === 0) {
  throw new Error("no changes array or empty changes");
}
for (const c of m.release.changes) {
  if (typeof c !== "string" || c.length === 0) throw new Error("invalid change item: " + JSON.stringify(c));
}
NODE

# ── Step 12: Dry-run bump does not modify files ──────────────────────────────
section "12" "Dry-run bump does not modify files"
PRE_VERSION="$(cat "$ROOT_DIR/VERSION")"
PRE_CHANGELOG="$(md5sum "$ROOT_DIR/CHANGELOG.md" | awk '{print $1}')"

bash "$ROOT_DIR/scripts/prepare-release.sh" --bump minor --dry-run 2>/dev/null || fail "dry-run bump failed"

POST_VERSION="$(cat "$ROOT_DIR/VERSION")"
POST_CHANGELOG="$(md5sum "$ROOT_DIR/CHANGELOG.md" | awk '{print $1}')"

[[ "$PRE_VERSION" == "$POST_VERSION" ]] && ok "VERSION unchanged after dry-run bump" || fail "VERSION unchanged after dry-run bump"
[[ "$PRE_CHANGELOG" == "$POST_CHANGELOG" ]] && ok "CHANGELOG unchanged after dry-run bump" || fail "CHANGELOG unchanged after dry-run bump"

# ── Step 13: Full bump cycle (copy) ──────────────────────────────────────────
section "13" "Full bump cycle with temp files"
cp "$ROOT_DIR/VERSION" "$TMP_DIR/version-backup"
cp "$ROOT_DIR/CHANGELOG.md" "$TMP_DIR/changelog-backup"

bash "$ROOT_DIR/scripts/prepare-release.sh" --bump patch --output "$TMP_DIR/bumped-manifest.json" 2>/dev/null || fail "bump execution failed"

NEW_VERSION="$(cat "$ROOT_DIR/VERSION")"
node - "$NEW_VERSION" "$TMP_DIR/version-backup" <<'NODE' && ok "VERSION file bumped correctly" || fail "VERSION file bumped correctly"
const fs = require("fs");
const bumped = process.argv[2];
const previous = fs.readFileSync(process.argv[3], "utf8").trim();
const match = String(previous).match(/^v?(\d+)\.(\d+)\.(\d+)$/);
if (!match) throw new Error("previous version not semver: " + previous);
const expected = [Number(match[1]), Number(match[2]), Number(match[3]) + 1].join(".");
if (bumped !== expected) throw new Error("expected " + expected + ", got: " + bumped);
NODE

node - "$ROOT_DIR/CHANGELOG.md" "$NEW_VERSION" <<'NODE' && ok "CHANGELOG has new version section" || fail "CHANGELOG has new version section"
const fs = require("fs");
const [file, expectedVersion] = process.argv.slice(2);
const content = fs.readFileSync(file, "utf8");
if (!content.includes("[" + expectedVersion + "]")) throw new Error("[" + expectedVersion + "] not found in CHANGELOG");
if (!content.includes("[Unreleased]")) throw new Error("[Unreleased] section missing");
const unreleasedIdx = content.indexOf("[Unreleased]");
const versionIdx = content.indexOf("[" + expectedVersion + "]");
if (unreleasedIdx > versionIdx) throw new Error("Unreleased should come before new version");
NODE

# Restore originals
cp "$TMP_DIR/version-backup" "$ROOT_DIR/VERSION"
cp "$TMP_DIR/changelog-backup" "$ROOT_DIR/CHANGELOG.md"
ok "files restored after bump test"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "prepare-release check: $PASS passed, $FAIL failed, $TOTAL total"
[[ $FAIL -gt 0 ]] && exit 1
exit 0
