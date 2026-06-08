#!/usr/bin/env bash
# prepare-release.sh — generate a release manifest from CHANGELOG.md
# Reads the changelog, extracts version notes, generates a release manifest JSON
# compatible with scripts/release-manifest-check.sh, and optionally bumps VERSION,
# creates a git tag, and updates the Unreleased section.
#
# Usage:
#   scripts/prepare-release.sh                          # manifest for current VERSION
#   scripts/prepare-release.sh --bump patch             # bump VERSION, move Unreleased
#   scripts/prepare-release.sh --bump minor --tag       # bump, git tag
#   scripts/prepare-release.sh --dry-run                # preview without writing
#   scripts/prepare-release.sh --channel stable         # set release channel
#   scripts/prepare-release.sh --artifact-url <url> --sha256 <hash>  # with artifact
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
CHANGELOG_FILE="$ROOT_DIR/CHANGELOG.md"

# ── Defaults ─────────────────────────────────────────────────────────────────
DRY_RUN=0
BUMP=""
TAG=0
CHANNEL="${AUTOPOIESIS_RELEASE_CHANNEL:-stable}"
ARTIFACT_URL=""
SHA256=""
NOTES_URL=""
ROLLBACK_NOTES="${AUTOPOIESIS_ROLLBACK_NOTES:-}"
MIN_VERSION=""
MAX_VERSION=""
ROLLOUT_PERCENT=""
OUTPUT=""
VERBOSE=0
ARTIFACT_PATH=""

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
  cat >&2 <<'EOF'
Usage: scripts/prepare-release.sh [options]

Options:
  --bump <level>           Bump VERSION: patch, minor, major (default: none)
  --tag                    Create a git tag after bump/manifest
  --channel <channel>      Release channel (default: stable)
  --artifact-url <url>     Download URL for the release artifact
  --artifact <path>        Local artifact file (computes sha256, needs --artifact-url)
  --sha256 <hash>          SHA-256 checksum for the artifact
  --notes-url <url>        URL to release notes / changelog
  --rollback-notes <text>  Rollback instructions
  --min-version <ver>      Minimum device version for this release
  --max-version <ver>      Maximum device version for this release
  --rollout-percent <n>    Rollout percentage (0-100)
  --output <path>          Write manifest to file (default: stdout)
  --dry-run                Preview without modifying files or creating tags
  --verbose                Show extracted notes and decisions
  -h, --help               Show this help

Environment:
  AUTOPOIESIS_RELEASE_CHANNEL     default release channel (stable)
  AUTOPOIESIS_ROLLBACK_NOTES      default rollback notes
  AUTOPOIESIS_PREPARE_RELEASE_OUT default output path

The tool reads CHANGELOG.md for the current version's notes and generates
a release manifest JSON compatible with scripts/release-manifest-check.sh.

When --bump is used:
  1. The Unreleased section is moved to a new version heading.
  2. VERSION file is updated.
  3. CHANGELOG.md is updated in place.
  4. (Optional) A git tag v<version> is created.

Examples:
  # Preview manifest for current version
  scripts/prepare-release.sh --dry-run --verbose

  # Bump patch, create tag, write manifest
  scripts/prepare-release.sh --bump patch --tag --output release.json

  # Full release with artifact
  scripts/prepare-release.sh --bump minor --tag --channel stable \
    --artifact-url https://github.com/NomadicVistas/autopoiesis-os-rpi/releases/download/v0.2.0/autopoiesis-os.tar.gz \
    --artifact dist/autopoiesis-os.tar.gz \
    --output release.json
EOF
}

# ── Arg parsing ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bump)        BUMP="${2:-}"; shift 2 ;;
    --tag)         TAG=1; shift ;;
    --channel)     CHANNEL="${2:-}"; shift 2 ;;
    --artifact-url) ARTIFACT_URL="${2:-}"; shift 2 ;;
    --artifact)    ARTIFACT_PATH="${2:-}"; shift 2 ;;
    --sha256)      SHA256="${2:-}"; shift 2 ;;
    --notes-url)   NOTES_URL="${2:-}"; shift 2 ;;
    --rollback-notes) ROLLBACK_NOTES="${2:-}"; shift 2 ;;
    --min-version) MIN_VERSION="${2:-}"; shift 2 ;;
    --max-version) MAX_VERSION="${2:-}"; shift 2 ;;
    --rollout-percent) ROLLOUT_PERCENT="${2:-}"; shift 2 ;;
    --output)      OUTPUT="${2:-}"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --verbose)     VERBOSE=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$BUMP" ]] && [[ "$BUMP" != "patch" && "$BUMP" != "minor" && "$BUMP" != "major" ]] && {
  echo "error: --bump must be patch, minor, or major" >&2; exit 1;
}

