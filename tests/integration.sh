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

# A relay on Docker's socket, such as a dev container's socat, can cut off a container's
# output after half a second while the command still succeeds.
out=$(docker run --rm --entrypoint sh "$image" -c 'sleep 1; echo ok')
[[ $out == ok ]] || {
    echo "Docker's output is cut short here; point DOCKER_HOST at the daemon's own socket" \
        "(in this repository's dev container, unix:///var/run/docker-host.sock)" >&2
    exit 1
}

# A directory tree as a restore must give it back: each entry's type, mode and path, and each
# file's mtime and contents. Not owners, which come from the target. The same commands run
# on a volume, in the image, and on a directory here.
# shellcheck disable=SC2016 # expanded by sh
readonly tree='cd "$1" && find . -exec stat -c "%A %n" {} + | LC_ALL=C sort &&
    find . -type f -exec stat -c "%Y %n" {} + | LC_ALL=C sort &&
    find . -type f -exec sha256sum {} + | LC_ALL=C sort'

volume_tree() {
    docker run --rm --entrypoint sh --mount "$1,dst=/t" "$image" -c "$tree" sh /t
}

dir_tree() {
    sh -c "$tree" sh "$1"
}

# grep reads all of the listing: -q would stop at the match, and tar, still listing, would
# die of SIGPIPE and fail the pipeline.
in_archive() {
    tar -tzf "$1" | grep -xF -- "$2" >/dev/null
}

