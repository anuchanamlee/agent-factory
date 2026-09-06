#!/usr/bin/env bash
# A stand-in for the `claude` CLI, so the orchestrator's reaction to a model can
# be tested without spending quota on a real one.
#
# factory.sh calls `claude` by name, so a test puts the directory holding a copy
# of this file named `claude` at the front of PATH. harness-test.sh does that.
#
# STUB_MODE picks which model behaviour to imitate:
#
#   noop   answers plausibly and touches no file. This is the shape of the false
#          pass found on 19 Aug: a phase that did nothing while the gate graded
#          the previous phase's work and called it a pass.
#   quota  prints what the CLI prints when the account is out of quota and exits
#          non-zero. Both halves matter: quota_stopped() only believes a
#          non-zero exit, because the same words inside a normal answer are the
#          model talking about limits.
#   write  creates a file and exits 0, so the tree changes and the gate runs.
#          The gate still fails - the file is not what the phase was asked for -
#          which is how the ordinary failure path gets exercised.
set -euo pipefail

case "${STUB_MODE:-noop}" in
  noop)
    echo "I reviewed the plan. Everything looks fine."
    exit 0
    ;;
  quota)
    echo "Claude usage limit reached. Your limit will reset at 3pm."
    exit 1
    ;;
  write)
    echo "Wrote some notes."
    printf 'stub was here\n' > stub-output.txt
    exit 0
    ;;
  *)
    echo "stub-claude: unknown STUB_MODE: ${STUB_MODE:-}" >&2
    exit 64
    ;;
esac