[[ -n "$ARTIFACT_PATH" && ! -f "$ARTIFACT_PATH" ]] && {
  echo "error: artifact file not found: $ARTIFACT_PATH" >&2; exit 1;
}

[[ -n "$ARTIFACT_PATH" && -z "$ARTIFACT_URL" ]] && {
  echo "error: --artifact requires --artifact-url" >&2; exit 1;
}

[[ -z "$ARTIFACT_PATH" && -z "$SHA256" && -n "$ARTIFACT_URL" ]] && {
  echo "error: --artifact-url requires --sha256 or --artifact" >&2; exit 1;
}

# ── Compute SHA-256 from artifact if provided ────────────────────────────────
if [[ -n "$ARTIFACT_PATH" && -z "$SHA256" ]]; then
  SHA256="$(sha256sum "$ARTIFACT_PATH" | awk '{print $1}')"
  [[ ${VERBOSE} -eq 1 ]] && echo "computed sha256 from artifact: $SHA256" >&2
fi

# ── Read VERSION ─────────────────────────────────────────────────────────────
[[ -f "$VERSION_FILE" ]] || { echo "error: VERSION file not found" >&2; exit 1; }
CURRENT_VERSION="$(cat "$VERSION_FILE" | tr -d '[:space:]')"
[[ -n "$CURRENT_VERSION" ]] || { echo "error: VERSION file is empty" >&2; exit 1; }

# ── Bump version if requested ────────────────────────────────────────────────
TARGET_VERSION="$CURRENT_VERSION"
if [[ -n "$BUMP" ]]; then
  TARGET_VERSION="$(node - "$CURRENT_VERSION" "$BUMP" <<'NODE'
    const [current, bump] = process.argv.slice(2);
    const match = current.match(/^v?(\d+)\.(\d+)\.(\d+)([-.+][0-9A-Za-z.-]+)?$/);
    if (!match) { process.stderr.write("error: cannot parse version: " + current + "\n"); process.exit(1); }
    let [, major, minor, patch, pre] = match;
    major = Number(major); minor = Number(minor); patch = Number(patch);
    if (bump === "major") { major += 1; minor = 0; patch = 0; }
    else if (bump === "minor") { minor += 1; patch = 0; }
    else if (bump === "patch") { patch += 1; }
    else { process.stderr.write("error: unknown bump: " + bump + "\n"); process.exit(1); }
    console.log(major + "." + minor + "." + patch);
NODE
  )"
  [[ ${VERBOSE} -eq 1 ]] && echo "version: $CURRENT_VERSION → $TARGET_VERSION" >&2
fi

# ── Extract changelog notes for the target version ───────────────────────────
# If bumping, extract Unreleased section. Otherwise extract the existing version.
EXTRACT_VERSION="$TARGET_VERSION"
[[ -n "$BUMP" ]] && EXTRACT_VERSION="Unreleased"

NOTES_JSON="$(node - "$CHANGELOG_FILE" "$EXTRACT_VERSION" <<'NODE'
const fs = require("fs");
const [file, targetVersion] = process.argv.slice(2);
const content = fs.readFileSync(file, "utf8");
const lines = content.split("\n");

