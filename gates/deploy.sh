#!/usr/bin/env bash
# Gate: the docker stack builds, comes up, and serves through Caddy.
#
# Deploying to a real host is deliberately NOT automatic. target=vps requires
# FACTORY_CONFIRM_PROD=yes, set by a human, on purpose.
set -euo pipefail
PROJ="$1"
cd "$PROJ"

TARGET="${FACTORY_DEPLOY_TARGET:-local}"
echo "== gate:deploy in $PROJ (target: $TARGET) =="

fail() { echo "FAIL: $*"; exit 1; }

for f in Dockerfile docker-compose.yml .env.example DEPLOY.md; do
  [ -f "$f" ] || fail "$f is missing"
done
[ -f Caddyfile ] || [ -f docker/Caddyfile ] || fail "no Caddyfile"

echo "-- compose config is valid"
docker compose config >/dev/null || fail "docker compose config rejected the file"

if [ "$TARGET" = "vps" ]; then
  [ -n "${FACTORY_VPS:-}" ] || fail "FACTORY_DEPLOY_TARGET=vps but FACTORY_VPS (user@host) is unset"
  if [ "${FACTORY_CONFIRM_PROD:-}" != "yes" ]; then
    cat <<'MSG'
FAIL: refusing to deploy to a production host from inside the pipeline.

A phase that can reach production without a human in the loop is a phase that
can take production down at 3am on its own initiative. Deploying is a decision,
not a build step.

To deploy on purpose:
  FACTORY_CONFIRM_PROD=yes FACTORY_DEPLOY_TARGET=vps FACTORY_VPS=user@host \
    ./factory.sh <spec> --name <project> --only 50-deploy
MSG
    exit 1
  fi
  echo "-- FACTORY_CONFIRM_PROD=yes — proceeding against $FACTORY_VPS"
  echo "   (follow DEPLOY.md; this gate still verifies locally first)"
fi

# ---------------------------------------------------------------- local stack
[ -f .env ] || { echo "-- no .env; using .env.example for the smoke run"; cp .env.example .env; }

PORT="${FACTORY_DEPLOY_PORT:-8087}"
cleanup() {
  echo "-- tearing the stack down"
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "-- build"
docker compose build

echo "-- up"
docker compose up -d

echo "-- waiting for the app to answer through caddy on :$PORT"
ok=0
for _ in $(seq 1 90); do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$PORT/" 2>/dev/null || echo 000)"
  if [ "$code" = "200" ]; then ok=1; break; fi
  sleep 2
done

if [ "$ok" -ne 1 ]; then
  echo "--- compose ps ---";   docker compose ps || true
  echo "--- compose logs ---"; docker compose logs --tail 120 || true
  fail "the stack came up but nothing answered 200 on :$PORT within 180s"
fi

echo "-- container health"
if docker compose ps --format '{{.Name}} {{.State}} {{.Status}}' | grep -iE 'unhealthy|restarting|exited'; then
  docker compose logs --tail 60 || true
  fail "a container is unhealthy, restarting, or exited (above)"
fi
docker compose ps --format '{{.Name}} {{.State}}'

echo "OK: deploy gate passed"
