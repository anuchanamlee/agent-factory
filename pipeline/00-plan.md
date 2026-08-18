# Phase 00 — plan

Turn the spec into the three files every later phase reads as ground truth.
Write no application code in this phase.

The spec may be written in Thai. Your output files may explain things in Thai,
but every identifier — file paths, table names, column names, route paths, env
var names, task ids — must be English.

## Produce exactly these files

### `PLAN.md`
The architecture the later phases build against. Cover, in this order:

- **Routes** — every URL from the spec, with its access level (public / requires
  login) and what it renders. Include the exact file path under `app/` that will
  serve it.
- **Data model** — one section per table: columns with SQLite types, NOT NULL,
  defaults, foreign keys, indexes. Name the migration file each table lands in.
- **Auth** — who can log in, how the session is checked, which routes the
  middleware protects.
- **File layout** — the directories you will create and what goes in each.
- **Uploads** — where image files are written on disk and how they are served,
  if the spec needs them.
- **Env vars** — every variable the app reads, what it is for, and whether it has
  a safe default.

Decide things. Do not list alternatives or leave a choice to a later phase.

### `TASKS.md`
The implementation checklist phase 30 works through. Every task is two lines:

```
- [ ] <id>: <one concrete change, small enough to finish in one sitting>
      verify: <a command or an observation that proves it works>
```

Rules the gate enforces:
- Every `- [ ]` line is immediately followed by a line whose first non-space
  token is `verify:`.
- No task, and no `verify:` line, may contain `TODO`, `FIXME`, `TBD`, `XXX`, or a
  `<placeholder>` in angle brackets.
- Ids are short and stable (`auth-1`, `products-3`), because notes and later
  phases refer to them.

Order tasks so each depends only on earlier ones. Cover every route, every table,
every acceptance step in the spec's "เสร็จ" section, and nothing beyond them.

### `CLAUDE.md`
Short — under 40 lines. What a later phase needs to not break things: the stack
as locked by the spec, the gotchas that already cost someone a day (they are
listed at the bottom of the spec — copy the ones that apply), the commands to
run (`npm run build`, `npm run migrate`, `npm run seed`), and the conventions you
chose (naming, where server-only code lives).

### `.factory/ROUTES.txt`
One line per route the smoke gate will request, `<path> <expected-status>`:

```
/ 200
/products/1 200
/admin 307
```

Use `307` (or `302`) for a route that redirects an anonymous visitor to login.
For a dynamic route, use an id the seed data will actually create. Include every
route in `PLAN.md` — the smoke gate cross-checks this file against the pages that
end up on disk and fails if a page is missing from it.

## Gate

`gates/plan.sh` checks that the four files exist, that every task has a `verify:`
line, and that no placeholder text survived. It cannot check whether the plan is
*good* — that is on you, and every later phase inherits whatever you decide here.
