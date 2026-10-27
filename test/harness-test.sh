#!/usr/bin/env bash
# harness-test.sh - prove the orchestrator reacts correctly to a model, without
# calling one.
#
#   ./test/harness-test.sh
#
# Everything here costs nothing and takes seconds, which is the point: the three
# behaviours it checks were added on 20 Aug after a measurement run was ruined,
# and until this file existed none of them had ever been executed. FACTORY_DRY_RUN
# cannot cover them - it deliberately skips the no-op check and never reaches the
# code that reads a model's exit status.
#
# Each case runs one phase (00-plan) in a throwaway directory under runs/ and
# checks the row written to metrics.tsv, because that row is what a measurement
# is later read from. A wrong row is a wrong pass rate.
set -uo pipefail

FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="$FACTORY_DIR/specs/minicat.md"
STUB_DIR="$(mktemp -d)"
FAILURES=0

cp "$FACTORY_DIR/test/stub-claude.sh" "$STUB_DIR/claude"
chmod +x "$STUB_DIR/claude"
trap 'rm -rf "$STUB_DIR"' EXIT

pass() { printf '  ok   %s\n' "$*"; }
skip() { printf '  skip %s\n' "$*"; }
# The reaper and the file-lock case use powershell.exe and taskkill, so they
# only mean something on Windows (Git Bash), where the factory actually runs.
# Elsewhere they would pass without having checked anything; say so instead.
ON_WINDOWS=0; command -v powershell.exe >/dev/null 2>&1 && ON_WINDOWS=1
fail() { printf '  FAIL %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

# The result column of every row for a phase, space separated.
results_for() {
  awk -F'\t' -v p="$2" 'NR > 1 && $2 == p { printf "%s ", $6 }' \
    "$FACTORY_DIR/runs/$1/.factory/metrics.tsv" 2>/dev/null
}

expect_results() {
  local name="$1" got want="$3"
  got="$(results_for "$name" 00-plan)"
  got="${got% }"
  if [ "$got" = "$want" ]; then pass "$2"; else fail "$2 (metrics said '${got:-<no rows>}', expected '$want')"; fi
}

expect_exit() {
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (exit $1, expected $2)"; fi
}

# Every node process alive, by pid. Compared before and after a phase, because
# matching on the command line has the same blind spot the reaper had: a server
# started as `node server.js` names no directory at all, and that is exactly the
# leak that survived three phases on 7 Sep. A test that cannot see it would pass
# while the thing it checks is broken.
all_node_pids() {
  powershell.exe -NoProfile -NonInteractive -Command '
    Get-CimInstance Win32_Process |
      Where-Object { $_.Name -eq "node.exe" } |
      ForEach-Object { $_.ProcessId }
  ' 2>/dev/null | tr -d '
' | grep -E '^[0-9]+$' | sort

}

run_phase() {
  local name="$1" mode="$2"
  rm -rf "${FACTORY_DIR:?}/runs/$name"
  ( cd "$FACTORY_DIR" && PATH="$STUB_DIR:$PATH" STUB_MODE="$mode" \
    ./factory.sh "$SPEC" --name "$name" --only 00-plan ) > "$STUB_DIR/$name.log" 2>&1
}

echo
echo "a model that answers but writes nothing"
run_phase harness-noop noop; rc=$?
expect_results harness-noop "both attempts recorded as nochange, gate never consulted" "nochange nochange"
expect_exit "$rc" 1 "the phase fails rather than inheriting the previous phase's pass"
if grep -q "gate: plan" "$STUB_DIR/harness-noop.log"; then
  fail "the gate ran anyway - it would have graded work this phase did not do"
else
  pass "the gate was skipped"
fi

echo
echo "a model that ran out of quota"
run_phase harness-quota quota; rc=$?
expect_results harness-quota "the attempt is recorded as quota, not as a failure" "quota"
expect_exit "$rc" 3 "exit 3 tells measure.sh to stop the whole measurement"

echo
echo "a model that writes the wrong thing"
run_phase harness-write write; rc=$?
expect_results harness-write "the tree changed, so the gate ran and failed twice" "fail fail"
expect_exit "$rc" 1 "a failed gate still ends the run"

echo
echo "a model stopped by the session cap, not the monthly one"
run_phase harness-session session; rc=$?
expect_results harness-session "the session cap is recognised as quota, not as a phase failure" "quota"
expect_exit "$rc" 3 "the measurement stops instead of reporting a rate off a run that never happened"

echo
echo "a model that leaves a server running"
if [ "$ON_WINDOWS" = 0 ]; then
  skip "the reaper is Windows-only (no powershell.exe here)"
else
nodes_pre="$(all_node_pids)"
run_phase harness-leak leak; rc=$?
leftover="$(comm -13 <(printf '%s
' "$nodes_pre") <(all_node_pids) | head -1)"
if [ -z "$leftover" ]; then
  pass "the leaked process was reaped before the next phase could inherit it"
else
  fail "a node process survived the phase (pid $leftover) - it will hold files open later"
  powershell.exe -NoProfile -NonInteractive -Command "taskkill /PID $leftover /T /F" >/dev/null 2>&1 || true
fi
fi

echo
echo "a start script that pins its own port"
if grep -qE 'hardcodes a port' "$FACTORY_DIR/gates/smoke.sh"; then
  pass "the smoke gate refuses it by name instead of waiting 60s for the wrong port"
else
  fail "the smoke gate no longer checks the start script"
fi

echo
echo "a run directory that cannot be cleared"
if [ "$ON_WINDOWS" = 0 ]; then
  skip "an open file only blocks deletion on Windows"
else
# The reaper handles a node process holding a file. This is the other case: a
# holder it must not touch. Silence here means measuring on top of a previous
# run and reporting its passes as this one's.
holddir="$FACTORY_DIR/runs/harness-hold-r1"
rm -rf "$holddir" 2>/dev/null; mkdir -p "$holddir"
cat > "$STUB_DIR/hold.ps1" <<'PS'
$f = [System.IO.File]::Open($args[0], 'Create', 'Write', 'None')
Start-Sleep -Seconds 60
$f.Close()
PS
powershell.exe -NoProfile -File "$STUB_DIR/hold.ps1" \
  "$(cd "$holddir" && pwd -W)/locked.bin" >/dev/null 2>&1 &
sleep 3
( cd "$FACTORY_DIR" && FACTORY_DRY_RUN=1 PATH="$STUB_DIR:$PATH" \
  ./measure.sh "$SPEC" --runs 1 --name harness-hold ) > "$STUB_DIR/hold.log" 2>&1
rc=$?
expect_exit "$rc" 1 "measure.sh stops instead of measuring on top of the old run"
if grep -q "cannot clear" "$STUB_DIR/hold.log"; then
  pass "it names the directory it could not clear"
else
  fail "it failed without saying a leftover directory was the reason"
fi
powershell.exe -NoProfile -NonInteractive -Command "
  Get-CimInstance Win32_Process |
    Where-Object { \$_.CommandLine -like '*hold.ps1*' } |
    ForEach-Object { taskkill /PID \$_.ProcessId /T /F 2>&1 | Out-Null }" >/dev/null 2>&1 || true
sleep 1; rm -rf "$holddir" "$FACTORY_DIR/runs/harness-hold-report.txt" 2>/dev/null || true
fi

echo
echo "measure.sh meeting an exhausted account mid-measurement"
rm -rf "${FACTORY_DIR:?}"/runs/harness-measure-r* "${FACTORY_DIR:?}/runs/harness-measure-report.txt"
( cd "$FACTORY_DIR" && PATH="$STUB_DIR:$PATH" STUB_MODE=quota \
  ./measure.sh "$SPEC" --runs 3 --name harness-measure ) > "$STUB_DIR/measure.log" 2>&1
rc=$?
expect_exit "$rc" 3 "measure.sh exits 3 rather than reporting a rate"
if grep -q "INCOMPLETE" "$STUB_DIR/measure.log"; then
  pass "the report says INCOMPLETE instead of showing a pass rate"
else
  fail "the report did not warn that the numbers are partial"
fi
if grep -q "summary over 1 of 3" "$STUB_DIR/measure.log"; then
  pass "runs 2 and 3 were abandoned instead of repeating the same wall"
else
  fail "measure.sh kept going after the account was empty"
fi

rm -rf "${FACTORY_DIR:?}"/runs/harness-noop "${FACTORY_DIR:?}"/runs/harness-quota \
       "${FACTORY_DIR:?}"/runs/harness-session "${FACTORY_DIR:?}"/runs/harness-leak \
       "${FACTORY_DIR:?}"/runs/harness-write "${FACTORY_DIR:?}"/runs/harness-measure-r* \
       "${FACTORY_DIR:?}/runs/harness-measure-report.txt"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "harness ok"
  exit 0
fi
echo "$FAILURES check(s) failed"
exit 1
