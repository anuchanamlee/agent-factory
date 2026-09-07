#!/usr/bin/env bash
# agent-factory — build a full Next.js project from a spec file, phase by phase.
#
# Each phase is one headless `claude -p` call followed by a real verification
# gate (build / migrate / smoke / docker). A phase is only marked done when its
# gate passes, so a broken phase never silently poisons the ones after it.
#
# Usage:
#   ./factory.sh specs/my-shop.md --name my-shop
#   ./factory.sh specs/my-shop.md --name my-shop --from 30-features
#   ./factory.sh specs/my-shop.md --name my-shop --only 50-deploy
#
# Model and effort are per phase, in pipeline/<phase>.conf. Planning and review
# get the stronger model; mechanical phases do not. FACTORY_MODEL / FACTORY_EFFORT
# override every phase at once — useful for a cheap dry run, not for normal use.
#
# Env knobs:
#   FACTORY_MODEL=opus|sonnet        override model for ALL phases
#   FACTORY_EFFORT=low|medium|high|xhigh|max   override effort for ALL phases
#   FACTORY_MAX_ATTEMPTS=2           gate retries per phase   (default: 2)
#   FACTORY_PERM=auto|acceptEdits|bypassPermissions           (default: auto)
#   FACTORY_DEPLOY_TARGET=local|vps  deploy phase target      (default: local)
#   FACTORY_VPS=user@host            required when target=vps
#   FACTORY_CONFIRM_PROD=yes         required to deploy to a real host
#   FACTORY_DRY_RUN=1                build every prompt and run every gate, but
#                                    make no model call - for iterating on the
#                                    phase prompts without spending quota
#   FACTORY_NOTES_LIMIT=6000         bytes of NOTES.md carried into a prompt
#
# Exit codes: 0 every phase passed  ·  1 a phase failed its gate after every
# attempt  ·  3 the subscription ran out of quota mid-run, so nothing from that
# phase onward was measured.
#
# Every attempt appends a row to runs/<name>/.factory/metrics.tsv (phase, model,
# effort, attempt, pass/fail, seconds, prompt bytes). ./measure.sh runs a spec
# several times and summarises those rows - which phase needs a retry, which one
# needs a human, and whether that is getting better or worse.

set -euo pipefail

FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Fallbacks for a phase with no .conf; env vars, if set, beat both.
DEFAULT_MODEL=opus
DEFAULT_EFFORT=high
# NOTES.md is append-only across six phases and every retry. Cap what reaches the
# prompt so a chatty early phase cannot tax every phase after it.
NOTES_LIMIT="${FACTORY_NOTES_LIMIT:-6000}"
MAX_ATTEMPTS="${FACTORY_MAX_ATTEMPTS:-2}"
# auto runs the classifier that blocks dangerous commands, and aborts a headless
# run outright if it keeps blocking. Failing loudly beats a wedged pipeline.
PERM="${FACTORY_PERM:-auto}"
DEPLOY_TARGET="${FACTORY_DEPLOY_TARGET:-local}"

# phase-id : gate-script
PHASES=(
  "00-plan:plan"
  "10-scaffold:build"
  "20-data:data"
  "30-features:features"
  "40-review:smoke"
  "50-deploy:deploy"
)

ALLOWED_TOOLS='Bash Edit Write Read Glob Grep'

