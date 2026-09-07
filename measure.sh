#!/usr/bin/env bash
# measure.sh - run the same spec several times and report how the pipeline did.
#
#   ./measure.sh specs/minicat.md --runs 3
#   ./measure.sh specs/minicat.md --runs 3 --name minicat --keep
#   ./measure.sh specs/minicat.md --name minicat --summary-only   # report only
#
# One run tells you the pipeline can work. Three tell you whether it works
# reliably, which is the only question worth asking of something meant to run
# unattended. It answers the three from DESIGN:
#
#   1. pass rate per phase  - and how often a phase needed a second attempt
#   2. phases a human had to rescue - the run stopped there. Target: zero
#   3. where to look for a false pass - a phase that sailed through while a
#      later phase failed on its work is the first place to check
#
# Each run gets its own runs/<name>-rN directory, because a resumed run skips
# phases that are already done and would measure nothing.
#
# This spends real quota: RUNS x 6 phases of model calls. FACTORY_DRY_RUN=1
# exercises the harness itself without calling a model (every gate then fails,
# which is the point - it proves the failure path records what it should).
set -euo pipefail

FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The reaper lives in factory.sh; pull in just that function rather than keeping
# a second copy that can drift from it.
eval "$(sed -n '/^node_snapshot()/,/^}/p;/^reap_project_processes()/,/^}/p' "$FACTORY_DIR/factory.sh")"

die() { printf '
[measure] ERROR: %s
' "$*" >&2; exit 1; }
say() { printf '
[measure] %s
' "$*"; }

SPEC="${1:-}"
[ -n "$SPEC" ] || die "usage: ./measure.sh <spec.md> [--runs N] [--name base] [--keep]"
shift
[ -f "$SPEC" ] || die "spec not found: $SPEC"

RUNS=3
BASE=""
KEEP=0
# Re-reads the rows an earlier measurement already wrote. Reporting again must
# never mean running again: these runs cost quota and hours.
SUMMARY_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --runs) RUNS="$2"; shift 2 ;;
    --name) BASE="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --summary-only) SUMMARY_ONLY=1; shift ;;
    *) die "unknown flag: $1" ;;
  esac
done
case "$RUNS" in ''|*[!0-9]*) die "--runs takes a number" ;; esac
[ "$RUNS" -ge 1 ] || die "--runs must be at least 1"
[ -n "$BASE" ] || BASE="$(basename "${SPEC%.*}")-measure"

REPORT="$FACTORY_DIR/runs/$BASE-report.txt"
ABORTED=0
mkdir -p "$FACTORY_DIR/runs"

PHASES="00-plan 10-scaffold 20-data 30-features 40-review 50-deploy"

if [ "$SUMMARY_ONLY" -eq 1 ]; then
  [ -s "$REPORT" ] || die "no earlier measurement for '$BASE' ($REPORT is missing)"
  RUNS="$(wc -l < "$REPORT" | tr -d ' ')"
