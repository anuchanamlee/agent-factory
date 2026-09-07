# Phase 10 — scaffold

Stand up an empty but complete project that builds. No features yet.

## Build

- **Next.js 16, App Router, TypeScript, Tailwind.** Set it up by hand rather than
  running an interactive generator — nothing can prompt you here.
- The directory layout from `PLAN.md`, with every directory it names created.
- `package.json` scripts: `dev`, `build`, `start`, plus placeholders for
  `migrate` and `seed` that phase 20 will fill in (they may exit 0 doing nothing
  for now, but the keys must exist).
  **`start` must be plain `next start` with no `-p` flag.** Next reads `PORT`
  from the environment, and the smoke gate starts the app on a port of its own
  choosing so it does not collide with anything already running. A hardcoded
  `-p 3000` there makes the gate wait 60 seconds for a server that is listening
  somewhere else, and then fail a phase that was fine.
- `proxy.ts` at the **repository root** — not under `src/` — even if it only
  passes everything through for now. Turbopack dev does not run it from `src/`,
  which means protected routes silently stop being protected.
- `next.config.ts` with `bcryptjs` in `serverExternalPackages`.
- `docker-compose.yml` (web + caddy) and a `Dockerfile` on `node:22-bookworm-slim`.
  A `Caddyfile` that reverse-proxies to the web container and serves the uploads
  directory. Phase 50 runs these; they must be correct now.
- `.env.example` listing every variable from `PLAN.md`, with values blank or safe
  defaults, and a comment for each.
- `.gitignore` covering `node_modules`, `.next`, the data directory, `.env`.
- Every route in `PLAN.md` as a real page file that renders a placeholder
  heading. The page must exist and compile; the content comes in phase 30.

`better-sqlite3` goes in `dependencies` at v12 — it ships prebuilt binaries for
current Node, and older majors will try to compile from source inside Docker.

## Do not

Write feature logic, real UI, database schema, or auth. A later phase owns each
of those, and code written here that they have to unpick costs more than it saves.

## Gate

`gates/build.sh` runs `npm install`, `tsc --noEmit`, and `npm run build`. All
three must pass on a clean checkout.
