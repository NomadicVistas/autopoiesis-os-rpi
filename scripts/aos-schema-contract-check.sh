#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:-${AUTOPOIESIS_AOS_SCHEMA_CONTRACT_SOURCE:-}}"
TMP_FILE=""

cleanup() {
  if [[ -n "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
  fi
}
trap cleanup EXIT

fail() {
  echo "aos schema contract check failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/aos-schema-contract-check.sh <schema-introspection.json>
  scripts/aos-schema-contract-check.sh <sqlite-database-file>

Environment:
  AUTOPOIESIS_AOS_SCHEMA_CONTRACT_SOURCE  default file when no argument is passed

Schema JSON may be either:
  - an array of sqlite-style rows with rowType/row_type = "column" or "index"
  - an object with tables: [{ name, columns, primaryKey, unique }]
EOF
}

if [[ -z "$SOURCE" ]]; then
  usage
  exit 2
fi

[[ -f "$SOURCE" ]] || fail "schema source not found: $SOURCE"

if LC_ALL=C grep -qa '^SQLite format 3' "$SOURCE"; then
  TMP_FILE="$(mktemp)"
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 -readonly "$SOURCE" <<'SQL' >"$TMP_FILE"
.mode json
SELECT
  'column' AS row_type,
  m.name AS table_name,
  p.name AS column_name,
  p.type AS column_type,
  p."notnull" AS not_null,
  p.pk AS pk_ordinal,
  NULL AS index_name,
  NULL AS index_unique,
  NULL AS index_seq
FROM sqlite_schema AS m, pragma_table_info(m.name) AS p
WHERE m.type = 'table' AND m.name LIKE 'aos_%'
UNION ALL
SELECT
  'index' AS row_type,
  m.name AS table_name,
  ii.name AS column_name,
  NULL AS column_type,
  NULL AS not_null,
  NULL AS pk_ordinal,
  il.name AS index_name,
  il."unique" AS index_unique,
  ii.seqno AS index_seq
FROM sqlite_schema AS m, pragma_index_list(m.name) AS il, pragma_index_info(il.name) AS ii
WHERE m.type = 'table' AND m.name LIKE 'aos_%';
SQL
  else
    node - "$PWD" "$SOURCE" <<'NODE' >"$TMP_FILE"
const repoRoot = process.argv[2];
const dbPath = process.argv[3];
const Database = require(require.resolve("better-sqlite3", { paths: [repoRoot] }));
const db = new Database(dbPath, { readonly: true });
const sql = `
SELECT
  'column' AS row_type,
  m.name AS table_name,
  p.name AS column_name,
  p.type AS column_type,
  p."notnull" AS not_null,
  p.pk AS pk_ordinal,
  NULL AS index_name,
  NULL AS index_unique,
  NULL AS index_seq
FROM sqlite_schema AS m, pragma_table_info(m.name) AS p
WHERE m.type = 'table' AND m.name LIKE 'aos_%'
UNION ALL
SELECT
  'index' AS row_type,
  m.name AS table_name,
  ii.name AS column_name,
  NULL AS column_type,
  NULL AS not_null,
  NULL AS pk_ordinal,
  il.name AS index_name,
  il."unique" AS index_unique,
  ii.seqno AS index_seq
FROM sqlite_schema AS m, pragma_index_list(m.name) AS il, pragma_index_info(il.name) AS ii
WHERE m.type = 'table' AND m.name LIKE 'aos_%';
`;
process.stdout.write(JSON.stringify(db.prepare(sql).all(), null, 2));
db.close();
NODE
  fi
  SOURCE="$TMP_FILE"
fi

node - "$SOURCE" <<'NODE'
const fs = require("fs");

const file = process.argv[2];

function fail(message) {
  console.error(message);
  process.exit(1);
}

function asArray(value) {
  if (Array.isArray(value)) return value;
  if (value === undefined || value === null) return [];
  return [value];
}

function normalizeName(value) {
  return String(value || "").trim();
}

function normalizeColumnList(value) {
  if (!value) return [];
  if (Array.isArray(value)) {
    return value.map(entry => typeof entry === "string" ? entry : normalizeName(entry.name || entry.columnName || entry.column_name)).filter(Boolean);
  }
  if (typeof value === "object") return Object.keys(value);
  return [];
}

function addTable(tables, name) {
  const tableName = normalizeName(name);
  if (!tableName) return null;
  if (!tables.has(tableName)) {
    tables.set(tableName, {
      name: tableName,
      columns: new Map(),
      primaryKey: [],
      unique: []
    });
  }
  return tables.get(tableName);
}

function normalizeTables(payload) {
  const tables = new Map();

  if (Array.isArray(payload)) {
    const rows = payload;
    for (const row of rows) {
      if (!row || typeof row !== "object") continue;
      const rowType = normalizeName(row.rowType || row.row_type || row.kind || row.type).toLowerCase();
      const table = addTable(tables, row.tableName || row.table_name || row.table || row.tbl_name);
      if (!table) continue;

      if (rowType === "column") {
        const columnName = normalizeName(row.columnName || row.column_name || row.name);
        if (!columnName) continue;
        table.columns.set(columnName, {
          name: columnName,
          type: normalizeName(row.columnType || row.column_type || row.dataType || row.data_type),
          notNull: Boolean(Number(row.notNull ?? row.not_null ?? row.notnull ?? 0)),
          pkOrdinal: Number(row.pkOrdinal ?? row.pk_ordinal ?? row.pk ?? 0) || 0
        });
        continue;
      }

      if (rowType === "index" || row.indexName || row.index_name) {
        if (!Boolean(Number(row.indexUnique ?? row.index_unique ?? row.unique ?? 0))) continue;
        const indexName = normalizeName(row.indexName || row.index_name || "unique");
        const columnName = normalizeName(row.columnName || row.column_name || row.name);
        if (!columnName) continue;
        let unique = table.unique.find(entry => entry.name === indexName);
        if (!unique) {
          unique = { name: indexName, columns: [] };
          table.unique.push(unique);
        }
        unique.columns.push({
          name: columnName,
          seq: Number(row.indexSeq ?? row.index_seq ?? row.seq ?? 0) || 0
        });
      }
    }
  } else if (payload && typeof payload === "object") {
    const tableInput = Array.isArray(payload.tables)
      ? payload.tables
      : Object.entries(payload.tables || payload).map(([name, table]) => ({ name, ...(table && typeof table === "object" ? table : {}) }));

    for (const tableDef of tableInput) {
      if (!tableDef || typeof tableDef !== "object") continue;
      const table = addTable(tables, tableDef.name || tableDef.tableName || tableDef.table_name);
      if (!table) continue;

      const columns = tableDef.columns || {};
      if (Array.isArray(columns)) {
        for (const column of columns) {
          const columnName = normalizeName(typeof column === "string" ? column : column.name || column.columnName || column.column_name);
          if (!columnName) continue;
          table.columns.set(columnName, {
            name: columnName,
            type: typeof column === "string" ? "" : normalizeName(column.type || column.columnType || column.column_type),
            notNull: typeof column === "string" ? false : Boolean(column.notNull || column.not_null || column.required),
            pkOrdinal: typeof column === "string" ? 0 : Number(column.pkOrdinal || column.pk_ordinal || column.pk || 0) || 0
          });
        }
      } else if (columns && typeof columns === "object") {
        for (const [columnName, column] of Object.entries(columns)) {
          table.columns.set(columnName, {
            name: columnName,
            type: column && typeof column === "object" ? normalizeName(column.type || column.columnType || column.column_type) : "",
            notNull: column && typeof column === "object" ? Boolean(column.notNull || column.not_null || column.required) : false,
            pkOrdinal: column && typeof column === "object" ? Number(column.pkOrdinal || column.pk_ordinal || column.pk || 0) || 0 : 0
          });
        }
      }

      table.primaryKey = normalizeColumnList(tableDef.primaryKey || tableDef.primary_key || tableDef.pk);
      table.unique = asArray(tableDef.unique || tableDef.uniqueKeys || tableDef.unique_keys || tableDef.indexes)
        .map((entry, index) => {
          if (Array.isArray(entry)) return { name: "unique_" + index, columns: entry };
          if (typeof entry === "string") return { name: entry, columns: [entry] };
          return {
            name: normalizeName(entry.name || entry.indexName || entry.index_name || "unique_" + index),
            columns: normalizeColumnList(entry.columns || entry.columnNames || entry.column_names)
          };
        })
        .filter(entry => entry.columns.length);
    }
  }

  for (const table of tables.values()) {
    if (!table.primaryKey.length) {
      table.primaryKey = Array.from(table.columns.values())
        .filter(column => column.pkOrdinal > 0)
        .sort((a, b) => a.pkOrdinal - b.pkOrdinal)
        .map(column => column.name);
    }
    table.unique = table.unique.map(entry => ({
      name: entry.name,
      columns: entry.columns
        .map(column => typeof column === "string" ? { name: column, seq: 0 } : column)
        .sort((a, b) => (a.seq || 0) - (b.seq || 0))
        .map(column => column.name)
        .filter(Boolean)
    })).filter(entry => entry.columns.length);
  }

  return tables;
}

function hasColumns(table, columns) {
  return columns.every(column => table.columns.has(column));
}

function hasKeySet(table, columns) {
  if (columns.length === table.primaryKey.length && columns.every((column, index) => table.primaryKey[index] === column)) return true;
  return table.unique.some(entry => columns.length === entry.columns.length && columns.every((column, index) => entry.columns[index] === column));
}

function requireTable(tables, name, columns, keySets = []) {
  const table = tables.get(name);
  if (!table) fail("missing required table: " + name);
  const missing = columns.filter(column => !table.columns.has(column));
  if (missing.length) fail(name + " missing required columns: " + missing.join(", "));
  for (const keySet of keySets) {
    if (!hasKeySet(table, keySet)) fail(name + " missing primary/unique key on: " + keySet.join(", "));
  }
  return table;
}

let payload;
try {
  payload = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (error) {
  fail("invalid schema JSON: " + error.message);
}

const tables = normalizeTables(payload);
const aosTables = new Map(Array.from(tables.entries()).filter(([name]) => name.startsWith("aos_")));
if (!aosTables.size) fail("no aos_ tables found in schema source");

requireTable(aosTables, "aos_frame_devices", [
  "device_id",
  "device_api_key",
  "owner_user_id",
  "device_name",
  "device_type",
  "software_version",
  "update_channel",
  "paired",
  "remote_enabled",
  "subscription_status",
  "last_heartbeat_at",
  "current_mode",
  "current_artwork_id",
  "network_online",
  "network_type",
  "storage_status_json",
  "metadata_json",
  "created_at",
  "updated_at"
], [["device_id"]]);

const pairing = requireTable(aosTables, "aos_frame_pairing_codes", [
  "device_id",
  "expires_at",
  "claimed_by_user_id",
  "claimed_at",
  "status",
  "created_at"
]);
if (!hasColumns(pairing, ["pairing_code_hash"]) && !hasColumns(pairing, ["pairing_code"])) {
  fail("aos_frame_pairing_codes must include pairing_code_hash or pairing_code");
}

requireTable(aosTables, "aos_frame_device_settings", ["device_id", "settings_json", "updated_at"], [["device_id"]]);
requireTable(aosTables, "aos_frame_user_preferences", ["user_id", "preferences_json", "updated_at"], [["user_id"]]);
requireTable(aosTables, "aos_heartbeats", ["device_id", "payload_json", "created_at"]);
requireTable(aosTables, "aos_device_commands", [
  "id",
  "device_id",
  "command_type",
  "payload_json",
  "status",
  "created_at",
  "acknowledged_at",
  "completed_at",
  "error"
], [["id"]]);
requireTable(aosTables, "aos_admin_command_audits", [
  "id",
  "command_id",
  "device_id",
  "command_type",
  "risk",
  "actor_id",
  "actor_role",
  "reason",
  "payload_summary_json",
  "status",
  "error",
  "created_at",
  "updated_at"
], [["id"]]);
requireTable(aosTables, "aos_device_events", [
  "device_id",
  "event_key",
  "source",
  "event_type",
  "status",
  "observed_at",
  "event_json",
  "ingested_at",
  "updated_at"
], [["device_id", "event_key"]]);
requireTable(aosTables, "aos_artwork_likes", ["user_id", "artwork_id", "created_at"], [["user_id", "artwork_id"]]);
requireTable(aosTables, "aos_broadcasts", [
  "id",
  "title",
  "body",
  "type",
  "media_url",
  "target_type",
  "target_value",
  "priority",
  "duration",
  "starts_at",
  "expires_at",
  "created_by",
  "created_at"
], [["id"]]);
requireTable(aosTables, "aos_releases", [
  "id",
  "version",
  "channel",
  "status",
  "artifact_url",
  "checksum",
  "notes",
  "rollout_percent",
  "created_by",
  "created_at",
  "published_at"
], [["id"]]);
requireTable(aosTables, "aos_subscriptions", [
  "user_id",
  "plan",
  "status",
  "provider",
  "external_subscription_id",
  "current_period_end",
  "created_at",
  "updated_at"
], [["user_id"]]);
requireTable(aosTables, "aos_broadcast_deliveries", [
  "broadcast_id",
  "device_id",
  "command_id",
  "status",
  "queued_at",
  "acknowledged_at",
  "completed_at",
  "error",
  "updated_at"
], [["broadcast_id", "device_id"]]);
requireTable(aosTables, "aos_release_rollouts", [
  "release_id",
  "device_id",
  "command_id",
  "status",
  "target_version",
  "current_version",
  "queued_at",
  "acknowledged_at",
  "completed_at",
  "error",
  "updated_at"
], [["release_id", "device_id"]]);

const warnings = [];
if (pairing.columns.has("pairing_code") && !pairing.columns.has("pairing_code_hash")) {
  warnings.push("aos_frame_pairing_codes stores pairing_code; migrate to pairing_code_hash before production hardening");
}

const expected = [
  "aos_frame_devices",
  "aos_frame_pairing_codes",
  "aos_frame_device_settings",
  "aos_frame_user_preferences",
  "aos_heartbeats",
  "aos_device_commands",
  "aos_admin_command_audits",
  "aos_device_events",
  "aos_artwork_likes",
  "aos_broadcasts",
  "aos_releases",
  "aos_subscriptions",
  "aos_broadcast_deliveries",
  "aos_release_rollouts"
];
const extra = Array.from(aosTables.keys()).filter(name => !expected.includes(name)).sort();

console.log(
  "aos schema contract ok: tables=" + aosTables.size +
    " required=" + expected.length +
    " extra=" + extra.length
);
for (const warning of warnings) console.log("warning: " + warning);
if (extra.length) console.log("extra aos_ tables: " + extra.join(", "));
NODE
