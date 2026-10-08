# agent-factory

One spec file in, a deployed Next.js project out, with nobody watching: a bash orchestrator that drives the
`claude` CLI one phase at a time and believes only exit codes.

**Status:** solo project (Aug–Sep 2026), experimental. Supported platform: Windows + Git Bash.
No measured success rate is published yet (see [Limitations](#limitations)).

```bash
./tools/spec-lint.sh specs/minicat.md          # check a spec: reads the file, no model call
./test/harness-test.sh                         # orchestrator tests with a stub model - read "Safety" first
./factory.sh specs/minicat.md --name minicat   # a real run: spends Claude quota, needs Docker for phase 50
```

## How it works

`factory.sh` walks six phases. Each phase is a single headless `claude -p` call
followed by a verification gate that is an ordinary command with an exit code —
`next build`, a migration against an empty database, `curl` against a running
server. A phase is done when its gate passes, never because the model said so.

Why it is built this way, with sources: [`DESIGN.md`](DESIGN.md).

## Requirements

- Bash. Windows + Git Bash is the platform it was built and tested on: `powershell.exe` is used to find and stop
  leaked node processes, and on Linux/macOS that step silently does nothing (`factory.sh`, `node_snapshot` /
  `reap_project_processes`); two harness checks also need PowerShell
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

## Safety

Read this before running anything here on a machine you use for other work.

- **Leftover processes are stopped per phase, and only the phase's own.** Each model call runs inside a Windows
  Job Object (`tools/run-in-job.ps1`, `run_tracked` in `factory.sh`). Everything started from inside - including a
  `node server.js` the model leaves running in the background - belongs to the job and is terminated when the call
  ends. A process started by anything else is never in the job, so other apps on the machine are not affected
  (`test/reaper-test.sh` checks exactly that). Without `powershell.exe` nothing is cleaned up. Until 2026-10-08 the
  reaper instead killed every new `node.exe` on the machine during a phase.
- **The model gets a shell.** Phases run `claude -p` with the `Bash`, `Edit` and `Write` tools and
  `--permission-mode auto` by default (`FACTORY_PERM`). "Work only inside the current directory" is an
  instruction in the prompt, not a sandbox. For unattended runs, use a VM or container.
- **Deploying to a real host needs a human.** `gates/deploy.sh` refuses `FACTORY_DEPLOY_TARGET=vps` unless
  `FACTORY_CONFIRM_PROD=yes` is set.
- Run names are restricted to letters, digits, `.`, `_`, `-` because `measure.sh` deletes `runs/<name>-rN`
  before each run.

## Knobs

| Variable | Effect |
|---|---|
| `FACTORY_DRY_RUN=1` | build every prompt, run every gate, make no model call |
| `FACTORY_MODEL` / `FACTORY_EFFORT` | override every phase at once |
| `FACTORY_MAX_ATTEMPTS` | gate retries per phase (default 2) |
| `FACTORY_PERM` | `auto` (default), `acceptEdits` or `bypassPermissions` - the model's permission mode |
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

Every attempt also appends a row to `runs/<name>/.factory/metrics.tsv`:

```
started_at  phase  model  effort  attempt  result  seconds  prompt_bytes
```

## Writing a spec

```
./tools/spec-lint.sh specs/my-shop.md
```

Reads the file, calls no model, costs nothing. It says whether the mandatory
sections carry content, whether any part of the template was left unfilled, and
whether section 5 is written as steps a person can actually walk - phase 40
curls that list. What it cannot say is whether the content is any good.

The pipeline already refuses a bad spec, but it refuses it in phase 00, after a
model call. This answers from the file what the file can answer.

`/spec` (`.claude/skills/spec/`) interviews you and writes the file, pushing
back on the two things that cost the most later: an acceptance list nothing can
check, and an empty "what not to build".

## Testing the harness

```
./test/harness-test.sh
```

Seconds, no quota. `test/stub-claude.sh` stands in for the CLI and imitates a
model that answers while writing nothing, one whose account is empty, one
stopped by the session cap, one that leaves a server running behind it, and one
that writes the wrong file. The test then reads `metrics.tsv` — the row is what
a measurement is later computed from, so a wrong row is a wrong pass rate.

Also covered: a run name containing `../` is refused by both `factory.sh` and `measure.sh` before anything
is created or deleted.

`./test/reaper-test.sh` (also run by the harness): a phase leaks two servers and keeps working; one second in,
an unrelated node process starts outside the factory. Afterwards the leaked servers must be gone and the
unrelated process must still be running. It only ever stops processes it started itself, so it is safe to run
on a machine with other node programs.

Results on 2026-10-08 (Windows, Git Bash, Node 24): `reaper-test.sh` passed with PowerShell available, and
every node process that existed before the run was still alive after it; with the job disabled it fails, as it
should. The full harness was run only with `powershell.exe` hidden from `PATH` (other node apps were running on
that machine): every check passed except the three that need PowerShell (the file-lock pair and the
reaper-test call), and the leak check is vacuous in that mode. CI runs the full harness on a clean Windows
runner but has not run on GitHub yet.

Not covered by tests: the real gates against a real generated project, the deploy phase, and any real model.

`FACTORY_DRY_RUN=1` does not cover this ground: it skips the no-op check on
purpose and never reaches the code that reads the model's exit status. Those are
exactly the two paths that let a ruined run be reported as a result.

## Measuring it

One successful run says the pipeline *can* work. It does not say it works
reliably, which is the only thing that matters for something meant to run with
nobody watching.

```
./measure.sh specs/minicat.md --runs 3
./measure.sh specs/minicat.md --name minicat --summary-only   # report, no new runs
```

Each run gets its own `runs/<base>-rN` directory — a resumed run skips phases
that are already done and would report passes it did not earn. The summary gives
attempts and passes per phase, how often a phase passed first try, average
seconds, and where each run stopped.

Read it as: attempts above passes means that phase needed a retry — fix its
prompt, not `FACTORY_MAX_ATTEMPTS`. A run that stopped names the phase a human
had to rescue; that count is the one to drive to zero. And a phase that sailed
through while a later phase failed on its work is the first place to look for a
false pass.

It costs `runs x 6` phases of quota. `FACTORY_DRY_RUN=1` exercises the harness
without calling a model — every gate then fails, which is exactly what proves
the failure path records what it should.

## If a phase keeps failing

Fix the phase prompt or tighten the gate. Do not raise `FACTORY_MAX_ATTEMPTS` —
a phase that needs four tries is a phase whose instructions or checks are wrong,
and more retries only buys the same failure at four times the price.

The dangerous failure is the opposite one: a gate that passes while the thing it
checks is broken. When you find one, the fix is a stricter gate, in the same
commit.

## Key decisions

- **One fresh `claude -p` session per phase, state on disk.** No `--continue`/`--resume`; phases hand over through
  `PLAN.md`, `TASKS.md` and `.factory/NOTES.md`, so a run can be resumed with `--from` and long contexts never build up.
- **Exit codes, not the model, decide a pass.** Each gate is an ordinary script; the review phase is the only one
  that uses a model as a checker, and it is followed by real HTTP requests.
- **A phase that changed no file skips its gate**, and an exhausted quota exits 3, because both used to let a gate
  grade the previous phase's work and record a false pass (both covered by the harness).
- **Per-phase model and effort** (`pipeline/*.conf`): expensive model where a mistake propagates (plan, data, review,
  deploy), cheaper where the stack is locked.
- Background and sources (Thai): [`DESIGN.md`](DESIGN.md).

## Limitations

- No measured success rate yet: `measure.sh` exists, but this repository contains no completed measurement.
- Process cleanup only works on Windows (Job Objects via PowerShell); elsewhere leaked servers are not stopped.
- The generated stack is fixed (Next.js + SQLite + Docker/Caddy); specs are written in Thai.
- `shellcheck` is not part of the checks.

## License

License: not yet specified.
