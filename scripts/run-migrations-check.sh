#!/usr/bin/env bash
# run-migrations-check.sh — Validate the AOS migration runner against expected behavior.
#
# Tests:
#   1. Script syntax (bash -n)
#   2. Help output
#   3. Fresh database creation (all 14 required tables + tracking table)
#   4. Migration tracking table structure
#   5. Schema contract validation passes automatically
#   6. Idempotent re-run (applied=0, tables unchanged)
#   7. Dry-run mode (no database modification)
#   8. Missing migrations directory (error exit)
#   9. --no-validate flag skips schema check
#  10. --engine flag validation (rejects unknown engines)
#  11. Database directory auto-creation
#  12. Migration file recorded for PostgreSQL canonical migration id
#
# Usage:
#   scripts/run-migrations-check.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$REPO_ROOT/scripts/run-migrations.sh"
SCHEMA_CHECK="$REPO_ROOT/scripts/aos-schema-contract-check.sh"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*" >&2; }

sqlite_query() {
  local db_path="$1"
  local sql="$2"
  node - "$REPO_ROOT" "$db_path" "$sql" <<'NODE'
const repoRoot = process.argv[2];
const dbPath = process.argv[3];
const sql = process.argv[4];
const Database = require(require.resolve("better-sqlite3", { paths: [repoRoot] }));
const db = new Database(dbPath, { readonly: true });
const rows = db.prepare(sql).raw().all();
if (rows.length) {
  process.stdout.write(rows.map((row) => row.join("|")).join("\n"));
  process.stdout.write("\n");
}
db.close();
NODE
}

cleanup() {
  rm -f /tmp/aos-migrate-test-*.db
  rm -rf /tmp/aos-migrate-test-dir-*
}
trap cleanup EXIT

echo "=== AOS Migration Runner Gate ==="

# ── Step 1: Script syntax ────────────────────────────────────────────────
echo -n "1. Script syntax ... "
if bash -n "$RUNNER"; then
  pass; echo "ok"
else
  fail; echo "FAIL"
fi

# ── Step 2: Help output ──────────────────────────────────────────────────
echo -n "2. Help output ... "
help_out="$("$RUNNER" --help 2>&1 || true)"
if echo "$help_out" | grep -q "run-migrations.sh" && echo "$help_out" | grep -q "\-\-db"; then
  pass; echo "ok"
else
  fail; echo "FAIL (help missing expected flags)"
fi

# ── Step 3: Fresh database creation ──────────────────────────────────────
echo -n "3. Fresh database creation ... "
rm -f /tmp/aos-migrate-test-fresh.db
out="$("$RUNNER" --db /tmp/aos-migrate-test-fresh.db --engine sqlite --no-validate 2>&1)"
tables="$(sqlite_query /tmp/aos-migrate-test-fresh.db "SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name;" | sort)"
required_tables=(
  aos_frame_devices
  aos_frame_pairing_codes
  aos_frame_device_settings
  aos_frame_user_preferences
  aos_heartbeats
  aos_device_commands
  aos_admin_command_audits
  aos_device_events
  aos_artwork_likes
  aos_broadcasts
  aos_broadcast_deliveries
  aos_releases
  aos_release_rollouts
  aos_subscriptions
  aos_schema_migrations
)
all_tables_ok=true
for t in "${required_tables[@]}"; do
  if ! echo "$tables" | grep -qxF "$t"; then
    all_tables_ok=false
    echo "  missing table: $t"
  fi
done
if $all_tables_ok; then
  pass; echo "ok (15 tables)"
else
  fail; echo "FAIL"
fi

# ── Step 4: Migration tracking table structure ───────────────────────────
echo -n "4. Tracking table structure ... "
cols="$(sqlite_query /tmp/aos-migrate-test-fresh.db "PRAGMA table_info(aos_schema_migrations);")"
if echo "$cols" | grep -q "id" && echo "$cols" | grep -q "applied_at"; then
  pass; echo "ok"
else
  fail; echo "FAIL"
fi