die() { printf '\n[factory] ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf '\n[factory] %s\n' "$*"; }

# One tab-separated line per attempt, so a run can be measured afterwards
# instead of being reconstructed by reading six logs. TSV rather than JSON
# because awk is everywhere and jq is not.
metric() {
  # phase model effort attempt result seconds prompt_bytes
  [ -s "$META_DIR/metrics.tsv" ] || \
    printf 'started_at\tphase\tmodel\teffort\tattempt\tresult\tseconds\tprompt_bytes\n' > "$META_DIR/metrics.tsv"
  { printf '%s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; printf '\t%s' "$@"; printf '\n'; } >> "$META_DIR/metrics.tsv"
}

# A subscription that has run out says so and exits non-zero. That is not a phase
# failure: the model never ran, so a retry burns the attempt budget and the gate
# that follows grades the PREVIOUS phase's work - which is how a run once
# recorded 20-data as passed while the model was doing nothing at all.
# Exit 3 means "nothing was measured"; measure.sh stops the remaining runs on it.
# A phase whose model call changed no file did not do its work. The gate that
# follows would then grade whatever the previous phase left behind - that is how
# a run recorded 20-data as PASSED while the model was doing nothing at all.
# Cheap enough to run twice per attempt: paths plus size plus mtime, with the
# directories nobody edits by hand left out.
tree_fingerprint() {
  ( cd "$1" 2>/dev/null && find . \
      -name node_modules -prune -o -name .git -prune -o \
      -name .next -prune -o -name .factory -prune -o \
      -type f -printf "%p %s %T@\n" 2>/dev/null \
    | LC_ALL=C sort | cksum ) || echo "unreadable"
}

# A phase that leaves a server running poisons every phase after it. The model
# is told to clean up after itself and mostly does, but "mostly" is not a
# property a run measured overnight can rely on: on 7 Sep a server started
# during 10-scaffold was still alive during 40-review, holding .next\standalone
# open, and next build died with EBUSY twice in a row. The report then said the
# review phase had failed. It had not - nothing was ever wrong with the model's
# work, and the number was noise.
#
# So the orchestrator reaps between attempts instead of trusting the prompt.
# Only processes whose command line names this project directory are killed,
# which leaves the operator's own editors and shells alone.
#
# Two guards, because a reaper that kills the wrong thing is worse than the leak
# it fixes:
#   - only node.exe and the cmd.exe that npm wraps it in. The orchestrator's own
#     bash, and the claude CLI whose command line carries the prompt (and with it
#     the project path), can never match.
#   - only command lines naming this project directory, so a server belonging to
#     another project on the same machine is left alone.
#
# Known limit: a process launched with a relative path from inside the project
# has a command line that never mentions the directory, so it survives. Windows
# does not expose a process's working directory here. The leak that actually
# happened - npm running next from node_modules - carries the absolute path.
reap_project_processes() {
  local dir="$1" win_dir
  command -v powershell.exe >/dev/null 2>&1 || return 0
  # PowerShell matches on the Windows form of the path, not the MSYS one.
  win_dir="$(cd "$dir" && pwd -W 2>/dev/null || echo "$dir")"
  PS_DIR="$win_dir" powershell.exe -NoProfile -NonInteractive -Command '
    # Both sides are normalised to one separator: a command line may carry
    # either, and a path that misses by a slash reaps nothing at all.
    $d = $env:PS_DIR.Replace("/", "\").TrimEnd("\")
    Get-CimInstance Win32_Process |
      Where-Object {
        $_.Name -in @("node.exe", "cmd.exe") -and
        $_.CommandLine -and $_.CommandLine.Replace("/", "\").Contains($d)
      } |
      ForEach-Object { taskkill /PID $_.ProcessId /T /F 2>&1 | Out-Null }
  ' >/dev/null 2>&1 || true
}

QUOTA_EXIT=3
# Every way the CLI says "I am not going to answer, and trying again now will not
# help". The session cap is a different sentence from the monthly one and cost a
# whole measurement on 7 Sep: unmatched, it fell through to the no-change check,
# and the report named the plan phase as the thing that had failed, which it had
# not. Widen this list rather than trimming it - a missed phrase is a run that
# never happened being reported as a result.
quota_stopped() {
  tail -c 4000 "$1" | grep -qiE \
    'monthly spend limit|usage limit reached|hit your (usage|spend|session) limit|session limit reached|limit .{0,20}resets? (at|in)|credit balance is too low|insufficient credits?|rate limit exceeded'
}

# ---------------------------------------------------------------- args
SPEC_ARG="${1:-}"
[ -n "$SPEC_ARG" ] || die "no spec file given. usage: ./factory.sh <spec.md> --name <project>"
shift

NAME=""
FROM=""
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    *) die "unknown flag: $1" ;;
  esac
done

[ -f "$SPEC_ARG" ] || die "spec file not found: $SPEC_ARG"
SPEC_PATH="$(cd "$(dirname "$SPEC_ARG")" && pwd)/$(basename "$SPEC_ARG")"
[ -n "$NAME" ] || NAME="$(basename "${SPEC_ARG%.*}")"

PROJECT_DIR="$FACTORY_DIR/runs/$NAME"
META_DIR="$PROJECT_DIR/.factory"
mkdir -p "$META_DIR/logs"
# The spec template carries HTML comments that tell a human how to fill it in.
# They are dead weight in a prompt that gets rebuilt for every phase and every
# retry, so strip them once here rather than paying for them a dozen times.
sed -E '/<!--/,/-->/d' "$SPEC_PATH" | sed -E '/^[[:space:]]*$/N;/^[[:space:]]*\n[[:space:]]*$/D' > "$META_DIR/SPEC.md"
[ -s "$META_DIR/SPEC.md" ] || die "spec is empty once comments are stripped: $SPEC_ARG"
say "spec    : $(wc -c < "$SPEC_PATH") bytes -> $(wc -c < "$META_DIR/SPEC.md") bytes after stripping comments"

say "project : $NAME"
say "dir     : $PROJECT_DIR"
say "phases  : ${#PHASES[@]} (model and effort per pipeline/<phase>.conf)"
say "deploy  : $DEPLOY_TARGET"

# ---------------------------------------------------------------- helpers
phase_done() { [ -f "$META_DIR/done-$1" ]; }

# Reads pipeline/<phase>.conf into PHASE_MODEL / PHASE_EFFORT. Planning and
# review are worth the expensive model; scaffolding against a locked stack is
# not, and on a subscription that difference is quota rather than money.
load_phase_conf() {
  local phase="$1"
  local conf="$FACTORY_DIR/pipeline/$phase.conf"
  local MODEL="" EFFORT="" ALLOW_NO_CHANGE=""

  if [ -f "$conf" ]; then
    # shellcheck disable=SC1090
    . "$conf"
  fi

  # 40-review is allowed to conclude that nothing needs fixing.
  PHASE_ALLOW_NO_CHANGE="${ALLOW_NO_CHANGE:-0}"
  PHASE_MODEL="${MODEL:-$DEFAULT_MODEL}"
  PHASE_EFFORT="${EFFORT:-$DEFAULT_EFFORT}"

  # An explicit env override beats the per-phase file.
  [ -n "${FACTORY_MODEL:-}" ]  && PHASE_MODEL="$FACTORY_MODEL"
  [ -n "${FACTORY_EFFORT:-}" ] && PHASE_EFFORT="$FACTORY_EFFORT"
  return 0
}

build_prompt() {
  # $1 = phase id, $2 = path to previous gate failure output (may be empty)
  local phase="$1" failure="$2"
  # Everything stable comes first and everything that changes between attempts
  # comes last, so a retry re-reads the identical prefix from cache instead of
  # paying for the spec and the instructions a second time.
  {
    echo "You are building a project autonomously. No human will answer questions."
    echo "Work only inside the current directory. Finish the phase completely."
    echo
    echo "<project-name>$NAME</project-name>"
    echo
    echo "<spec>"
    cat "$META_DIR/SPEC.md"
    echo "</spec>"
    echo
    echo "<phase-instructions>"
    cat "$FACTORY_DIR/pipeline/$phase.md"
    echo "</phase-instructions>"
    if [ -f "$PROJECT_DIR/PLAN.md" ]; then
      echo
      echo "<ground-truth>"
      echo "PLAN.md, TASKS.md and CLAUDE.md are in the working directory. The"
      echo "planning phase wrote them and this phase builds against them. Read them"
      echo "before you touch anything. Where they disagree with what you would have"
      echo "chosen, follow them and record the disagreement in .factory/NOTES.md -"
      echo "later phases read the files, not your reasoning."
      echo "</ground-truth>"
    fi
    echo
    echo "When the phase is complete, append a short section to .factory/NOTES.md"
    echo "recording decisions later phases need (file layout, table names, env vars,"
    echo "ports, gotchas). Keep it under 40 lines. Notes are truncated to the most"
    echo "recent ${NOTES_LIMIT} bytes before the next phase sees them, so put the"
    echo "durable decisions in PLAN.md and CLAUDE.md, not here."
    # --- volatile from here down ---
    if [ -f "$META_DIR/NOTES.md" ]; then
      echo
      echo "<notes-from-earlier-phases>"
      tail -c "$NOTES_LIMIT" "$META_DIR/NOTES.md"
      echo "</notes-from-earlier-phases>"
    fi
    if [ -n "$failure" ] && [ -s "$failure" ]; then
      echo
      echo "<previous-attempt-failed>"
      echo "Your last attempt at this phase did not pass its verification gate."
      echo "Fix the root cause. Do not work around the check."
      echo
      tail -c 8000 "$failure"
      echo "</previous-attempt-failed>"
    fi
  }
}

run_phase() {
  local phase="$1" gate="$2"
  local attempt=1 failure=""

  load_phase_conf "$phase"

  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    say "phase $phase — attempt $attempt/$MAX_ATTEMPTS ($PHASE_MODEL, effort $PHASE_EFFORT)"
    local prompt_file="$META_DIR/logs/$phase-a$attempt.prompt.md"
    local out_file="$META_DIR/logs/$phase-a$attempt.out.txt"
    local gate_file="$META_DIR/logs/$phase-a$attempt.gate.txt"
    local t0 t1
    t0="$(date +%s)"

    build_prompt "$phase" "$failure" > "$prompt_file"

    local fp_before fp_after
    fp_before="$(tree_fingerprint "$PROJECT_DIR")"

    if [ -n "${FACTORY_DRY_RUN:-}" ]; then
      say "dry run: would call claude --model $PHASE_MODEL --effort $PHASE_EFFORT"
      say "         prompt is $(wc -c < "$prompt_file") bytes at $prompt_file"
      echo "(dry run - no model call)" > "$out_file"
    else
      local claude_rc=0
      ( cd "$PROJECT_DIR" && claude -p "$(cat "$prompt_file")" \
        --model "$PHASE_MODEL" \
        --effort "$PHASE_EFFORT" \
        --permission-mode "$PERM" \
        --allowedTools $ALLOWED_TOOLS \
        --output-format text ) 2>&1 | tee "$out_file" || claude_rc=$?
      if [ "$claude_rc" -ne 0 ]; then
        say "claude exited non-zero on $phase (see $out_file)"
        # Only a non-zero exit counts as running dry: the same words inside a
        # normal answer are the model talking about limits, not the CLI refusing.
        if quota_stopped "$out_file"; then
          t1="$(date +%s)"
          metric "$phase" "$PHASE_MODEL" "$PHASE_EFFORT" "$attempt" quota "$((t1 - t0))" "$(wc -c < "$prompt_file" | tr -d ' ')"
          say "out of model quota during $phase - stopping before the gate."
          say "The model did nothing this attempt, so a gate result here would grade"
          say "the previous phase's work. Nothing from $phase onward was measured."
          say "resume once quota is back:  ./factory.sh $SPEC_ARG --name $NAME --from $phase"
          exit "$QUOTA_EXIT"
        fi
      fi
      fi

    # Before anything reads the tree: whatever the model left running still has
    # file handles open, and on Windows an open handle is a build failure two
    # phases later rather than an error here.
    reap_project_processes "$PROJECT_DIR"

    fp_after="$(tree_fingerprint "$PROJECT_DIR")"
    if [ -z "${FACTORY_DRY_RUN:-}" ] && [ "$PHASE_ALLOW_NO_CHANGE" != "1" ] \
       && [ "$fp_before" = "$fp_after" ]; then
      t1="$(date +%s)"
      metric "$phase" "$PHASE_MODEL" "$PHASE_EFFORT" "$attempt" nochange "$((t1 - t0))" "$(wc -c < "$prompt_file" | tr -d ' ')"
      say "no file changed during $phase - skipping the gate, which would grade the previous phase."
      printf "the model wrote nothing this attempt. gate not run.\n" > "$gate_file"
      tail -n 20 "$out_file" >> "$gate_file" 2>/dev/null || true
      failure="$gate_file"
      attempt=$((attempt + 1))
      continue
    fi

    say "gate: $gate"
    if ( FACTORY_DEPLOY_TARGET="$DEPLOY_TARGET" \
         bash "$FACTORY_DIR/gates/$gate.sh" "$PROJECT_DIR" ) > "$gate_file" 2>&1; then
      t1="$(date +%s)"
      tail -n 5 "$gate_file"
      touch "$META_DIR/done-$phase"
      metric "$phase" "$PHASE_MODEL" "$PHASE_EFFORT" "$attempt" pass "$((t1 - t0))" "$(wc -c < "$prompt_file" | tr -d ' ')"
      say "phase $phase PASSED"
      return 0
    fi
    t1="$(date +%s)"
    metric "$phase" "$PHASE_MODEL" "$PHASE_EFFORT" "$attempt" fail "$((t1 - t0))" "$(wc -c < "$prompt_file" | tr -d ' ')"

    say "gate FAILED for $phase:"
    tail -n 25 "$gate_file"
    failure="$gate_file"
    attempt=$((attempt + 1))
  done

  die "phase $phase failed after $MAX_ATTEMPTS attempts. Logs: $META_DIR/logs/
Fix by hand, then resume with:  ./factory.sh $SPEC_ARG --name $NAME --from $phase"
}

# ---------------------------------------------------------------- run
for entry in "${PHASES[@]}"; do
  phase="${entry%%:*}"
  gate="${entry##*:}"
  [ -f "$FACTORY_DIR/pipeline/$phase.md" ] || die "pipeline/$phase.md is missing - every phase needs its prompt"
  [ -f "$FACTORY_DIR/gates/$gate.sh" ]     || die "gates/$gate.sh is missing - phase $phase has no gate to pass"
done

started=0
for entry in "${PHASES[@]}"; do
  phase="${entry%%:*}"
  gate="${entry##*:}"

  if [ -n "$ONLY" ]; then
    [ "$phase" = "$ONLY" ] || continue
    rm -f "$META_DIR/done-$phase"
    run_phase "$phase" "$gate"
    say "done (--only $ONLY)"
    exit 0
  fi

  if [ -n "$FROM" ] && [ "$started" -eq 0 ]; then
    if [ "$phase" = "$FROM" ]; then started=1; rm -f "$META_DIR/done-$phase"; else continue; fi
  fi

  if phase_done "$phase"; then
    say "phase $phase already done — skipping (use --from $phase to redo)"
    continue
  fi

  run_phase "$phase" "$gate"
done

say "ALL PHASES COMPLETE — project at $PROJECT_DIR"
