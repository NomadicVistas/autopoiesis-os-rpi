#!/usr/bin/env bash
set -euo pipefail

# Changelog format and consistency gate.
# Validates CHANGELOG.md follows Keep a Changelog structure,
# version entries are in descending semver order, current VERSION
# is documented, and required sections exist for non-unreleased entries.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGELOG="${1:-$ROOT_DIR/CHANGELOG.md}"
VERSION_FILE="${2:-$ROOT_DIR/VERSION}"

PASS=0
FAIL=0
TOTAL=0

pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); }
fail() { echo "  ✗ $*" >&2; FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); }
check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✓ $label"
    pass
  else
    echo "  ✗ $label"
    fail
  fi
}
check_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  ✓ $label"
    pass
  else
    echo "  ✗ $label (expected '$expected', got '$actual')"
    fail
  fi
}
check_match() {
  local label="$1" pattern="$2" text="$3"
  if echo "$text" | grep -qP "$pattern"; then
    echo "  ✓ $label"
    pass
  else
    echo "  ✗ $label (pattern '$pattern' not found)"
    fail
  fi
}

echo "=== Changelog Gate ==="
echo ""

# --- Step 1: Syntax ---
echo "Step 1: Syntax validation"
check "changelog file exists" test -f "$CHANGELOG"
check "version file exists" test -f "$VERSION_FILE"
check "bash syntax (self)" bash -n "$ROOT_DIR/scripts/changelog-check.sh"
echo ""

if [[ ! -f "$CHANGELOG" ]]; then
  echo "FATAL: CHANGELOG.md not found at $CHANGELOG" >&2
  exit 1
fi

CURRENT_VERSION=""
if [[ -f "$VERSION_FILE" ]]; then
  CURRENT_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
fi

# --- Step 2: Header and structure ---
echo "Step 2: Header and structure"
check "has h1 title" grep -qP '^# Changelog$' "$CHANGELOG"
check "has Keep a Changelog reference" grep -q 'keepachangelog.com' "$CHANGELOG"
check "has Semantic Versioning reference" grep -q 'semver.org' "$CHANGELOG"
check "has Unreleased section" grep -qP '^## \[Unreleased\]' "$CHANGELOG"
echo ""

# --- Step 3: Version entries ---
echo "Step 3: Version entries"

VERSION_HEADINGS=()
while IFS= read -r line; do
  VERSION_HEADINGS+=("$line")
done < <(grep -P '^## \[' "$CHANGELOG" || true)

NUM_VERSIONS="${#VERSION_HEADINGS[@]}"
check "at least one version entry" test "$NUM_VERSIONS" -ge 1
echo "  Found $NUM_VERSIONS version heading(s)"

# Extract semver versions from headings
VERSIONS=()
for heading in "${VERSION_HEADINGS[@]}"; do
  if [[ "$heading" =~ \[([0-9]+\.[0-9]+\.[0-9]+)\] ]]; then
    VERSIONS+=("${BASH_REMATCH[1]}")
  fi
done

check "at least one semver version" test "${#VERSIONS[@]}" -ge 1
echo ""

# --- Step 4: Version descending order ---
echo "Step 4: Version order (descending semver)"

if [[ "${#VERSIONS[@]}" -ge 2 ]]; then
  ORDER_OK=true
  PREV_MAJOR=999
  PREV_MINOR=999
  PREV_PATCH=999
  for v in "${VERSIONS[@]}"; do
    MAJOR="${v%%.*}"
    REST="${v#*.}"
    MINOR="${REST%%.*}"
    PATCH="${REST#*.}"
    if [[ "$MAJOR" -gt "$PREV_MAJOR" ]]; then
      ORDER_OK=false
      echo "  ✗ $v is out of order (major $MAJOR > previous $PREV_MAJOR)"
    elif [[ "$MAJOR" -eq "$PREV_MAJOR" && "$MINOR" -gt "$PREV_MINOR" ]]; then
      ORDER_OK=false
      echo "  ✗ $v is out of order (minor $MINOR > previous $PREV_MINOR)"
    elif [[ "$MAJOR" -eq "$PREV_MAJOR" && "$MINOR" -eq "$PREV_MINOR" && "$PATCH" -gt "$PREV_PATCH" ]]; then
      ORDER_OK=false
      echo "  ✗ $v is out of order (patch $PATCH > previous $PREV_PATCH)"
    fi
    PREV_MAJOR="$MAJOR"
    PREV_MINOR="$MINOR"
    PREV_PATCH="$PATCH"
  done
  if $ORDER_OK; then
    echo "  ✓ Versions in descending semver order"
    pass
  else
    fail
  fi
else
  echo "  ⓘ Only one version, order check skipped"
fi
echo ""

# --- Step 5: Current VERSION documented ---
echo "Step 5: Current VERSION in changelog"
if [[ -n "$CURRENT_VERSION" ]]; then
  check "VERSION file ($CURRENT_VERSION) has changelog entry" grep -qP "## \[$CURRENT_VERSION\]" "$CHANGELOG"
else
  echo "  ⓘ No VERSION file, skipping"
fi
echo ""

# --- Step 6: Required sections per version ---
echo "Step 6: Required sections per version"

