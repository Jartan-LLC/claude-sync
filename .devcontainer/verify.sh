#!/bin/bash
# Checks pnpm and what post-create.sh installs in the dev container. post-create.sh only
# reports its failures, so these checks are what fails on them. Run it in a fresh
# container: the last check expects a clean git status.

set -uo pipefail
failures=0
check() {  # description  command...
    if "${@:2}" >/dev/null 2>&1 </dev/null; then echo "ok    $1"; else echo "FAIL  $1"; failures=$((failures + 1)); fi
}

check "pre-commit hook wired" test -f "$(git rev-parse --git-path hooks)/pre-commit"
# Liza sets core.hooksPath in task worktrees; set here, make install skips pre-commit.
check "core.hooksPath unset" test -z "$(git config core.hooksPath)"
check "pnpm available" pnpm --version
check "git status clean" test -z "$(git status --porcelain)"
exit $((failures > 0))