# ── Step 5: Schema contract validation passes automatically ──────────────
echo -n "5. Auto schema contract validation ... "
rm -f /tmp/aos-migrate-test-contract.db
out="$("$RUNNER" --db /tmp/aos-migrate-test-contract.db --engine sqlite 2>&1)"
if echo "$out" | grep -q "schema contract: passed"; then
  pass; echo "ok"
else
  fail; echo "FAIL (output: $out)"
fi

# ── Step 6: Idempotent re-run ────────────────────────────────────────────
echo -n "6. Idempotent re-run ... "
out2="$("$RUNNER" --db /tmp/aos-migrate-test-contract.db --engine sqlite --verbose 2>&1)"
if echo "$out2" | grep -q "already applied: sqlite-validation-schema" && echo "$out2" | grep -q "applied=0"; then
  pass; echo "ok"
else
  fail; echo "FAIL (output: $out2)"
fi

# ── Step 7: Dry-run mode ─────────────────────────────────────────────────
echo -n "7. Dry-run mode ... "
rm -f /tmp/aos-migrate-test-dryrun.db
out3="$("$RUNNER" --db /tmp/aos-migrate-test-dryrun.db --engine sqlite --dry-run --no-validate 2>&1)"
if echo "$out3" | grep -q "\[dry-run\] would apply"; then
  # Verify the database was NOT created at all
  if [[ ! -f /tmp/aos-migrate-test-dryrun.db ]]; then
    pass; echo "ok (no database created in dry-run)"
  else
    tables_dry="$(sqlite_query /tmp/aos-migrate-test-dryrun.db "SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name;" 2>/dev/null || true)"
    if [[ -z "$tables_dry" ]]; then
      pass; echo "ok (empty database in dry-run)"
    else
      fail; echo "FAIL (tables were created in dry-run: $tables_dry)"
    fi
  fi
else
  fail; echo "FAIL (no dry-run output: $out3)"
fi

# ── Step 8: Missing migrations directory ─────────────────────────────────
echo -n "8. Missing migrations directory ... "
rm -rf /tmp/aos-migrate-test-nodir
rm -f /tmp/aos-migrate-test-nodir.db
if "$RUNNER" --db /tmp/aos-migrate-test-nodir.db --dir /tmp/aos-migrate-test-nodir --engine sqlite 2>&1; then
  fail; echo "FAIL (should have exited with error)"
else
  pass; echo "ok (exited with error)"
fi

# ── Step 9: --no-validate skips schema check ─────────────────────────────
echo -n "9. --no-validate flag ... "
rm -f /tmp/aos-migrate-test-noval.db
out4="$("$RUNNER" --db /tmp/aos-migrate-test-noval.db --engine sqlite --no-validate 2>&1)"
if echo "$out4" | grep -q "schema contract"; then
  fail; echo "FAIL (schema check ran despite --no-validate)"
else
  pass; echo "ok"
fi

# ── Step 10: --engine flag validation ────────────────────────────────────
echo -n "10. Invalid engine rejection ... "
rm -f /tmp/aos-migrate-test-engine.db
if "$RUNNER" --db /tmp/aos-migrate-test-engine.db --engine mysql 2>&1; then
  fail; echo "FAIL (should have exited with error)"
else
  pass; echo "ok"
fi

# ── Step 11: Database directory auto-creation ────────────────────────────
echo -n "11. Database directory auto-creation ... "
rm -rf /tmp/aos-migrate-test-deep
out5="$("$RUNNER" --db /tmp/aos-migrate-test-deep/sub/dir/aos.db --engine sqlite --no-validate 2>&1)"
if [[ -f /tmp/aos-migrate-test-deep/sub/dir/aos.db ]] && echo "$out5" | grep -q "applied=1"; then
  pass; echo "ok"
else
  fail; echo "FAIL"
fi

# ── Step 12: PostgreSQL migration id recorded ────────────────────────────
echo -n "12. PostgreSQL migration id tracked ... "
ids="$(sqlite_query /tmp/aos-migrate-test-contract.db "SELECT id FROM aos_schema_migrations ORDER BY id;")"
if echo "$ids" | grep -q "20260607000001_initial_aos_frames" && echo "$ids" | grep -q "sqlite-validation-schema"; then
  pass; echo "ok (both ids tracked)"
else
  fail; echo "FAIL (ids: $ids)"
fi

# ── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
