# shellcheck shell=bash
# Helpers that need neither Docker nor Syncthing, and those for claude-sync's own file.

die() {
    printf 'claude-sync: %s\n' "$*" >&2
    exit 1
}

# die for a mistake in the command line, such as an unknown or missing option or a value of
# the wrong form: exit status 2, which usage_error in claude-sync also exits with.
die_usage() {
    printf 'claude-sync: %s\n' "$*" >&2
    exit 2
}

# Whether COMMAND prints the line LINE. Not grep -q: it stops reading at the first match,
# and the command, killed by SIGPIPE writing its next line, fails the pipeline under pipefail.
prints_line() {
    local line=$1
    shift
    "$@" | grep -xF -- "$line" >/dev/null
}

# PATH with a leading ~ expanded where it stands for the home directory, alone or before a
# slash. ~NAME, which a shell reads as NAME's home, is left as it is.
expand_home() {
    if [[ $1 == \~ || $1 == \~/* ]]; then
        printf '%s\n' "$HOME${1#\~}"
    else
        printf '%s\n' "$1"
    fi
}

# PATH with its ~ expanded as expand_home does and, where it exists here, symlinks resolved:
# Syncthing follows a symlinked folder root.
real_path() {
    local path
    path=$(expand_home "$1")
    (cd -- "$path" 2>/dev/null && pwd -P) || echo "${path%/}"
}

# The nearest of PATH and its ancestors that is a directory here, or . for a relative PATH
# with none.
nearest_dir() {
    local path=$1
    while [[ ! -d $path ]]; do
        if [[ $path == */* ]]; then
            path=${path%/*}
            path=${path:-/}
        else
            path=.
        fi
    done
    printf '%s\n' "$path"
}

# PATH as real_path gives it, for a directory that may not exist yet: its nearest existing
# ancestor resolved, and the rest, which mkdir -p would make, cleaned.
planned_path() {
    local path base
    path=$(expand_home "$1")
    # So that cutting nearest_dir's . off the front never takes the dot of a hidden name such
    # as .cache.
    [[ $path == /* ]] || path=./$path
    base=$(nearest_dir "$path")
    clean_path "$(real_path "$base")/${path#"$base"}"
}

# Whether resolved PATH is DIR or inside it. The slash is dropped before adding one, so a DIR
# at / holds every path.
path_within() {
    [[ $1 == "$2" || $1 == "${2%/}"/* ]]
}

# Whether one of two resolved paths is the other or inside it, so both would sync the same
# files.
paths_overlap() {
    path_within "$1" "$2" || path_within "$2" "$1"
}

# PATH made absolute and cleaned as Docker cleans a bind mount's path: no ".", ".." or
# repeated or trailing slashes. Without needing it to exist here, since Docker resolves the
# path on its host, and in bash alone, since realpath's options differ between systems.
clean_path() {
    local path=$1 part parts cleaned=()
    [[ $path == /* ]] || path=$PWD/$path
    IFS=/ read -ra parts <<<"$path"
    for part in "${parts[@]}"; do
        case $part in
            '' | .) ;;
            ..) ((${#cleaned[@]} == 0)) || unset 'cleaned[${#cleaned[@]}-1]' ;;
            *) cleaned+=("$part") ;;
        esac
    done
    local IFS=/
    echo "/${cleaned[*]}"
}

# Dies when this claude-sync has no file to name: under bash -s, bash -c or bash <(...).
check_running_from_file() {
    [[ -f $claude_sync_file ]] || die "this claude-sync is not running from a file; save it to a file and run that"
}

# The file this claude-sync runs from, symlinks resolved.
installed_file() {
    readlink -f -- "$claude_sync_file"
}
