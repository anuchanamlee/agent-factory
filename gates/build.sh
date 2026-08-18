#!/usr/bin/env bash
# Gate: the project installs, typechecks, lints and production-builds.
set -euo pipefail
PROJ="$1"
cd "$PROJ"

echo "== gate:build in $PROJ =="

[ -f package.json ] || { echo "FAIL: no package.json — scaffold did not happen"; exit 1; }

if [ ! -d node_modules ]; then
  echo "-- installing deps"
  npm install --no-audit --no-fund
fi

if [ -f tsconfig.json ]; then
  echo "-- typecheck"
  npx --yes tsc --noEmit
fi

echo "-- next build"
npm run build

echo "OK: build gate passed"
