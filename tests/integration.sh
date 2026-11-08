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
readonly net=${prefix}net a=${prefix}a b=${prefix}b c=${prefix}c d=${prefix}d e=${prefix}e g=${prefix}g k=${prefix}k
readonly j=${prefix}j l=${prefix}l m=${prefix}m n=${prefix}n p=${prefix}p q=${prefix}q s=${prefix}s t=${prefix}t
readonly hu=${prefix}hu
readonly sx=${prefix}sx sy=${prefix}sy sz=${prefix}sz vol_sx=${prefix}sx-data vol_sy=${prefix}sy-data
readonly owner_sx=1470:1470 owner_sy=2580:2580
readonly v=${prefix}v w=${prefix}w vol_v=${prefix}v-data owner_v=3690:3690
readonly u=${prefix}u y=${prefix}y vol_u=${prefix}u-data owner_u=8642:8642
readonly listener=${prefix}listener foreign=${prefix}foreign h=${prefix}h host_image=${prefix}host
readonly vol_a=${prefix}a-data vol_b=${prefix}b-data vol_missing=${prefix}missing
readonly vol_root=${prefix}root-data vol_c=${prefix}c-data vol_d=${prefix}d-data
readonly vol_e=${prefix}e-data vol_g=${prefix}g-data vol_j=${prefix}j-data vol_l=${prefix}l-data
readonly vol_m=${prefix}m-data vol_n=${prefix}n-data vol_p=${prefix}p-data vol_q=${prefix}q-data vol_r=${prefix}r-data
readonly vol_t=${prefix}t-data vol_q_missing=${prefix}q-missing
# Not Syncthing's default 1000, so a match proves the owner was read from the target.
readonly owner_a=1234:1234 owner_b=2345:2345 owner_c=3456:3456 owner_d=4567:4567
readonly owner_e=6789:6789 owner_g=7890:7890 owner_j=8901:8901 owner_l=9012:9012 owner_m=5678:5678
readonly owner_n=1357:1357 owner_p=2468:2468 owner_q=4680:4680 owner_r=3579:3579 owner_t=5791:5791
readonly mount_a=type=volume,src=$vol_a mount_b=type=volume,src=$vol_b mount_c=type=volume,src=$vol_c
readonly mount_j=type=volume,src=$vol_j mount_l=type=volume,src=$vol_l mount_m=type=volume,src=$vol_m
readonly mount_n=type=volume,src=$vol_n mount_p=type=volume,src=$vol_p mount_r=type=volume,src=$vol_r
readonly mount_q=type=volume,src=$vol_q mount_t=type=volume,src=$vol_t
image=$(sed -n 's/^ *image: *//p' "$root/compose.yaml")
readonly image
[[ -n $image ]] || {
    echo "no image in compose.yaml" >&2
    exit 1
}
readonly bad_name=${prefix}BAD
export CLAUDE_SYNC_COMPOSE_OVERRIDE=$root/tests/compose.test.yaml
# For the compose overlays, which join the test network or the listener's.
export CLAUDE_SYNC_TEST_NET=$net CLAUDE_SYNC_TEST_LISTENER=$listener
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

# A relay on Docker's socket, such as a dev container's socat, can cut off a container's
# output after half a second while the command still succeeds.
out=$(docker run --rm --entrypoint sh "$image" -c 'sleep 1; echo ok')
[[ $out == ok ]] || {
    echo "Docker's output is cut short here; point DOCKER_HOST at the daemon's own socket" \
        "(in this repository's dev container, unix:///var/run/docker-host.sock)" >&2
    exit 1
}

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
        for node in "$a" "$b" "$c" "$d" "$e" "$g" "$j" "$l" "$m" "$n" "$p" "$q" "$t" "$v" "$sx" "$sy" "$sz" "$h" "$hu" "$u" "$y"; do
            docker logs --tail 30 "$node" 2>&1 | sed "s/^/[$node] /" || true
        done
        for out in "$scratch"/join-*.out; do
            [[ ! -s $out ]] || sed "s/^/[${out##*/}] /" "$out"
        done
    fi
    cleanup
    [[ -z $scratch ]] || rm -rf -- "$scratch"
}

