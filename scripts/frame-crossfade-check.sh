#!/usr/bin/env bash
set -euo pipefail

# Frame cross-fade transition acceptance gate
# Validates that the kiosk frame cycling uses smooth fade transitions
# instead of instant content swaps.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER_JS="$REPO_DIR/local-ui/server.js"
PASS=0
FAIL=0
TOTAL=0

ok() { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
section() { echo ""; echo "## $1"; }

echo "Frame cross-fade transition gate"
echo "================================="

# ---- 1. Syntax ----
section "1. Syntax validation"
if node --check "$SERVER_JS" 2>/dev/null; then
  ok "node --check local-ui/server.js"
else
  fail "node --check local-ui/server.js failed"
fi

# ---- 2. CSS transition property ----
section "2. CSS fade transition"
if grep -q '\.frame-stage.*transition:.*opacity' "$SERVER_JS"; then
  ok ".frame-stage has CSS opacity transition"
else
  fail ".frame-stage missing CSS opacity transition"
fi

if grep -q '\.frame-stage\.fading' "$SERVER_JS"; then
  ok ".frame-stage.fading class defined"
else
  fail ".frame-stage.fading class not found"
fi

if grep -q '\.frame-stage\.fading.*opacity: 0' "$SERVER_JS"; then
  ok ".frame-stage.fading sets opacity: 0"
else
  fail ".frame-stage.fading does not set opacity: 0"
fi

# ---- 3. Transition duration ----
section "3. Transition duration constant"
if grep -q 'FADE_MS' "$SERVER_JS"; then
  ok "FADE_MS constant defined"
else
  fail "FADE_MS constant not found"
fi

FADE_VALUE=$(grep -oP 'FADE_MS\s*=\s*\K[0-9]+' "$SERVER_JS" || echo "")
if [[ -n "$FADE_VALUE" ]]; then
  if [[ "$FADE_VALUE" -ge 300 && "$FADE_VALUE" -le 1500 ]]; then
    ok "FADE_MS value ($FADE_VALUE ms) is in reasonable range (300-1500ms)"
  else
    fail "FADE_MS value ($FADE_VALUE ms) is outside reasonable range (300-1500ms)"
  fi
else
  fail "Could not extract FADE_MS value"
fi

# Verify FADE_MS matches CSS transition duration
CSS_DURATION=$(grep -oP '\.frame-stage[^}]*transition:\s*opacity\s+\K[0-9]+' "$SERVER_JS" || echo "")
if [[ -n "$CSS_DURATION" && -n "$FADE_VALUE" ]]; then
  if [[ "$CSS_DURATION" -eq "$FADE_VALUE" ]]; then
    ok "CSS transition duration ($CSS_DURATION ms) matches FADE_MS ($FADE_VALUE ms)"
  else
    fail "CSS transition duration ($CSS_DURATION ms) does not match FADE_MS ($FADE_VALUE ms)"
  fi
fi

# ---- 4. transitionToNext function ----
section "4. transitionToNext function"
if grep -q 'function transitionToNext' "$SERVER_JS"; then
  ok "transitionToNext function defined"
else
  fail "transitionToNext function not found"
fi

if grep -q 'isFirstFrame' "$SERVER_JS"; then
  ok "isFirstFrame state variable used for first-frame skip"
else
  fail "isFirstFrame not found"
fi

if grep -q 'classList.add.*fading' "$SERVER_JS"; then
  ok "Adds fading class for fade-out"
else
  fail "Does not add fading class"
fi

if grep -q 'classList.remove.*fading' "$SERVER_JS"; then
  ok "Removes fading class for fade-in"
else
  fail "Does not remove fading class"
fi

if grep -q 'requestAnimationFrame' "$SERVER_JS"; then
  ok "Uses requestAnimationFrame for fade-in timing"
else
  fail "Does not use requestAnimationFrame for fade-in"
fi

# ---- 5. setTimeout matches FADE_MS ----
section "5. Fade-out delay matches transition"
# In the embedded JS template, look for the setTimeout pattern that waits FADE_MS
if grep -A15 'function transitionToNext' "$SERVER_JS" | grep -q 'setTimeout'; then
  ok "renderFrameItem is called after setTimeout delay"
  # Verify it's actually called inside the timeout
  if grep -A15 'function transitionToNext' "$SERVER_JS" | grep -A10 'setTimeout' | grep -q 'renderFrameItem'; then
    ok "renderFrameItem is inside the setTimeout callback"
  else
    fail "renderFrameItem is not inside the setTimeout callback"
  fi
else
  fail "renderFrameItem is not called after delay"
fi

# ---- 6. Overlay hidden during transition ----
section "6. Overlay handling"
if grep -q 'transitionToNext.*overlay.*hidden\|overlay.*hidden.*transitionToNext' "$SERVER_JS"; then
  ok "Overlay hidden in transitionToNext (visual grep)"
elif grep -A5 'function transitionToNext' "$SERVER_JS" | grep -q 'overlay.*hidden'; then
  ok "Overlay hidden at start of transitionToNext"
else
  fail "Overlay may not be hidden during transition"
fi

# ---- 7. scheduleNext integration ----
section "7. scheduleNext uses transitionToNext"
if grep -A3 'const advance' "$SERVER_JS" | grep -q 'transitionToNext'; then
  ok "scheduleNext advance callback calls transitionToNext"
else
  fail "scheduleNext advance callback does not call transitionToNext"
fi

# Verify scheduleNext no longer directly calls renderFrameItem in advance
if grep -A3 'const advance' "$SERVER_JS" | grep -q 'renderFrameItem'; then
  fail "scheduleNext advance still calls renderFrameItem directly (should use transitionToNext)"
else
  ok "scheduleNext advance no longer calls renderFrameItem directly"
fi

# ---- 8. Initial call uses transitionToNext ----
section "8. First frame uses transitionToNext"
# The bottom of the frame script should call transitionToNext, not renderFrameItem
if grep -q 'transitionToNext()' "$SERVER_JS"; then
  ok "transitionToNext is called (not renderFrameItem) for frame start"
else
  fail "transitionToNext is not called for frame start"
fi

# ---- 9. isFirstFrame lifecycle ----
section "9. isFirstFrame lifecycle"
if grep -q 'isFirstFrame = true' "$SERVER_JS"; then
  ok "isFirstFrame initialized to true"
else
  fail "isFirstFrame not initialized"
fi

if grep -q 'isFirstFrame = false' "$SERVER_JS"; then
  ok "isFirstFrame set to false after first frame"
else
  fail "isFirstFrame never set to false"
fi

# ---- 10. renderFrameItem still works standalone ----
section "10. renderFrameItem standalone integrity"
# renderFrameItem should still contain the core display logic
if grep -q 'function renderFrameItem' "$SERVER_JS"; then
  ok "renderFrameItem function still exists"
else
  fail "renderFrameItem function missing"
fi

# Should still handle empty items case
if grep -A5 'function renderFrameItem' "$SERVER_JS" | grep -q 'frameItems.length'; then
  ok "renderFrameItem still handles empty items"
else
  fail "renderFrameItem empty items handling may be broken"
fi

# Should still do display tracking
if grep -A20 'function renderFrameItem' "$SERVER_JS" | grep -q 'local/frame/display'; then
  ok "renderFrameItem still reports display events"
else
  fail "renderFrameItem display tracking may be broken"
fi

# ---- 11. No duplicate fade on first frame ----
section "11. First frame skips fade"
# transitionToNext should check isFirstFrame and skip the fade
if grep -A8 'function transitionToNext' "$SERVER_JS" | grep -q 'isFirstFrame.*renderFrameItem\|isFirstFrame.*false'; then
  ok "First frame skips fade (isFirstFrame guard present)"
else
  fail "First frame may get an unnecessary fade"
fi

# ---- 12. Video ended events trigger transition ----
section "12. Media ended triggers transition"
if grep -A15 'function scheduleNext' "$SERVER_JS" | grep -q 'ended'; then
  ok "Video/audio ended event still triggers advance"
else
  fail "Media ended event handling may be broken"
fi

# ---- Summary ----
echo ""
echo "================================="
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ $FAIL -eq 0 ]]; then
  echo "All checks passed ✅"
  exit 0
else
  echo "Some checks failed ❌"
  exit 1
fi
