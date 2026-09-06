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
       "${FACTORY_DIR:?}"/runs/harness-write "${FACTORY_DIR:?}"/runs/harness-measure-r* \
       "${FACTORY_DIR:?}/runs/harness-measure-report.txt"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "harness ok"
  exit 0
fi
echo "$FAILURES check(s) failed"
exit 1
