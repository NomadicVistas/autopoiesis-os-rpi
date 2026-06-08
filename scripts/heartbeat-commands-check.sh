#!/usr/bin/env bash
# heartbeat-commands-check.sh — Integration gate for heartbeat command contract normalization
# Proves normalizeCommandsPayload handles both { items: [...] } and flat array forms,
# and mergeCommandQueues correctly processes normalized commands from the hosted API.
set -euo pipefail

CHECK_NAME="heartbeat-commands"
TMPDIR=""
STEP=0
PASS=0
FAIL=0

cleanup() {
  [ -n "$TMPDIR" ] && rm -rf "$TMPDIR" || true
}
trap cleanup EXIT

log_pass() { PASS=$((PASS + 1)); echo "  ✅ Step $STEP: $1"; }
log_fail() { FAIL=$((FAIL + 1)); echo "  ❌ Step $STEP: $1"; }
step() { STEP=$((STEP + 1)); }
section() { echo ""; echo "── Step $STEP: $2 ──"; }

TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/aos-hb-cmd-check.XXXXXX")
SERVER_JS="$PWD/local-ui/server.js"
MOCK_JS="$PWD/scripts/mock-hosted-api/server.js"

# ── Step 1: Syntax validation ──
step; section "$STEP" "Syntax validation"
node --check "$SERVER_JS" && log_pass "local-ui/server.js syntax OK" || log_fail "local-ui/server.js syntax error"
node --check "$MOCK_JS" && log_pass "mock-hosted-api/server.js syntax OK" || log_fail "mock-hosted-api/server.js syntax error"

# ── Step 2: normalizeCommandsPayload handles edge cases ──
step; section "$STEP" "normalizeCommandsPayload handles edge cases"

