#!/usr/bin/env bash
# Builds the single-file claude-sync: the script with its version and its own files built
# in, so it runs without this repository.
# Usage: packaging/build.sh VERSION OUT
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly root
readonly assets=(compose.yaml compose.path.yaml compose.volume.yaml stignore)
readonly delimiter=CLAUDE_SYNC_ASSET

die() {
    printf 'build.sh: %s\n' "$*" >&2
    exit 1
}

(($# == 2)) || die "usage: packaging/build.sh VERSION OUT"
readonly version=$1 out=$2
# The version is written into the script as code.
[[ $version =~ ^[0-9A-Za-z][0-9A-Za-z.+~-]*$ ]] || die "not a version: $version"

src=$root/claude-sync
for marker in '^# BEGIN ASSETS' '^# END ASSETS$'; do
    [[ $(grep -c -- "$marker" "$src") == 1 ]] || die "claude-sync needs exactly one line matching $marker"
done

# shellcheck disable=SC2016 # each $1 is the built script's, not this one's
block() {
    printf 'readonly claude_sync_version=%s\n' "$version"
    printf '%s\n' "# Prints one of claude-sync's own files, built in by packaging/build.sh." \
        'asset() {' '    case $1 in'
    local f
    for f in "${assets[@]}"; do
        ! grep -qx -- "$delimiter" "$root/$f" || die "$f has a line $delimiter, which would end it early"
        # The here-document adds a final newline of its own.
        [[ -z $(tail -c 1 -- "$root/$f") ]] || die "$f does not end with a newline"
        printf '        %s)\n' "$f"
        printf "            cat <<'%s'\n" "$delimiter"
        cat -- "$root/$f"
        printf '%s\n            ;;\n' "$delimiter"
    done
    printf '%s\n' '        *)' \
        '            echo "claude-sync: no file $1 built in" >&2' \
        '            return 1' '            ;;' '    esac' '}'
}

mkdir -p -- "$(dirname -- "$out")"
trap 'rm -f -- "$out.tmp"' EXIT
{
    sed '/^# BEGIN ASSETS/,$d' "$src"
    block
    sed '1,/^# END ASSETS$/d' "$src"
} >"$out.tmp"
chmod 755 "$out.tmp"
bash -n "$out.tmp"
mv -- "$out.tmp" "$out"