scratch=""
cleanup
# -E carries the trap into functions; the subshell test skips command substitutions in
# check arguments, which fail on purpose. A group runs in a subshell of its own, whose
# level it stores in top.
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
long=projects/-work-$(printf '%060d' 0 | tr 0 x)/memory/a-note-whose-path-is-longer-than-a-tar-header.md
readonly long
in_target "$mount_q" "$fixture && chmod 600 .credentials.json && ln -s settings.json link.json &&
    mkdir -p .stversions \"\$(dirname '$long')\" && echo old >.stversions/settings.json && echo long >'$long' &&
    chown -R $owner_q /t"
in_target "$mount_r" "chown $owner_r /t"
in_target "$mount_b" "chown $owner_b /t"
in_target "type=volume,src=$vol_d" "chown $owner_d /t"
in_target "type=volume,src=$vol_u" "chown $owner_u /t"

# The groups below share only the test network, each with nodes and volumes of its own,
# so they run in parallel.
# Each runs in the background, its output in $scratch/NAME.log and its failure count in
# $scratch/NAME.failures; one that aborts writes no count.
declare -A group_of=()
run_group() {
    (
        # shellcheck disable=SC2034 # read by the ERR trap
        top=$BASH_SUBSHELL
        # Where setup writes its compose files, so checks can see it removes them.
        export TMPDIR=$scratch/tmp-$1
        mkdir "$TMPDIR"
        "group_$1"
        echo "$failures" >"$scratch/$1.failures"
    ) >"$scratch/$1.log" 2>&1 &
    group_of[$!]=$1
}

# status of instance NODE from the 0.4.0 build in $sdir, with the fake releases in LIST.
status_of() {
    CLAUDE_SYNC_RELEASES_API="file://$sdir/$2" CLAUDE_SYNC_NAME=$1 "$sdir/claude-sync" status
}

# Whether status of NODE prints a line that matches the extended regular expression RE.
status_says() {
    status_of "$1" releases.json | grep -E -- "$2" >/dev/null
}

