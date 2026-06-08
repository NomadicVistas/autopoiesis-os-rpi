#!/usr/bin/env bash
# run-migrations.sh — Apply AOS schema migrations to a SQLite or PostgreSQL database.
#
# SQLite mode (default) uses the SQLite-compatible validation schema from
# scripts/aos-schema-sqlite-validation.sql. PostgreSQL mode applies the
# canonical migration files from migrations/ in sorted order.
#
# Both modes track applied migrations in aos_schema_migrations and optionally
# validate the resulting schema against the AOS schema contract checker.
#
# Usage:
#   scripts/run-migrations.sh [OPTIONS]
#
# Options:
#   --db PATH         Database file path (SQLite) or connection string (PostgreSQL)
#   --dir DIR         Migrations directory (default: ./migrations)
#   --engine ENGINE   Database engine: sqlite (default) or postgres
#   --dry-run         Show what would be applied without executing
#   --no-validate     Skip schema contract validation after migration
#   --verbose         Print applied migration details
#   --help            Show this help text
#
# Environment:
#   AUTOPOIESIS_MIGRATION_DB      Database path (overridden by --db)
#   AUTOPOIESIS_MIGRATION_DIR     Migrations directory (overridden by --dir)
#   AUTOPOIESIS_MIGRATION_ENGINE  Database engine (overridden by --engine)

set -euo pipefail

# ── defaults ──────────────────────────────────────────────────────────────
DB_PATH=""
MIGRATION_DIR=""
ENGINE=""
DRY_RUN=0
NO_VALIDATE=0
VERBOSE=0

# ── parse args ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)          DB_PATH="$2"; shift 2 ;;
    --dir)         MIGRATION_DIR="$2"; shift 2 ;;
    --engine)      ENGINE="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --no-validate) NO_VALIDATE=1; shift ;;
    --verbose)     VERBOSE=1; shift ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *) echo "run-migrations: unknown option: $1" >&2; exit 1 ;;
  esac
done

ENGINE="${ENGINE:-${AUTOPOIESIS_MIGRATION_ENGINE:-sqlite}}"
DB_PATH="${DB_PATH:-${AUTOPOIESIS_MIGRATION_DB:-data/aos.db}}"
MIGRATION_DIR="${MIGRATION_DIR:-${AUTOPOIESIS_MIGRATION_DIR:-migrations}}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEMA_CHECK="$REPO_ROOT/scripts/aos-schema-contract-check.sh"
SQLITE_SCHEMA="$REPO_ROOT/scripts/aos-schema-sqlite-validation.sql"

# ── validate engine ───────────────────────────────────────────────────────
case "$ENGINE" in
  sqlite|postgres) ;;
  *) echo "run-migrations: unsupported engine: $ENGINE (use sqlite or postgres)" >&2; exit 1 ;;
esac

# ── preflight ─────────────────────────────────────────────────────────────
if [[ ! -d "$MIGRATION_DIR" ]]; then
  echo "run-migrations: migrations directory not found: $MIGRATION_DIR" >&2
  exit 1
fi

if [[ "$ENGINE" == "sqlite" ]]; then
  command -v sqlite3 >/dev/null 2>&1 || {
    echo "run-migrations: sqlite3 CLI required for sqlite engine" >&2
    exit 1
  }
  if [[ ! -f "$SQLITE_SCHEMA" ]]; then
    echo "run-migrations: SQLite schema not found: $SQLITE_SCHEMA" >&2
    exit 1
  fi
fi

# ── ensure database directory ─────────────────────────────────────────────
DB_DIR="$(dirname "$DB_PATH")"
if [[ "$DB_DIR" != "." && "$DB_DIR" != "" && ! -d "$DB_DIR" ]]; then
  mkdir -p "$DB_DIR"
fi

# ── SQLite helpers ────────────────────────────────────────────────────────
run_sqlite() {
  sqlite3 "$DB_PATH" "$@"
}

ensure_tracking_table_sqlite() {
  run_sqlite <<'SQL'
CREATE TABLE IF NOT EXISTS aos_schema_migrations (
  id         TEXT NOT NULL PRIMARY KEY,
  applied_at TEXT NOT NULL DEFAULT (datetime('now'))
);
SQL
}

applied_ids_sqlite() {
  run_sqlite "SELECT id FROM aos_schema_migrations ORDER BY id;"
}

record_migration_sqlite() {
  local mid="$1"
  run_sqlite "INSERT OR IGNORE INTO aos_schema_migrations (id) VALUES ('$mid');"
}

# ── PostgreSQL helpers (stub for future implementation) ───────────────────
run_postgres() {
  echo "run-migrations: postgres engine not yet implemented" >&2
  exit 1
}

