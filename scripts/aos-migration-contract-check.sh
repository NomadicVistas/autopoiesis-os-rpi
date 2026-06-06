#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:-${AUTOPOIESIS_AOS_MIGRATION_CONTRACT_SOURCE:-}}"

fail() {
  echo "aos migration contract check failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/aos-migration-contract-check.sh <migrations-directory>
  scripts/aos-migration-contract-check.sh <migration-manifest.json>

Environment:
  AUTOPOIESIS_AOS_MIGRATION_CONTRACT_SOURCE  default source when no argument is passed
  AUTOPOIESIS_ALLOW_DESTRUCTIVE_MIGRATIONS   allow DROP/TRUNCATE/destructive UPDATE/DELETE when set to 1

Migration manifest JSON shape:
  {
    "migrations": [
      { "id": "202606061845_create_aos_frames", "sql": "CREATE TABLE aos_frame_devices (...);" }
    ],
    "finalSchema": { "tables": ["aos_frame_devices", "..."] }
  }

Directory mode scans .sql files recursively, sorted by relative path.
EOF
}

if [[ -z "$SOURCE" ]]; then
  usage
  exit 2
fi

[[ -e "$SOURCE" ]] || fail "migration source not found: $SOURCE"

node - "$SOURCE" "${AUTOPOIESIS_ALLOW_DESTRUCTIVE_MIGRATIONS:-0}" <<'NODE'
const fs = require("fs");
const path = require("path");

const source = process.argv[2];
const allowDestructive = process.argv[3] === "1";

