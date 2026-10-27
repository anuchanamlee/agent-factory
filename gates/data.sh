#!/usr/bin/env bash
# Gate: schema + migrations actually run and produce a usable SQLite database.
set -euo pipefail
PROJ="$1"
cd "$PROJ"

echo "== gate:data in $PROJ =="

[ -d migrations ] || { echo "FAIL: no migrations/ directory"; exit 1; }
ls migrations/*.sql >/dev/null 2>&1 || { echo "FAIL: no .sql files in migrations/"; exit 1; }

grep -q '"migrate"' package.json || { echo "FAIL: package.json has no 'migrate' script"; exit 1; }

echo "-- running migrations against a throwaway database"
rm -rf .factory-tmp-data 2>/dev/null || true
mkdir -p .factory-tmp-data
DATA_DIR="$PROJ/.factory-tmp-data" DATABASE_PATH="$PROJ/.factory-tmp-data/app.db" npm run migrate

DB="$PROJ/.factory-tmp-data/app.db"
[ -f "$DB" ] || DB="$(ls -1 "$PROJ"/.factory-tmp-data/*.db 2>/dev/null | head -1 || true)"
[ -n "$DB" ] && [ -f "$DB" ] || { echo "FAIL: migrate ran but produced no .db file in .factory-tmp-data/"; exit 1; }

echo "-- listing tables"
node -e '
const Database = require("better-sqlite3");
const db = new Database(process.argv[1], { readonly: true });
const rows = db.prepare("SELECT name FROM sqlite_master WHERE type=? ORDER BY name").all("table");
const names = rows.map(r => r.name).filter(n => !n.startsWith("sqlite_"));
console.log("tables:", names.join(", ") || "(none)");
if (names.length === 0) { console.error("FAIL: migrations created no tables"); process.exit(1); }
const v = db.pragma("user_version", { simple: true });
console.log("user_version:", v);
if (!v) { console.error("FAIL: PRAGMA user_version was never bumped by the migration runner"); process.exit(1); }
' "$DB"

rm -rf .factory-tmp-data 2>/dev/null || true

echo "-- build must still pass with the data layer wired in"
bash "$(dirname "${BASH_SOURCE[0]}")/build.sh" "$PROJ"

echo "OK: data gate passed"
