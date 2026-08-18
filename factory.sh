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
# Env knobs:
#   FACTORY_MODEL=opus|sonnet        model per phase          (default: opus)
#   FACTORY_EFFORT=low|medium|high|xhigh|max                  (default: high)
#   FACTORY_MAX_ATTEMPTS=2           gate retries per phase   (default: 2)
#   FACTORY_PERM=acceptEdits|bypassPermissions                (default: acceptEdits)
#   FACTORY_DEPLOY_TARGET=local|vps  deploy phase target      (default: local)
#   FACTORY_VPS=user@host            required when target=vps

set -euo pipefail

FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL="${FACTORY_MODEL:-opus}"
EFFORT="${FACTORY_EFFORT:-high}"
MAX_ATTEMPTS="${FACTORY_MAX_ATTEMPTS:-2}"
PERM="${FACTORY_PERM:-acceptEdits}"
DEPLOY_TARGET="${FACTORY_DEPLOY_TARGET:-local}"

# phase-id : gate-script
PHASES=(
  "10-scaffold:build"
  "20-data:data"
  "30-features:build"
  "40-verify:smoke"
  "50-deploy:deploy"
)

ALLOWED_TOOLS='Bash Edit Write Read Glob Grep'

die() { printf '\n[factory] ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf '\n[factory] %s\n' "$*"; }

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
cp "$SPEC_PATH" "$META_DIR/SPEC.md"

say "project : $NAME"
say "dir     : $PROJECT_DIR"
say "model   : $MODEL (effort $EFFORT)"
say "deploy  : $DEPLOY_TARGET"

# ---------------------------------------------------------------- helpers
phase_done() { [ -f "$META_DIR/done-$1" ]; }

build_prompt() {
  # $1 = phase id, $2 = path to previous gate failure output (may be empty)
  local phase="$1" failure="$2"
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
    if [ -f "$META_DIR/NOTES.md" ]; then
      echo "<notes-from-earlier-phases>"
      cat "$META_DIR/NOTES.md"
      echo "</notes-from-earlier-phases>"
      echo
    fi
    echo "<phase-instructions>"
    cat "$FACTORY_DIR/pipeline/$phase.md"
    echo "</phase-instructions>"
    if [ -n "$failure" ] && [ -s "$failure" ]; then
      echo
      echo "<previous-attempt-failed>"
      echo "Your last attempt at this phase did not pass its verification gate."
      echo "Fix the root cause. Do not work around the check."
      echo
      tail -c 8000 "$failure"
      echo "</previous-attempt-failed>"
    fi
    echo
    echo "When the phase is complete, append a short section to .factory/NOTES.md"
    echo "recording decisions later phases need (file layout, table names, env vars,"
    echo "ports, gotchas). Keep it under 40 lines total per phase."
  }
}

run_phase() {
  local phase="$1" gate="$2"
  local attempt=1 failure=""

  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    say "phase $phase — attempt $attempt/$MAX_ATTEMPTS"
    local prompt_file="$META_DIR/logs/$phase-a$attempt.prompt.md"
    local out_file="$META_DIR/logs/$phase-a$attempt.out.txt"
    local gate_file="$META_DIR/logs/$phase-a$attempt.gate.txt"

    build_prompt "$phase" "$failure" > "$prompt_file"

    if ! ( cd "$PROJECT_DIR" && claude -p "$(cat "$prompt_file")" \
             --model "$MODEL" \
             --effort "$EFFORT" \
             --permission-mode "$PERM" \
             --allowedTools $ALLOWED_TOOLS \
             --output-format text ) 2>&1 | tee "$out_file"; then
      say "claude exited non-zero on $phase (see $out_file)"
    fi

    say "gate: $gate"
    if ( FACTORY_DEPLOY_TARGET="$DEPLOY_TARGET" \
         bash "$FACTORY_DIR/gates/$gate.sh" "$PROJECT_DIR" ) > "$gate_file" 2>&1; then
      tail -n 5 "$gate_file"
      touch "$META_DIR/done-$phase"
      say "phase $phase PASSED"
      return 0
    fi

    say "gate FAILED for $phase:"
    tail -n 25 "$gate_file"
    failure="$gate_file"
    attempt=$((attempt + 1))
  done

  die "phase $phase failed after $MAX_ATTEMPTS attempts. Logs: $META_DIR/logs/
Fix by hand, then resume with:  ./factory.sh $SPEC_ARG --name $NAME --from $phase"
}

# ---------------------------------------------------------------- run
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
