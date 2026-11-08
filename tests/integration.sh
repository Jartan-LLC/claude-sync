#!/usr/bin/env bash
# Integration tests: claude-sync against real Syncthing containers on throwaway targets.
# Every container, volume, network and image this keeps is named claude-sync-test-*, and
# cleanup refuses anything else: a dev container may share the host's live Docker daemon,
# where a real ~/.claude volume lives.
# shellcheck source-path=SCRIPTDIR/..
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly root
# Another prefix keeps runs on one Docker daemon apart, such as mutation checks in parallel.
prefix=${CLAUDE_SYNC_TEST_PREFIX:-claude-sync-test-}
readonly prefix
[[ $prefix =~ ^claude-sync-test-[a-z0-9-]*$ ]] || {
    echo "CLAUDE_SYNC_TEST_PREFIX must start with claude-sync-test-: $prefix" >&2
    exit 1
}
readonly net=${prefix}net host_image=${prefix}host
image=$(sed -n 's/^ *image: *//p' "$root/compose.yaml")
readonly image
[[ -n $image ]] || {
    echo "no image in compose.yaml" >&2
    exit 1
}
export CLAUDE_SYNC_COMPOSE_OVERRIDE=$root/tests/compose.test.yaml
# For the compose overlay, which joins the test network.
export CLAUDE_SYNC_TEST_NET=$net
# claude-sync looks for a Syncthing of the user running it on this host; pointed at a
# home that does not exist, it never reaches a developer's own.
export STHOMEDIR=/nonexistent/${prefix}home
unset STCONFDIR STDATADIR STGUIADDRESS STGUIAPIKEY

for tool in docker jq cmp ps tar; do
    command -v "$tool" >/dev/null || {
        echo "tests/integration.sh needs $tool" >&2
        exit 1
    }
done
# wait -n -p, which collects the groups below, came in bash 5.1.
((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 501)) || {
    echo "tests/integration.sh needs bash 5.1 or newer" >&2
    exit 1
}