# The NAMES still in DIR.
left_of() {
    local dir=$1 name
    shift
    for name; do
        [[ ! -e $dir/$name ]] || echo "$name"
    done
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

# Q: backup and restore of a folder with every kind of file, then restore on Q once it is
# paired with T.
group_backups() {
    # Restored modes are the archive's less the umask, as with any tar.
    umask 022
    echo "# backup"
    check "backup before setup is refused" fails_with "run setup first" \
        claude_sync "$q" backup "$scratch/backups"
    claude_sync "$q" setup --volume "$vol_q" --private >/dev/null
    wait_for owned_by "$mount_q" .stfolder "$owner_q"
    original=$(volume_tree "$mount_q")
    # Another umask than the group's, so a mode set by claude-sync cannot match it by chance.
    out=$(umask 027 && claude_sync "$q" backup "$scratch/backups")
    archive=$(find "$scratch/backups" -name '*.tar.gz')
    check "backup writes an archive named after the instance and the time" \
        grep -qxE "$q-[0-9]{8}T[0-9]{6}Z\.tar\.gz" <<<"${archive##*/}"
    check "  and says where" grep -qF "$archive" <<<"$out"
    check "  and nothing else" [ "$(files_in "$scratch/backups")" = 1 ]
    check "  with the umask's default mode" [ "$(stat -c %a "$archive")" = 640 ]
    check "the archive holds the login" in_archive "$archive" ./.credentials.json
    check "  and the trash can" in_archive "$archive" ./.stversions/settings.json
    check "backup leaves the folder as it was" [ "$(volume_tree "$mount_q")" = "$original" ]
    # The folder is a volume, which no directory here is in: this docker runs the search for
    # backup's probe in a directory here instead of the folder, then, with FIND_SAYS set,
    # prints it and exits 1, as BusyBox's find when files went as it searched.
    mkdir -p "$scratch/probe-bin" "$scratch/folder/sub"
    cat >"$scratch/probe-bin/docker" <<EOF
#!/bin/sh
if [ "\$1" = exec ] && [ "\$5" = find ]; then
    shift 6
    find "$scratch/folder" "\$@" || exit
    [ -z "\$FIND_SAYS" ] || { printf '%s\n' "\$FIND_SAYS" >&2; exit 1; }
    exit 0
fi
exec "$(command -v docker)" "\$@"
EOF
    chmod +x "$scratch/probe-bin/docker"
    # shellcheck disable=SC2329 # called below; ShellCheck cannot follow run_group
    backup_in_folder() {
        env PATH="$scratch/probe-bin:$PATH" CLAUDE_SYNC_NAME="$q" "$bin" backup "$@"
    }
    check "a container backup into its synced folder is refused" fails_with "is in the synced folder" \
        backup_in_folder "$scratch/folder/sub"
    check "  and into a directory in it not made yet" fails_with "is in the synced folder" \
        backup_in_folder "$scratch/folder/sub/backups"
    check "  without making it" [ ! -e "$scratch/folder/sub/backups" ]
    check "  or leaving its probe there" [ "$(files_in "$scratch/folder/sub")" = 0 ]
    check "a container backup passes find's status 1 for files that went as it searched" \
        env FIND_SAYS="find: /var/syncthing/claude/jobs/gone: No such file or directory" \
        PATH="$scratch/probe-bin:$PATH" CLAUDE_SYNC_NAME="$q" "$bin" backup "$scratch/searched"
    check "  but not for another error" fails_with "could not search the synced folder" \
        env FIND_SAYS="find: /var/syncthing/claude/jobs: Permission denied" \
        PATH="$scratch/probe-bin:$PATH" CLAUDE_SYNC_NAME="$q" "$bin" backup "$scratch/unsearched"
    # Files that come and go as backup reads the folder, as temporary files do. Beside large
    # files, so tar reads for long enough that files it listed go before it opens them. In a
    # directory Syncthing ignores.
    churn=/var/syncthing/claude/jobs/churn/tmp
    docker exec -u "$owner_q" "$q" sh -c "mkdir -p $churn && touch /tmp/churning &&
        for i in 1 2 3 4 5; do head -c 5000000 /dev/urandom >$churn/big\$i; done"
    docker exec -u "$owner_q" "$q" sh -c "i=0; while [ -e /tmp/churning ]; do
        i=\$((i + 1)); echo x >$churn/t\$i; rm -f $churn/t\$((i - 20)); done" &
    churning=$!
    wait_for docker exec "$q" sh -c "ls $churn | grep -q '^t[0-9]\{3\}'"
    if claude_sync "$q" backup "$scratch/busy" >/dev/null 2>"$scratch/busy.err"; then busy=ok; else busy=failed; fi
    docker exec -u "$owner_q" "$q" rm /tmp/churning
    wait "$churning" || true
    check "backup takes files that go as tar reads the folder" [ "$busy" = ok ]
    check "  after tar found some gone" grep -qF "No such file or directory" "$scratch/busy.err"
    check "  in a whole archive" in_archive "$(find "$scratch/busy" -name '*.tar.gz')" ./jobs/churn/tmp/big5
    in_target "$mount_q" "echo locked >/t/jobs/churn/tmp/locked && chmod 000 /t/jobs/churn/tmp/locked"
    check "a file the folder's owner cannot read fails backup" fails_with "tar could not archive" \
        claude_sync "$q" backup "$scratch/unreadable"
    check "  leaving no partial archive" [ "$(files_in "$scratch/unreadable")" = 0 ]
    in_target "$mount_q" "rm -r /t/jobs/churn"

    echo "# restore"
    # Run as T, which is not set up yet: restore needs no instance.
    check "restore into a fresh volume" claude_sync "$t" restore "$archive" --volume "$vol_r"
    check "  gives back the folder as it was" [ "$(volume_tree "$mount_r")" = "$original" ]
    check "  owned by the volume's owner" owned_by "$mount_r" settings.json "$owner_r"
    check "restore into a fresh directory" claude_sync "$t" restore "$archive" --path "$scratch/restored"
    check "  gives back the folder as it was" [ "$(dir_tree "$scratch/restored")" = "$original" ]
    check "a missing archive is refused" fails_with "no file $scratch/none.tar.gz" \
        claude_sync "$t" restore "$scratch/none.tar.gz" --path "$scratch/restored"
    head -c "$(($(stat -c %s "$archive") / 2))" "$archive" >"$scratch/truncated.tar.gz"
    mkdir "$scratch/untouched"
    check "a truncated archive is refused" fails_with "cannot read $scratch/truncated.tar.gz" \
        claude_sync "$t" restore "$scratch/truncated.tar.gz" --path "$scratch/untouched"
    check "  before writing anything" [ "$(files_in "$scratch/untouched")" = 0 ]
    check "a missing volume is refused" fails_with "no Docker volume named $vol_q_missing" \
        claude_sync "$t" restore "$archive" --volume "$vol_q_missing"
    check "  and is not created" fails docker volume inspect "$vol_q_missing"
    check "a root-owned volume is refused" fails_with "owned by root" \
        claude_sync "$t" restore "$archive" --volume "$vol_t"
    check "a restore with no target is refused" fails claude_sync "$t" restore "$archive"
    check "a restore given both a volume and a directory is refused" fails_with "give only one of" \
        claude_sync "$t" restore "$archive" --volume "$vol_r" --path "$scratch/restored"
    check "a target with no value is refused" fails_with "--path needs a value" \
        claude_sync "$t" restore "$archive" --path
    check "an unknown flag is refused" fails_with "unknown argument: --into" \
        claude_sync "$t" restore "$archive" --into "$scratch/restored"

    echo "# backup retention"
    # Empty stand-ins, as backup reads only the names. In 2025, before any run of this test.
    # The 9th of March is a Sunday, the 10th a Monday.
    old=("$q-20250115T120000Z.tar.gz" "$q-20250228T120000Z.tar.gz" "$q-20250309T235959Z.tar.gz"
        "$q-20250310T000000Z.tar.gz" "$q-20250312T120000Z.tar.gz")
    # Another instance's, one whose name starts with this one's, and files of other shapes.
    others=("$t-20250101T000000Z.tar.gz" "$q-work-20250101T000000Z.tar.gz" "$q-20250101.tar.gz" notes.txt)
    mkdir "$scratch/keep-3-3"
    (cd "$scratch/keep-3-3" && touch -- "${old[@]}" "${others[@]}")
    out=$(claude_sync "$q" backup "$scratch/keep-3-3" --keep-weekly 3 --keep-monthly 3)
    check "--keep-weekly 3 --keep-monthly 3 keeps the newest archive of the last 3 weeks and months" \
        [ "$(left_of "$scratch/keep-3-3" "${old[@]}")" = "$(printf '%s\n' "${old[1]}" "${old[2]}" "${old[4]}")" ]
    check "  beside the new one" [ "$(files_in "$scratch/keep-3-3")" = 8 ]
    check "  and says which it removed" grep -qF "$scratch/keep-3-3/${old[3]}" <<<"$out"
    check "  leaving other files alone" [ "$(left_of "$scratch/keep-3-3" "${others[@]}")" = "$(printf '%s\n' "${others[@]}")" ]
    old=("$q-20250115T120000Z.tar.gz" "$q-20250215T120000Z.tar.gz" "$q-20250315T120000Z.tar.gz"
        "$q-20250415T120000Z.tar.gz" "$q-20250515T120000Z.tar.gz" "$q-20250615T120000Z.tar.gz"
        "$q-20250702T120000Z.tar.gz" "$q-20250709T120000Z.tar.gz" "$q-20250716T120000Z.tar.gz"
        "$q-20250723T120000Z.tar.gz")
    mkdir "$scratch/keep-default"
    (cd "$scratch/keep-default" && touch -- "${old[@]}")
    claude_sync "$q" backup "$scratch/keep-default" >/dev/null
    check "by default it keeps 4 weeks and 6 months" \
        [ "$(left_of "$scratch/keep-default" "${old[@]}")" = "$(printf '%s\n' "${old[@]:2:4}" "${old[@]:7}")" ]
    mkdir "$scratch/keep-0-0"
    touch "$scratch/keep-0-0/${old[9]}"
    claude_sync "$q" backup "$scratch/keep-0-0" --keep-weekly 0 --keep-monthly 0 >/dev/null
    check "--keep-weekly 0 --keep-monthly 0 removes every older archive" [ ! -e "$scratch/keep-0-0/${old[9]}" ]
    check "  and keeps the new one" [ "$(files_in "$scratch/keep-0-0")" = 1 ]
    check "a count that is not a number is refused" fails_with "--keep-weekly takes" \
        claude_sync "$q" backup "$scratch/keep-0-0" --keep-weekly x
    check "  and so is one over 9999" fails_with "--keep-monthly takes" \
        claude_sync "$q" backup "$scratch/keep-0-0" --keep-monthly 10000
    check "  and one below 0" fails_with "--keep-weekly takes" \
        claude_sync "$q" backup "$scratch/keep-0-0" --keep-weekly -1
    check "a count of 9999 is taken" claude_sync "$q" backup "$scratch/keep-9999" --keep-weekly 9999
    check "a count with no value is refused" fails_with "--keep-monthly needs a value" \
        claude_sync "$q" backup "$scratch/keep-0-0" --keep-monthly
    check "an unknown flag is refused" fails_with "unknown argument: --keep-daily" \
        claude_sync "$q" backup "$scratch/keep-0-0" --keep-daily 3
    check "backup with no directory prints the usage" fails_with "Usage:" claude_sync "$q" backup
    # A clock that gives the same second for each run, as when backup runs twice within one.
    mkdir "$scratch/fixed-date" "$scratch/same-second"
    printf '#!/bin/sh\necho 20250101T000000Z\n' >"$scratch/fixed-date/date"
    chmod +x "$scratch/fixed-date/date"
    echo stand-in >"$scratch/same-second/$q-20250101T000000Z.tar.gz"
    check "an archive already named for this second is refused" fails_with "already exists; rerun in a second" \
        env PATH="$scratch/fixed-date:$PATH" CLAUDE_SYNC_NAME="$q" "$bin" backup "$scratch/same-second"
    check "  and left as it was" [ "$(cat "$scratch/same-second/$q-20250101T000000Z.tar.gz")" = stand-in ]
    # Temporary files of backups stopped before they could remove them: one untouched since
    # 2025, one still being written, and one of an instance whose name starts with this one's.
    stale=.$q-20250101T000000Z.tar.gz.123 writing=.$q-20250102T000000Z.tar.gz.456
    others_stale=.$q-work-20250101T000000Z.tar.gz.789
    mkdir "$scratch/stopped"
    (cd "$scratch/stopped" && touch -t 202501010000 -- "$stale" "$others_stale" && touch -- "$writing")
    out=$(claude_sync "$q" backup "$scratch/stopped")
    check "backup removes a temporary file that a backup stopped a day ago left" [ ! -e "$scratch/stopped/$stale" ]
    check "  and says so" grep -qF "Removed $scratch/stopped/$stale." <<<"$out"
    check "  keeping one still being written" [ -e "$scratch/stopped/$writing" ]
    check "  and another instance's" [ -e "$scratch/stopped/$others_stale" ]

    echo "# restore, on a paired device"
    in_target "$mount_t" "chown $owner_t /t"
    claude_sync "$t" setup --volume "$vol_t" --private >/dev/null
    id_q=$(docker exec -u "$owner_q" "$q" syncthing device-id)
    id_t=$(docker exec -u "$owner_t" "$t" syncthing device-id)
    pair_bounded "$q" "$id_t" --address "tcp://$t:22000" --keep >/dev/null
    check "T joins Q" pair_bounded "$t" "$id_q" --address "tcp://$q:22000"
    in_target "$mount_q" "echo changed >/t/settings.json && rm /t/claude.json &&
        echo newer >/t/newer.md && chown $owner_q /t/newer.md"
    check "a change and a delete on Q reach T" \
        wait_for in_target "$mount_t" '[ ! -e /t/claude.json ] && grep -qx changed /t/settings.json'
    check "restore over Q's live folder" claude_sync "$q" restore "$archive" --volume "$vol_q"
    check "  gives T the changed file back" \
        wait_for in_target "$mount_t" "grep -qx 'fixture settings.json' /t/settings.json"
    check "  and the deleted one" wait_for in_target "$mount_t" "grep -qx 'fixture claude.json' /t/claude.json"
    check "  and keeps Q's file that the archive lacks" in_target "$mount_q" "grep -qx newer /t/newer.md"
}

# The calls the stub systemctl got since the last reset, apart from is-system-running and
# is-enabled, which change nothing.
systemctl_calls() {
    grep -v -e '^--user is-system-running$' -e '^--user is-enabled ' "$SYSTEMCTL_CALLS" 2>/dev/null || true
}

# U, then the host fixture Y: the daily backup's units, with a stub systemctl that logs its
# calls and a config directory of this group's, so no check reaches the real systemd or the
# runner's ~/.config.
group_timer() {
    local tm=$scratch/timer
    mkdir -p "$tm/bin" "$tm/other"
    export XDG_CONFIG_HOME=$tm/config SYSTEMCTL_CALLS=$tm/calls PATH=$tm/bin:$PATH
    local units=$XDG_CONFIG_HOME/systemd/user
    local service=$units/$u-backup.service timer=$units/$u-backup.timer
    # SYSTEMCTL_STATE is the user manager's, which is-system-running prints with the status
    # SYSTEMCTL_STATUS; offline fails every call, as a manager that cannot be reached does.
    # SYSTEMCTL_FAIL names one command that fails.
    cat >"$tm/bin/systemctl" <<'EOF'
#!/bin/sh
echo "$*" >>"$SYSTEMCTL_CALLS"
state=${SYSTEMCTL_STATE:-running}
[ "$state" != offline ] || exit 1
if [ "$2" = "${SYSTEMCTL_FAIL:-}" ]; then
    echo "Failed to $2" >&2
    exit 1
fi
if [ "$*" = "--user is-system-running" ]; then
    echo "$state"
    exit "${SYSTEMCTL_STATUS:-0}"
fi
EOF
    chmod +x "$tm/bin/systemctl"
    # A docker that finds setup's probe in the container's synced folder, as for a DIR in it,
    # which no directory here is.
    mkdir "$tm/probe-bin"
    cat >"$tm/probe-bin/docker" <<EOF
#!/bin/sh
if [ "\$1" = exec ] && [ "\$5" = find ]; then
    echo "\$6/\$8"
    exit 0
fi
exec "$(command -v docker)" "\$@"
EOF
    chmod +x "$tm/probe-bin/docker"
    # A DIR holding what systemd reads as escapes, specifiers and variables in a unit, and
    # how the unit quotes it.
    # shellcheck disable=SC2016 # the $ is part of the name
    local odd=$tm/'back ups/a"b\c%h$e' odd_quoted=\"$tm/'back ups/a\"b\\c%%h$$e"'
    local real_bin
    real_bin=$(readlink -f -- "$bin")

    echo "# setup --backup-dir"
    check "--backup-dir with --no-backup is refused" fails_with "only one of --backup-dir or --no-backup" \
        claude_sync "$u" setup --volume "$vol_u" --backup-dir "$tm/backups" --no-backup
    check "  and so is --no-backup with --backup-dir" fails_with "only one of --backup-dir or --no-backup" \
        claude_sync "$u" setup --volume "$vol_u" --no-backup --backup-dir "$tm/backups"
    check "--backup-dir with no value is refused" fails_with "--backup-dir needs a value" \
        claude_sync "$u" setup --volume "$vol_u" --backup-dir
    check "a DIR containing a newline is refused" fails_with "paths containing a newline are not supported" \
        claude_sync "$u" setup --volume "$vol_u" --backup-dir "$tm/a"$'\n'"b"
    check "--backup-dir without systemd's user manager is refused" fails_with "needs systemd's user manager" \
        env SYSTEMCTL_STATE=offline CLAUDE_SYNC_NAME="$u" "$bin" setup --volume "$vol_u" --backup-dir "$tm/backups"
    check "  before setting anything up" fails docker container inspect "$u"
    check "  as with a systemctl that prints a notice in place of a state" \
        fails_with "needs systemd's user manager" env SYSTEMCTL_STATE='"systemd" is not running in this container' \
        CLAUDE_SYNC_NAME="$u" "$bin" setup --volume "$vol_u" --backup-dir "$tm/backups"
    check "  writing no unit" [ ! -e "$units" ]
    rm -f -- "$SYSTEMCTL_CALLS"
    claude_sync "$u" setup --volume "$vol_u" >/dev/null
    check "setup without --backup-dir writes no unit" [ ! -e "$units" ]
    check "  and calls no systemctl" [ -z "$(systemctl_calls)" ]
    check "in a container, a DIR in the synced folder is refused" fails_with "is in the synced folder" \
        env PATH="$tm/probe-bin:$PATH" CLAUDE_SYNC_NAME="$u" "$bin" setup --backup-dir "$tm/synced"
    check "  writing no unit" [ ! -e "$units" ]
    check "  and not making DIR" [ ! -e "$tm/synced" ]
    docker exec -u "$owner_u" "$u" rm /var/syncthing/config/claude-sync-version
    rm -f -- "$SYSTEMCTL_CALLS"
    check "setup stops when systemd fails to enable the timer" \
        fails_with "systemctl --user enable --now $u-backup.timer failed: Failed to enable" \
        env SYSTEMCTL_FAIL=enable CLAUDE_SYNC_NAME="$u" "$bin" setup --backup-dir "$tm/backups"
    check "  before recording its version" fails stamp_of "$u"
    # The checks below that $units is empty would pass on a directory that is not there.
    check "  after making the unit directory" [ -d "$units" ]
    check "  removing the units it wrote" [ -z "$(ls -A "$units")" ]
    check "  after disabling the timer, which enable may have left enabled" [ "$(systemctl_calls)" = "--user daemon-reload
--user enable --now $u-backup.timer
--user disable $u-backup.timer
--user daemon-reload" ]
    out=$(claude_sync "$u" setup)
    check "  so that setup after it does not say it backs up" fails grep -qF "Backs up to" <<<"$out"
    mkdir "$tm/tmp"
    ln -s "$tm/missing/timer" "$timer"
    check "setup stops when it cannot write the units" fails_with "No such file or directory" \
        env TMPDIR="$tm/tmp" CLAUDE_SYNC_NAME="$u" "$bin" setup --backup-dir "$tm/backups"
    check "  removing those it wrote" [ -z "$(ls -A "$units")" ]
    check "  and its temporary directory" [ -z "$(ls -A "$tm/tmp")" ]
    rm -f -- "$SYSTEMCTL_CALLS"

    out=$(claude_sync "$u" setup --backup-dir "$odd")
    check "setup --backup-dir with no target installs the daily backup" \
        grep -qxF "Environment=CLAUDE_SYNC_NAME=$u" "$service"
    check "  running this claude-sync's backup into DIR, each one quoted word for systemd" \
        grep -qxF "ExecStart=\"$real_bin\" backup $odd_quoted" "$service"
    check "  daily" grep -qxF OnCalendar=daily "$timer"
    check "  catching up a day missed while logged out" grep -qxF Persistent=true "$timer"
    check "  once enabled" grep -qxF WantedBy=timers.target "$timer"
    check "  which it is, after systemd reloads the units" [ "$(systemctl_calls)" = "--user daemon-reload
--user enable --now $u-backup.timer" ]
    check "  making DIR" [ -d "$odd" ]
    check "  and saying where it backs up" grep -qF "Backs up to $odd daily" <<<"$out"

    echo "# setup again"
    local units_before
    units_before=$(cat "$service" "$timer")
    rm -f -- "$SYSTEMCTL_CALLS"
    check "setup --backup-dir stops when systemd fails to enable the timer for a new DIR" \
        fails_with "systemctl --user enable --now $u-backup.timer failed" \
        env SYSTEMCTL_FAIL=enable CLAUDE_SYNC_NAME="$u" "$bin" setup --backup-dir "$tm/elsewhere"
    check "  putting back the units it replaced" [ "$(cat "$service" "$timer")" = "$units_before" ]
    check "  and reloading them" [ "$(systemctl_calls)" = "--user daemon-reload
--user enable --now $u-backup.timer
--user daemon-reload" ]
    rm -f -- "$SYSTEMCTL_CALLS"
    out=$(claude_sync "$u" setup)
    check "setup with no target keeps the daily backup" [ "$(cat "$service" "$timer")" = "$units_before" ]
    check "  calling no systemctl, with nothing to change" [ -z "$(systemctl_calls)" ]
    check "  and reads DIR back, to say where it backs up" grep -qF "Backs up to $odd daily" <<<"$out"
    out=$(env SYSTEMCTL_FAIL=is-enabled CLAUDE_SYNC_NAME="$u" "$bin" setup)
    check "  which it does not say of a timer the user disabled" fails grep -qF "Backs up to" <<<"$out"
    claude_sync "$u" setup --volume "$vol_u" >/dev/null
    check "setup with the target keeps it too" [ "$(cat "$service" "$timer")" = "$units_before" ]
    out=$(env PATH="$tm/probe-bin:$PATH" CLAUDE_SYNC_NAME="$u" "$bin" setup 2>&1) && status=0 || status=$?
    check "setup that finds the kept DIR in the synced folder goes on" [ "$status" = 0 ]
    check "  warning that the daily backup fails" grep -qF "the daily backup into $odd fails each day" <<<"$out"
    check "  and keeping it" [ "$(cat "$service" "$timer")" = "$units_before" ]
    copy_under_test "$tm/other"
    check "setup by another claude-sync stops when systemd fails to reload the units" \
        fails_with "systemctl --user daemon-reload failed" \
        env SYSTEMCTL_FAIL=daemon-reload CLAUDE_SYNC_NAME="$u" "$tm/other/claude-sync" setup
    check "  putting back the units it replaced" [ "$(cat "$service" "$timer")" = "$units_before" ]
    rm -f -- "$SYSTEMCTL_CALLS"
    CLAUDE_SYNC_NAME=$u "$tm/other/claude-sync" setup >/dev/null
    check "setup by another claude-sync points the backup at it" \
        grep -qxF "ExecStart=\"$tm/other/claude-sync\" backup $odd_quoted" "$service"
    check "  reloading the units without enabling the timer again" \
        [ "$(systemctl_calls)" = "--user daemon-reload" ]
    check "a degraded user manager runs the backup too" env SYSTEMCTL_STATE=degraded SYSTEMCTL_STATUS=1 \
        CLAUDE_SYNC_NAME="$u" "$bin" setup --backup-dir "$tm/backups"
    check "  moving it to the new DIR" grep -qxF "ExecStart=\"$real_bin\" backup \"$tm/backups\"" "$service"

    echo "# --no-backup and uninstall"
    check "--no-backup without systemd's user manager says so" \
        fails_with "cannot reach systemd's user manager to remove $u-backup.timer" \
        env SYSTEMCTL_STATE=offline CLAUDE_SYNC_NAME="$u" "$bin" setup --no-backup
    check "  keeping the units" ls -- "$service" "$timer"
    rm -f -- "$SYSTEMCTL_CALLS"
    out=$(claude_sync "$u" setup --no-backup)
    check "setup --no-backup removes the daily backup" [ -z "$(ls -A "$units")" ]
    check "  disabling the timer, then reloading" [ "$(systemctl_calls)" = "--user disable --now $u-backup.timer
--user daemon-reload" ]
    check "  saying so" grep -qF "Removed the daily backup to $tm/backups;" <<<"$out"
    rm -f -- "$SYSTEMCTL_CALLS"
    check "  and with none, needs no user manager" \
        env SYSTEMCTL_STATE=offline CLAUDE_SYNC_NAME="$u" "$bin" setup --no-backup
    check "  calling no systemctl" [ -z "$(systemctl_calls)" ]
    claude_sync "$u" setup --backup-dir "$tm/backups" >/dev/null
    claude_sync "$u" backup "$tm/backups" >/dev/null
    check "uninstall without systemd's user manager says so" \
        fails_with "cannot reach systemd's user manager to remove $u-backup.timer" \
        env SYSTEMCTL_STATE=offline CLAUDE_SYNC_NAME="$u" "$bin" uninstall
    check "  removing nothing" docker container inspect "$u"
    mkdir "$tm/kept"
    cp -p -- "$service" "$timer" "$tm/kept/"
    check "uninstall that systemd fails to finish says to run it again" \
        fails_with "run CLAUDE_SYNC_NAME=$u claude-sync uninstall again" \
        env SYSTEMCTL_FAIL=disable CLAUDE_SYNC_NAME="$u" "$bin" uninstall
    check "  keeping the units" ls -- "$service" "$timer"
    rm -f -- "$SYSTEMCTL_CALLS"
    claude_sync "$u" uninstall >/dev/null
    check "uninstall run again, with the container gone, removes the daily backup" [ -z "$(ls -A "$units")" ]
    check "  disabling the timer" grep -qxF -- "--user disable --now $u-backup.timer" <<<"$(systemctl_calls)"
    check "  leaving the archives" [ "$(files_in "$tm/backups")" = 1 ]
    # As left by an instance removed outside claude-sync.
    cp -p -- "$tm/kept/"* "$units/"
    out=$(claude_sync "$u" setup --no-backup)
    check "setup --no-backup removes the daily backup of an instance that is gone" [ -z "$(ls -A "$units")" ]
    check "  saying so" grep -qF "Removed the daily backup to $tm/backups;" <<<"$out"

    echo "# --backup-dir with --use-host-syncthing"
    docker run -d --name "$y" --network "$net" --user user --entrypoint env "$host_image" \
        -u STHOMEDIR -u STGUIADDRESS HOME=/home/user syncthing serve --no-browser >/dev/null
    docker exec -u 0 "$y" mkdir /opt/claude-sync
    stage=$(mktemp -d -p "$scratch")
    copy_under_test "$stage"
    chmod 755 "$stage"
    docker cp -q "$stage/." "$y:/opt/claude-sync"
    as_user "$y" mkdir stub claude
    docker cp -q "$tm/bin/systemctl" "$y:/home/user/stub/"
    wait_for as_user "$y" syncthing cli show version
    # In the fixture's own ~/.config, with no XDG_CONFIG_HOME.
    y_sync() {
        # shellcheck disable=SC2016 # expanded by the fixture's shell
        as_user "$y" sh -c 'PATH=/home/user/stub:$PATH SYSTEMCTL_CALLS=/home/user/calls exec "$@"' sh \
            timeout 300 /opt/claude-sync/claude-sync "$@"
    }
    check "a DIR in the synced folder is refused" fails_with "is in the synced folder" \
        y_sync setup --path claude --use-host-syncthing --backup-dir claude/backups
    check "  writing no unit" fails as_user "$y" test -e .config/systemd/user/claude-sync-backup.service
    local folders
    folders=$(as_user "$y" syncthing cli config folders list)
    check "  or adding the folder" fails grep -qx claude-sync <<<"$folders"
    # A relative XDG_CONFIG_HOME, which user_unit_dir ignores.
    # shellcheck disable=SC2016 # expanded by the fixture's shell
    as_user "$y" XDG_CONFIG_HOME=config sh -c 'PATH=/home/user/stub:$PATH SYSTEMCTL_CALLS=/home/user/calls exec "$@"' \
        sh timeout 300 /opt/claude-sync/claude-sync setup --path claude --use-host-syncthing --backup-dir backups >/dev/null
    check "setup --use-host-syncthing --backup-dir installs the daily backup in ~/.config, DIR made absolute" \
        as_user "$y" grep -qxF 'ExecStart="/opt/claude-sync/claude-sync" backup "/home/user/backups"' \
        .config/systemd/user/claude-sync-backup.service
    check "  for the default instance" as_user "$y" grep -qxF Environment=CLAUDE_SYNC_NAME=claude-sync \
        .config/systemd/user/claude-sync-backup.service
    check "  enabling it" as_user "$y" grep -qxF -- "--user enable --now claude-sync-backup.timer" calls
    local y_units=.config/systemd/user/claude-sync-backup
    units_before=$(as_user "$y" cat "$y_units.service" "$y_units.timer")
    y_sync setup >/dev/null
    check "setup there keeps it" [ "$(as_user "$y" cat "$y_units.service" "$y_units.timer")" = "$units_before" ]
    # Another instance selected, as upgrade finds it when it sets up each instance by name.
    as_user "$y" mkdir -p .config/claude-sync
    as_user "$y" sh -c 'echo other >.config/claude-sync/instance'
    # shellcheck disable=SC2016 # expanded by the fixture's shell
    as_user "$y" CLAUDE_SYNC_NAME=claude-sync sh -c 'PATH=/home/user/stub:$PATH SYSTEMCTL_CALLS=/home/user/calls exec "$@"' \
        sh timeout 300 /opt/claude-sync/claude-sync setup >/dev/null
    check "  as it does with another instance selected" \
        [ "$(as_user "$y" cat "$y_units.service" "$y_units.timer")" = "$units_before" ]
    as_user "$y" rm .config/claude-sync/instance
    y_sync setup --no-backup >/dev/null
    check "setup --no-backup there removes it" [ -z "$(as_user "$y" ls -A .config/systemd/user)" ]
    # shellcheck disable=SC2088 # the ~ is for setup to expand
    y_sync setup --backup-dir '~/backups' >/dev/null
    check "setup --backup-dir expands a leading ~" as_user "$y" grep -qxF \
        'ExecStart="/opt/claude-sync/claude-sync" backup "/home/user/backups"' "$y_units.service"
    y_sync uninstall >/dev/null
    check "uninstall there removes it" fails as_user "$y" test -e "$y_units.timer"
}

# claude-sync as the user runs it, with no CLAUDE_SYNC_NAME, and the docker shim of
# group_select.
unnamed() {
    env -u CLAUDE_SYNC_NAME PATH="$scratch/select:$PATH" "$bin" "$@"
}

# claude-sync with CLAUDE_SYNC_NAME set to NAME, and the docker shim of group_select.
named() {
    env CLAUDE_SYNC_NAME="$1" PATH="$scratch/select:$PATH" "$bin" "${@:2}"
}

# V and W: listing a host's instances and selecting the one commands act on.
group_select() {
    echo "# list and use"
    # A config directory of this group's own, as the groups run in parallel: a command
    # without CLAUDE_SYNC_NAME in another group would otherwise follow this selection.
    export XDG_CONFIG_HOME=$scratch/config-select
    local selection=$XDG_CONFIG_HOME/claude-sync/instance
    # list and use read every instance on the Docker daemon, which may hold real ones, and
    # with no CLAUDE_SYNC_NAME a command acts on the default name, which may be a real
    # instance's. So these run with a shim that lists only V's and W's volumes, and lets
    # through only reads, unless claude-sync acts on V or W. With
    # CLAUDE_SYNC_TEST_DOCKER_DOWN set, every command fails, as with a daemon that is not
    # running.
    mkdir "$scratch/select"
    cat >"$scratch/select/docker" <<EOF
#!/usr/bin/env bash
real=$(command -v docker) v=$v w=$w
EOF
    cat >>"$scratch/select/docker" <<'EOF'
if [[ -n ${CLAUDE_SYNC_TEST_DOCKER_DOWN:-} ]]; then
    echo "docker shim: cannot connect to the Docker daemon" >&2
    exit 1
fi
if [[ $1 == volume && $2 == ls ]]; then
    "$real" "$@" | grep -xF -e "$v-config" -e "$w-config" || true
    exit
fi
[[ ${CLAUDE_SYNC_NAME:-} == "$v" || ${CLAUDE_SYNC_NAME:-} == "$w" ]] && exec "$real" "$@"
[[ $1 == inspect || ($1 =~ ^(container|volume|image)$ && $2 == inspect) ]] && exec "$real" "$@"
echo "docker shim: refusing docker $* under CLAUDE_SYNC_NAME=${CLAUDE_SYNC_NAME:-}" >&2
exit 97
EOF
    chmod +x "$scratch/select/docker"
    docker volume create "$vol_v" >/dev/null
    in_target "type=volume,src=$vol_v" "chown $owner_v /t"

    out=$(unnamed list)
    check "list with no instance says so" grep -qxF "No instance is set up on this host." <<<"$out"
    mkdir -p "${selection%/*}"
    : >"$selection"
    check "  but refuses an empty selection file, naming it" \
        fails_with "$selection does not hold a valid instance name" unnamed list
    rm "$selection"
    mkdir "$selection"
    check "a command refuses a selection file it cannot read, naming it" \
        fails_with "$selection does not hold a valid instance name" unnamed pair not-a-device-id
    check "  and use, unable to remove it, says so" fails_with "cannot remove $selection" unnamed use claude-sync
    rmdir "$selection"
    claude_sync "$v" setup --volume "$vol_v" >/dev/null
    docker volume create --label claude-sync=config "$w-config" >/dev/null
    out=$(unnamed list)
    check "list shows a running instance and what it syncs" grep -qE "^  $v +running +volume $vol_v\$" <<<"$out"
    check "  and one with only its Syncthing state" grep -qE "^  $w +state only +-\$" <<<"$out"
    check "  and that the default, which commands act on, is not set up" \
        grep -qxF "Commands act on instance claude-sync, which is not set up on this host." <<<"$out"

    check "use refuses a name that is not an instance" fails_with "no instance named ${prefix}typo" \
        unnamed use "${prefix}typo"
    check "  selecting nothing" [ ! -e "$selection" ]
    mkdir "$selection"
    check "use says when it cannot write the selection" fails_with "cannot write the selection to $selection" \
        unnamed use "$v"
    rmdir "$selection"
    check "use when docker cannot list the instances fails, saying so" \
        fails_with "so use cannot check that $v is one" \
        env -u CLAUDE_SYNC_NAME CLAUDE_SYNC_TEST_DOCKER_DOWN=1 PATH="$scratch/select:$PATH" "$bin" use "$v"
    check "use with neither HOME nor XDG_CONFIG_HOME fails, saying so" \
        fails_with "nowhere to keep the selection" \
        env -u CLAUDE_SYNC_NAME -u HOME -u XDG_CONFIG_HOME PATH="$scratch/select:$PATH" "$bin" use "$v"
    check "  or with a relative XDG_CONFIG_HOME, which it ignores" fails_with "nowhere to keep the selection" \
        env -C "${selection%/*}" -u CLAUDE_SYNC_NAME -u HOME XDG_CONFIG_HOME=relative PATH="$scratch/select:$PATH" "$bin" use "$v"
    check "use selects an instance" unnamed use "$v"
    check "  in the config directory" [ "$(cat "$selection")" = "$v" ]
    check "  after which messages name the default instance in its setup command" \
        [ "$(calls setup_command claude-sync)" = "CLAUDE_SYNC_NAME=claude-sync claude-sync setup" ]
    check "  which list marks" grep -qE "^\* $v +running" <<<"$(unnamed list)"
    out=$(unnamed pair not-a-device-id 2>&1) || true
    check "a command then acts on it, saying so" \
        grep -qF "acting on instance $v, selected with claude-sync use" <<<"$out"
    check "  and finds it running" grep -qF "not a device ID" <<<"$out"
    out=$(unnamed setup --use-host-syncthing --path "$scratch" 2>&1) || true
    check "setup says so too" grep -qF "acting on instance $v, selected with claude-sync use" <<<"$out"
    check "  and refuses --use-host-syncthing, saying to select the default" \
        grep -qF "run claude-sync use claude-sync first" <<<"$out"
    check "unpair says so too" fails_with "acting on instance $v, selected with claude-sync use" \
        unnamed unpair not-a-device-id

    check "CLAUDE_SYNC_NAME still wins over the selection" grep -qE "^\* $w +state only" <<<"$(named "$w" list)"
    check "  and a command it names says so" \
        fails_with "acting on instance $w, named by CLAUDE_SYNC_NAME" named "$w" pair not-a-device-id
    check "  as backup does" \
        fails_with "acting on instance $w, named by CLAUDE_SYNC_NAME" named "$w" backup "$scratch/w-backups"
    check "  and --use-host-syncthing under it says to clear the selection too" \
        fails_with "leave CLAUDE_SYNC_NAME unset and run claude-sync use claude-sync first" \
        named "$w" setup --use-host-syncthing --path "$scratch"
    check "use with CLAUDE_SYNC_NAME set says it still wins" \
        grep -qF "CLAUDE_SYNC_NAME is set, so commands run with it still act on instance $w." \
        <<<"$(named "$w" use "$v")"
    check "use of the default clears the selection" unnamed use claude-sync
    check "  removing the file" [ ! -e "$selection" ]
    printf '\n%s\n' "$v" >"$selection"
    check "a selection file with no valid name on its first line is refused, naming the file" \
        fails_with "$selection does not hold a valid instance name" unnamed pair not-a-device-id
    unnamed use "$v" >/dev/null
    # A bind source must exist on the Docker host, hence /. The container is never started,
    # so nothing is mounted: list reads only its list of mounts.
    docker create --name "$w" --label "com.docker.compose.project=$w" \
        --mount type=bind,src=/,dst=/var/syncthing/claude,readonly "$image" >/dev/null
    check "list shows what an instance on a directory syncs" \
        grep -qE "^  $w +stopped +directory /\$" <<<"$(unnamed list)"
    out=$(named "$w" uninstall 2>&1)
    check "uninstall of another instance leaves the selection" [ "$(cat "$selection")" = "$v" ]
    check "  and says nothing of it" fails grep -qF "no longer selected" <<<"$out"

    docker stop "$v" >/dev/null
    check "list shows a stopped instance" grep -qE "^\* $v +stopped +volume $vol_v\$" <<<"$(unnamed list)"
    check "list when docker cannot list the instances fails, saying so" \
        fails_with "docker cannot list the instances in containers" \
        env -u CLAUDE_SYNC_NAME CLAUDE_SYNC_TEST_DOCKER_DOWN=1 PATH="$scratch/select:$PATH" "$bin" list
    out=$(unnamed uninstall 2>&1)
    check "uninstall acts on the selected instance" fails docker container inspect "$v"
    check "  and clears the selection" [ ! -e "$selection" ]
    check "  saying later commands act on the default" \
        grep -qF "later commands act on the default instance, claude-sync." <<<"$out"
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
