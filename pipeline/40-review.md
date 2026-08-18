# Phase 40 — review

You are reading this project for the first time. Earlier phases claimed it is
done. Check whether that is true, and fix what is not.

## Review

Read `TASKS.md` and `PLAN.md`, then read the code that is supposed to implement
them. For each acceptance step in the spec's "เสร็จ" section, follow it through
the actual code and decide whether it works — not whether a box is ticked.

Look for the things a build passes straight through:

- A route that renders but queries the wrong column, or ignores its parameter.
- A form that posts to a handler that does not persist anything.
- A protected route the middleware does not actually cover.
- A query built by string interpolation instead of bound parameters.
- An upload path that writes outside the directory it is supposed to.
- A task ticked with no corresponding code.

Then fix what you find, in this project, now.

## Scope

Report and fix gaps against `TASKS.md` and the spec. Style, naming, structure,
and "this could be cleaner" are out of scope — a reviewer asked to find problems
will always find some, and acting on every one of them is how a working project
turns into a half-finished refactor.

If you find something wrong that you decide not to fix, write it in
`.factory/NOTES.md` with the reason. Do not leave it unsaid.

## Gate

`gates/smoke.sh` starts the real server against a freshly migrated and seeded
database, then requests every route in `.factory/ROUTES.txt` and compares the
status code. It also cross-checks that file against the pages on disk, so a route
you added without listing there fails the gate. Server-side errors in the log
fail it too.