// Find the target version section
let startLine = -1;
let endLine = -1;
for (let i = 0; i < lines.length; i++) {
  const line = lines[i];
  // Match ## [Unreleased] or ## [X.Y.Z]
  const headerMatch = line.match(/^##\s*\[([^\]]+)\]/);
  if (headerMatch) {
    const section = headerMatch[1].trim();
    if (section === targetVersion || (targetVersion === "Unreleased" && section === "Unreleased")) {
      startLine = i + 1;
    } else if (startLine >= 0 && endLine < 0) {
      endLine = i;
    }
  }
}

if (startLine < 0) {
  process.stderr.write("error: version [" + targetVersion + "] not found in CHANGELOG.md\n");
  process.exit(1);
}
if (endLine < 0) endLine = lines.length;

const notes = lines.slice(startLine, endLine).join("\n").trim();

// Convert markdown notes to plain-text summary for the manifest
const summaryLines = [];
let sectionName = "";
for (const line of notes.split("\n")) {
  const trimmed = line.trim();
  if (trimmed.startsWith("### ")) {
    sectionName = trimmed.replace(/^###\s*/, "").trim();
    continue;
  }
  if (trimmed.startsWith("#### ")) {
    // Sub-section header — skip
    continue;
  }
  if (trimmed.startsWith("- ")) {
    const item = trimmed.replace(/^-\s*/, "");
    if (sectionName) {
      summaryLines.push("[" + sectionName + "] " + item);
    } else {
      summaryLines.push(item);
    }
  }
}

// Sanitize summary lines against forbidden patterns from release-manifest-check.sh
const forbiddenPatterns = [
  /deviceApiKey/i,
  /device_api_key/i,
  /pairingCodeHash/i,
  /pairing_code_hash/i,
  /accessToken/i,
  /refreshToken/i,
  /privateToken/i,
  /adminToken/i,
  /\bsecret\b/i,
  /password/i,
  /\/var\/lib\/autopoiesis-os/i,
  /\/opt\/autopoiesis-os/i,
  /\/var\/log\/autopoiesis-os/i
];

const sanitized = summaryLines.map(line => {
  let clean = line;
  for (const pattern of forbiddenPatterns) {
    clean = clean.replace(pattern, "[redacted]");
  }
  return clean;
}).filter(line => line.trim().length > 0);

// Output as JSON with both raw markdown and plain-text summary
const output = {
  rawMarkdown: notes,
  summary: sanitized,
  itemcount: sanitized.length
};
console.log(JSON.stringify(output));
NODE
)" || { echo "error: failed to extract changelog notes for [$EXTRACT_VERSION]" >&2; exit 1; }

RAW_NOTES="$(echo "$NOTES_JSON" | node -e "const d=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(d.rawMarkdown)")"
SUMMARY_LINES="$(echo "$NOTES_JSON" | node -e "const d=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(JSON.stringify(d.summary))")"
ITEM_COUNT="$(echo "$NOTES_JSON" | node -e "const d=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(String(d.itemcount))")"

[[ ${VERBOSE} -eq 1 ]] && echo "extracted $ITEM_COUNT items for [$EXTRACT_VERSION]" >&2

# If no notes found and not bumping from Unreleased, that's a problem
if [[ "$ITEM_COUNT" -eq 0 && -z "$BUMP" ]]; then
  echo "warning: no changelog items found for [$TARGET_VERSION]" >&2
fi

# ── Build release manifest ───────────────────────────────────────────────────
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
TAG_NAME="v${TARGET_VERSION}"
GITHUB_REPO="${AUTOPOIESIS_GITHUB_REPO:-NomadicVistas/autopoiesis-os-rpi}"

# Default notesUrl to GitHub comparison if not provided
if [[ -z "$NOTES_URL" ]]; then
  NOTES_URL="https://github.com/${GITHUB_REPO}/compare/v${CURRENT_VERSION}...v${TARGET_VERSION}"
fi

# Default rollback notes
if [[ -z "$ROLLBACK_NOTES" ]]; then
  ROLLBACK_NOTES="Rollback from v${TARGET_VERSION} to v${CURRENT_VERSION} via the release rollback tool."
fi

MANIFEST="$(node - "$TARGET_VERSION" "$CHANNEL" "$TAG_NAME" "$NOW_ISO" "$NOTES_URL" "$ROLLBACK_NOTES" "$CURRENT_VERSION" "$ARTIFACT_URL" "$SHA256" "$MIN_VERSION" "$MAX_VERSION" "$ROLLOUT_PERCENT" "$SUMMARY_LINES" <<'NODE'
const args = process.argv.slice(2);
const [
  version, channel, tag, createdAt, notesUrl, rollbackNotes,
  previousVersion, artifactUrl, sha256, minVersion, maxVersion,
  rolloutPercent, summaryJson
] = args;

const summary = JSON.parse(summaryJson);

const manifest = {
  ok: true,
  release: {
    version,
    channel,
    tag,
    createdAt,
    notesUrl,
    rollbackNotes,
    previousVersion
  }
};

if (artifactUrl) {
  manifest.release.artifactUrl = artifactUrl;
  manifest.release.artifactSha256 = sha256;
}

if (minVersion) manifest.release.minVersion = minVersion;
if (maxVersion) manifest.release.maxVersion = maxVersion;
if (rolloutPercent) manifest.release.rolloutPercent = Number(rolloutPercent);

// Include a plain-text change summary for the hosted API release endpoint
if (summary.length > 0) {
  manifest.release.changes = summary.slice(0, 50); // Cap at 50 items
}

// Assets array for compatibility with release-manifest-check
if (artifactUrl) {
  manifest.release.assets = [{
    url: artifactUrl,
    sha256,
    name: "autopoiesis-os.tar.gz"
  }];
}

console.log(JSON.stringify(manifest, null, 2));
NODE
)"

