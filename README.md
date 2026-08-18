# agent-factory

One spec file in, a deployed Next.js project out, with nobody watching.

`factory.sh` walks six phases. Each phase is a single headless `claude -p` call
followed by a verification gate that is an ordinary command with an exit code —
`next build`, a migration against an empty database, `curl` against a running
server. A phase is done when its gate passes, never because the model said so.

Why it is built this way, with sources: [`DESIGN.md`](DESIGN.md).

## Requirements

- Node 24 (`better-sqlite3` v12 ships prebuilt binaries for it)
- Docker with a running daemon — only the deploy phase needs it
- `claude` on your PATH, logged in

On a Claude Pro or Max subscription there is no per-token bill. The cost is quota
and wall-clock time, which is what the per-phase model table is for.

## Run

```bash
cp specs/_template.md specs/my-shop.md    # fill in the [บังคับ] sections
./factory.sh specs/my-shop.md --name my-shop
```

The project lands in `runs/my-shop/`. That directory is gitignored — it holds a
generated project, not this repo's source.

```bash
./factory.sh specs/my-shop.md --name my-shop --from 30-features   # resume
./factory.sh specs/my-shop.md --name my-shop --only 40-review     # one phase
```

Resuming works because nothing lives in a model's context: every phase reads
`PLAN.md`, `TASKS.md` and `.factory/NOTES.md` off disk. Close the laptop
mid-run and pick it up tomorrow.

## Phases

| # | Phase | Model | Gate — what actually runs |
|---|---|---|---|
| 00 | plan | opus / high | files exist, every task has a `verify:` line, no placeholder text survived |
| 10 | scaffold | sonnet / medium | `npm install` → `tsc --noEmit` → `next build` |
| 20 | data | opus / high | migrate an empty database, assert tables exist and `PRAGMA user_version` moved |
| 30 | features | sonnet / medium | no `- [ ]` left in `TASKS.md`, then build again |
| 40 | review | opus / high | start the server, request every route, compare status codes, read the log |
| 50 | deploy | opus / high | `docker compose up`, wait for health, `curl` through Caddy |

Model and effort per phase live in `pipeline/<phase>.conf`. Planning and review
get the expensive model because a mistake there is paid for by every phase after
it; scaffolding against a locked stack does not.

## Two things the gates refuse to trust

**The model's account of its own surface.** `gates/smoke.sh` finds pages by
walking `app/` and checks them against `.factory/ROUTES.txt`. A page added
without being declared fails the gate, so a phase cannot pass by under-reporting
what it built.

**Its judgement about production.** `gates/deploy.sh` will not touch a VPS unless
a human sets `FACTORY_CONFIRM_PROD=yes`. Deploying is a decision, not a build
step.

## Knobs

| Variable | Effect |
|---|---|
| `FACTORY_DRY_RUN=1` | build every prompt, run every gate, make no model call |
| `FACTORY_MODEL` / `FACTORY_EFFORT` | override every phase at once |
| `FACTORY_MAX_ATTEMPTS` | gate retries per phase (default 2) |
| `FACTORY_NOTES_LIMIT` | bytes of `NOTES.md` carried into a prompt (default 6000) |
| `FACTORY_DEPLOY_TARGET` | `local` (default) or `vps` |
| `FACTORY_VPS` / `FACTORY_CONFIRM_PROD` | required together to deploy to a host |

`FACTORY_DRY_RUN=1` is how you iterate on a phase prompt without spending quota:
the prompt is assembled and written to `runs/<name>/.factory/logs/`, and the gate
runs against whatever is on disk.

## Logs

```
runs/<name>/.factory/logs/<phase>-a<attempt>.prompt.md   what the model was told
runs/<name>/.factory/logs/<phase>-a<attempt>.out.txt     what it said
runs/<name>/.factory/logs/<phase>-a<attempt>.gate.txt    why the gate passed or failed
```

Three files per attempt, kept for every attempt. When a phase fails twice, these
are what tell you whether the prompt was wrong, the gate was wrong, or the model
was.

## If a phase keeps failing

Fix the phase prompt or tighten the gate. Do not raise `FACTORY_MAX_ATTEMPTS` —
a phase that needs four tries is a phase whose instructions or checks are wrong,
and more retries only buys the same failure at four times the price.

The dangerous failure is the opposite one: a gate that passes while the thing it
checks is broken. When you find one, the fix is a stricter gate, in the same
commit.
