# Phase 30 — features

Work through `TASKS.md` until every box is ticked.

## How to work

Take tasks in order. For each one: make the change, run its `verify:` line, and
only then tick the box to `- [x]`. A box ticked before its verify command passed
is worse than an unticked one — phase 40 trusts these marks when it decides what
to review.

Build the real thing: real pages, real queries, real forms, real error states.
The placeholder headings from phase 10 go away.

If a task turns out to be wrong — the plan missed something, two tasks conflict,
the spec implies work no task covers — fix it and say so. Edit `TASKS.md` to
match reality (add the task, split it, correct the verify line) and record the
change in `.factory/NOTES.md`. Do not silently skip a task, and do not tick a box
for work you did not do.

## Scope

The spec's "สิ่งที่ไม่ต้องทำ" section is binding. Build what the tasks describe
and stop there — no extra abstractions, no features nobody asked for, no error
handling for states that cannot occur. A bug fix does not need surrounding
cleanup, and a one-shot operation does not need a helper.

Match the code around you: the naming, the comment density, and the idiom already
in the repository from earlier phases.

## Gate

`gates/features.sh` fails if any `- [ ]` remains in `TASKS.md`, then runs the
build gate. Both have to pass.