ensure_tracking_table_postgres() {
  run_postgres <<'SQL'
CREATE TABLE IF NOT EXISTS aos_schema_migrations (
  id         TEXT NOT NULL PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SQL
}

# ── derive migration id from filename ─────────────────────────────────────
migration_id_from_file() {
  basename "$1" .sql
}

# ── discover migration files ──────────────────────────────────────────────
discover_files() {
  find "$MIGRATION_DIR" -maxdepth 1 -name '*.sql' -type f | sort
}

# ── apply SQLite schema ──────────────────────────────────────────────────
apply_sqlite_schema() {
  local schema_id="sqlite-validation-schema"

  local applied_set
  applied_set="$(applied_ids_sqlite)"

  if echo "$applied_set" | grep -qxF "$schema_id" 2>/dev/null; then
    if [[ "$VERBOSE" -eq 1 ]]; then
      echo "already applied: $schema_id"
    fi
    return 1  # signals "already applied, nothing new"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would apply: $schema_id ($SQLITE_SCHEMA)"
    return 0
  fi

  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "applying: $schema_id"
  fi

  # The SQLite validation schema already contains BEGIN TRANSACTION / COMMIT.
  run_sqlite < "$SQLITE_SCHEMA"

  record_migration_sqlite "$schema_id"

  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "  applied: $schema_id"
  fi

  return 0  # signals "new migration applied"
}

# ── apply one PostgreSQL migration ────────────────────────────────────────
apply_postgres_migration() {
  local file="$1"
  local mid
  mid="$(migration_id_from_file "$file")"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would apply: $mid ($file)"
    return 0
  fi

  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "applying: $mid"
  fi

  local sql
  sql="$(cat "$file")"

  # Check if the migration already contains transaction boundaries.
  if echo "$sql" | grep -qiE '^\s*BEGIN\b'; then
    echo "$sql" | run_postgres
  else
    run_postgres <<WRAPPER
BEGIN;
$sql
COMMIT;
WRAPPER
  fi

  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "  applied: $mid"
  fi
}

# ── main ──────────────────────────────────────────────────────────────────
main() {
  local applied_count=0

  if [[ "$DRY_RUN" -eq 1 ]]; then
    # Dry-run: report what would be applied without touching the database.
    if [[ ! -f "$DB_PATH" ]]; then
      echo "[dry-run] would create fresh database: $DB_PATH"
      echo "[dry-run] would create tracking table: aos_schema_migrations"
    else
      echo "[dry-run] existing database: $DB_PATH"
    fi
    echo "[dry-run] would apply: sqlite-validation-schema ($SQLITE_SCHEMA)"
    while IFS= read -r file; do
      [[ -z "$file" ]] && continue
      local mid
      mid="$(migration_id_from_file "$file")"
      echo "[dry-run] would record migration id: $mid"
    done < <(discover_files)
    applied_count=1  # report one would-be-applied

  elif [[ "$ENGINE" == "sqlite" ]]; then
    # Ensure tracking table exists.
    if [[ ! -f "$DB_PATH" ]]; then
      # Fresh database.
      ensure_tracking_table_sqlite
    else
      ensure_tracking_table_sqlite
    fi

    # Apply SQLite-compatible schema.
    if apply_sqlite_schema; then
      applied_count=$((applied_count + 1))
    fi

    # Also discover and record any .sql migration files as tracked
    # (for audit/completeness — the SQLite schema is the flattened equivalent).
    while IFS= read -r file; do
      [[ -z "$file" ]] && continue
      local mid
      mid="$(migration_id_from_file "$file")"
      # Record but don't re-execute PostgreSQL migrations against SQLite.
      record_migration_sqlite "$mid"
    done < <(discover_files)

  elif [[ "$ENGINE" == "postgres" ]]; then
    ensure_tracking_table_postgres

    local applied_set
    applied_set=""  # TODO: query from postgres

    while IFS= read -r file; do
      [[ -z "$file" ]] && continue
      local mid
      mid="$(migration_id_from_file "$file")"

      if echo "$applied_set" | grep -qxF "$mid" 2>/dev/null; then
        if [[ "$VERBOSE" -eq 1 ]]; then
          echo "already applied: $mid"
        fi
        continue
      fi

      apply_postgres_migration "$file"
      applied_count=$((applied_count + 1))
    done < <(discover_files)
  fi

  # Summary.
  local total_migrations=0
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    total_migrations=$((total_migrations + 1))
  done < <(discover_files)

  echo "migrations: engine=$ENGINE db=$DB_PATH applied=$applied_count migration_files=$total_migrations"

  # Schema contract validation (SQLite only for now).
  if [[ "$ENGINE" == "sqlite" && "$applied_count" -gt 0 && "$NO_VALIDATE" -eq 0 && -x "$SCHEMA_CHECK" ]]; then
    if [[ "$VERBOSE" -eq 1 ]]; then
      echo "running schema contract validation..."
    fi
    if "$SCHEMA_CHECK" "$DB_PATH"; then
      echo "schema contract: passed"
    else
      echo "schema contract: FAILED (database was migrated but schema validation failed)" >&2
      exit 1
    fi
  fi
}

main
