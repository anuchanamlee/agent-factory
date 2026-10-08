#!/usr/bin/env bash
# reaper-test.sh - prove that factory.sh stops the processes a phase started,
# and only those.
#
#   ./test/reaper-test.sh
#
# One phase runs with the stub model in leak-slow mode: it starts two node
# servers in the background (one with a path on its command line, one as plain
# `node leaked-server.js`) and keeps working for four seconds. One second into
# the phase, this script starts an unrelated node process from outside the
# factory - a bystander. After the phase:
#   - both leaked servers must be gone
#   - the bystander must still be running
# The old reaper killed every node.exe that appeared during a phase, so it
# killed the bystander too.
#
# Safe on a machine with other node programs running: the factory only stops
# processes inside its own job, and this script only ever stops the bystander it
# started, by its own pid. Windows only (needs powershell.exe).
set -uo pipefail

FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="$FACTORY_DIR/specs/minicat.md"
STUB_DIR="$(mktemp -d)"
NAME="reaper-test-$$"
FAILURES=0
cp "$FACTORY_DIR/test/stub-claude.sh" "$STUB_DIR/claude"
chmod +x "$STUB_DIR/claude"
printf 'setInterval(function(){}, 1e9);\n' > "$STUB_DIR/bystander.js"

pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

command -v powershell.exe >/dev/null 2>&1 || { echo "reaper-test: needs powershell.exe (Windows)"; exit 2; }

# Windows pids of node processes whose command line contains $1. Read-only.
node_pids_matching() {
  powershell.exe -NoProfile -NonInteractive -Command "
    Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" |
      Where-Object { \$_.CommandLine -like '*$1*' } |
      ForEach-Object { \$_.ProcessId }" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$'
}

alive() {
  powershell.exe -NoProfile -NonInteractive -Command \
    "if (Get-Process -Id $1 -ErrorAction SilentlyContinue) { 'yes' }" 2>/dev/null | tr -d '\r' | grep -q yes
}

cleanup() {
  # Only processes this test created: its bystander, and stub servers left behind
  # if the factory failed to stop them.
  local p
  for p in ${bystander_winpid:-} ${leftover:-}; do
    powershell.exe -NoProfile -NonInteractive -Command \
      "Stop-Process -Id $p -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1
  done
  rm -rf "${FACTORY_DIR:?}/runs/$NAME" "$STUB_DIR"
}
trap cleanup EXIT

echo
echo "a phase that leaks servers while an unrelated node process starts"
(
  cd "$FACTORY_DIR" && PATH="$STUB_DIR:$PATH" STUB_MODE=leak-slow \
    ./factory.sh "$SPEC" --name "$NAME" --only 00-plan
) > "$STUB_DIR/phase.log" 2>&1 &
phase_pid=$!

sleep 1
node "$STUB_DIR/bystander.js" >/dev/null 2>&1 &
bystander_winpid="$(cat "/proc/$!/winpid" 2>/dev/null)"
[ -n "$bystander_winpid" ] || { echo "could not start the bystander"; exit 2; }

wait "$phase_pid"
sleep 1

leftover="$(node_pids_matching 'leaked-server.js' | tr '\n' ' ')"
if [ -z "$leftover" ]; then
  pass "both servers the phase leaked were stopped"
else
  fail "leaked servers still running: $leftover"
fi

if alive "$bystander_winpid"; then
  pass "the unrelated node process started during the phase is still running"
else
  fail "the unrelated node process (pid $bystander_winpid) was killed"
fi

echo
if [ "$FAILURES" -eq 0 ]; then echo "reaper ok"; exit 0; fi
echo "$FAILURES check(s) failed"
exit 1
