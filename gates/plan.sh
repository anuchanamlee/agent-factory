#!/usr/bin/env bash
# Gate: the plan phase produced files later phases can actually build against.
set -euo pipefail
PROJ="$1"
cd "$PROJ"

echo "== gate:plan in $PROJ =="

fail() { echo "FAIL: $*"; exit 1; }

for f in PLAN.md TASKS.md CLAUDE.md .factory/ROUTES.txt; do
  [ -f "$f" ] || fail "$f was not created"
  [ -s "$f" ] || fail "$f is empty"
done

echo "-- placeholder scan"
if grep -rnEi '\b(TODO|FIXME|TBD|XXX)\b|<[a-z][a-z0-9 _-]*>' PLAN.md TASKS.md CLAUDE.md; then
  fail "placeholder text survived into the plan (lines above)"
fi

echo "-- task shape"
awk '
  /^[[:space:]]*-[[:space:]]*\[[[:space:]xX]\]/ {
    tasks++
    if (getline nextline <= 0) { print "  no line after task on line " NR; bad++; next }
    if (nextline !~ /^[[:space:]]*verify:/) {
      print "  task on line " NR " has no verify: line"
      bad++
    }
    next
  }
  END {
    if (tasks == 0)  { print "  TASKS.md contains no tasks"; bad++ }
    print "tasks: " tasks+0
    exit (bad+0 > 0) ? 1 : 0
  }
' TASKS.md || fail "TASKS.md is not in the required two-line form"

echo "-- routes file"
awk '
  /^[[:space:]]*(#|$)/ { next }
  {
    n++
    if ($1 !~ /^\//)          { print "  line " NR ": path must start with / — got: " $1; bad++ }
    if ($2 !~ /^[1-5][0-9][0-9]$/) { print "  line " NR ": second field must be an HTTP status — got: " $2; bad++ }
  }
  END {
    if (n == 0) { print "  ROUTES.txt lists no routes"; bad++ }
    print "routes: " n+0
    exit (bad+0 > 0) ? 1 : 0
  }
' .factory/ROUTES.txt || fail ".factory/ROUTES.txt is malformed"

echo "OK: plan gate passed"