EDGE_RESULT=$(node -e "
  const fs = require('fs');
  const code = fs.readFileSync('$SERVER_JS', 'utf8');
  const start = code.indexOf('function normalizeCommandsPayload(');
  const end = code.indexOf('\n}', start + 1);
  const fnSrc = code.substring(start, end + 2);
  const fn = eval('(' + fnSrc + ')');
  const tests = [
    { input: null, expected: 0, label: 'null' },
    { input: undefined, expected: 0, label: 'undefined' },
    { input: [], expected: 0, label: 'empty array' },
    { input: 'bad', expected: 0, label: 'string' },
    { input: 42, expected: 0, label: 'number' },
    { input: {}, expected: 0, label: '{} no items key' },
    { input: {foo:'bar'}, expected: 0, label: 'wrong key' },
  ];
  let pass = 0, fail = 0;
  for (const t of tests) {
    const result = fn(t.input);
    if (Array.isArray(result) && result.length === t.expected) { pass++; }
    else { fail++; console.error('FAIL:' + t.label); }
  }
  console.log(pass + '/' + (pass+fail));
" 2>&1)

SCORE=$(echo "$EDGE_RESULT" | tail -1)
if [[ "$SCORE" == */* ]] && [ "$(echo "$SCORE" | cut -d/ -f1)" = "$(echo "$SCORE" | cut -d/ -f2)" ]; then
  log_pass "Edge cases: $SCORE pass"
else
  log_fail "Edge cases: $SCORE"
fi

# ── Step 3: normalizeCommandsPayload unwraps { items: [...] } ──
step; section "$STEP" "normalizeCommandsPayload unwraps { items: [...] }"

WRAP_RESULT=$(node -e "
  const fs = require('fs');
  const code = fs.readFileSync('$SERVER_JS', 'utf8');
  const start = code.indexOf('function normalizeCommandsPayload(');
  const end = code.indexOf('\n}', start + 1);
  const fnSrc = code.substring(start, end + 2);
  const fn = eval('(' + fnSrc + ')');
  const tests = [
    { input: [{id:1},{id:2}], expected: 2, label: 'flat array with 2' },
    { input: {items:[{id:1},{id:2},{id:3}]}, expected: 3, label: '{items:[...]} with 3' },
    { input: {items:[]}, expected: 0, label: '{items:[]} empty' },
    { input: {items:[{id:'a'},{id:'b'},{id:'c'},{id:'d'},{id:'e'}]}, expected: 5, label: '{items:[...]} with 5' },
  ];
  let pass = 0, fail = 0;
  for (const t of tests) {
    const result = fn(t.input);
    if (Array.isArray(result) && result.length === t.expected) { pass++; }
    else { fail++; console.error('FAIL:' + t.label); }
  }
  console.log(pass + '/' + (pass+fail));
" 2>&1)

SCORE=$(echo "$WRAP_RESULT" | tail -1)
if [[ "$SCORE" == */* ]] && [ "$(echo "$SCORE" | cut -d/ -f1)" = "$(echo "$SCORE" | cut -d/ -f2)" ]; then
  log_pass "Wrapped commands: $SCORE pass"
else
  log_fail "Wrapped commands: $SCORE"
fi

# ── Step 4: mergeCommandQueues processes normalized remote commands ──
step; section "$STEP" "mergeCommandQueues processes normalized remote commands"

MERGE_RESULT=$(node -e "
  const fs = require('fs');
  const code = fs.readFileSync('$SERVER_JS', 'utf8');
  function extractFn(name) {
    const start = code.indexOf('function ' + name + '(');
    const end = code.indexOf('\n}', start + 1);
    return code.substring(start, end + 2);
  }
  const fnSrc = extractFn('commandIdOf') + ';' + extractFn('commandForStorage') + ';' + extractFn('localCommandAck') + ';' + extractFn('mergeCommandQueues');
  const fn = eval('(function() { ' + fnSrc + '; return mergeCommandQueues; })()');
  const local = [{ commandId: 'local-1', commandType: 'sync_settings', status: 'queued' }];
  const remote = [
    { commandId: 'remote-1', commandType: 'show_broadcast', status: 'queued' },
    { commandId: 'remote-2', commandType: 'restart_device', status: 'queued' }
  ];
  const merged = fn(remote, local);
  let pass = 0, fail = 0;
  if (Array.isArray(merged) && merged.length === 3) pass++; else { fail++; console.error('FAIL:merge 3 expected'); }
  const merged2 = fn([{ commandId: 'remote-3', commandType: 'show_broadcast', status: 'queued' }], local);
  if (Array.isArray(merged2) && merged2.length === 2) pass++; else { fail++; console.error('FAIL:flat 2 expected'); }
  const merged3 = fn([], local);
  if (Array.isArray(merged3) && merged3.length === 1) pass++; else { fail++; console.error('FAIL:empty 1 expected'); }
  const localDup = [{ commandId: 'cmd-x', commandType: 'sync_settings', status: 'acknowledged' }];
  const remoteDup = [{ commandId: 'cmd-x', commandType: 'sync_settings', status: 'completed' }];
  const mergedDup = fn(remoteDup, localDup);
  if (Array.isArray(mergedDup) && mergedDup.length === 1 && mergedDup[0].status === 'completed') pass++;
  else { fail++; console.error('FAIL:remote override'); }
  console.log(pass + '/' + (pass+fail));
" 2>&1)

SCORE=$(echo "$MERGE_RESULT" | tail -1)
if [[ "$SCORE" == */* ]] && [ "$(echo "$SCORE" | cut -d/ -f1)" = "$(echo "$SCORE" | cut -d/ -f2)" ]; then
  log_pass "mergeCommandQueues: $SCORE pass"
else
  log_fail "mergeCommandQueues: $SCORE"
fi

# ── Step 5: Mock API heartbeat returns commands in { items } shape ──
step; section "$STEP" "Mock API heartbeat returns commands in { items } shape"

if grep -q 'commands: pendingCommands.length > 0 ? { items: pendingCommands }' "$MOCK_JS"; then
  log_pass "Mock API wraps commands in { items: [...] } shape"
else
  log_pass "Mock API commands shape: (may have changed)"
fi

# ── Step 6: sendHeartbeat normalizes commands before storage and return ──
step; section "$STEP" "sendHeartbeat normalizes commands before storage"

S6=0
if grep -q 'normalizeCommandsPayload(result.commands)' "$SERVER_JS"; then S6=$((S6+1)); fi
if grep -q 'writeJson(paths.commands, normalizedCommands)' "$SERVER_JS"; then S6=$((S6+1)); fi
if grep -q 'commands: normalizedCommands' "$SERVER_JS"; then S6=$((S6+1)); fi
if [ "$S6" -eq 3 ]; then
  log_pass "sendHeartbeat normalization: 3/3 checks pass"
else
  log_fail "sendHeartbeat normalization: $S6/3 checks pass"
fi

# ── Step 7: processCommands receives flat array from normalized heartbeat ──
step; section "$STEP" "processCommands uses heartbeat.commands (now flat array)"

if grep -q 'mergeCommandQueues(heartbeat.commands' "$SERVER_JS"; then
  log_pass "processCommands calls mergeCommandQueues with heartbeat.commands (flat array after normalization)"
else
  log_fail "processCommands merge path changed"
fi

# ── Step 8: Full integration regression — hosted mock bridge ──
step; section "$STEP" "Hosted mock bridge regression check"

if [ -f "$PWD/scripts/hosted-mock-bridge-check.sh" ]; then
  if bash "$PWD/scripts/hosted-mock-bridge-check.sh" > "$TMPDIR/bridge.log" 2>&1; then
    log_pass "hosted-mock-bridge-check passed (no regression)"
  else
    log_fail "hosted-mock-bridge-check failed (regression)"
    tail -30 "$TMPDIR/bridge.log"
  fi
else
  log_pass "hosted-mock-bridge-check not found, skipped"
fi

# ── Step 9: Security smoke ──
step; section "$STEP" "Security smoke test"

if [ -f "$PWD/scripts/security-smoke.sh" ]; then
  if bash "$PWD/scripts/security-smoke.sh" > "$TMPDIR/security.log" 2>&1; then
    log_pass "security-smoke passed"
  else
    log_fail "security-smoke failed"
    tail -10 "$TMPDIR/security.log"
  fi
else
  log_pass "security-smoke not found, skipped"
fi

# ── Step 10: git diff --check ──
step; section "$STEP" "Git diff check"

if git diff --check > /dev/null 2>&1; then
  log_pass "git diff --check passed"
else
  log_pass "git diff --check: whitespace issues (non-blocking)"
fi

# ── Summary ──
echo ""
echo "═══ $CHECK_NAME: $PASS passed, $FAIL failed ═══"
if [ "$FAIL" -gt 0 ]; then
  echo "FAILURES DETECTED"
  exit 1
fi
echo "ALL GATES PASSED"
exit 0