# Where each function was first defined. A file that defines one again would silently
# replace it, so the runner dies on that before any Docker call.
declare -A defined_at=()
defined_once() {
    local fns fn line file
    mapfile -t fns < <(compgen -A function)
    shopt -s extdebug
    while read -r fn line file; do
        file=${file#"$root/"}
        if [[ -z ${defined_at[$fn]:-} ]]; then
            defined_at[$fn]=$file:$line
        elif [[ ${defined_at[$fn]} != "$file:$line" ]]; then
            echo "$fn is defined in $file:$line and before that in ${defined_at[$fn]}" >&2
            exit 1
        fi
    done < <(declare -F "${fns[@]}")
    shopt -u extdebug
}

# Checked after each source line below, then after the runner's own functions.
trap defined_once RETURN

source "$root/tests/lib/checks.sh"
source "$root/tests/lib/sandbox.sh"
source "$root/tests/lib/nodes.sh"
source "$root/tests/lib/claude-sync.sh"
source "$root/tests/lib/claude-dir.sh"
source "$root/tests/lib/releases.sh"
source "$root/tests/groups/chain.sh"
source "$root/tests/groups/instances.sh"
source "$root/tests/groups/stuck.sh"
source "$root/tests/groups/refusals.sh"
source "$root/tests/groups/upgrade.sh"
source "$root/tests/groups/backups.sh"
source "$root/tests/groups/timer.sh"
source "$root/tests/groups/select.sh"
source "$root/tests/groups/status.sh"
trap - RETURN

# This run's live processes, each before its children, leaving out the subshell that lists
# them; a zombie is gone already, waiting only for its parent to collect it.
descendants() {
    local pid stat
    while read -r pid stat; do
        [[ $pid != "$BASHPID" && $stat != Z* ]] || continue
        echo "$pid"
        descendants "$pid"
    done < <(ps -o pid=,stat= --ppid "$1")
}

on_exit() {
    local status=$? node pids frozen=() i out
    # Stopped, a process starts no other, so freeze them all until no new one appears, then
    # end them: nothing then creates an object after cleanup. Bounded, so it cannot hang.
    for ((i = 0; i < 50; i++)); do
        mapfile -t pids < <(descendants $$)
        [[ ${pids[*]} != "${frozen[*]}" ]] || break
        kill -STOP "${pids[@]}" 2>/dev/null || true
        frozen=("${pids[@]}")
    done
    if ((${#frozen[@]})); then
        kill -TERM "${frozen[@]}" 2>/dev/null || true
        kill -CONT "${frozen[@]}" 2>/dev/null || true
    fi
    wait 2>/dev/null || true
    if ((status != 0)); then
        for node in "${registered_containers[@]}"; do
            docker container inspect "$node" >/dev/null 2>&1 || continue
            docker logs --tail 30 "$node" 2>&1 | sed "s/^/[$node] /" || true
        done
        for out in "$scratch"/join-*.out; do
            [[ ! -s $out ]] || sed "s/^/[${out##*/}] /" "$out"
        done
    fi
    cleanup
    [[ -z $scratch ]] || rm -rf -- "$scratch"
}

# Each group runs in the background, its output in $scratch/NAME.log and its failure count
# in $scratch/NAME.failures; one that aborts writes no count. The groups share only the
# test network and the host image, each with nodes and volumes of its own, so they run in
# parallel.
declare -A group_of=()
run_group() {
    (
        top=$BASH_SUBSHELL
        # Where setup writes its compose files, so checks can see it removes them.
        export TMPDIR=$scratch/tmp-$1
        mkdir "$TMPDIR"
        "group_$1"
        echo "$failures" >"$scratch/$1.failures"
    ) >"$scratch/$1.log" 2>&1 &
    group_of[$!]=$1
}
defined_once

# A test file the runner does not source is neither linted nor loaded: fails would pass
# on a helper missing from it, and a group in it would never run.
for file in "$root"/tests/lib/*.sh "$root"/tests/groups/*.sh; do
    rel=${file#"$root/"}
    grep -qxF "source \"\$root/$rel\"" "$root/tests/integration.sh" || {
        echo "tests/integration.sh does not source $rel; add: source \"\$root/$rel\"" >&2
        exit 1
    }
done
# The groups, one per file: tests/groups/NAME.sh defines group_NAME.
groups=()
for file in "$root"/tests/groups/*.sh; do
    group=${file##*/}
    group=${group%.sh}
    declare -F "group_$group" >/dev/null || {
        echo "tests/groups/$group.sh defines no group_$group" >&2
        exit 1
    }
    groups+=("$group")
done
# A prefixed name no own_* call registers would outlive the run, and the next run would
# reuse it: docker volume create takes an existing volume as it is.
while read -r var; do
    value=${!var:-}
    [[ $value == "$prefix"* && -z ${registered[$value]:-} ]] || continue
    [[ $value == "$prefix" || $value == "$net" || $value == "$host_image" ]] && continue
    echo "$var=$value is not registered: add it to an own_* call beside it" >&2
    exit 1
done < <(compgen -v)


# A relay on Docker's socket, such as a dev container's socat, can cut off a container's
# output after half a second while the command still succeeds.
out=$(docker run --rm --entrypoint sh "$image" -c 'sleep 1; echo ok')
[[ $out == ok ]] || {
    echo "Docker's output is cut short here; point DOCKER_HOST at the daemon's own socket" \
        "(in this repository's dev container, unix:///var/run/docker-host.sock)" >&2
    exit 1
}

scratch=""
cleanup
# -E carries the trap into functions; the subshell test skips command substitutions in
# check arguments, which fail on purpose. A group runs in a subshell of its own, whose
# level it stores in top.
# shellcheck disable=SC2034 # read by the ERR trap
top=0
set -E
trap '((BASH_SUBSHELL == top)) && echo "aborted at ${BASH_SOURCE[0]#"$root/"}:$LINENO${FUNCNAME:+ in ${FUNCNAME[0]}, called from ${BASH_SOURCE[1]#"$root/"}:${BASH_LINENO[0]}}" >&2' ERR
trap on_exit EXIT
scratch=$(mktemp -d -t "${prefix}XXXXXX")
# Where claude-sync keeps the selected instance, so no run reads or writes the user's own.
export XDG_CONFIG_HOME=$scratch/config
# The claude-sync under test: this checkout's, or with CLAUDE_SYNC_BIN the single file
# `make build` writes, alone in a directory so it can only use the files it carries.
if [[ -n ${CLAUDE_SYNC_BIN:-} ]]; then
    : "${CLAUDE_SYNC_BIN_VERSION:?the version CLAUDE_SYNC_BIN was built as}"
    mkdir "$scratch/bin"
    cp "$CLAUDE_SYNC_BIN" "$scratch/bin/claude-sync"
    bin=$scratch/bin/claude-sync
else
    bin=$root/claude-sync
fi
readonly bin

docker network create "$net" >/dev/null
docker volume create "$vol_a" >/dev/null
docker volume create "$vol_b" >/dev/null
docker volume create "$vol_root" >/dev/null
docker volume create "$vol_c" >/dev/null
docker volume create "$vol_d" >/dev/null
docker volume create "$vol_e" >/dev/null
docker volume create "$vol_g" >/dev/null
docker volume create "$vol_j" >/dev/null
docker volume create "$vol_l" >/dev/null
docker volume create "$vol_m" >/dev/null
docker volume create "$vol_n" >/dev/null
docker volume create "$vol_p" >/dev/null
# For the groups that run a host fixture.
docker build -q -t "$host_image" --build-arg IMAGE="$image" -f "$root/tests/host.Dockerfile" \
    "$root/tests" >/dev/null
docker volume create "$vol_q" >/dev/null
docker volume create "$vol_r" >/dev/null
docker volume create "$vol_t" >/dev/null
docker volume create "$vol_u" >/dev/null
in_target "type=volume,src=$vol_e" "echo e >/t/e-only.md && chown -R $owner_e /t"
in_target "type=volume,src=$vol_g" "echo 'g claude.json' >/t/claude.json && chown -R $owner_g /t"
in_target "$mount_l" "echo 'l claude.json' >/t/claude.json && chown -R $owner_l /t"
in_target "$mount_m" "chown $owner_m /t"
in_target "$mount_c" "chown $owner_c /t"
in_target "$mount_n" "chown $owner_n /t"
in_target "$mount_p" "chown $owner_p /t"
in_target "$mount_a" "$fixture && chown -R $owner_a /t"
# Q's fixture adds what an archive must carry as it is: a login only its owner reads, a
# symlink, a path too long for tar's basic header, and a file in the trash can.
in_target "$mount_q" "$fixture && chmod 600 .credentials.json && ln -s settings.json link.json &&
    mkdir -p .stversions \"\$(dirname '$long')\" && echo old >.stversions/settings.json && echo long >'$long' &&
    chown -R $owner_q /t"
in_target "$mount_r" "chown $owner_r /t"
in_target "$mount_b" "chown $owner_b /t"
in_target "type=volume,src=$vol_d" "chown $owner_d /t"
in_target "type=volume,src=$vol_u" "chown $owner_u /t"

for group in "${groups[@]}"; do run_group "$group"; done
# Each group's output as it ends.
while ((${#group_of[@]})); do
    wait -n -p done_pid || true
    name=${group_of[$done_pid]}
    unset "group_of[$done_pid]"
    cat "$scratch/$name.log"
    if [[ -s $scratch/$name.failures ]]; then
        failures=$((failures + $(<"$scratch/$name.failures")))
    else
        echo "group $name stopped early"
        failures=$((failures + 1))
    fi
    # The other groups are stopped on exit.
    ((failures == 0)) || [[ -z ${CLAUDE_SYNC_TEST_FAIL_FAST:-} ]] || break
done

((failures == 0)) || {
    echo "$failures check(s) failed" >&2
    exit 1
}
echo "all checks passed"
