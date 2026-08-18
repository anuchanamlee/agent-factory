#!/usr/bin/env bash
# Gate: the built app actually serves every route it claims to, against a real
# migrated + seeded database. This is the only gate that runs the app.
set -euo pipefail
PROJ="$1"
cd "$PROJ"

echo "== gate:smoke in $PROJ =="

fail() { echo "FAIL: $*"; exit 1; }

ROUTES=".factory/ROUTES.txt"
[ -f "$ROUTES" ] || fail "$ROUTES is missing — phase 00 was supposed to write it"

# ---------------------------------------------------------------- 1. routes on
# disk must all be declared. The agent does not get to under-report its own
# surface: pages are discovered from the filesystem and checked against the list.
echo "-- cross-checking pages on disk against $ROUTES"
APP_DIR="app"
[ -d "$APP_DIR" ] || [ ! -d "src/app" ] || APP_DIR="src/app"
[ -d "$APP_DIR" ] || fail "no app/ directory — nothing to serve"

declared() { grep -vE '^[[:space:]]*(#|$)' "$ROUTES" | awk '{print $1}'; }

missing=0
while IFS= read -r page; do
  route="${page#"$APP_DIR"}"          # /products/[id]/page.tsx
  route="${route%/page.*}"            # /products/[id]
  route="$(printf '%s' "$route" | sed -E 's#/\([^)]*\)##g')"   # drop (route groups)
  [ -n "$route" ] || route="/"

  if printf '%s' "$route" | grep -q '\['; then
    # dynamic: [id] matches any single non-slash segment
    pattern="^$(printf '%s' "$route" | sed -E 's#\[\[?\.\.\.[^]]*\]\]?#.+#g; s#\[[^]]*\]#[^/]+#g')\$"
    if ! declared | grep -qE "$pattern"; then
      echo "  page $page (route $route) has no matching line in $ROUTES"
      missing=$((missing + 1))
    fi
  else
    if ! declared | grep -qxF "$route"; then
      echo "  page $page (route $route) is not listed in $ROUTES"
      missing=$((missing + 1))
    fi
  fi
done < <(find "$APP_DIR" -type f \( -name 'page.tsx' -o -name 'page.ts' -o -name 'page.jsx' -o -name 'page.js' \) | sort)

[ "$missing" -eq 0 ] || fail "$missing page(s) on disk are not declared in $ROUTES"

# ---------------------------------------------------------------- 2. fresh data
TMP="$PROJ/.factory-tmp-smoke"
rm -rf "$TMP"; mkdir -p "$TMP"
export DATA_DIR="$TMP"
export DATABASE_PATH="$TMP/app.db"
export NODE_ENV=production

echo "-- migrate"
npm run migrate
if grep -q '"seed"' package.json; then
  echo "-- seed"
  npm run seed
else
  echo "   (no seed script — routes needing rows will have to cope)"
fi

# ---------------------------------------------------------------- 3. build+serve
echo "-- build"
npm run build

PORT="${FACTORY_SMOKE_PORT:-3987}"
LOG="$TMP/server.log"
SERVER_PID=""

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "$SERVER_PID" ] && wait "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "-- starting server on :$PORT"
PORT="$PORT" npm start > "$LOG" 2>&1 &
SERVER_PID=$!

ready=0
for _ in $(seq 1 60); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "--- server log ---"; cat "$LOG"
    fail "server exited before it accepted a connection"
  fi
  if curl -sS -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/" 2>/dev/null; then ready=1; break; fi
  sleep 1
done
[ "$ready" -eq 1 ] || { echo "--- server log ---"; cat "$LOG"; fail "server never answered on :$PORT within 60s"; }

# ---------------------------------------------------------------- 4. every route
echo "-- requesting routes"
bad=0
while read -r path want _rest; do
  case "$path" in ''|'#'*) continue ;; esac
  got="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
         "http://127.0.0.1:$PORT$path" || echo 000)"
  if [ "$got" = "$want" ]; then
    printf '   %-32s %s\n' "$path" "$got"
  else
    printf '   %-32s %s  (expected %s)\n' "$path" "$got" "$want"
    bad=$((bad + 1))
  fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$ROUTES")

# ---------------------------------------------------------------- 5. clean log
echo "-- server log"
if grep -nE '(^|[[:space:]])(⨯|Error:|TypeError:|ReferenceError:|unhandledRejection|UnhandledPromiseRejection)' "$LOG"; then
  echo "FAIL: the server logged errors while handling those requests (above)"
  bad=$((bad + 1))
else
  echo "   clean"
fi

[ "$bad" -eq 0 ] || fail "$bad problem(s) — see above"

echo "OK: smoke gate passed"