# SX and SY: what status shows of an instance as it pairs and stops; SZ: of the host's own
# Syncthing.
group_status() {
    echo "# status"
    # This group's files; the helpers above use it.
    sdir=$scratch/status
    mkdir -p "$sdir/rpm" "$sdir/down" "$sdir/no-exec"
    "$root/packaging/build.sh" 0.4.0 "$sdir/claude-sync"
    releases_json "file://$sdir" >"$sdir/releases.json"
    # shellcheck disable=SC2016 # expanded by the fake rpm
    printf '#!/bin/sh\n[ "$1" = -qf ] && echo claude-sync-0.4.0-1.noarch\n' >"$sdir/rpm/rpm"
    printf '#!/bin/sh\nexit 1\n' >"$sdir/down/docker"
    # docker as it is when the container answers inspect but not exec.
    # shellcheck disable=SC2016 # expanded by the shim
    printf '#!/bin/sh\n[ "$1" = exec ] && exit 1\nexec %s "$@"\n' "$(command -v docker)" >"$sdir/no-exec/docker"
    chmod +x "$sdir/rpm/rpm" "$sdir/down/docker" "$sdir/no-exec/docker"

    out=$(status_of "$sx" releases.json) && status=0 || status=$?
    check "status of an instance not set up says how to set it up" grep -qF \
        "not set up on this host; CLAUDE_SYNC_NAME=$sx claude-sync setup --volume NAME or --path DIR sets it up" <<<"$out"
    check "  succeeding" [ "$status" = 0 ]
    check "  naming what chose the instance" grep -qE "^Instance: +$sx, named by CLAUDE_SYNC_NAME\$" <<<"$out"
    check "  with the installed version" grep -qE '^Installed: +claude-sync 0\.4\.0$' <<<"$out"
    check "  the newest release that is not breaking, with how to upgrade" \
        grep -qE '^Newer release: +claude-sync 0\.4\.1; run claude-sync upgrade$' <<<"$out"
    check "  and the newest breaking one, with its notes" grep -qF \
        "claude-sync 0.5.0, a breaking release; its release notes say how to upgrade: file://$sdir/releases/tag/v0.5.0" \
        <<<"$out"
    check "  and says nothing on stderr" [ -z "$(status_of "$sx" releases.json 2>&1 >/dev/null)" ]
    check "status when docker cannot be reached says so" fails_with "docker cannot be reached" \
        env PATH="$sdir/down:$PATH" CLAUDE_SYNC_RELEASES_API="file://$sdir/releases.json" \
        CLAUDE_SYNC_NAME="$sx" "$sdir/claude-sync" status
    check "status takes no arguments" fails_with "status takes no arguments" \
        claude_sync "$sx" status --volume "$vol_sx"

    docker volume create "$vol_sx" >/dev/null
    docker volume create "$vol_sy" >/dev/null
    # A conflict copy, and one in the trash can, which is an old version, not a conflict.
    in_target "type=volume,src=$vol_sx" "echo x >/t/notes.md &&
        echo older >/t/notes.sync-conflict-20261107-120000-AAAAAAA.md && mkdir /t/.stversions &&
        echo old >/t/.stversions/notes.sync-conflict-20261101-120000-AAAAAAA.md && chown -R $owner_sx /t"
    in_target "type=volume,src=$vol_sy" "chown $owner_sy /t"
    claude_sync "$sx" setup --volume "$vol_sx" --private >/dev/null 2>&1
    claude_sync "$sy" setup --volume "$vol_sy" --private >/dev/null 2>&1
    id_sx=$(docker exec -u "$owner_sx" "$sx" syncthing device-id)
    id_sy=$(docker exec -u "$owner_sy" "$sy" syncthing device-id)
    claude_sync "$sx" pair "$id_sy" --keep --address "tcp://$sy:22000" >/dev/null 2>&1
    pair_bounded "$sy" "$id_sx" --address "tcp://$sx:22000" >/dev/null 2>&1

    config_sx=$(st "$sx" "$owner_sx" config dump-json)
    out=$(status_of "$sx" releases.json) && status=0 || status=$?
    check "status of a running instance succeeds" [ "$status" = 0 ]
    check "  shows where Syncthing runs" grep -qE "^Syncthing: +in container $sx\$" <<<"$out"
    check "  what it syncs" grep -qE "^Syncs: +volume $vol_sx\$" <<<"$out"
    check "  its web UI" grep -qE '^Web UI: +http://127\.0\.0\.1:8384$' <<<"$out"
    check "  this device's ID" grep -qE "^Device ID: +$id_sx\$" <<<"$out"
    check "  the sync port" grep -qE '^Sync port: +22000$' <<<"$out"
    check "  that it is private" grep -qE '^Network: +private$' <<<"$out"
    check "  the conflict copies, leaving out the trash can" grep -qE '^Conflict copies: +1$' <<<"$out"
    local set_up_by=${CLAUDE_SYNC_BIN_VERSION:-dev}
    check "  which claude-sync set it up, with the setup that applies this version" grep -qE \
        "^Set up by: +claude-sync ${set_up_by//./\\.}; run CLAUDE_SYNC_NAME=$sx claude-sync setup to apply 0\.4\.0\$" <<<"$out"
    check "  and the paired device by its ID" grep -qE "^  (.* )?$id_sy\$" <<<"$out"
    check "  changing nothing in Syncthing" [ "$(st "$sx" "$owner_sx" config dump-json)" = "$config_sx" ]
    check "status shows the folder's state" wait_for status_says "$sx" '^Folder: +idle$'
    check "  and a paired device connected, how, and all it has" \
        wait_for status_says "$sx" "^    connected directly at [^ ]+:22000; has 100% of the folder\$"
    out=$(status_of "$sx" missing.json) && status=0 || status=$?
    check "status without the list of releases says it could not check" \
        grep -qE '^Newer release: +could not check$' <<<"$out"
    check "  and shows the rest" grep -qE "^Device ID: +$id_sx\$" <<<"$out"
    check "  succeeding" [ "$status" = 0 ]
    check "status of an RPM install says to upgrade with dnf" \
        grep -qE '^Newer release: +claude-sync 0\.4\.1; upgrade it with dnf' \
        <<<"$(env PATH="$sdir/rpm:$PATH" CLAUDE_SYNC_RELEASES_API="file://$sdir/releases.json" \
            CLAUDE_SYNC_NAME="$sx" "$sdir/claude-sync" status)"
    # The checkout's own script, whatever claude-sync the suite tests.
    out=$(CLAUDE_SYNC_RELEASES_API="file://$sdir/releases.json" CLAUDE_SYNC_NAME="$sx" "$root/claude-sync" status)
    check "status from a checkout leaves out the release check" fails grep -qE '^Newer release:' <<<"$out"
    check "status fails when the Syncthing in a running container does not answer" \
        fails_with "cannot reach Syncthing in container $sx" \
        env PATH="$sdir/no-exec:$PATH" CLAUDE_SYNC_RELEASES_API="file://$sdir/releases.json" \
        CLAUDE_SYNC_NAME="$sx" "$sdir/claude-sync" status

    # Syncthing's replies for a device through a relay, one that does not share the folder,
    # and one whose completion does not parse.
    cat >"$sdir/replies.sh" <<'EOF'
