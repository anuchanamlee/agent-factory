# Phase 20 — data

Make the database real: schema, migration runner, auth, seed.

## Build

**Migrations.** `.sql` files in `migrations/`, named so they sort in apply order
(`001-products.sql`). One concern per file. The tables, columns, types, and
indexes are the ones in `PLAN.md` — if you find a problem with that schema, fix
it here and record what changed and why in `.factory/NOTES.md`.

**Migration runner.** A script wired to `npm run migrate` that:
- reads `PRAGMA user_version` to find where the database is,
- applies only the migrations after that point, in order, each in a transaction,
- sets `PRAGMA user_version` to the highest applied number,
- is safe to run twice — the second run applies nothing and exits 0,
- creates the database file and its parent directory if they do not exist.

It must honour `DATABASE_PATH` from the environment, because the gate points it at
a throwaway database rather than your development one.

**Data access.** `better-sqlite3` with raw parameterized SQL. No ORM, no query
builder. Every value that came from a request is a bound parameter — string
interpolation into SQL is how this project gets an injection bug.

**Auth.** NextAuth v5 credentials against the users table, passwords hashed with
`bcryptjs`. No signup page — accounts are created by the seed script or a CLI.
Fill in `proxy.ts` so it actually protects the routes `PLAN.md` marks as
requiring login, and redirects anonymous visitors to the login page.

**Seed.** `npm run seed` creates the admin account and enough rows for every
route in `.factory/ROUTES.txt` to return its expected status. The dynamic-route
ids listed there have to exist after seeding. Idempotent: running it twice must
not duplicate rows or fail.

## Gate

`gates/data.sh` runs your migrations against an empty database, then asserts that
tables exist and that `PRAGMA user_version` was bumped, then runs the build gate
again. A migration runner that forgets `user_version` fails here, because a
second deploy would replay every migration.
