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

# On a failed check, the command's exit status and output go to stderr, which check leaves
# shown: they come just above the FAIL line.
fails_with() {
    local message=$1 out status=0 lines
    shift
    out=$("$@" 2>&1) || status=$?
    ((status != 0)) && grep -qF -- "$message" <<<"$out" && return
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
