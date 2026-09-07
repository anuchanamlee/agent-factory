#!/usr/bin/env bash
# spec-lint.sh - say whether a spec is filled in enough to be worth running.
#
#   ./tools/spec-lint.sh specs/my-shop.md
#
# The pipeline already refuses a bad plan, but it refuses it in phase 00, after
# a model call. That is minutes and quota spent to be told a heading was left
# empty. Everything here is answerable by reading the file, so it is answered
# by reading the file.
#
# It checks that the mandatory sections carry content and that no part of the
# template survived unfilled. It cannot check whether the content is any good -
# that is what phase 00 is for.
set -uo pipefail

SPEC="${1:-}"
[ -n "$SPEC" ] || { echo "usage: ./tools/spec-lint.sh <spec.md>" >&2; exit 2; }
[ -f "$SPEC" ] || { echo "spec not found: $SPEC" >&2; exit 2; }

problems=0
warnings=0
fail() { printf 'FAIL  %s\n' "$*"; problems=$((problems + 1)); }
warn() { printf 'WARN  %s\n' "$*"; warnings=$((warnings + 1)); }
ok()   { printf 'ok    %s\n' "$*"; }

# The comments are instructions for whoever fills the form. They are stripped
# before the spec reaches a model, so they must not count as content here either
# - a section holding nothing but its own instructions is an empty section.
BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT
perl -0777 -pe 's/<!--.*?-->//gs' "$SPEC" > "$BODY"

# Everything under a numbered heading, up to the next one.
section() {
  awk -v n="$1" '
    $0 ~ "^## " n "\\." { grab = 1; next }
    /^## / { grab = 0 }
    grab { print }
  ' "$BODY"
}

# A section counts as filled when something is left after the headings, table
# scaffolding, bullet markers and blank lines come out.
filled() {
  section "$1" \
    | grep -vE '^\s*$|^\|[- |]*\|$|^[-*]\s*$|^[0-9]+\.\s*$|^###\s*$' \
    | grep -qE '[^[:space:]|.-]'
}

echo "── $SPEC ──"

title="$(grep -m1 '^# ' "$BODY" | sed 's/^# //')"
case "$title" in
  ''|'<'*) fail "the title is still the template's placeholder - name the project" ;;
  *) ok "title: $title" ;;
esac

for n in 1 2 3 4 5; do
  name="$(grep -m1 "^## $n\." "$SPEC" | sed 's/^## [0-9]*\. *//; s/\[บังคับ\] *//')"
  if filled "$n"; then ok "section $n filled — $name"
  else fail "section $n is empty — $name"; fi
done

# Leftovers from the template. Each one means a question nobody answered, and
# phase 00 would read them as real instructions.
for marker in '<ชื่อตาราง' '<ตารางถัดไป>' '/xxx' '<ชื่อโปรเจค>'; do
  if grep -qF "$marker" "$BODY"; then
    fail "template placeholder left in the file: $marker"
  fi
done

# Section 2 is what phase 40 turns into a list of routes to curl. One row is a
# spec that forgot the rest of the site.
routes="$(section 2 | grep -cE '^\|\s*`?/' || true)"
[ "$routes" -ge 2 ] && ok "section 2 lists $routes routes" \
                    || fail "section 2 lists $routes route(s) - list every URL, including /admin"

# Section 3 needs at least one named table with fields under it.
tables="$(section 3 | grep -cE '^### ' || true)"
[ "$tables" -ge 1 ] && ok "section 3 defines $tables table(s)" \
                    || fail "section 3 defines no table - name each one with '### <table>'"

# Section 5 is the acceptance list. It is the only place that says what "done"
# means, and phase 40 walks it. Three steps is not a rule, it is the point where
# a spec stops being a wish.
steps="$(section 5 | grep -cE '^[0-9]+\.\s*\S' || true)"
[ "$steps" -ge 3 ] && ok "section 5 has $steps acceptance steps" \
                   || fail "section 5 has $steps step(s) - write them as things a person can do and check"

# Not mandatory, but the section that keeps a project from growing sideways.
if section 7 | grep -qE '^[-*]\s*\S'; then
  ok "section 7 says what not to build"
else
  warn "section 7 is empty - without it the agent decides for itself what else to add"
fi

# A spec is pasted into every prompt of every phase and every retry. A secret in
# here is a secret in the logs, several times over.
if grep -inE '(api[_-]?key|secret|token|password|passwd)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9_/+.-]{12,}' "$BODY"; then
  fail "that looks like a real secret - put the variable name here and the value in .env"
fi

echo
if [ "$problems" -gt 0 ]; then
  echo "$problems problem(s), $warnings warning(s) - fix these before spending a model call"
  exit 1
fi
echo "spec looks complete${warnings:+ ($warnings warning(s))}"
exit 0
