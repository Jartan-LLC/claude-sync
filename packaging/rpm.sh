#!/usr/bin/env bash
# Builds claude-sync's RPM from the commit checked out, as VERSION, into
# OUTDIR/claude-sync.noarch.rpm. Needs git and rpmbuild, as in CI's Fedora container.
# Usage: packaging/rpm.sh VERSION OUTDIR
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly root

die() {
    printf 'rpm.sh: %s\n' "$*" >&2
    exit 1
}

# In a container, the checkout belongs to another user than root, which git otherwise refuses.
git() {
    command git -C "$root" -c safe.directory='*' "$@"
}

(($# == 2)) || die "usage: packaging/rpm.sh VERSION OUTDIR"
# The version goes into sed and the spec before build.sh checks it.
[[ $1 =~ ^[0-9A-Za-z][0-9A-Za-z.+~-]*$ ]] || die "not a version: $1"
# RPM sorts ~ before a release, where a tag has -.
version=${1//-/\~} outdir=$2

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/SOURCES"
git archive --format=tar.gz --prefix="claude-sync-$version/" \
    -o "$work/SOURCES/claude-sync-$version.tar.gz" HEAD
git show HEAD:packaging/claude-sync.spec |
    sed "s/^Version:.*/Version:        $version/" >"$work/claude-sync.spec"
rpmbuild -bb --define "_topdir $work" "$work/claude-sync.spec"
mkdir -p -- "$outdir"
cp -- "$work"/RPMS/noarch/claude-sync-*.rpm "$outdir/claude-sync.noarch.rpm"
