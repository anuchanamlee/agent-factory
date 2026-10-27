#!/usr/bin/env bash
# Gate: every task is ticked, and the project still builds.
set -euo pipefail
PROJ="$1"
cd "$PROJ"

echo "== gate:features in $PROJ =="

[ -f TASKS.md ] || { echo "FAIL: TASKS.md is missing — phase 00 output was lost"; exit 1; }

open_tasks="$(grep -cE '^[[:space:]]*-[[:space:]]*\[[[:space:]]\]' TASKS.md || true)"
done_tasks="$(grep -cE '^[[:space:]]*-[[:space:]]*\[[xX]\]' TASKS.md || true)"
echo "tasks: $done_tasks done, $open_tasks open"

if [ "$open_tasks" -ne 0 ]; then
  echo "FAIL: $open_tasks task(s) still unticked:"
  grep -nE '^[[:space:]]*-[[:space:]]*\[[[:space:]]\]' TASKS.md | head -20
  exit 1
fi
[ "$done_tasks" -gt 0 ] || { echo "FAIL: TASKS.md has no tasks at all"; exit 1; }

echo "-- build must pass with the features in"
bash "$(dirname "${BASH_SOURCE[0]}")/build.sh" "$PROJ"

echo "OK: features gate passed"
