# Phase 50 — deploy

Get the container running and prove the app is reachable through Caddy.

## Do

- Make `docker compose build` succeed on the `Dockerfile` from phase 10. Multi-stage
  if it keeps the image small; `node:22-bookworm-slim` as the base.
- Make `docker compose up -d` bring up web and caddy, with the database and the
  uploads directory on a volume so they survive a container replacement.
- Migrations run on container start, before the app serves traffic.
- The web service has a healthcheck that fails while the app is not answering.
- `.env.example` matches what the compose file actually reads. Someone copying it
  to `.env` and filling in the blanks must get a working stack.
- Write `DEPLOY.md`: the exact commands to bring this up on a fresh host, in
  order, with the manual steps (DNS, secrets, seeding the admin account) called
  out where they belong.

## Do not

Deploy to a production host from inside this phase. The gate deploys locally.
Pushing to a real server is a separate, human-triggered step — `gates/deploy.sh`
refuses to touch a VPS unless someone sets `FACTORY_CONFIRM_PROD=yes` by hand.

## Gate

`gates/deploy.sh` builds the images, brings the stack up, waits for health, and
requests `/` through Caddy expecting a 200. Then it tears the stack down. If the
container starts but the app never answers, that is a failure, not a slow start.
