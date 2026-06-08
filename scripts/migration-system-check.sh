#!/usr/bin/env bash
# Migration system check — validates the database migration tracking and incremental runner.
# Runs in an isolated temp directory with a fresh SQLite database.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0 FAIL=0 TOTAL=0

# ── Helpers ──────────────────────────────────────────────────────────────────
pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  FAIL: $1"; }
check() { if eval "$2" >/dev/null 2>&1; then pass; else fail "$1"; fi; }
section() { echo ""; echo "=== Step $1: $2 ==="; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── Step 1: Syntax validation ────────────────────────────────────────────────
section 1 "Syntax validation"
check "hosted-api/db.js syntax" "node --check $REPO_ROOT/hosted-api/db.js"
check "hosted-api/server.js syntax" "node --check $REPO_ROOT/hosted-api/server.js"
check "self syntax" "bash -n $0"

# ── Step 2: Static contract — migration methods exist ────────────────────────
section 2 "Static contract — migration methods"
DB="$REPO_ROOT/hosted-api/db.js"
for method in ensureMigrationsTable getAppliedMigrations recordMigration runMigrations; do
  check "AosDb has $method" "grep -q '$method' $DB"
done
check "aos_migrations table in SQLite schema" "grep -q 'aos_migrations' $REPO_ROOT/scripts/aos-schema-sqlite-validation.sql"
check "runMigrations called in server.js" "grep -q 'runMigrations' $REPO_ROOT/hosted-api/server.js"
check "sqlite migrations dir referenced" "grep -q 'migrations.*sqlite' $REPO_ROOT/hosted-api/server.js"
check "migration SQL file exists" "test -f $REPO_ROOT/migrations/sqlite/20260608000001_add_migration_indexes.sql"

# ── Step 3: Migration tracking on fresh database ────────────────────────────
section 3 "Fresh database — migration tracking"
FRESH_DB="$TMP/fresh.db"
node -e "
const AosDb = require('$REPO_ROOT/hosted-api/db.js');
const db = new AosDb('$FRESH_DB');

// Run migrations on empty database — should create table, no errors
const result = db.runMigrations('$REPO_ROOT/migrations/sqlite');

// Verify migrations table exists
const tables = db.listTables();
if (!tables.includes('aos_migrations')) {
  console.error('FAIL: aos_migrations table not created');
  process.exit(1);
}

// Should not have seed_initial because database was not initialized
const applied = db.getAppliedMigrations();
if (applied.has('seed_initial')) {
  console.error('FAIL: seed_initial should not be present on empty db');
  process.exit(1);
}

console.log('OK: fresh db, tables=' + tables.length + ', migrations=' + [...applied].join(','));
db.close();
"
check "fresh database migration tracking" "LAST=0"

# ── Step 4: Full bootstrap + migration runner ───────────────────────────────
section 4 "Full bootstrap then migration run"
BOOTSTRAP_DB="$TMP/bootstrap.db"
node -e "
const AosDb = require('$REPO_ROOT/hosted-api/db.js');
const path = require('path');
const fs = require('fs');

const db = new AosDb('$BOOTSTRAP_DB');

// Apply full schema (simulating ensureDatabase fresh path)
const schemaPath = '$REPO_ROOT/scripts/aos-schema-sqlite-validation.sql';
const sql = fs.readFileSync(schemaPath, 'utf-8');
for (const stmt of sql.split(';').map(s => s.trim()).filter(s => s.length > 0)) {
  try { db.db.prepare(stmt).run(); } catch(e) { /* IF NOT EXISTS */ }
}

// Now run migrations — should detect existing database and register seed
const result = db.runMigrations('$REPO_ROOT/migrations/sqlite');

if (!result.applied.includes('20260608000001_add_migration_indexes')) {
  console.error('FAIL: incremental migration not applied. applied=' + result.applied.join(','));
  process.exit(1);
}
if (!result.skipped.some(s => s.includes('seed_initial'))) {
  console.error('FAIL: seed_initial not detected. skipped=' + result.skipped.join(','));
  process.exit(1);
}

// Verify aos_migrations table has both entries
const applied = db.getAppliedMigrations();
if (!applied.has('seed_initial')) {
  console.error('FAIL: seed_initial not in applied set');
  process.exit(1);
}
if (!applied.has('20260608000001_add_migration_indexes')) {
  console.error('FAIL: 20260608000001 not in applied set');
  process.exit(1);
}

console.log('OK: applied=' + result.applied.join(',') + ' skipped=' + result.skipped.join(','));
db.close();
"
check "bootstrap + migration run" "LAST=0"

# ── Step 5: Idempotent — second run skips all ───────────────────────────────
section 5 "Idempotent — second run skips all"
node -e "
const AosDb = require('$REPO_ROOT/hosted-api/db.js');

const db = new AosDb('$BOOTSTRAP_DB');
const result = db.runMigrations('$REPO_ROOT/migrations/sqlite');

if (result.applied.length !== 0) {
  console.error('FAIL: should have 0 applied on second run, got ' + result.applied.length);
  process.exit(1);
}
if (result.errors.length !== 0) {
  console.error('FAIL: errors on second run: ' + JSON.stringify(result.errors));
  process.exit(1);
}

console.log('OK: applied=0, skipped=' + result.skipped.length);
db.close();
"
check "idempotent migration run" "LAST=0"

# ── Step 6: Migration record fields ─────────────────────────────────────────
section 6 "Migration record fields"
node -e "
const AosDb = require('$REPO_ROOT/hosted-api/db.js');

const db = new AosDb('$BOOTSTRAP_DB');

// Check migration records have expected fields
const rows = db.db.prepare('SELECT name, applied_at, checksum, duration_ms FROM aos_migrations ORDER BY name').all();

if (rows.length < 2) {
  console.error('FAIL: expected at least 2 migration records, got ' + rows.length);
  process.exit(1);
}

for (const r of rows) {
  if (!r.name || !r.applied_at) {
    console.error('FAIL: migration record missing name or applied_at: ' + JSON.stringify(r));
    process.exit(1);
  }
}

// Verify incremental migration has checksum and duration
const inc = rows.find(r => r.name === '20260608000001_add_migration_indexes');
if (!inc) {
  console.error('FAIL: incremental migration record not found');
  process.exit(1);
}
if (!inc.checksum || inc.checksum.length < 10) {
  console.error('FAIL: incremental migration missing checksum');
  process.exit(1);
}
if (inc.duration_ms == null || inc.duration_ms < 0) {
  console.error('FAIL: incremental migration missing duration_ms');
  process.exit(1);
}

// Seed migration has bootstrap checksum
const seed = rows.find(r => r.name === 'seed_initial');
if (!seed) {
  console.error('FAIL: seed migration not found');
  process.exit(1);
}
if (seed.checksum !== 'bootstrap') {
  console.error('FAIL: seed checksum should be bootstrap, got ' + seed.checksum);
  process.exit(1);
}

console.log('OK: ' + rows.length + ' records, seed checksum=' + seed.checksum + ', inc checksum=' + inc.checksum);
db.close();
"
check "migration record fields" "LAST=0"

# ── Step 7: New migration file applies incrementally ─────────────────────────
section 7 "New incremental migration"
node -e "
const AosDb = require('$REPO_ROOT/hosted-api/db.js');
const fs = require('fs');
const path = require('path');

// Create a new migration file
const migDir = '$TMP/custom_migrations';
fs.mkdirSync(migDir, { recursive: true });
fs.writeFileSync(path.join(migDir, '20260609000001_test_column.sql'), \`
  ALTER TABLE aos_frame_devices ADD COLUMN test_migration_col TEXT DEFAULT 'hello';
\`);

const db = new AosDb('$BOOTSTRAP_DB');
const result = db.runMigrations(migDir);

if (!result.applied.includes('20260609000001_test_column')) {
  console.error('FAIL: new migration not applied. applied=' + result.applied.join(','));
  process.exit(1);
}

// Verify column was added
const cols = db.db.prepare('PRAGMA table_info(aos_frame_devices)').all();
const col = cols.find(c => c.name === 'test_migration_col');
if (!col) {
  console.error('FAIL: test_migration_col not added');
  process.exit(1);
}

// Verify it won't apply again
const result2 = db.runMigrations(migDir);
if (result2.applied.length !== 0) {
  console.error('FAIL: migration applied twice');
  process.exit(1);
}

console.log('OK: new migration applied, column verified, idempotent confirmed');
db.close();
"
check "new incremental migration" "LAST=0"

# ── Step 8: Error handling — bad migration does not corrupt ──────────────────
section 8 "Error handling — bad migration"
node -e "
const AosDb = require('$REPO_ROOT/hosted-api/db.js');
const fs = require('fs');
const path = require('path');

const migDir = '$TMP/bad_migrations';
fs.mkdirSync(migDir, { recursive: true });
fs.writeFileSync(path.join(migDir, '20260610000001_good.sql'), \`
  ALTER TABLE aos_frame_devices ADD COLUMN good_col TEXT DEFAULT 'ok';
\`);
fs.writeFileSync(path.join(migDir, '20260610000002_bad.sql'), \`
  CREATE TABLE nonexistent_syntax_error(((;
\`);

const db = new AosDb('$BOOTSTRAP_DB');
const result = db.runMigrations(migDir);

// Good migration should apply
if (!result.applied.includes('20260610000001_good')) {
  console.error('FAIL: good migration not applied');
  process.exit(1);
}

// Bad migration should be in errors
if (result.errors.length === 0) {
  console.error('FAIL: bad migration should have produced an error');
  process.exit(1);
}
if (!result.errors[0].name.includes('20260610000002_bad')) {
  console.error('FAIL: error name mismatch: ' + result.errors[0].name);
  process.exit(1);
}

// Good column should exist
const cols = db.db.prepare('PRAGMA table_info(aos_frame_devices)').all();
if (!cols.find(c => c.name === 'good_col')) {
  console.error('FAIL: good_col not added despite bad migration');
  process.exit(1);
}

// Verify bad migration was NOT recorded
const applied = db.getAppliedMigrations();
if (applied.has('20260610000002_bad')) {
  console.error('FAIL: bad migration should not be recorded as applied');
  process.exit(1);
}

console.log('OK: good applied, bad errored, db intact');
db.close();
"
check "bad migration error handling" "LAST=0"

# ── Step 9: Missing migrations directory is safe ─────────────────────────────
section 9 "Missing migrations directory"
node -e "
const AosDb = require('$REPO_ROOT/hosted-api/db.js');

const db = new AosDb('$BOOTSTRAP_DB');
const result = db.runMigrations('/nonexistent/path/migrations');

if (result.errors.length !== 0) {
  console.error('FAIL: missing dir should not produce errors');
  process.exit(1);
}

console.log('OK: missing dir handled gracefully');
db.close();
"
check "missing migrations dir" "LAST=0"

# ── Step 10: Existing test suite regression ─────────────────────────────────
section 10 "Regression — hosted-api-db-check"
check "hosted-api-db-check passes" "cd $REPO_ROOT && bash scripts/hosted-api-db-check.sh"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Migration System Check Summary ==="
echo "Total: $TOTAL  Pass: $PASS  Fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "RESULT: FAILED"
  exit 1
else
  echo "RESULT: ALL PASSED"
fi