# ── Output ───────────────────────────────────────────────────────────────────
if [[ ${DRY_RUN} -eq 1 ]]; then
  echo "--- dry-run: release manifest for v${TARGET_VERSION} ---" >&2
  echo "$MANIFEST"
  echo "--- end dry-run ---" >&2
  if [[ -n "$BUMP" ]]; then
    echo "[dry-run] would bump VERSION: $CURRENT_VERSION → $TARGET_VERSION" >&2
    echo "[dry-run] would update CHANGELOG.md: rename [Unreleased] → [$TARGET_VERSION]" >&2
    if [[ ${TAG} -eq 1 ]]; then
      echo "[dry-run] would create git tag: $TAG_NAME" >&2
    fi
  fi
  exit 0
fi

# ── Write manifest ───────────────────────────────────────────────────────────
if [[ -n "$OUTPUT" ]]; then
  echo "$MANIFEST" > "$OUTPUT"
  [[ ${VERBOSE} -eq 1 ]] && echo "manifest written to: $OUTPUT" >&2
else
  echo "$MANIFEST"
fi

# ── Update CHANGELOG.md if bumping ──────────────────────────────────────────
if [[ -n "$BUMP" ]]; then
  # Replace [Unreleased] with [TARGET_VERSION] - DATE
  TODAY="$(date +"%Y-%m-%d")"
  sed -i "s/^## \[Unreleased\]$/## [${TARGET_VERSION}] - ${TODAY}/" "$CHANGELOG_FILE"

  # Add a new empty [Unreleased] section at the top (after the header block)
  node - "$CHANGELOG_FILE" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
let content = fs.readFileSync(file, "utf8");

// Find the position after the "## [Unreleased]" was replaced —
// now we need to insert a new ## [Unreleased] section at the top
// It should go after the header comment block and before the first version section
const lines = content.split("\n");
let insertAt = -1;
for (let i = 0; i < lines.length; i++) {
  // Find the first version heading (## [X.Y.Z])
  if (/^##\s*\[/.test(lines[i])) {
    insertAt = i;
    break;
  }
}

if (insertAt < 0) {
  process.stderr.write("error: could not find version section to insert Unreleased\n");
  process.exit(1);
}

// Insert new Unreleased section before the first version heading
const newLines = [
  "## [Unreleased]",
  "",
  ...lines.slice(0, insertAt),
  ...lines.slice(insertAt)
];

fs.writeFileSync(file, newLines.join("\n") + "\n");
NODE

  # Update VERSION file
  echo "$TARGET_VERSION" > "$VERSION_FILE"
  [[ ${VERBOSE} -eq 1 ]] && echo "VERSION updated: $TARGET_VERSION" >&2

  # Create git tag if requested
  if [[ ${TAG} -eq 1 ]]; then
    if git -C "$ROOT_DIR" rev-parse "$TAG_NAME" >/dev/null 2>&1; then
      echo "warning: tag $TAG_NAME already exists, skipping" >&2
    else
      SUMMARY_TEXT="$(echo "$SUMMARY_LINES" | node -e "const d=JSON.parse(require('fs').readFileSync(0,'utf8'));console.log(d.slice(0,10).join('\n'))")"
      git -C "$ROOT_DIR" tag -a "$TAG_NAME" -m "Release $TAG_NAME"$'\n\n'"$SUMMARY_TEXT"
      [[ ${VERBOSE} -eq 1 ]] && echo "git tag created: $TAG_NAME" >&2
    fi
  fi
fi

# ── Validate manifest against release-manifest-check.sh ──────────────────────
if [[ -f "$ROOT_DIR/scripts/release-manifest-check.sh" ]]; then
  VALIDATE_TMP="$(mktemp)"
  echo "$MANIFEST" > "$VALIDATE_TMP"

  if AUTOPOIESIS_RELEASE_REQUIRE_CHANNEL=1 \
     AUTOPOIESIS_RELEASE_REQUIRE_TAG=1 \
     bash "$ROOT_DIR/scripts/release-manifest-check.sh" "$VALIDATE_TMP" 2>&1; then
    [[ ${VERBOSE} -eq 1 ]] && echo "release manifest validation: PASSED" >&2
  else
    echo "warning: release manifest validation failed (manifest still generated)" >&2
  fi
  rm -f "$VALIDATE_TMP"
fi