else
: > "$REPORT"
for i in $(seq 1 "$RUNS"); do
  NAME="$BASE-r$i"
  DIR="$FACTORY_DIR/runs/$NAME"
  # A leftover directory would be resumed, not rebuilt, and every phase already
  # done would report a pass it did not earn on this run.
  if [ -d "$DIR" ]; then
    [ "$KEEP" -eq 0 ] || die "$DIR already exists and --keep was given; move it aside first"
    say "clearing previous $NAME"
    # A directory that will not go away is almost always a process still holding
    # a file in it - the leak this harness already knows about. Reap, retry, and
    # if it is still there, stop: measuring on top of a half-deleted run reports
    # passes from the run before it.
    rm -rf "$DIR" 2>/dev/null || true
    if [ -d "$DIR" ]; then
      reap_project_processes "$DIR"
      sleep 2
      rm -rf "$DIR" 2>/dev/null || true
    fi
    [ -d "$DIR" ] && die "cannot clear $DIR - something is still holding a file open in it. Close it, then run again."
  fi

  say "run $i/$RUNS -> $NAME"
  start="$(date +%s)"
  # PIPESTATUS, not the pipeline status: tee always succeeds and would hide the
  # exit code that says whether this run measured anything at all.
  set +e
  ( cd "$FACTORY_DIR" && ./factory.sh "$SPEC" --name "$NAME" ) 2>&1 | tee "$FACTORY_DIR/runs/$NAME.log"
  rc=${PIPESTATUS[0]}
  set -e
  case "$rc" in
    0) verdict=complete ;;
    3) verdict=quota ;;
    *) verdict=stopped ;;
  esac
  finish="$(date +%s)"

  # Where it stopped, if it did: the first phase with no done- marker.
  stopped_at=""
  for p in $PHASES; do
    if [ ! -f "$DIR/.factory/done-$p" ]; then stopped_at="$p"; break; fi
  done
  [ -n "$stopped_at" ] || [ "$verdict" = quota ] || verdict=complete

  printf '%s\t%s\t%s\t%s\n' "$NAME" "$verdict" "${stopped_at:--}" "$((finish - start))" >> "$REPORT"
  say "run $i: $verdict${stopped_at:+ at $stopped_at} in $((finish - start))s"

  # Every later run hits the same wall and writes the same meaningless row.
  # Three rows reading "stopped at 00-plan" look like a broken pipeline when all
  # they mean is that the account ran dry.
  if [ "$verdict" = quota ]; then
    ABORTED=1
    say "out of quota - abandoning runs $((i + 1))..$RUNS. This measurement is incomplete."
    break
  fi
done
fi

# ---------------------------------------------------------------- summary
say "summary over $(wc -l < "$REPORT" | tr -d ' ') of $RUNS requested run(s) of $SPEC"

cat "$FACTORY_DIR"/runs/"$BASE"-r*/.factory/metrics.tsv 2>/dev/null \
  | awk -F'\t' '
      $1 == "started_at" { next }
      NF < 7 { next }
      # A quota row means the model never ran. Counting it as an attempt would
      # drag the pass rate down for a phase that was never given a chance.
      $6 == "quota" { quota[$2]++; quota_total++; next }
      {
        phase = $2; attempt = $5 + 0; result = $6; secs = $7 + 0
        seen[phase] = 1
        attempts[phase]++
        secs_total[phase] += secs
        if (result == "pass") {
          passed[phase]++
          if (attempt == 1) first_try[phase]++
        }
      }
      END {
        n = split("00-plan 10-scaffold 20-data 30-features 40-review 50-deploy", order, " ")
        printf "%-12s %8s %8s %8s %8s\n", "phase", "attempts", "passed", "1st-try", "avg-sec"
        for (i = 1; i <= n; i++) {
          p = order[i]
          if (!(p in seen)) { printf "%-12s %8s %8s %8s %8s\n", p, "-", "-", "-", "-"; continue }
          printf "%-12s %8d %8d %8d %8.0f\n", p, attempts[p], passed[p] + 0, first_try[p] + 0, secs_total[p] / attempts[p]
        }
      }'

echo
echo "runs:"
awk -F'\t' '{ printf "  %-24s %-9s stopped-at=%-12s %ss\n", $1, $2, $3, $4 }' "$REPORT"

echo
if [ "$ABORTED" -eq 1 ]; then
  echo
  echo "INCOMPLETE: the account ran out of quota part-way through. The numbers above"
  echo "cover only the attempts that actually reached a model. Re-run the whole"
  echo "measurement once quota is back - do not read a pass rate off a partial run."
  echo
fi
echo "A phase whose attempts exceed its passes needed a retry."
echo "A run that stopped names the phase a human has to rescue - the number to drive to zero."
echo "Logs: runs/$BASE-r<N>/.factory/logs/  ·  per-attempt rows: runs/$BASE-r<N>/.factory/metrics.tsv"


[ "$ABORTED" -eq 0 ] || exit 3