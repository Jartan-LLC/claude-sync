# shellcheck shell=bash
# Checks: each prints ok or FAIL and counts its failures, and the commands they test with.

failures=0

check() {
    local desc=$1
    shift
    if "$@" >/dev/null; then
        printf 'ok   %s\n' "$desc"
    else
        printf 'FAIL %s\n' "$desc"
        failures=$((failures + 1))
        # A red run or a mutation check needs only its first failure.
        [[ -z ${CLAUDE_SYNC_TEST_FAIL_FAST:-} ]] || exit 1
    fi
}

fails() {
    ! "$@" >/dev/null 2>&1
}

# Whether the command ran until its timeout cut it off, as a join that waits does.
cut_off() {
    "$@" >/dev/null 2>&1
    (($? == 124))
}

# Whether the command fails, saying MESSAGE.
fails_with() {
    fails_as "" "$@"
}

# Whether the command fails as claude-sync does for a mistake in its command line: with exit
# status 2, saying MESSAGE.
misused() {
    fails_as 2 "$@"
}

# fails_with, also checking that the exit status is STATUS unless STATUS is empty. On a
# failed check, the command's exit status and output go to stderr, which check leaves shown:
# they come just above the FAIL line.
fails_as() {
    local want=$1 message=$2 out status=0 lines
    shift 2
    out=$("$@" 2>&1) || status=$?
    ((status != 0)) && [[ -z $want || $status == "$want" ]] && grep -qF -- "$message" <<<"$out" && return
    mapfile -t lines <<<"$out"
    printf '     exited %s, saying:\n' "$status" >&2
    printf '     | %s\n' "${lines[@]}" >&2
    return 1
}

wait_for() {
    local i
    for ((i = 0; i < 120; i++)); do
        "$@" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

no_leftovers() {
    [ -z "$(ls -A "$TMPDIR")" ]
}

files_in() {
    find "$1" -mindepth 1 -maxdepth 1 | wc -l
}
