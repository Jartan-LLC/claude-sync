#!/usr/bin/env bash
# Builds the single-file claude-sync: the script with its version, its own files and the
# lib files its SOURCES block lists built in, so it runs without this repository.
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
readonly markers=('^# BEGIN ASSETS' '^# END ASSETS$' '^# BEGIN SOURCES' '^# END SOURCES$')
at=()
for marker in "${markers[@]}"; do
    [[ $(grep -c -- "$marker" "$src") == 1 ]] || die "claude-sync needs exactly one line matching $marker"
    at+=("$(grep -n -- "$marker" "$src" | cut -d: -f1)")
done
((at[0] < at[1] && at[1] < at[2] && at[2] < at[3])) || die "claude-sync's markers are out of order: ${markers[*]}"

sources=()
while IFS= read -r line; do
    [[ $line =~ ^source\ \"\$here/(lib/[a-z0-9_-]+\.sh)\"$ ]] ||
        die "not a source line in claude-sync's SOURCES block: $line"
    f=${BASH_REMATCH[1]}
    [[ " ${sources[*]} " != *" $f "* ]] || die "$f is listed twice"
    [[ -f $root/$f ]] || die "$f is listed but missing"
    [[ -z $(tail -c 1 -- "$root/$f") ]] || die "$f does not end with a newline"
    sources+=("$f")
done < <(sed -n '/^# BEGIN SOURCES/,/^# END SOURCES$/{/^# BEGIN SOURCES/d;/^# END SOURCES$/d;p;}' "$src")
# With no lib file, an unmatched glob would otherwise reach grep as a literal file name.
shopt -s nullglob
libs=("$root"/lib/*.sh)
for f in "${libs[@]}"; do
    f=lib/${f##*/}
    [[ " ${sources[*]} " == *" $f "* ]] || die "$f is not listed in claude-sync's SOURCES block"
done
# A later definition silently replaces the earlier one, and neither bash -n nor shellcheck
# reports it.
dups=$(grep -ho '^[a-z_][a-z0-9_]*() {' "$src" "${libs[@]}" | sort | uniq -d)
[[ -z $dups ]] || die "functions defined twice in claude-sync and lib/: $dups"

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
    sed -n '/^# END ASSETS$/,/^# BEGIN SOURCES/{/^# END ASSETS$/d;/^# BEGIN SOURCES/d;p;}' "$src"
    for f in "${sources[@]}"; do
        cat -- "$root/$f"
    done
    sed '1,/^# END SOURCES$/d' "$src"
} >"$out.tmp"
chmod 755 "$out.tmp"
bash -n "$out.tmp"
mv -- "$out.tmp" "$out"