st() {
    case $* in
        "config folders claude-sync devices list") printf '%s\n' SELF-ID RELAYED-ID UNSHARED-ID ODD-ID ;;
        "config devices RELAYED-ID name get") echo laptop ;;
        *) echo ;;
    esac
}
rest() {
    case $1 in
        /rest/system/connections) cat <<'JSON' ;;
{
  "connections": {
    "ODD-ID": {
      "address": "192.0.2.3:22000",
      "connected": true,
      "type": "tcp-client"
    },
    "RELAYED-ID": {
      "address": "192.0.2.1:22067",
      "at": "2026-11-07T12:00:00Z",
      "connected": true,
      "paused": false,
      "type": "relay-client"
    },
    "UNSHARED-ID": {
      "address": "192.0.2.2:22000",
      "connected": true,
      "type": "tcp-server"
    }
  },
  "total": {
    "at": "2026-11-07T12:00:00Z",
    "inBytesTotal": 0
  }
}
JSON
        /rest/stats/device) echo '{}' ;;
        *UNSHARED-ID) printf '{\n  "completion": 0,\n  "remoteState": "notSharing"\n}\n' ;;
        *ODD-ID) printf '{\n  "completion": null,\n  "remoteState": "valid"\n}\n' ;;
        *) printf '{\n  "completion": 100,\n  "remoteState": "valid"\n}\n' ;;
    esac
}
EOF
    out=$(calls eval ". $(printf %q "$sdir/replies.sh") && device_status SELF-ID")
    check "status shows a device reached through a relay, by its name" grep -qx '  laptop RELAYED-ID' <<<"$out"
    check "  how" grep -qx '    connected through a relay at 192.0.2.1:22067; has 100% of the folder' <<<"$out"
    check "  one that does not share the folder" \
        grep -qx '    connected directly at 192.0.2.2:22000; does not share the folder' <<<"$out"
    check "  and one whose completion it cannot read" \
        grep -qx '    connected directly at 192.0.2.3:22000; completion unknown' <<<"$out"
    # shellcheck disable=SC2016 # expanded by the inner bash
    check "status shows a network setting other than public or private option by option" \
        [ "$(calls eval 'st() { if [ "$3" = relays-enabled ]; then echo false; else echo true; fi; }; network_setting')" \
        = "global discovery on, relays off, NAT traversal on" ]

    docker stop "$sy" >/dev/null
    check "status shows when a device it no longer reaches was last seen" wait_for status_says "$sx" \
        '^    not connected, last seen [0-9-]+T[0-9:]+Z; has 100% of the folder, as far as this device knows$'
    st "$sx" "$owner_sx" config folders claude-sync paused set true
    check "status of a paused folder says so" wait_for status_says "$sx" '^Folder: +paused$'
    out=$(status_of "$sx" releases.json) && status=0 || status=$?
    check "  with its devices' completion unknown" \
        grep -qE '^    not connected, last seen [0-9-]+T[0-9:]+Z; completion unknown$' <<<"$out"
    check "  succeeding" [ "$status" = 0 ]
    st "$sx" "$owner_sx" config folders claude-sync paused set false
    docker exec -u 0 "$sx" sh -c 'mkdir /var/syncthing/claude/sealed && chmod 700 /var/syncthing/claude/sealed'
    out=$(status_of "$sx" releases.json 2>&1) && status=0 || status=$?
    check "status says when it cannot count the conflict copies" \
        grep -qE '^Conflict copies: +could not search the synced folder; the message above says why$' <<<"$out"
    check "  with find's message" grep -qF "Permission denied" <<<"$out"
    check "  succeeding" [ "$status" = 0 ]
    st "$sx" "$owner_sx" config folders claude-sync delete
    out=$(status_of "$sx" releases.json 2>/dev/null) && status=0 || status=$?
    check "status of an instance whose folder was removed from Syncthing says how to add it again" grep -qE \
        "^Folder: +not in Syncthing; CLAUDE_SYNC_NAME=$sx claude-sync setup adds it again\$" <<<"$out"
    check "  with no devices" fails grep -qE '^Devices:' <<<"$out"
    check "  succeeding" [ "$status" = 0 ]
    check "  and leaves the folder out" fails grep -qx claude-sync <<<"$(st "$sx" "$owner_sx" config folders list)"
    out=$(status_of "$sy" releases.json) && status=0 || status=$?
    check "status of a stopped instance says how to start it" grep -qE \
        "^Syncthing: +in container $sy, stopped; CLAUDE_SYNC_NAME=$sy claude-sync setup starts it\$" <<<"$out"
    check "  succeeding" [ "$status" = 0 ]
    check "  and leaves it stopped" [ "$(docker inspect -f '{{.State.Running}}' "$sy")" = false ]

    echo "# status, on the host's Syncthing"
    docker run -d --name "$sz" --network "$net" --user user --entrypoint env "$host_image" \
        -u STHOMEDIR -u STGUIADDRESS HOME=/home/user syncthing serve --no-browser >/dev/null
    docker cp -q "$sdir/claude-sync" "$sz:/home/user/"
    docker exec -u 0 "$sz" chown user /home/user/claude-sync
    wait_for as_user "$sz" syncthing cli show version
    as_user "$sz" mkdir claude
    as_user "$sz" ./claude-sync setup --path claude --use-host-syncthing >/dev/null
    # A device on the unpaired list, which a command that acts on the instance would remove; SY, stopped, never
    # connects.
    as_user "$sz" syncthing cli config devices add --device-id "$id_sy"
    as_user "$sz" sh -c "mkdir claude/.claude-sync-unpaired && : >claude/.claude-sync-unpaired/$id_sy"
    out=$(as_user "$sz" env CLAUDE_SYNC_RELEASES_API=file:///nonexistent ./claude-sync status)
    check "status shows the host's own Syncthing" grep -qE '^Syncthing: +your own, on this host$' <<<"$out"
    check "  naming the default instance alone" grep -qE '^Instance: +claude-sync$' <<<"$out"
    check "  the directory it syncs" grep -qE '^Syncs: +directory /home/user/claude$' <<<"$out"
    check "  its web UI" grep -qE '^Web UI: +http://127\.0\.0\.1:8384$' <<<"$out"
    check "  that it is public" grep -qE '^Network: +public$' <<<"$out"
    check "  the version that set it up" grep -qE '^Set up by: +claude-sync 0\.4\.0$' <<<"$out"
    check "  and no devices" grep -qE '^Devices: +none$' <<<"$out"
    check "  and leaves the unpaired list unapplied" as_user "$sz" sh -c \
        "syncthing cli config devices list | grep -x $id_sy"
    as_user "$sz" syncthing cli config folders claude-sync devices add --device-id "$id_sy"
    out=$(as_user "$sz" env CLAUDE_SYNC_RELEASES_API=file:///nonexistent ./claude-sync status)
    check "status shows a device never seen, leaving out how much of the folder it has" \
        grep -qx '    not connected, never seen' <<<"$out"
    # The host's Syncthing as it is when not running: its config is there, its cli gets no
    # answer.
    # shellcheck disable=SC2016 # expanded by the shim
    printf '#!/bin/sh\n[ "$1" = cli ] && exit 1\nexec %s "$@"\n' "$(as_user "$sz" sh -c 'command -v syncthing')" |
        docker exec -i -u user -w /home/user "$sz" sh -c 'mkdir down && cat >down/syncthing && chmod +x down/syncthing'
    # shellcheck disable=SC2016 # expanded by the fixture's shell
    out=$(as_user "$sz" sh -c 'PATH=$HOME/down:$PATH CLAUDE_SYNC_RELEASES_API=file:///nonexistent ./claude-sync status') &&
        status=0 || status=$?
    check "status of the host's Syncthing when it is not running says to start it" \
        grep -qE '^Syncthing: +your own, on this host, not running as user; start it$' <<<"$out"
    check "  with what it syncs" grep -qE '^Syncs: +directory /home/user/claude$' <<<"$out"
    check "  succeeding" [ "$status" = 0 ]
}

run_group chain
run_group instances
run_group stuck
run_group refusals
run_group upgrade
run_group backups
run_group timer
run_group select
run_group status
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