const requiredTables = [
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

function fail(message) {
  console.error(message);
  process.exit(1);
}

function asArray(value) {
  if (Array.isArray(value)) return value;
  if (value === undefined || value === null) return [];
  return [value];
}

function normalizeText(value) {
  return String(value || "");
}

function stripSqlComments(sql) {
  return sql
    .replace(/\/\*[\s\S]*?\*\//g, " ")
    .replace(/--[^\n\r]*/g, " ");
}

function normalizeIdentifier(value) {
  return String(value || "")
    .trim()
    .replace(/^["'\`\[]+|["'\`\]]+$/g, "")
    .replace(/;$/, "");
}

function readDirectory(dir) {
  const files = [];
  function walk(current) {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) {
        if (entry.name === "node_modules" || entry.name === ".git") continue;
        walk(full);
        continue;
      }
      if (entry.isFile() && entry.name.toLowerCase().endsWith(".sql")) {
        files.push(full);
      }
    }
  }
  walk(dir);
  files.sort((a, b) => path.relative(dir, a).localeCompare(path.relative(dir, b)));
  return files.map(file => ({
    id: path.relative(dir, file).replace(/\\/g, "/"),
    filename: path.relative(dir, file).replace(/\\/g, "/"),
    sql: fs.readFileSync(file, "utf8")
  }));
}

function normalizeTables(value) {
  if (!value) return [];
  if (Array.isArray(value)) {
    return value.map(entry => typeof entry === "string" ? entry : entry && (entry.name || entry.tableName || entry.table_name)).filter(Boolean);
  }
  if (typeof value === "object") {
    if (Array.isArray(value.tables)) return normalizeTables(value.tables);
    return Object.keys(value);
  }
  return [];
}

function readManifest(file) {
  let payload;
  try {
    payload = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    fail("invalid migration manifest JSON: " + error.message);
  }
  const migrations = asArray(payload.migrations || payload.files || payload.steps).map((migration, index) => {
    if (typeof migration === "string") {
      return { id: migration, filename: migration, sql: "" };
    }
    if (!migration || typeof migration !== "object") return null;
    return {
      id: normalizeText(migration.id || migration.name || migration.filename || migration.file || ("migration_" + index)),
      filename: normalizeText(migration.filename || migration.file || migration.path || migration.id || migration.name || ("migration_" + index)),
      sql: normalizeText(migration.sql || migration.statement || migration.statements || migration.body || ""),
      nonTransactional: Boolean(migration.nonTransactional || migration.non_transactional),
      tables: normalizeTables(migration.tables || migration.tableNames || migration.table_names || migration.creates || migration.alters)
    };
  }).filter(Boolean);
  return {
    migrations,
    finalTables: normalizeTables(payload.finalSchema || payload.final_schema || payload.schema || payload.tables)
  };
}

function readSource(sourcePath) {
  const stat = fs.statSync(sourcePath);
  if (stat.isDirectory()) return { migrations: readDirectory(sourcePath), finalTables: [] };
  return readManifest(sourcePath);
}

function validateMigrationId(migration) {
  const id = migration.id || migration.filename;
  if (!id) fail("migration missing id or filename");
  const base = path.basename(id);
  if (!/^(?:v?\d{3,}|20\d{6,}(?:\d{4,6})?)[._-][a-z0-9][a-z0-9._-]*$/i.test(base.replace(/\.sql$/i, ""))) {
    fail("migration id should start with a sortable version/timestamp prefix: " + id);
  }
}

function extractTablesFromSql(sql) {
  const clean = stripSqlComments(sql);
  const tables = new Set();
  const tablePatterns = [
    /\bcreate\s+table\s+(?:if\s+not\s+exists\s+)?([A-Za-z_][\w."]*)/gi,
    /\balter\s+table\s+(?:if\s+exists\s+)?([A-Za-z_][\w."]*)/gi,
    /\bdrop\s+table\s+(?:if\s+exists\s+)?([A-Za-z_][\w."]*)/gi,
    /\bdelete\s+from\s+([A-Za-z_][\w."]*)/gi,
    /\bupdate\s+([A-Za-z_][\w."]*)\s+set\b/gi,
    /\binsert\s+into\s+([A-Za-z_][\w."]*)/gi
  ];
  for (const pattern of tablePatterns) {
    let match;
    while ((match = pattern.exec(clean))) {
      tables.add(normalizeIdentifier(match[1]).split(".").pop());
    }
  }
  return Array.from(tables);
}

function validateNamespace(migration, tables) {
  const offenders = tables.filter(table => !table.startsWith("aos_"));
  if (offenders.length) {
    fail(migration.id + " touches non-aos table(s): " + offenders.join(", "));
  }
}

function validateIndexes(migration, sql) {
  const clean = stripSqlComments(sql);
  const pattern = /\bcreate\s+(?:unique\s+)?index\s+(?:if\s+not\s+exists\s+)?([A-Za-z_][\w."]*)\s+on\s+([A-Za-z_][\w."]*)/gi;
  let match;
  while ((match = pattern.exec(clean))) {
    const indexName = normalizeIdentifier(match[1]).split(".").pop();
    const tableName = normalizeIdentifier(match[2]).split(".").pop();
    if (!tableName.startsWith("aos_")) fail(migration.id + " creates index on non-aos table: " + tableName);
    if (!indexName.startsWith("aos_") && !indexName.startsWith("idx_aos_") && !indexName.startsWith("uniq_aos_")) {
      fail(migration.id + " creates non-namespaced index: " + indexName);
    }
  }
}

function validateTransaction(migration, sql) {
  if (migration.nonTransactional) return;
  const clean = stripSqlComments(sql).toLowerCase();
  if (!clean.trim()) return;
  const hasBegin = /\bbegin(?:\s+transaction)?\b/.test(clean);
  const hasCommit = /\bcommit\b/.test(clean);
  if (!hasBegin || !hasCommit) {
    fail(migration.id + " should wrap SQL in BEGIN/COMMIT or set nonTransactional in a manifest");
  }
}

function validateDestructive(migration, sql) {
  const clean = stripSqlComments(sql);
  const destructive = [
    /\bdrop\s+table\b/i,
    /\bdrop\s+column\b/i,
    /\btruncate\s+table\b/i,
    /\bdelete\s+from\s+aos_[A-Za-z0-9_]+\s*(?:;|$)/i,
    /\bupdate\s+aos_[A-Za-z0-9_]+\s+set\b(?![\s\S]*?\bwhere\b)/i
  ].some(pattern => pattern.test(clean));
  if (destructive && !allowDestructive) {
    fail(migration.id + " contains destructive SQL; set AUTOPOIESIS_ALLOW_DESTRUCTIVE_MIGRATIONS=1 only for reviewed rollback/data-repair migrations");
  }
}

function validatePairingHash(migration, sql) {
  const clean = stripSqlComments(sql);
  if (/\bpairing_code\b/i.test(clean) && !/\bpairing_code_hash\b/i.test(clean)) {
    fail(migration.id + " references persistent plaintext pairing_code without pairing_code_hash");
  }
}

function validateSecretLiterals(migration, sql) {
  const clean = stripSqlComments(sql);
  const secretPatterns = [
    /-----BEGIN\s+(?:RSA\s+|EC\s+|OPENSSH\s+)?PRIVATE\s+KEY-----/i,
    /\bsk-[A-Za-z0-9_-]{20,}\b/,
    /\b[A-Za-z0-9_-]{24,}\.[A-Za-z0-9_-]{24,}\.[A-Za-z0-9_-]{24,}\b/
  ];
  if (secretPatterns.some(pattern => pattern.test(clean))) {
    fail(migration.id + " appears to contain a secret literal");
  }
}

const { migrations, finalTables } = readSource(source);
if (!migrations.length) fail("no migrations found");

const ids = new Set();
const touchedTables = new Set(finalTables.map(normalizeIdentifier).filter(Boolean));
let sqlFiles = 0;

for (const migration of migrations) {
  validateMigrationId(migration);
  if (ids.has(migration.id)) fail("duplicate migration id: " + migration.id);
  ids.add(migration.id);

  const sql = normalizeText(migration.sql);
  const sqlTables = extractTablesFromSql(sql);
  const manifestTables = asArray(migration.tables).map(normalizeIdentifier).filter(Boolean);
  const tables = Array.from(new Set([...sqlTables, ...manifestTables]));
  tables.forEach(table => touchedTables.add(table));

  if (sql.trim()) {
    sqlFiles += 1;
    validateNamespace(migration, tables);
    validateIndexes(migration, sql);
    validateTransaction(migration, sql);
    validateDestructive(migration, sql);
    validatePairingHash(migration, sql);
    validateSecretLiterals(migration, sql);
  } else if (!tables.length) {
    fail(migration.id + " has no SQL and no table metadata");
  }
}

const missing = requiredTables.filter(table => !touchedTables.has(table));
if (missing.length) {
  fail("migration plan does not cover required table(s): " + missing.join(", "));
}

console.log(
  "aos migration contract ok: migrations=" + migrations.length +
    " sql=" + sqlFiles +
    " tables=" + touchedTables.size +
    " destructiveAllowed=" + (allowDestructive ? "yes" : "no")
);
NODE
