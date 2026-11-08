# shellcheck shell=bash
# Running the claude-sync under test, and copying it elsewhere.

claude_sync() {
    local node=$1
    shift
    CLAUDE_SYNC_NAME=$node "$bin" "$@"
}

# A joining device's pair blocks until caught up; a bound turns a hang into a failure.
# Not for a background pair: killing a backgrounded function leaves timeout and pair
# running, so background `timeout ... claude-sync pair` itself.
pair_bounded() {
    local node=$1
    shift
    CLAUDE_SYNC_NAME=$node timeout 300 "$bin" pair "$@"
}

# Copies this checkout's claude-sync into DIR with the files it reads beside it.
copy_checkout() {
    cp -r "$root/claude-sync" "$root/lib" "$root"/compose*.yaml "$root/stignore" "$1"
}

# Copies the claude-sync under test into DIR: the built file alone, or this checkout's.
copy_under_test() {
    if [[ -n ${CLAUDE_SYNC_BIN:-} ]]; then
        cp "$bin" "$1/claude-sync"
    else
        copy_checkout "$1"
    fi
}

# FILE's text run with ARGS from no file: HOW is stdin (bash -s), string (bash -c) or
# procsub (bash <(...)).
fileless() {
    local how=$1 file=$2
    shift 2
    case $how in
        stdin) bash -s "$@" <"$file" ;;
        string) bash -c "$(cat -- "$file")" _ "$@" ;;
        procsub) bash <(cat -- "$file") "$@" ;;
    esac
}

# A function of the claude-sync under test, run with its arguments.
calls() {
    # shellcheck disable=SC2016 # expanded by the inner bash
    bash -c 'source "$1" help >/dev/null && "${@:2}"' _ "$bin" "$@"
}
