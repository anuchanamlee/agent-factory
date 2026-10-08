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
# factory - a bystander. Then:
#   - the leaked servers must have been seen running during the phase
#     (otherwise "none left afterwards" would prove nothing)
#   - the phase must have really run (exit code and log)
#   - afterwards every leaked server seen must be gone
#   - the bystander must still be running
# The old reaper killed every node.exe that appeared during a phase, so it
# killed the bystander too.
#
# Stops nothing by name: cleanup acts only on pids this script recorded (its
# bystander, and leaked servers it saw during its own phase). Windows only.
set -uo pipefail

FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="$FACTORY_DIR/specs/minicat.md"
STUB_DIR="$(mktemp -d)"
NAME="reaper-test-$$"
FAILURES=0
SEEN=""
bystander_winpid=""
cp "$FACTORY_DIR/test/stub-claude.sh" "$STUB_DIR/claude"
chmod +x "$STUB_DIR/claude"
printf 'setInterval(function(){}, 1e9);\n' > "$STUB_DIR/bystander.js"

pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

command -v powershell.exe >/dev/null 2>&1 || { echo "reaper-test: needs powershell.exe (Windows)"; exit 2; }

# Windows pids of node processes running the stub's leaked-server.js. Read-only.
leaked_now() {
  powershell.exe -NoProfile -NonInteractive -Command "
    Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" |
      Where-Object { \$_.CommandLine -like '*leaked-server.js*' } |
      ForEach-Object { \$_.ProcessId }" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$'
}

# "Is pid $1 still our process?" Windows reuses pids quickly, so a pid counts as
# ours only while its command line still names the script we started ($2).
alive_as() {
  powershell.exe -NoProfile -NonInteractive -Command "
    \$p = Get-CimInstance Win32_Process -Filter 'ProcessId=$1'
    if (\$p -and \$p.CommandLine -like '*$2*') { 'yes' }" 2>/dev/null | tr -d '\r' | grep -q yes
}

stop_if_ours() {
  alive_as "$1" "$2" && powershell.exe -NoProfile -NonInteractive -Command \
    "Stop-Process -Id $1 -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1
  return 0
}

cleanup() {
  local p
  [ -n "$bystander_winpid" ] && stop_if_ours "$bystander_winpid" bystander.js
  for p in $SEEN; do stop_if_ours "$p" leaked-server.js; done
  rm -rf "${FACTORY_DIR:?}/runs/$NAME" "$STUB_DIR"
}
trap cleanup EXIT

already="$(leaked_now | tr '\n' ' ')"
[ -z "$already" ] || { echo "reaper-test: leaked-server.js processes already running ($already); stop them first"; exit 2; }

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

# Record every leaked server that shows up while the phase is running.
while kill -0 "$phase_pid" 2>/dev/null; do
  for p in $(leaked_now); do
    case " $SEEN " in *" $p "*) ;; *) SEEN="$SEEN $p" ;; esac
  done
  sleep 0.5
done
wait "$phase_pid"; phase_rc=$?
sleep 1

# The stub writes files, so the plan gate runs, fails, and the phase ends 1.
if [ "$phase_rc" -eq 1 ] && grep -q "gate: plan" "$STUB_DIR/phase.log"; then
  pass "the phase really ran (model called, gate reached, exit 1)"
else
  fail "the phase did not run as expected (exit $phase_rc) - nothing below would mean anything"
  sed 's/^/        /' "$STUB_DIR/phase.log" | tail -20
fi

if [ -n "$SEEN" ]; then
  pass "leaked servers were running during the phase (pids:$SEEN)"
else
  fail "no leaked server was ever seen - the leak did not happen, so its cleanup is untested"
fi

survivors=""
for p in $SEEN; do alive_as "$p" leaked-server.js && survivors="$survivors $p"; done
if [ -n "$SEEN" ] && [ -z "$survivors" ]; then
  pass "every leaked server seen during the phase was stopped"
elif [ -n "$survivors" ]; then
  fail "leaked servers still running:$survivors"
fi

if alive_as "$bystander_winpid" bystander.js; then
  pass "the unrelated node process started during the phase is still running"
else
  fail "the unrelated node process (pid $bystander_winpid) was killed"
fi

echo
if [ "$FAILURES" -eq 0 ]; then echo "reaper ok"; exit 0; fi
echo "$FAILURES check(s) failed"
exit 1