for heading in "${VERSION_HEADINGS[@]}"; do
  ver=""
  if [[ "$heading" =~ \[([^\]]+)\] ]]; then
    ver="${BASH_REMATCH[1]}"
  fi
  # Unreleased section is allowed to be empty
  if [[ "$ver" == "Unreleased" ]]; then
    echo "  ⓘ [Unreleased] — skipping section check"
    continue
  fi

  # Check that at least one subsection exists (Added, Changed, Fixed, etc.)
  HAS_SUBSECTION=false
  IN_BLOCK=false
  while IFS= read -r line; do
    if echo "$line" | grep -qP "^## \["; then
      if [[ "$line" == *"[$ver]"* ]]; then
        IN_BLOCK=true
      else
        IN_BLOCK=false
      fi
    fi
    if $IN_BLOCK && echo "$line" | grep -qP '^### (Added|Changed|Deprecated|Removed|Fixed|Security)$'; then
      HAS_SUBSECTION=true
      break
    fi
  done < "$CHANGELOG"

  if $HAS_SUBSECTION; then
    echo "  ✓ [$ver] has at least one subsection (Added/Changed/Fixed/Security)"
    pass
  else
    echo "  ✗ [$ver] missing subsections (Added/Changed/Fixed/Security)"
    fail
  fi
done
echo ""

# --- Step 7: Date format ---
echo "Step 7: Date format (YYYY-MM-DD)"

for heading in "${VERSION_HEADINGS[@]}"; do
  ver=""
  if [[ "$heading" =~ \[([^\]]+)\] ]]; then
    ver="${BASH_REMATCH[1]}"
  fi
  [[ "$ver" == "Unreleased" ]] && continue

  # heading format: ## [version] - YYYY-MM-DD or ## [version] - YYYY-MM-DD
  if echo "$heading" | grep -qP '^## \[[^\]]+\] - \d{4}-\d{2}-\d{2}'; then
    echo "  ✓ [$ver] has valid date"
    pass
  else
    echo "  ✗ [$ver] missing or malformed date (expected '## [$ver] - YYYY-MM-DD')"
    fail
  fi
done
echo ""

# --- Step 8: Link references ---
echo "Step 8: Link references"

for v in "${VERSIONS[@]}"; do
  REF_LINE="$(grep -P "^\[$v\]:" "$CHANGELOG" || true)"
  if [[ -n "$REF_LINE" ]]; then
    echo "  ✓ [$v]: link reference present"
    pass
    # Check that the link is a valid URL
    URL="$(echo "$REF_LINE" | sed -E 's/^\[.*\]:[[:space:]]*//')"
    if echo "$URL" | grep -qP '^https?://'; then
      echo "  ✓ [$v]: link is a valid URL"
      pass
    else
      echo "  ✗ [$v]: link is not a valid URL: $URL"
      fail
    fi
  else
    echo "  ✗ [$v]: missing link reference"
    fail
  fi
done
echo ""

# --- Step 9: No empty subsections ---
echo "Step 9: No empty subsections"

CURRENT_VER=""
CURRENT_SUB=""
IN_SUB=false
SUB_LINE_COUNT=0

while IFS= read -r line; do
  if echo "$line" | grep -qP '^## \['; then
    # Check previous subsection
    if $IN_SUB && [[ "$SUB_LINE_COUNT" -eq 0 ]]; then
      echo "  ✗ [$CURRENT_VER] → ### $CURRENT_SUB is empty"
      fail
    fi
    CURRENT_VER=""
    if [[ "$line" =~ \[([^\]]+)\] ]]; then
      CURRENT_VER="${BASH_REMATCH[1]}"
    fi
    IN_SUB=false
    SUB_LINE_COUNT=0
    continue
  fi

  if echo "$line" | grep -qP '^### (Added|Changed|Deprecated|Removed|Fixed|Security)$'; then
    # Check previous subsection
    if $IN_SUB && [[ "$SUB_LINE_COUNT" -eq 0 ]]; then
      echo "  ✗ [$CURRENT_VER] → ### $CURRENT_SUB is empty"
      fail
    fi
    CURRENT_SUB="$(echo "$line" | sed 's/^### //')"
    IN_SUB=true
    SUB_LINE_COUNT=0
    continue
  fi

  if $IN_SUB; then
    # Count non-empty, non-comment lines
    trimmed="$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
    if [[ -n "$trimmed" && "$trimmed" != "---" ]]; then
      SUB_LINE_COUNT=$((SUB_LINE_COUNT + 1))
    fi
  fi
done < "$CHANGELOG"

# Check last subsection
if $IN_SUB && [[ "$SUB_LINE_COUNT" -eq 0 ]]; then
  echo "  ✗ [$CURRENT_VER] → ### $CURRENT_SUB is empty"
  fail
else
  echo "  ✓ No empty subsections found"
  pass
fi
echo ""

# --- Step 10: Changelog content quality ---
echo "Step 10: Content quality"

TOTAL_LINES=0
TOTAL_ITEMS=0
while IFS= read -r line; do
  TOTAL_LINES=$((TOTAL_LINES + 1))
  if echo "$line" | grep -qP '^\s*[-*] '; then
    TOTAL_ITEMS=$((TOTAL_ITEMS + 1))
  fi
done < "$CHANGELOG"

check "changelog has content (items > 0)" test "$TOTAL_ITEMS" -gt 0
echo "  Changelog: $TOTAL_LINES lines, $TOTAL_ITEMS items"

# Check for forbidden patterns
FORBIDDEN_OK=true
for pattern in "TODO" "FIXME" "XXX" "HACK"; do
  if grep -qP "$pattern" "$CHANGELOG"; then
    echo "  ✗ Contains $pattern marker"
    FORBIDDEN_OK=false
    fail
  fi
done
if $FORBIDDEN_OK; then
  echo "  ✓ No TODO/FIXME/HACK markers"
  pass
fi
echo ""

# --- Summary ---
echo "=== Summary ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "  Total:  $TOTAL"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo "RESULT: FAIL ($FAIL failures)"
  exit 1
fi

echo "RESULT: PASS ($PASS checks)"
exit 0
