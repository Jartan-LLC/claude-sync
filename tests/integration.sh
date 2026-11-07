#!/usr/bin/env bash
# Integration tests: claude-sync against real Syncthing containers on throwaway targets.
# Every container, volume, network and image this keeps is named claude-sync-test-*, and
# cleanup refuses anything else: a dev container may share the host's live Docker daemon,
# where a real ~/.claude volume lives.
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
# A relay on Docker's socket, such as a dev container's socat, can cut off a container's
# output after half a second while the command still succeeds.
out=$(docker run --rm --entrypoint sh "$image" -c 'sleep 1; echo ok')
[[ $out == ok ]] || {
    echo "Docker's output is cut short here; point DOCKER_HOST at the daemon's own socket" \
        "(in this repository's dev container, unix:///var/run/docker-host.sock)" >&2
    exit 1
}

# Synthetic ~/.claude: real filename shapes, no real data. The look-alikes in `synced`
# (lockfiles, .tmp-like names, nested daemon/, ide/ and jobs/) must not be caught by ignore rules.
readonly task=tasks/3570ff36-0222-44b7-8023-47d964bf700c
readonly job=jobs/5d1c8e2a
readonly synced=(
    settings.json
    claude.json
    projects/-work-demo/memory/note.md
    projects/-work-demo/0b6c1f9e-4d2a-4c8e-9f3b-2a7d5e8c1b40.jsonl
    skills/demo/SKILL.md
    skills/demo/bun.lock
    skills/demo/template.tmpl
    skills/demo/plan.tmp.md
    skills/demo/notes.tmp.data.txt
    skills/demo/draft.tmp.2.changelog.md
    skills/demo/daemon/notes.md
    skills/demo/ide/4242.lock
    sessions/0b6c1f9e-demo-session.tmp
    "$task/.highwatermark"
    "$job/state.json"
    "$job/timeline.jsonl"
    skills/demo/jobs/1/tmp/notes.md
)
readonly ignored=(
    .credentials.json
    .update.lock
    sessions/4242.json
    sessions/4242.key
    ide/4242.lock
    "$task/.lock"
    plugins/cache/market/demo/1.0.0/.in_use
    plugins/marketplaces/demo/.git/HEAD
    plugins/marketplaces/demo/bun.lock
    daemon/control.key
    session-env/0b6c1f9e-4d2a-4c8e-9f3b-2a7d5e8c1b40/sessionstart-hook-1.sh
    shell-snapshots/snapshot-bash-1700000000000-abc123.sh
    telemetry/1p_failed_events.0b6c1f9e.json
    settings.json.tmp.ab12cd34
    history.jsonl.tmp.4242.0123456789ab
    "$job/tmp/notes.md"
)

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

guard() {
    [[ $1 == "$prefix"* ]] || {
        echo "refusing to touch $1" >&2
        exit 1
    }
}

# Root shell with a target mounted at /t.
in_target() {
    docker run --rm --entrypoint sh --mount "$1,dst=/t" "$image" -c "$2"
}

claude_sync() {
    local node=$1
    shift
    CLAUDE_SYNC_NAME=$node "$bin" "$@"
}

st() {
    local node=$1 owner=$2
    shift 2
    docker exec -u "$owner" "$node" syncthing cli "$@"
}

# A node's Syncthing REST API: node, owner, path, then extra curl options.
rest() {
    local node=$1 owner=$2
    shift 2
    docker exec -u "$owner" "$node" sh -c \
        'path=$1; shift
        curl "$@" -H "X-API-Key: $(syncthing cli config gui apikey get)" "http://127.0.0.1:8384$path"' \
        sh "$@"
}

folder_status() {
    rest "$1" "$2" "/rest/db/status?folder=claude-sync" -fsS
}

# HTTP status of A's index entry for a file: 200 when indexed, 404 when not.
index_status() {
    rest "$a" "$owner_a" "/rest/db/file?folder=claude-sync&file=$1" -s -o /dev/null -w '%{http_code}'
}

owned_by() {
    [[ $(in_target "$1" "stat -c %u:%g /t/$2") == "$3" ]]
}

synced_to_b() {
    local a_local b_status
    a_local=$(folder_status "$a" "$owner_a" | jq .localTotalItems)
    b_status=$(folder_status "$b" "$owner_b")
    jq -e --argjson want "$a_local" \
        '.state == "idle" and .needTotalItems == 0 and .globalTotalItems == $want' \
        <<<"$b_status"
}

stignore_installed() {
    in_target "$1" 'cat /t/.stignore' | cmp -s - "$root/stignore"
}

trash_can_14_days() {
    st "$1" "$2" config folders claude-sync versioning dump-json |
        jq -e '.type == "trashcan" and .params.cleanoutDays == "14"'
}

network_options() {
    st "$1" "$2" config options dump-json | jq -c '[.globalAnnounceEnabled, .relaysEnabled, .natEnabled]'
}

# Whether a node's Syncthing is scanning the folder, or waiting to.
scanning() {
    [[ $(folder_status "$1" "$2" | jq -r .state) == scan* ]]
}

folder_type() {
    st "$1" "$2" config folders claude-sync type get
}

knows_device() {
    st "$1" "$2" config devices list | grep -qx "$3"
}

no_conflict_files() {
    [ -z "$(in_target "$1" "find /t -name '*.sync-conflict-*'")" ]
}

addresses() {
    st "$1" "$2" config devices "$3" dump-json | jq -r '.addresses | join(" ")'
}

forgets() {
    local devices
    devices=$(st "$1" "$2" config devices list) && ! grep -qx "$3" <<<"$devices"
}

introduced_by() {
    st "$1" "$2" config devices "$3" dump-json | jq -r .introducedBy
}

# A fresh exchange of device lists between two nodes, as on a reconnection.
reconnect() {
    st "$1" "$2" config devices "$3" paused set true
    sleep 3
    st "$1" "$2" config devices "$3" paused set false
    sleep 20
}

trusts() {
    [ "$(st "$1" "$2" config devices "$3" introducer get)" = true ]
}

# A command as `user` on the host fixture, with Syncthing's defaults rather than the
# image's settings.
on_host() {
    as_user "$h" "$@"
}

# A command as `user` on a host fixture CONTAINER.
as_user() {
    docker exec -u user -w /home/user "$1" env -u STHOMEDIR -u STGUIADDRESS HOME=/home/user "${@:2}"
}

host_sync() {
    on_host timeout 300 /opt/claude-sync/claude-sync "$@"
}

host_introducer() {
    on_host syncthing cli config devices "$1" introducer get
}

# Whether the archive in the host's DIR holds MEMBER.
host_archive_has() {
    on_host sh -c "tar -tzf $1/*.tar.gz" | grep -xF -- "$2" >/dev/null
}

host_has_folder() {
    # Not grep -q, which can cut the list off and so fail the pipeline; see prints_line in
    # claude-sync.
    on_host syncthing cli config folders list | grep -x claude-sync >/dev/null
}

host_trash_can_14_days() {
    on_host syncthing cli config folders claude-sync versioning dump-json |
        jq -e '.type == "trashcan" and .params.cleanoutDays == "14"'
}

# The host Syncthing's configuration outside what claude-sync manages: its folder and the
# devices it pairs with.
host_config() {
    on_host syncthing cli config dump-json |
        jq -S '{folders: [.folders[] | select(.id != "claude-sync")], options, gui, defaults, ldap}'
}

host_idle() {
    # shellcheck disable=SC2016 # expanded by the fixture's shell
    on_host sh -c 'curl -kfsS -H "X-API-Key: $(syncthing cli config gui apikey get)" \
        "https://127.0.0.1:8384/rest/db/status?folder=claude-sync"' |
        jq -e '.state == "idle" and .needTotalItems == 0'
}

# The files of the user's other folders.
host_others() {
    on_host sh -c "find photos notes tilde -type f ! -path '*/.stfolder/*' -exec sha256sum {} + | sort"
}

# Without .stfolder, Syncthing's marker, which it deletes along with the folder.
host_snapshot() {
    on_host sh -c 'cd claude && find . -path ./.stfolder -prune -o -print | sort &&
        find . -path ./.stfolder -prune -o -type f -exec sha256sum {} + | sort'
}

# claude-sync for an instance in the listener's network namespace, where another program
# holds Syncthing's default ports.
beside() {
    local node=$1
    shift
    CLAUDE_SYNC_COMPOSE_OVERRIDE=$root/tests/compose.busy.yaml CLAUDE_SYNC_NAME=$node \
        timeout 300 "$bin" "$@"
}

# A node's sync port, from its listen addresses.
sync_port() {
    st "$1" "$2" config options dump-json |
        jq -r '.listenAddresses[] | select(startswith("tcp://")) | sub(".*:"; "")'
}

listens() {
    docker exec "$1" nc -z 127.0.0.1 "$2"
}

listens_soon() {
    local i
    for ((i = 0; i < 20; i++)); do
        listens "$@" && return 0
        sleep 1
    done
    return 1
}

# A joining device's pair blocks until caught up; a bound turns a hang into a failure.
# Not for a background pair: killing a backgrounded function leaves timeout and pair
# running, so background `timeout ... claude-sync pair` itself.
pair_bounded() {
    local node=$1
    shift
    CLAUDE_SYNC_NAME=$node timeout 300 "$bin" pair "$@"
}

relative_path_resolved() {
    local err
    err=$(cd "$root" && CLAUDE_SYNC_NAME=$m "$bin" setup --path "${prefix}missing" 2>&1 >/dev/null) &&
        return 1
    grep -qxF "claude-sync: cannot read $root/${prefix}missing" <<<"$err"
}

path_overlay_renders() {
    CLAUDE_SYNC_NAME=$a CLAUDE_SYNC_UID=1 CLAUDE_SYNC_GID=1 CLAUDE_SYNC_TARGET=/srv/claude \
        docker compose -f "$root/compose.yaml" -f "$root/compose.path.yaml" config --format json |
        jq -e '.services.syncthing.volumes | any(
            .type == "bind" and .source == "/srv/claude" and .target == "/var/syncthing/claude")'
}

# Whether the claude-sync under test gives out FILE as this checkout has it, including the
# compose overlay for --path, which no test runs in a container.
carries() {
    # shellcheck disable=SC2016 # expanded by the inner bash
    bash -c 'source "$1" help >/dev/null && asset "$2"' _ "$bin" "$1" | cmp -s - "$root/$1"
}

no_leftovers() {
    [ -z "$(ls -A "$TMPDIR")" ]
}

snapshot() {
    in_target "$1" 'cd /t && find . | sort && find . -type f -exec sha256sum {} + | sort'
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

files_in() {
    find "$1" -mindepth 1 -maxdepth 1 | wc -l
}

cleanup() {
    local x
    for x in "$a" "$b" "$c" "$d" "$e" "$g" "$k" "$j" "$l" "$m" "$n" "$p" "$q" "$t" "$v" "$w" "$h" "$hu" "$u" "$y" "$bad_name" \
        "$listener" "$foreign"; do
        guard "$x"
        docker rm --force -v "$x" >/dev/null 2>&1 || true
    done
    guard "$host_image"
    docker image rm "$host_image" >/dev/null 2>&1 || true
    for x in "$a-config" "$b-config" "$c-config" "$d-config" "$e-config" "$g-config" "$k-config" \
        "$j-config" "$l-config" "$m-config" "$n-config" "$p-config" "$q-config" "$s-config" "$t-config" "$v-config" \
        "$w-config" "$u-config" "$bad_name-config" "$foreign-config" \
        "$vol_a" "$vol_b" "$vol_c" "$vol_d" "$vol_e" "$vol_g" "$vol_j" "$vol_l" "$vol_m" "$vol_n" "$vol_p" \
        "$vol_q" "$vol_r" "$vol_t" "$vol_v" "$vol_u" "$vol_q_missing" "$vol_missing" "$vol_root"; do
        guard "$x"
        docker volume rm "$x" >/dev/null 2>&1 || true
    done
    guard "$net"
    docker network rm "$net" >/dev/null 2>&1 || true
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
        for node in "$a" "$b" "$c" "$d" "$e" "$g" "$j" "$l" "$m" "$n" "$p" "$q" "$t" "$v" "$h" "$hu" "$u" "$y"; do
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
trap '((BASH_SUBSHELL == top)) && echo "aborted at tests/integration.sh:$LINENO${FUNCNAME:+ in ${FUNCNAME[0]}, called from line ${BASH_LINENO[0]}}" >&2' ERR
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
fixture="cd /t"
for f in "${synced[@]}" "${ignored[@]}"; do
    fixture+=" && mkdir -p \"\$(dirname '$f')\" && echo 'fixture $f' >'$f'"
done
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

# Devices A to D pairing, joining and unpairing, with the host's own Syncthing.
group_chain() {
    echo "# setup --volume --private"
    out=$(claude_sync "$a" setup --volume "$vol_a" --private)
    id_a=$(docker exec -u "$owner_a" "$a" syncthing device-id)
    check "prints this device's ID" grep -qF "This device ID: $id_a" <<<"$out"
    check "Syncthing writes as the volume's owner" wait_for owned_by "$mount_a" .stfolder "$owner_a"
    check ".stignore is the repo's stignore" stignore_installed "$mount_a"
    check "leaves no compose files behind" no_leftovers
    check "trash can versioning, 14 days" trash_can_14_days "$a" "$owner_a"
    check "no global discovery, relays or NAT traversal" \
        [ "$(network_options "$a" "$owner_a")" = '[false,false,false]' ]

    echo "# setup --volume, again"
    container_a=$(docker inspect -f '{{.Id}}' "$a")
    out=$(claude_sync "$a" setup --volume "$vol_a")
    check "keeps the device ID" grep -qF "This device ID: $id_a" <<<"$out"
    check "keeps the container" [ "$(docker inspect -f '{{.Id}}' "$a")" = "$container_a" ]
    check "keeps exactly one folder" [ "$(st "$a" "$owner_a" config folders list)" = claude-sync ]
    check "keeps trash can versioning" trash_can_14_days "$a" "$owner_a"
    check "stays private" [ "$(network_options "$a" "$owner_a")" = '[false,false,false]' ]
    check "refuses --private with --public" fails_with "only one of --private or --public" \
        claude_sync "$a" setup --volume "$vol_a" --private --public
    claude_sync "$a" setup --volume "$vol_a" --public >/dev/null
    check "--public restores Syncthing's defaults" \
        [ "$(network_options "$a" "$owner_a")" = '[true,true,true]' ]
    claude_sync "$a" setup --volume "$vol_a" --private >/dev/null
    check "refuses a different target" fails_with "already set up for $vol_a" \
        claude_sync "$a" setup --volume "$vol_b"
    check "  and writes nothing to it" in_target "$mount_b" '[ ! -e /t/.stignore ]'

    echo "# pair rejects bad input"
    check "pair before setup is refused" fails_with "run setup first" \
        pair_bounded "$c" "$id_a" --address "tcp://$a:22000"
    check "this device's own ID is refused" fails_with "this device's own ID" \
        pair_bounded "$a" "$id_a" --address "tcp://$a:22000"
    check "an invalid device ID is refused" fails_with "not a device ID" \
        pair_bounded "$a" not-a-device-id --address "tcp://$b:22000"

    echo "# setup --volume, second device"
    claude_sync "$b" setup --volume "$vol_b" --private >/dev/null
    id_b=$(docker exec -u "$owner_b" "$b" syncthing device-id)
    check "Syncthing writes as the volume's owner" wait_for owned_by "$mount_b" .stfolder "$owner_b"

    echo "# pair, the first two devices"
    # Canonical in form, so only Syncthing's check character catches it.
    bad_id=$([[ ${id_b:0:1} == A ]] && echo B || echo A)${id_b:1}
    check "a device ID with a wrong check character is refused" fails_with "cannot add device" \
        pair_bounded "$a" "$bad_id" --address "tcp://$b:22000"
    check "  and leaves the folder send-receive" [ "$(folder_type "$a" "$owner_a")" = sendreceive ]
    check "a private device needs --address" fails_with "--address" pair_bounded "$a" "$id_b" --keep
    check "  and adds no device" [ "$(st "$a" "$owner_a" config devices list)" = "$id_a" ]
    # B starts joining before A pairs with it, and is cut off while it waits.
    check "a join cut off while waiting" cut_off env CLAUDE_SYNC_NAME="$b" timeout 10 \
        "$bin" pair "$id_a" --address "tcp://$a:22000"
    check "  leaves B's folder receive-only" [ "$(folder_type "$b" "$owner_b")" = receiveonly ]
    check "  where unpair refuses until the join ends" fails_with "still joining" claude_sync "$b" unpair "$id_a"
    check "A pairs with B, keeping its files" pair_bounded "$a" "$id_b" --address "tcp://$b:22000" --keep
    check "pairing again changes nothing" pair_bounded "$a" "$id_b" --address "tcp://$b:22000"
    check "B's join finishes when re-run" pair_bounded "$b" "$id_a" --address "tcp://$a:22000"
    check "B trusts A as introducer" trusts "$b" "$owner_b" "$id_a"
    check "A trusts B as introducer" trusts "$a" "$owner_a" "$id_b"
    check "B's folder is send-receive after joining" [ "$(folder_type "$b" "$owner_b")" = sendreceive ]
    check "pairing B again changes nothing" pair_bounded "$b" "$id_a" --address "tcp://$a:22000"
    check "  and leaves it send-receive" [ "$(folder_type "$b" "$owner_b")" = sendreceive ]
    check "an invalid address is refused" fails_with "not an address" \
        pair_bounded "$a" "$id_b" --address 'tcp://b"x'
    check "  and leaves the address as it was" [ "$(addresses "$a" "$owner_a" "$id_b")" = "tcp://$b:22000" ]
    pair_bounded "$a" "$id_b" --address "tcp://elsewhere:22000" >/dev/null
    check "pairing again with --address replaces the address" \
        [ "$(addresses "$a" "$owner_a" "$id_b")" = "tcp://elsewhere:22000" ]
    check "  back again too" pair_bounded "$a" "$id_b" --address "tcp://$b:22000"

    echo "# ignore list, across two devices"
    if wait_for synced_to_b; then
        for f in "${synced[@]}"; do
            check "syncs $f" [ "$(in_target "$mount_b" "cat '/t/$f'")" = "fixture $f" ]
        done
        check "received files belong to B's owner" owned_by "$mount_b" settings.json "$owner_b"
        for f in "${ignored[@]}"; do
            check "ignores $f" in_target "$mount_b" "[ ! -e '/t/$f' ]"
        done
        # B shares the ignore list, so B alone would mask A announcing these.
        for f in "${synced[@]}"; do
            check "A indexes $f" [ "$(index_status "$f")" = 200 ]
        done
        for f in "${ignored[@]}"; do
            check "A never indexes $f" [ "$(index_status "$f")" = 404 ]
        done
    else
        check "B catches up with A" false
    fi
    check "A's sync port is reachable from another host" docker exec "$b" nc -z "$a" 22000
    # 000: no connection at all. An HTTP error would mean the port is open.
    check "A's web UI is unreachable from another host" [ "$(docker exec "$b" \
        curl -s -o /dev/null -w '%{http_code}' -m 3 "http://$a:8384/rest/noauth/health")" = 000 ]

    echo "# deletes reach past ignored leftovers"
    in_target "$mount_b" "echo b >'/t/$task/.lock' && chown $owner_b '/t/$task/.lock'"
    in_target "$mount_a" "rm -r '/t/$task'"
    check "a task folder deleted on A goes on B despite B's own .lock" \
        wait_for in_target "$mount_b" "[ ! -e '/t/$task' ]"
    # B's own copies of the ignored files inside these folders, and a half-written file. The
    # first try at deleting the folders past them fails, and Syncthing retries a failed pull
    # only after a minute unless told sooner.
    st "$b" "$owner_b" config folders claude-sync puller-pauses set 2
    own="cd /t"
    for f in "${ignored[@]}" plugins/cache/market/demo/1.0.0/plugin.json.tmp.ab12cd34; do
        case $f in
            plugins/* | ide/* | sessions/* | jobs/*) own+=" && mkdir -p \"\$(dirname '$f')\" && echo b >'$f'" ;;
        esac
    done
    in_target "$mount_b" "$own && chown -R $owner_b plugins ide sessions jobs"
    in_target "$mount_a" "rm -r /t/plugins /t/ide /t/sessions /t/jobs"
    for dir in plugins ide sessions jobs; do
        check "$dir/ deleted on A goes on B despite B's own ignored files in it" \
            wait_for in_target "$mount_b" "[ ! -e /t/$dir ]"
    done

    echo "# pair, the first device of a new set without --keep"
    # C's claude.json is newer than A's, so Syncthing's newest-wins rule alone would pick C's.
    # C's own plugin version holds files the ignore list keeps out of sync.
    c_plugin=plugins/cache/market/c-only/1.0.0
    in_target "$mount_c" "echo 'c claude.json' >/t/claude.json && echo c >/t/c-only.md && \
        mkdir -p /t/$c_plugin && cd /t/$c_plugin && echo c >plugin.json && echo c >.in_use && \
        echo c >plugin.json.tmp.ab12cd34 && echo c >plugin.json.tmp.4242.0123456789ab && chown -R $owner_c /t"
    claude_sync "$c" setup --volume "$vol_c" --private >/dev/null
    id_c=$(docker exec -u "$owner_c" "$c" syncthing device-id)
    # C, with files, and D, with none, both pair with no other device yet: both join, and
    # only --keep on C would give D anything to join.
    claude_sync "$d" setup --volume "$vol_d" --private >/dev/null
    id_d=$(docker exec -u "$owner_d" "$d" syncthing device-id)
    CLAUDE_SYNC_NAME=$d timeout 300 "$bin" pair "$id_c" --address "tcp://$c:22000" >/dev/null 2>&1 &
    d_pairing=$!
    check "joining devices with no files is refused" fails_with "has no files to join" \
        pair_bounded "$c" "$id_d" --address "tcp://$d:22000"
    check "  and C keeps its files" [ "$(in_target "$mount_c" 'cat /t/claude.json')" = "c claude.json" ]
    check "  all of them" in_target "$mount_c" '[ -e /t/c-only.md ]'
    check "  and is unpaired" [ "$(st "$c" "$owner_c" config devices list)" = "$id_c" ]
    check "  and send-receive again" [ "$(folder_type "$c" "$owner_c")" = sendreceive ]
    kill "$d_pairing" 2>/dev/null || true
    docker rm --force -v "$d" >/dev/null
    wait "$d_pairing" || true

    echo "# pair, a device with its own files joining"
    # Started before A accepts C, so nothing can let it finish but waiting for A.
    CLAUDE_SYNC_NAME=$c timeout 300 "$bin" pair "$id_a" --address "tcp://$a:22000" \
        >"$scratch/join-c.out" 2>&1 &
    joining=$!
    check "a join says what to run on the device it joins through" \
        wait_for grep -qF "claude-sync pair $id_c" "$scratch/join-c.out"
    check "  and waits for it" kill -0 "$joining"
    check "  and leaves C's files alone meanwhile" [ "$(in_target "$mount_c" 'cat /t/claude.json')" = "c claude.json" ]
    pair_bounded "$a" "$id_c" --address "tcp://$c:22000" >/dev/null
    check "C joins once A accepts" wait "$joining"
    check "C gets A's claude.json" [ "$(in_target "$mount_c" 'cat /t/claude.json')" = "fixture claude.json" ]
    check "C's own file is discarded" in_target "$mount_c" '[ ! -e /t/c-only.md ]'
    check "  into C's trash can" in_target "$mount_c" '[ -e /t/.stversions/c-only.md ]'
    check "C's own plugin version is discarded, ignored files and all" in_target "$mount_c" "[ ! -e /t/$c_plugin ]"
    check "  into C's trash can" in_target "$mount_c" "[ -e /t/.stversions/$c_plugin/plugin.json ]"
    check "C's folder is send-receive after joining" [ "$(folder_type "$c" "$owner_c")" = sendreceive ]
    in_target "$mount_c" "echo c >/t/from-c.md && chown $owner_c /t/from-c.md"
    check "C's edits reach A" wait_for in_target "$mount_a" '[ -e /t/from-c.md ]'
    check "  and B" wait_for in_target "$mount_b" '[ -e /t/from-c.md ]'
    # Checked once C's edits have spread, so anything C sent on joining would have too.
    check "A gets no conflict files" no_conflict_files "$mount_a"
    check "B gets no conflict files" no_conflict_files "$mount_b"

    echo "# every device introduces the others"
    check "B learns of C" wait_for knows_device "$b" "$owner_b" "$id_c"
    check "C learns of B" wait_for knows_device "$c" "$owner_c" "$id_b"
    # D starts over with a file of its own and pairs through B rather than A. Its join is cut
    # off, and --keep finishes it without discarding the file.
    claude_sync "$d" uninstall >/dev/null
    in_target "type=volume,src=$vol_d" "echo d >/t/d-only.md && chown $owner_d /t/d-only.md"
    claude_sync "$d" setup --volume "$vol_d" --private >/dev/null
    id_d=$(docker exec -u "$owner_d" "$d" syncthing device-id)
    check "D's join cut off while waiting" cut_off env CLAUDE_SYNC_NAME="$d" timeout 10 \
        "$bin" pair "$id_b" --address "tcp://$b:22000"
    check "  leaves D's folder receive-only" [ "$(folder_type "$d" "$owner_d")" = receiveonly ]
    # B on the unpaired list in D's folder, where a joining D could never take it off.
    in_target "type=volume,src=$vol_d" "mkdir /t/.claude-sync-unpaired && touch /t/.claude-sync-unpaired/$id_b &&
        chown -R $owner_d /t/.claude-sync-unpaired"
    check "  where pair refuses a device on the unpaired list" \
        fails_with "pair it from a device that already syncs" pair_bounded "$d" "$id_b" --address "tcp://$b:22000"
    in_target "type=volume,src=$vol_d" "rm -r /t/.claude-sync-unpaired"
    pair_bounded "$b" "$id_d" --address "tcp://$d:22000" >/dev/null
    check "--keep ends it" pair_bounded "$d" "$id_b" --address "tcp://$b:22000" --keep
    check "  leaving D's folder send-receive" [ "$(folder_type "$d" "$owner_d")" = sendreceive ]
    check "  and D's own file in place" in_target "type=volume,src=$vol_d" '[ -e /t/d-only.md ]'
    check "D's own file reaches A" wait_for in_target "$mount_a" '[ -e /t/d-only.md ]'
    check "A learns of D" wait_for knows_device "$a" "$owner_a" "$id_d"
    check "C learns of D" wait_for knows_device "$c" "$owner_c" "$id_d"
    check "D learns of A and C" wait_for knows_device "$d" "$owner_d" "$id_a"
    check "  and C" wait_for knows_device "$d" "$owner_d" "$id_c"
    check "A trusts D as introducer" wait_for trusts "$a" "$owner_a" "$id_d"
    check "D trusts A as introducer" wait_for trusts "$d" "$owner_d" "$id_a"
    in_target "type=volume,src=$vol_d" "echo d >/t/from-d.md && chown $owner_d /t/from-d.md"
    check "D's edits reach A" wait_for in_target "$mount_a" '[ -e /t/from-d.md ]'
    check "  and C" wait_for in_target "$mount_c" '[ -e /t/from-d.md ]'

    echo "# setup --use-host-syncthing"
    docker run -d --name "$h" --network "$net" --user user --entrypoint env "$host_image" \
        -u STHOMEDIR -u STGUIADDRESS HOME=/home/user syncthing serve --no-browser >/dev/null
    docker exec -u 0 "$h" mkdir /opt/claude-sync
    docker cp -q "$bin" "$h:/opt/claude-sync/"
    # Beside the script only for this checkout's, which reads it from there.
    [[ -n ${CLAUDE_SYNC_BIN:-} ]] || docker cp -q "$root/stignore" "$h:/opt/claude-sync/"
    docker cp -q "$root/stignore" "$h:/opt/stignore"
    wait_for on_host syncthing cli show version
    id_h=$(on_host syncthing device-id)
    # The user's own Syncthing: folders of their own, one shared with B, private options, and
    # a web UI address with no host.
    on_host mkdir claude photos photos/sub notes other tilde
    on_host sh -c 'echo p >photos/p.md && echo s >photos/sub/s.md && echo n >notes/n.md && echo t >tilde/t.md'
    on_host ln -s photos/sub into-photos
    on_host sh -c 'echo h >claude/h-only.md'
    on_host syncthing cli config devices add --device-id "$id_b" --addresses "tcp://$b:22000"
    on_host syncthing cli config folders add --id photos --label photos --path /home/user/photos
    on_host syncthing cli config folders photos devices add --device-id "$id_b"
    on_host syncthing cli config folders add --id notes --label notes --path /home/user/notes
    # shellcheck disable=SC2088 # Syncthing stores the ~ as given
    on_host syncthing cli config folders add --id tilde --label tilde --path '~/tilde/'
    for option in global-ann-enabled relays-enabled natenabled; do
        on_host syncthing cli config options "$option" set false
    done
    # Syncthing restarts its web UI at once, so this call may not get its answer.
    on_host syncthing cli config gui raw-address set :8384 2>/dev/null || true
    wait_for on_host sh -c 'syncthing cli config gui raw-address get | grep -qx :8384'
    host_before=$(host_config)
    others_before=$(host_others)
    check "--volume is refused" fails_with "only with --path" \
        host_sync setup --volume "$vol_a" --use-host-syncthing
    check "--private is refused" fails_with "set them in that Syncthing" \
        host_sync setup --path claude --use-host-syncthing --private
    check "--public is refused" fails_with "set them in that Syncthing" \
        host_sync setup --path claude --use-host-syncthing --public
    check "a directory another folder syncs is refused" fails_with "folder notes already syncs" \
        host_sync setup --path notes --use-host-syncthing
    check "  and one inside another folder" fails_with "folder photos already syncs" \
        host_sync setup --path photos/sub --use-host-syncthing
    check "  and one around another folder" fails_with "which overlaps /home/user;" \
        host_sync setup --path /home/user --use-host-syncthing
    check "  and one stored as ~/ with a trailing slash" fails_with "folder tilde already syncs" \
        host_sync setup --path tilde --use-host-syncthing
    check "  and a symlink into another folder" fails_with "folder photos already syncs" \
        host_sync setup --path into-photos --use-host-syncthing
    docker exec -i -u user "$h" sh -c 'mkdir -p /home/user/old && cat >/home/user/old/syncthing &&
        chmod +x /home/user/old/syncthing' <<'EOF'
#!/bin/sh
# Syncthing 1, as far as claude-sync's version check can tell.
if [ "$*" = "cli show version" ]; then
    printf '{\n  "version": "v1.30.0"\n}\n'
    exit
fi
exec /bin/syncthing "$@"
EOF
    check "Syncthing 1 is refused" fails_with "needs Syncthing 2" \
        on_host env PATH=/home/user/old:/usr/bin:/bin /opt/claude-sync/claude-sync setup --path claude \
        --use-host-syncthing
    check "  and nothing is set up" fails on_host test -e claude/.stignore
    check "  nor any claude-sync folder, by any refusal" fails host_has_folder
    out=$(host_sync setup --path claude --use-host-syncthing)
    check "prints this device's ID" grep -qF "This device ID: $id_h" <<<"$out"
    check "the folder is the directory, made absolute" \
        [ "$(on_host syncthing cli config folders claude-sync path get)" = /home/user/claude ]
    check ".stignore is the repo's stignore" on_host cmp -s claude/.stignore /opt/stignore
    check "trash can versioning, 14 days" host_trash_can_14_days

    echo "# backup, on the host's Syncthing"
    check "the host's tar is GNU tar" on_host sh -c 'tar --version | grep -q "GNU tar"'
    check "backup archives the folder with this host's tar" host_sync backup backups
    check "  all of it" host_archive_has backups ./h-only.md
    check "restore run by root" docker exec -u 0 "$h" sh -c \
        '/opt/claude-sync/claude-sync restore /home/user/backups/*.tar.gz --path /root/restored'
    check "  gives root the files, not the archive's owner" \
        [ "$(docker exec -u 0 "$h" stat -c %u /root/restored/h-only.md)" = 0 ]
    host_archive=$(on_host sh -c 'ls backups/*.tar.gz')
    # shellcheck disable=SC2088 # given to claude-sync unexpanded, as when quoted
    check "restore expands a quoted ~ in the archive and the directory" \
        host_sync restore "~/$host_archive" --path '~/tilde-restored'
    check "  into the home directory" on_host test -f tilde-restored/h-only.md
    check "  but not a ~ that starts a name" host_sync restore "$host_archive" --path '~restored'
    check "  which stays a name in the working directory" on_host test -f '~restored/h-only.md'
    # shellcheck disable=SC2088 # given to claude-sync unexpanded, as when quoted
    check "backup expands a quoted ~ in its directory" host_sync backup '~/tilde-backups'
    check "  into the home directory" on_host sh -c 'ls tilde-backups/*.tar.gz'
    check "  making no ~ directory" fails on_host test -e '~'
    # A directory that user can neither write in nor chmod.
    docker exec -u 0 "$h" mkdir /home/user/root-owned
    check "a restore that tar cannot finish fails" fails_with "could not restore all of" \
        host_sync restore "$host_archive" --path root-owned
    check "a restore into a volume needs Docker" fails_with "Docker is required" \
        host_sync restore "$host_archive" --volume "$vol_r"
    # Files that come and go as GNU tar reads the folder, set up as in group_backups.
    churn=/home/user/claude/jobs/churn/tmp
    on_host sh -c "mkdir -p $churn && touch /tmp/churning &&
        for i in 1 2 3 4 5; do head -c 5000000 /dev/urandom >$churn/big\$i; done"
    on_host sh -c "i=0; while [ -e /tmp/churning ]; do
        i=\$((i + 1)); echo x >$churn/t\$i; rm -f $churn/t\$((i - 20)); done" &
    churning=$!
    wait_for on_host sh -c "ls $churn | grep -q '^t[0-9]\{3\}'"
    if host_sync backup busy >/dev/null 2>"$scratch/host-busy.err"; then busy=ok; else busy=failed; fi
    on_host rm /tmp/churning
    wait "$churning" || true
    check "backup takes files that go as GNU tar reads the folder" [ "$busy" = ok ]
    check "  after tar found some gone" grep -qF "File removed before we read it" "$scratch/host-busy.err"
    check "  in a whole archive" host_archive_has busy ./jobs/churn/tmp/big5
    on_host rm -r claude/jobs
    # GNU tar, archiving the folder, then exiting 1 with the lines in TAR_SAYS, as when files
    # changed while it read them; unless LC_ALL is C, it says so in German instead, as a GNU tar
    # with translations would, which the fixture's is not. And a tar that fails.
    docker exec -i -u user "$h" sh -c 'mkdir -p /home/user/changing && cat >/home/user/changing/tar &&
        chmod +x /home/user/changing/tar' <<'EOF'
#!/bin/sh
/bin/tar "$@" || exit
if [ "$LC_ALL" = C ]; then
    printf '%s\n' "$TAR_SAYS" >&2
else
    echo 'tar: ./h-only.md: Datei hat sich beim Lesen geändert' >&2
fi
exit 1
EOF
    docker exec -u user "$h" sh -c 'mkdir /home/user/failing && printf "#!/bin/sh\necho partial\nexit 2\n" \
        >/home/user/failing/tar && chmod +x /home/user/failing/tar'
    check "backup passes GNU tar's status 1 for files that changed or went as it read them, in any locale" \
        on_host env PATH=/home/user/changing:/usr/bin:/bin LC_ALL=de_DE.UTF-8 TAR_SAYS="tar: ./h-only.md: file changed as we read it
tar: ./gone.md: File removed before we read it" /opt/claude-sync/claude-sync backup changed
    check "  as an archive" on_host sh -c 'tar -tzf changed/*.tar.gz >/dev/null'
    check "a file that shrank as tar read it fails backup" fails_with "tar could not archive" \
        on_host env PATH=/home/user/changing:/usr/bin:/bin TAR_SAYS="tar: ./h-only.md: file changed as we read it
tar: ./big: File shrank by 10 bytes; padding with zeros" /opt/claude-sync/claude-sync backup shrank
    check "  leaving no archive" [ -z "$(on_host ls -A shrank)" ]
    check "a tar that fails fails backup" fails \
        on_host env PATH=/home/user/failing:/usr/bin:/bin /opt/claude-sync/claude-sync backup failed
    check "  leaving no partial archive" [ -z "$(on_host ls -A failed)" ]
    on_host ln -s claude into-claude
    check "a directory in the folder is refused" fails_with "is in the synced folder" \
        host_sync backup claude/.stfolder
    check "  and the folder itself, through a symlink" fails_with "is in the synced folder" \
        host_sync backup into-claude
    check "  and a directory in it not made yet" fails_with "is in the synced folder" \
        host_sync backup into-claude/new
    check "  without making it" on_host test ! -e claude/new
    check "  leaving no archive in it" [ -z "$(on_host find claude -name '*.tar.gz')" ]
    check "setup again, naming the directory another way" host_sync setup --path ./claude/ --use-host-syncthing
    # A syncthing that pauses after each line of the folder list. claude-sync comes first, so
    # a reader that stops at it exits before the next line and cuts the list off.
    docker exec -i -u user "$h" sh -c 'mkdir /home/user/slow && cat >/home/user/slow/syncthing &&
        chmod +x /home/user/slow/syncthing' <<'EOF'
#!/bin/sh
if [ "$*" = "cli config folders list" ]; then
    /bin/syncthing "$@" | while IFS= read -r line; do echo "$line" && sleep 0.5; done
    exit
fi
exec /bin/syncthing "$@"
EOF
    check "setup again, Syncthing listing folders slowly" on_host env PATH=/home/user/slow:/usr/bin:/bin \
        /opt/claude-sync/claude-sync setup --path claude --use-host-syncthing
    # A curl that never reaches the API, while `syncthing cli` still does.
    docker exec -u user "$h" sh -c 'mkdir /home/user/nocurl && printf "#!/bin/sh\nexit 7\n" >/home/user/nocurl/curl &&
        chmod +x /home/user/nocurl/curl'
    check "setup says when it cannot reach Syncthing's API" fails_with "cannot reach Syncthing" \
        on_host env PATH=/home/user/nocurl:/usr/bin:/bin /opt/claude-sync/claude-sync setup --path claude \
        --use-host-syncthing
    check "  and refuses a different directory" fails_with "already set up for /home/user/claude" \
        host_sync setup --path other --use-host-syncthing
    check "another CLAUDE_SYNC_NAME is refused" fails_with "leave CLAUDE_SYNC_NAME unset" \
        on_host env CLAUDE_SYNC_NAME=work /opt/claude-sync/claude-sync setup --path claude --use-host-syncthing
    check "  and pair under it does not use this Syncthing" fails_with "run setup first" \
        on_host env CLAUDE_SYNC_NAME=work /opt/claude-sync/claude-sync pair "$id_b"
    check "  nor does uninstall" on_host env CLAUDE_SYNC_NAME=work /opt/claude-sync/claude-sync uninstall
    check "  which leaves the folder" host_has_folder
    check "--gui-port is refused" fails_with "set them in that Syncthing" \
        host_sync setup --path claude --use-host-syncthing --gui-port 8484
    # Another Syncthing home whose web UI nothing listens on: this user's Syncthing, stopped.
    on_host sh -c 'mkdir stopped && cp .local/state/syncthing/*.pem .local/state/syncthing/config.xml stopped/ &&
        sed -i "s|:8384</address>|:1</address>|" stopped/config.xml'
    check "uninstall with the host's Syncthing stopped says so" fails_with "cannot reach the Syncthing" \
        on_host env STHOMEDIR=/home/user/stopped /opt/claude-sync/claude-sync uninstall

    echo "# pair, on the host's Syncthing"
    check "a private host Syncthing needs --address" fails_with "--address" host_sync pair "$id_b"
    pair_bounded "$b" "$id_h" --address "tcp://$h:22000" >/dev/null
    out=$(host_sync pair "$id_b" --address "tcp://$b:22000")
    check "joins through B" grep -qF "Joined through $id_b" <<<"$out"
    check "  and gets B's claude.json" [ "$(on_host cat claude/claude.json)" = "fixture claude.json" ]
    check "  moving its own file to the trash can" on_host test -e claude/.stversions/h-only.md
    check "  out of the folder" fails on_host test -e claude/h-only.md
    check "  and syncs both ways afterwards" \
        [ "$(on_host syncthing cli config folders claude-sync type get)" = sendreceive ]
    check "B, which shares another folder here, is not made introducer" \
        [ "$(host_introducer "$id_b")" = false ]
    check "  and pairing says to pair with each device" grep -qF "pair this device with each" <<<"$out"
    pair_bounded "$a" "$id_h" --address "tcp://$h:22000" >/dev/null
    check "pairing with A, which shares nothing else here" host_sync pair "$id_a" --address "tcp://$a:22000"
    check "  makes A introducer" [ "$(host_introducer "$id_a")" = true ]
    on_host sh -c 'echo h >claude/from-h.md'
    check "the host device's edits reach A" wait_for in_target "$mount_a" '[ -e /t/from-h.md ]'
    # Checked once its edits have spread, so anything it sent on joining would have too.
    check "  but never its discarded file" in_target "$mount_a" '[ ! -e /t/h-only.md ]'
    check "  nor conflict files" no_conflict_files "$mount_a"
    check "the user's other folders and options are untouched" [ "$(host_config)" = "$host_before" ]
    # Turning on TLS restarts the web UI, so this call may not get its answer. The web UI
    # takes HTTPS with TLS off too, so only reading the setting back shows it took.
    on_host syncthing cli config gui raw-use-tls set true 2>/dev/null || true
    wait_for on_host sh -c 'syncthing cli config gui raw-use-tls get | grep -qx true'
    check "pair reaches a web UI that uses TLS" \
        host_sync pair "$id_a" --address "tcp://$a:22000"
    host_before=$(host_config)

    echo "# unpair"
    check "this device's own ID is refused" fails_with "this device's own ID" claude_sync "$a" unpair "$id_a"
    check "an invalid device ID is refused" fails_with "not a device ID" claude_sync "$a" unpair not-a-device-id
    # The host device pairs with D directly, so no introducer takes D away there, and also
    # shares another folder with it. It knows D by introduction so far, which pairing alone
    # does not change, so D is deleted there first. Until pair has added D and shared the
    # folder with it, the host device does not trust its other introducers: a ClusterConfig
    # from one of them would add D back by introduction. Their connections stay up: a
    # reconnection here would have the host device introduce D to A again just after A's
    # unpair, before the test checks that the unpair removed it.
    check "the host device knows D" \
        wait_for on_host sh -c "syncthing cli config devices list | grep -qx $id_d"
    ids=$(on_host syncthing cli config dump-json |
        jq -r --arg d "$id_d" '.devices[] | select(.introducer and .deviceID != $d) | .deviceID')
    introducers=()
    [[ -z $ids ]] || mapfile -t introducers <<<"$ids"
    for x in "${introducers[@]}"; do
        on_host syncthing cli config devices "$x" introducer set false
    done
    on_host syncthing cli config folders claude-sync devices "$id_d" delete
    on_host syncthing cli config devices "$id_d" delete
    host_sync pair "$id_d" --address "tcp://$d:22000" >/dev/null
    for x in "${introducers[@]}"; do
        on_host syncthing cli config devices "$x" introducer set true
    done
    pair_bounded "$d" "$id_h" --address "tcp://$h:22000" >/dev/null
    on_host syncthing cli config folders photos devices add --device-id "$id_d"
    check "the host device knows D directly" [ -z "$(on_host syncthing cli config devices "$id_d" dump-json | jq -r .introducedBy)" ]
    # A knows D only through an introduction, where removing it by hand alone would not stick.
    check "A knows D only by introduction" [ -n "$(introduced_by "$a" "$owner_a" "$id_d")" ]
    claude_sync "$a" unpair "$id_d" >/dev/null
    check "unpair removes D on A" forgets "$a" "$owner_a" "$id_d"
    check "  and on B, which D paired with" wait_for forgets "$b" "$owner_b" "$id_d"
    check "  and on C" wait_for forgets "$c" "$owner_c" "$id_d"
    check "the list of unpaired devices reaches the host device" \
        wait_for on_host test -e "claude/.claude-sync-unpaired/$id_d"
    check "  which keeps D until claude-sync runs there" \
        on_host sh -c "syncthing cli config folders claude-sync devices list | grep -qx $id_d"
    since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    reconnect "$a" "$owner_a" "$id_h"
    check "the host device, still sharing with D, introduces it to A again" \
        wait_for sh -c "docker logs --since $since $a 2>&1 | grep 'vouched for by introducer' | grep -q device=${id_d:0:7}"
    check "  and A removes it again" wait_for forgets "$a" "$owner_a" "$id_d"
    host_sync pair "$id_a" --address "tcp://$a:22000" >/dev/null
    check "the host device drops D from claude-sync's folder once claude-sync runs there" \
        sh -c "! docker exec -u user $h env -u STHOMEDIR -u STGUIADDRESS HOME=/home/user \
            syncthing cli config folders claude-sync devices list | grep -qx $id_d"
    check "  and keeps it for the other folder they share" \
        on_host sh -c "syncthing cli config devices list | grep -qx $id_d"
    on_host syncthing cli config folders photos devices "$id_d" delete
    on_host syncthing cli config devices "$id_d" delete
    pair_bounded "$b" "$id_d" --address "tcp://$d:22000" >/dev/null
    check "D pairs again" pair_bounded "$d" "$id_b" --address "tcp://$b:22000" --keep
    check "  leaving the list" fails in_target "$mount_b" "[ -e /t/.claude-sync-unpaired/$id_d ]"
    check "  and B keeps it" wait_for knows_device "$b" "$owner_b" "$id_d"
    check "  and A learns of it again" wait_for knows_device "$a" "$owner_a" "$id_d"
    check "  and C" wait_for knows_device "$c" "$owner_c" "$id_d"
    in_target "$mount_b" "echo b >/t/after-unpair.md && chown $owner_b /t/after-unpair.md"
    check "  and D syncs again" wait_for in_target "type=volume,src=$vol_d" '[ -e /t/after-unpair.md ]'

    echo "# uninstall, on the host's Syncthing"
    wait_for on_host test -e claude/after-unpair.md
    wait_for host_idle
    before=$(host_snapshot)
    devices=$(on_host syncthing cli config devices list | sort)
    host_sync uninstall >/dev/null
    check "removes claude-sync's folder" fails host_has_folder
    check "keeps the devices it paired" [ "$(on_host syncthing cli config devices list | sort)" = "$devices" ]
    check "keeps the user's other folders and options" [ "$(host_config)" = "$host_before" ]
    check "  and their files, through setup, pair, unpair and uninstall" [ "$(host_others)" = "$others_before" ]
    check "leaves the synced data byte-identical" [ "$(host_snapshot)" = "$before" ]
    check "Syncthing keeps running" on_host syncthing cli show version
    check "pair afterwards is refused" fails_with "run setup first" host_sync pair "$id_a"

    echo "# uninstall"
    before=$(snapshot "$mount_a")
    anonymous=$(docker container inspect \
        --format '{{range .Mounts}}{{if eq .Destination "/var/syncthing"}}{{.Name}}{{end}}{{end}}' "$a")
    claude_sync "$a" uninstall >/dev/null
    check "removes the container" fails docker container inspect "$a"
    check "  and the image's anonymous volume" fails docker volume inspect "${anonymous:?}"
    check "removes Syncthing's state volume" fails docker volume inspect "$a-config"
    check "keeps the synced volume" docker volume inspect "$vol_a"
    check "leaves the synced data byte-identical" [ "$(snapshot "$mount_a")" = "$before" ]
    check "succeeds when there is nothing to remove" claude_sync "$a" uninstall
}

# Two instances on one host, beside a program that holds the default ports.
group_instances() {
    echo "# several instances on one host"
    # E and G share a listener's network namespace, as two instances on one host where another
    # program holds Syncthing's default ports.
    docker run -d --name "$listener" --network "$net" --entrypoint sh "$image" \
        -c '(while true; do nc -l -p 22000 >/dev/null; done) &
            while true; do nc -l -p 8384 >/dev/null; done' >/dev/null
    wait_for listens "$listener" 8384
    wait_for listens "$listener" 22000
    check "a busy port asked for is refused" fails_with "port 8384 is in use" \
        beside "$e" setup --volume "$vol_e" --gui-port 8384
    check "  leaving no Syncthing state" fails docker volume inspect "$e-config"
    check "  nor writing to the target" in_target "type=volume,src=$vol_e" '[ ! -e /t/.stignore ]'
    out=$(beside "$e" setup --volume "$vol_e" --private)
    check "setup starts beside the busy default ports" grep -qF "This device ID" <<<"$out"
    check "  as a healthy container" [ "$(docker inspect -f '{{.State.Health.Status}}' "$e")" = healthy ]
    port_e=$(sync_port "$e" "$owner_e")
    check "  on another sync port" [ "${port_e:-22000}" != 22000 ]
    check "  and says which ports it uses" grep -qF "sync port $port_e" <<<"$out"
    check "  and why" grep -qF "Another program holds Syncthing's default" <<<"$out"
    out=$(beside "$g" setup --volume "$vol_g" --private --gui-port 8484 --sync-port 22100)
    check "--gui-port fixes the web UI port" listens "$g" 8484
    check "--sync-port fixes the sync port" [ "$(sync_port "$g" "$owner_g")" = 22100 ]
    check "  and Syncthing listens on it" wait_for listens "$g" 22100
    check "  and setup says so" grep -qF "127.0.0.1:8484" <<<"$out"
    check "setup again keeps the ports" beside "$g" setup --volume "$vol_g"
    check "  the web UI port" listens "$g" 8484
    check "  and the sync port" [ "$(sync_port "$g" "$owner_g")" = 22100 ]
    check "  and asking for them again is no clash" \
        beside "$g" setup --volume "$vol_g" --gui-port 8484 --sync-port 22100
    check "a busy port asked for again is refused" fails_with "port 8384 is in use" \
        beside "$g" setup --volume "$vol_g" --gui-port 8384
    check "  and the instance keeps its own" listens "$g" 8484
    check "the web UI on the sync port is refused" fails_with "would both be 22100" \
        beside "$g" setup --volume "$vol_g" --gui-port 22100
    check "  and the web UI stays put" listens "$g" 8484
    check "the sync port moving onto the web UI's" \
        beside "$g" setup --volume "$vol_g" --gui-port 8585 --sync-port 8484
    check "  puts the web UI on its new port" listens "$g" 8585
    # Syncthing retries a failed listener only after about a minute.
    check "  so the sync port binds without waiting for a retry" listens_soon "$g" 8484
    check "an exact swap of the two ports" beside "$g" setup --volume "$vol_g" --gui-port 8484 --sync-port 8585
    check "  keeps Syncthing's API in reach" st "$g" "$owner_g" show version
    check "  and the sync port binds once Syncthing retries" wait_for listens "$g" 8585
    check "a target another instance syncs is refused" fails_with "container $e already syncs $vol_e" \
        beside "$k" setup --volume "$vol_e"
    check "  creating no Syncthing state" fails docker volume inspect "$k-config"
    id_e=$(docker exec -u "$owner_e" "$e" syncthing device-id)
    id_g=$(docker exec -u "$owner_g" "$g" syncthing device-id)
    # Started before G accepts, so the join prints what to run there, with E's own sync port.
    CLAUDE_SYNC_COMPOSE_OVERRIDE=$root/tests/compose.busy.yaml CLAUDE_SYNC_NAME=$e timeout 300 \
        "$bin" pair "$id_g" --address "tcp://$listener:$(sync_port "$g" "$owner_g")" >"$scratch/join-e.out" 2>&1 &
    joining=$!
    check "pair names this instance's sync port" \
        wait_for grep -qF "tcp://THIS-HOST:$port_e" "$scratch/join-e.out"
    beside "$g" pair "$id_e" --address "tcp://$listener:$port_e" --keep >/dev/null
    check "E joins through G" wait "$joining"
    check "  and gets G's claude.json" [ "$(in_target "type=volume,src=$vol_e" 'cat /t/claude.json')" = "g claude.json" ]
    check "  moving its own file to the trash can" in_target "type=volume,src=$vol_e" '[ -e /t/.stversions/e-only.md ]'
    beside "$e" uninstall >/dev/null
    check "uninstalling E removes E" fails docker container inspect "$e"
    check "  and leaves G running" [ "$(docker inspect -f '{{.State.Running}}' "$g")" = true ]
    check "  with its folder" [ "$(st "$g" "$owner_g" config folders list)" = claude-sync ]
    beside "$g" uninstall >/dev/null
    docker rm --force -v "$listener" >/dev/null
}

# J: a first scan setup does not wait for, and a join stuck under an old ignore list.
group_stuck() {
    echo "# setup, while Syncthing's first scan runs"
    # A sparse file takes Syncthing far longer to hash than these checks, and no disk space.
    in_target "$mount_j" "truncate -s 64G /t/big && chown -R $owner_j /t"
    out=$(claude_sync "$j" setup --volume "$vol_j" --private)
    check "setup returns while Syncthing still scans" scanning "$j" "$owner_j"
    check "  and says so, with the web UI's address" \
        grep -qF "see progress at http://$(st "$j" "$owner_j" config gui raw-address get)" <<<"$out"
    check "setup again returns too" claude_sync "$j" setup --volume "$vol_j" --private
    check "  before the scan ends" scanning "$j" "$owner_j"
    claude_sync "$j" uninstall >/dev/null
    docker volume rm "$vol_j" >/dev/null
    docker volume create "$vol_j" >/dev/null

    echo "# pair, a join stuck on this device's own ignored files"
    # A copy with every (?d) taken out, which leaves .in_use without one as in 0.1.0:
    # Syncthing cannot remove J's own plugin version while its .in_use is there, so J's
    # join cannot finish.
    mkdir "$scratch/old"
    cp "$root/claude-sync" "$root"/compose*.yaml "$scratch/old"
    sed 's/^(?d)//' "$root/stignore" >"$scratch/old/stignore"
    j_plugin=plugins/cache/market/j-only/1.0.0
    in_target "$mount_j" "mkdir -p /t/$j_plugin && echo j >/t/$j_plugin/plugin.json && \
        echo j >/t/$j_plugin/.in_use && chown -R $owner_j /t"
    env CLAUDE_SYNC_NAME="$j" "$scratch/old/claude-sync" setup --volume "$vol_j" --private >/dev/null
    id_j=$(docker exec -u "$owner_j" "$j" syncthing device-id)
    claude_sync "$l" setup --volume "$vol_l" --private >/dev/null
    id_l=$(docker exec -u "$owner_l" "$l" syncthing device-id)
    pair_bounded "$l" "$id_j" --address "tcp://$j:22000" --keep >/dev/null
    check "J's join does not finish under that list" cut_off env CLAUDE_SYNC_NAME="$j" timeout 15 \
        "$scratch/old/claude-sync" pair "$id_l" --address "tcp://$l:22000"
    check "setup applies this version's ignore list" claude_sync "$j" setup --volume "$vol_j" --private
    # Syncthing reloads the list on its own at a later pull, but only minutes later, so a
    # join that finishes within this timeout shows setup applied it.
    check "  and the join then finishes at once" env CLAUDE_SYNC_NAME="$j" timeout 30 \
        "$bin" pair "$id_l" --address "tcp://$l:22000"
    check "  discarding J's own plugin version" in_target "$mount_j" "[ ! -e /t/$j_plugin ]"
    check "  into J's trash can" in_target "$mount_j" "[ -e /t/.stversions/$j_plugin/plugin.json ]"
}

# Input setup refuses, and objects uninstall refuses, on node M of its own.
group_refusals() {
    echo "# version"
    check "version prints the version" [ "$("$bin" version)" = "claude-sync ${CLAUDE_SYNC_BIN_VERSION:-dev}" ]
    check "  and so does --version" [ "$("$bin" --version)" = "claude-sync ${CLAUDE_SYNC_BIN_VERSION:-dev}" ]
    for f in compose.yaml compose.path.yaml compose.volume.yaml stignore; do
        check "carries $f unchanged" carries "$f"
    done

    echo "# setup rejects bad input"
    check "a missing volume is rejected" fails_with "no Docker volume named $vol_missing" \
        claude_sync "$m" setup --volume "$vol_missing"
    check "  and is not created" fails docker volume inspect "$vol_missing"
    check "a root-owned target is rejected" fails_with "owned by root" claude_sync "$m" setup --volume "$vol_root"
    check "  and nothing is written to it" in_target "type=volume,src=$vol_root" '[ ! -e /t/.stignore ]'
    check "an invalid CLAUDE_SYNC_NAME is rejected" fails_with CLAUDE_SYNC_NAME \
        claude_sync "$bad_name" setup --volume "$vol_m"
    check "  and creates no volume" fails docker volume inspect "$bad_name-config"
    # A missing volume, so a broken name check still stops before creating anything unprefixed.
    check "a one-character CLAUDE_SYNC_NAME is rejected" fails_with CLAUDE_SYNC_NAME \
        claude_sync x setup --volume "$vol_missing"
    check "a port that is not a number is refused" fails_with "not a port" \
        claude_sync "$m" setup --volume "$vol_m" --gui-port http
    check "  and one below 1024" fails_with "not a port" claude_sync "$m" setup --volume "$vol_m" --sync-port 80
    check "  and the same port for both" fails_with "need different ports" \
        claude_sync "$m" setup --volume "$vol_m" --gui-port 8500 --sync-port 8500
    check "  and creates no Syncthing state" fails docker volume inspect "$m-config"
    # A stand-in for this user's Syncthing on the host, stopped: it answers only `paths`, so
    # the checks must read its config file, which write_host_folders writes. The volume and
    # directories do not exist, so even a setup that got past the checks would stop before
    # creating anything.
    mkdir "$scratch/host"
    cat >"$scratch/host/syncthing" <<'EOF'
#!/bin/sh
[ "$*" = paths ] || exit 1
printf 'Configuration file:\n\t%s/config.xml\n' "${0%/*}"
EOF
    chmod +x "$scratch/host/syncthing"
    # The stand-in's folders, as ID and path pairs, the path already escaped for XML.
    write_host_folders() {
        {
            echo '<configuration version="51">'
            # As Syncthing writes it: the template for new folders, with no ID or path.
            printf '    <defaults>\n        <folder id="" label="" path="" type="sendreceive">\n        </folder>\n    </defaults>\n'
            while (($#)); do
                printf '    <folder id="%s" label="x" path="%s" type="sendreceive">\n    </folder>\n' "$1" "$2"
                shift 2
            done
            echo '</configuration>'
        } >"$scratch/host/config.xml"
    }
    # shellcheck disable=SC2329 # called below; ShellCheck cannot follow run_group
    beside_host() {
        env PATH="$scratch/host:$PATH" CLAUDE_SYNC_NAME=claude-sync "$bin" setup "$@"
    }
    readonly elsewhere=/nonexistent/$prefix$$
    write_host_folders claude-sync "$elsewhere/claude"
    check "a volume beside a Syncthing that syncs claude-sync's folder is refused" \
        fails_with "set CLAUDE_SYNC_NAME to another name" beside_host --volume "$vol_missing"
    check "  and a directory, pointing to --use-host-syncthing" fails_with "add --use-host-syncthing" \
        beside_host --path "$elsewhere/other"
    write_host_folders photos "$elsewhere/photos"
    check "  but not beside one without that folder" fails_with "no Docker volume named $vol_missing" \
        beside_host --volume "$vol_missing"
    check "a directory inside a folder of that Syncthing is refused" fails_with "folder photos already syncs" \
        beside_host --path "$elsewhere/photos/sub"
    check "  and one around it" fails_with "folder photos already syncs" beside_host --path "$elsewhere"
    # Under a name of their own: a real claude-sync instance on this Docker daemon, under the
    # default name, would refuse these first.
    check "  but not one beside it" fails_with "cannot read $elsewhere/photos2" \
        env PATH="$scratch/host:$PATH" CLAUDE_SYNC_NAME="$m" "$bin" setup --path "$elsewhere/photos2"
    check "  nor one here, where the folder template's empty path would point" \
        fails_with "cannot read $PWD/${prefix}here" \
        env PATH="$scratch/host:$PATH" CLAUDE_SYNC_NAME="$m" "$bin" setup --path "${prefix}here"
    check "  and under another name too" fails_with "folder photos already syncs" \
        env PATH="$scratch/host:$PATH" CLAUDE_SYNC_NAME="$m" "$bin" setup --path "$elsewhere/photos/sub"
    write_host_folders claude-sync "$elsewhere/claude"
    check "  where claude-sync's own folder there counts as any other" fails_with "folder claude-sync already syncs" \
        env PATH="$scratch/host:$PATH" CLAUDE_SYNC_NAME="$m" "$bin" setup --path "$elsewhere/claude/x"
    write_host_folders music "$elsewhere/rock&amp;roll"
    check "  read with the path's XML escapes undone" fails_with "folder music already syncs" \
        beside_host --path "$elsewhere/rock&roll/live"
    write_host_folders notes "$elsewhere/it&#39;s"
    check "  numeric ones too" fails_with "folder notes already syncs" beside_host --path "$elsewhere/it's/x"
    check "no container or state is left behind" fails docker container inspect "$m"
    check "  nor Syncthing state" fails docker volume inspect "$m-config"

    # A real --path run would need a directory on the Docker host, which is not this
    # filesystem when the tests run in a dev container that shares the host's daemon. Path
    # mode differs from volume mode only in its compose overlay and path handling, which
    # these check without a mount.
    echo "# setup --path"
    check "a missing directory is rejected" fails_with "cannot read /nonexistent/$prefix$$" \
        claude_sync "$m" setup --path "/nonexistent/$prefix$$"
    check "a path with a comma is rejected" fails_with comma claude_sync "$m" setup --path /tmp/a,b
    check "  and one with a newline" fails_with newline claude_sync "$m" setup --path $'/tmp/a\nb'
    check "a relative path is made absolute" relative_path_resolved
    check "  and one spelled loosely is cleaned as Docker does" fails_with "cannot read $root/${prefix}missing" \
        claude_sync "$m" setup --path "$root/./tests/..//${prefix}missing/"
    check "the overlay bind-mounts the directory" path_overlay_renders

    echo "# setup fails when Syncthing cannot run the folder"
    # A scratch copy of the checkout, so the broken ignore list never touches the repo's.
    mkdir "$scratch/broken"
    cp "$root/claude-sync" "$root"/compose*.yaml "$root/stignore" "$scratch/broken"
    echo '*.bad[0-9a-f]' >>"$scratch/broken/stignore"
    check "an ignore list Syncthing rejects fails setup with its error" fails_with "invalid pattern" \
        env CLAUDE_SYNC_NAME="$m" "$scratch/broken/claude-sync" setup --volume "$vol_m" --private
    check "  and leaves no compose files behind" no_leftovers
    claude_sync "$m" uninstall >/dev/null

    echo "# uninstall refuses what claude-sync did not create"
    # One foreign object at a time, so each refusal can only come from its own check.
    docker run -d --name "$foreign" --entrypoint sleep "$image" 600 >/dev/null
    check "a foreign container is refused" fails_with "container $foreign was not created by claude-sync" \
        claude_sync "$foreign" uninstall
    check "  and survives" docker container inspect "$foreign"
    docker rm --force -v "$foreign" >/dev/null
    docker volume create "$foreign-config" >/dev/null
    check "a foreign volume is refused" fails_with "volume $foreign-config was not created by claude-sync" \
        claude_sync "$foreign" uninstall
    check "  and survives" docker volume inspect "$foreign-config"
}

# A function of the claude-sync under test, run with its arguments.
calls() {
    # shellcheck disable=SC2016 # expanded by the inner bash
    bash -c 'source "$1" help >/dev/null && "${@:2}"' _ "$bin" "$@"
}

# The version an instance's container was last set up by.
stamp_of() {
    docker exec "$1" cat /var/syncthing/config/claude-sync-version
}

# A fake release list in the shape of GitHub's API, for a repository at BASE: v0.4.1 is the
# only release with files, and SUMS, if given, is the repository its SHA-256 is in.
releases_json() {
    local base=$1 sums=${2:-$1}
    cat <<EOF
[
  {"html_url": "$base/releases/tag/v0.5.0", "tag_name": "v0.5.0", "prerelease": false, "assets": []},
  {"html_url": "$base/releases/tag/v0.4.2-rc.1", "tag_name": "v0.4.2-rc.1", "prerelease": true, "assets": []},
  {"html_url": "$base/releases/tag/v0.4.1", "tag_name": "v0.4.1", "prerelease": false, "assets": [
    {"browser_download_url": "$base/releases/download/v0.4.1/claude-sync"},
    {"browser_download_url": "$sums/releases/download/v0.4.1/claude-sync.sha256"}
  ]},
  {"html_url": "$base/releases/tag/v0.4.0", "tag_name": "v0.4.0", "prerelease": false, "assets": []}
]
EOF
}

# The newest releases in LIST, to the 0.4.0 build: the one that is not breaking and the
# one that is.
newest_releases() {
    # shellcheck disable=SC2016 # expanded by the inner bash
    CLAUDE_SYNC_RELEASES_API="file://$up/releases/$1" bash -c \
        'source "$1" help >/dev/null && check_releases && echo "$release_safe $release_breaking"' _ "$up/old/claude-sync"
}

# CMD with the fake releases in LIST. Upgrade acts on every instance on the Docker daemon
# and in the runner's own Syncthing, which may hold real ones, and the other groups run
# beside it, so it runs with the shims for docker and syncthing.
with_releases() {
    env PATH="$up/shim:$PATH" CLAUDE_SYNC_RELEASES_API="file://$up/releases/$1" \
        timeout 600 "${@:2}"
}

# upgrade as installed in $up/install, with the fake releases in LIST.
upgrade_here() {
    with_releases "$1" "$up/install/claude-sync" upgrade
}

# N, P and the host fixture HU: instances set up by one build, reapplied by a newer one.
group_upgrade() {
    echo "# upgrade"
    # This group's files, apart from the other groups' in $scratch; the helpers above use it.
    up=$scratch/upgrade
    # 0.4.0, the build installed: a copy whose ignore list and compose file differ from this
    # checkout's, so the reapply shows. 0.4.1, the release: this checkout.
    mkdir -p "$up/old-src/packaging" "$up/old" "$up/install" "$up/shim" "$up/rpm" \
        "$up/releases/download/v0.4.1" "$up/bad/releases/download/v0.4.1" \
        "$up/wrong/releases/download/v0.4.1"
    cp "$root/claude-sync" "$root"/compose*.yaml "$root/stignore" "$up/old-src"
    cp "$root/packaging/build.sh" "$up/old-src/packaging"
    echo '// the old ignore list' >>"$up/old-src/stignore"
    sed -i 's/^    restart: unless-stopped$/&\n    labels: [claude-sync-test-old=1]/' "$up/old-src/compose.yaml"
    "$up/old-src/packaging/build.sh" 0.4.0 "$up/old/claude-sync"
    "$root/packaging/build.sh" 0.4.1 "$up/releases/download/v0.4.1/claude-sync"
    (cd "$up/releases/download/v0.4.1" && sha256sum claude-sync >claude-sync.sha256)
    echo "0000000000000000000000000000000000000000000000000000000000000000  claude-sync" \
        >"$up/bad/releases/download/v0.4.1/claude-sync.sha256"
    # A release whose file says it is another version.
    "$root/packaging/build.sh" 0.4.9 "$up/wrong/releases/download/v0.4.1/claude-sync"
    (cd "$up/wrong/releases/download/v0.4.1" && sha256sum claude-sync >claude-sync.sha256)
    releases_json "file://$up" >"$up/releases/releases.json"
    releases_json "file://$up" "file://$up/bad" >"$up/releases/bad.json"
    releases_json "file://$up/wrong" >"$up/releases/wrong.json"
    # A release with no files, and one whose claude-sync is not there, though its SHA-256 is.
    releases_json "file://$up" | sed '/browser_download_url/d' >"$up/releases/no-assets.json"
    releases_json "file://$up/gone" "file://$up" >"$up/releases/gone.json"
    # Tags in no version order, as GitHub lists releases by date: neither the first nor the
    # last of each kind is the newest.
    cat >"$up/releases/order.json" <<'EOF'
[
  {"tag_name": "v0.4.2"}, {"tag_name": "v0.5.0"}, {"tag_name": "v0.4.3"},
  {"tag_name": "v0.6.0"}, {"tag_name": "v0.4.1"}, {"tag_name": "v0.5.1"}
]
EOF
    readonly new=$up/releases/download/v0.4.1/claude-sync
    cp "$up/old/claude-sync" "$up/install/claude-sync"
    # A second name for the installed file: a rewrite in place would show through it.
    ln "$up/install/claude-sync" "$up/held"
    # Lists only N's, P's and S's volumes, as `volume ls -q` gives them; S has no container.
    # Under any other instance's name, or under one of the names in CLAUDE_SYNC_TEST_REFUSE,
    # which makes that instance's setup fail, it lets through only reads and commands run in
    # N's and P's containers. With CLAUDE_SYNC_TEST_DOCKER_DOWN set, every command fails, as
    # with a daemon that is not running.
    cat >"$up/shim/docker" <<EOF
#!/usr/bin/env bash
real=$(command -v docker) n=$n p=$p s=$s
EOF
    cat >>"$up/shim/docker" <<'EOF'
if [[ -n ${CLAUDE_SYNC_TEST_DOCKER_DOWN:-} ]]; then
    echo "docker shim: cannot connect to the Docker daemon" >&2
    exit 1
fi
if [[ $1 == volume && $2 == ls ]]; then
    "$real" "$@" | grep -xF -e "$n-config" -e "$p-config" -e "$s-config" || true
    exit
fi
ours() { [[ $1 == "$n" || $1 == "$p" ]]; }
if ours "${CLAUDE_SYNC_NAME:-}" && [[ " ${CLAUDE_SYNC_TEST_REFUSE:-} " != *" $CLAUDE_SYNC_NAME "* ]]; then
    exec "$real" "$@"
fi
[[ $1 == inspect || $1 == ps || ($1 =~ ^(container|volume|image)$ && $2 == inspect) ]] && exec "$real" "$@"
[[ $1 == exec ]] && ours "$2" && exec "$real" "$@"
echo "docker shim: refusing docker $* under CLAUDE_SYNC_NAME=${CLAUDE_SYNC_NAME:-}" >&2
exit 97
EOF
    # No Syncthing on this host as far as upgrade can tell, so it never finds the runner's.
    printf '#!/bin/sh\nexit 1\n' >"$up/shim/syncthing"
    # shellcheck disable=SC2016 # expanded by the fake rpm
    printf '#!/bin/sh\n[ "$1" = -qf ] && echo claude-sync-0.4.0-1.noarch\n' >"$up/rpm/rpm"
    chmod +x "$up/shim/docker" "$up/shim/syncthing" "$up/rpm/rpm"

    check "a new minor version while the major is 0 is breaking" calls version_breaking 0.4.0 0.5.0
    check "  a new patch version is not" fails calls version_breaking 0.4.0 0.4.9
    check "  nor a new minor version from 1" fails calls version_breaking 1.4.0 1.9.0
    check "  but a new major version is" calls version_breaking 1.4.0 2.0.0
    check "versions compare by number" calls version_older 0.9.0 0.10.0
    check "  a pre-release before its release" calls version_older 0.4.0-rc.1 0.4.0
    check "  also as an RPM writes it" calls version_older 0.4.0~rc.1 0.4.0
    check "  and a version not before itself" fails calls version_older 0.4.0 0.4.0
    check "the newest release of each kind is picked, whatever the list's order" \
        [ "$(newest_releases order.json)" = "v0.4.3 v0.6.0" ]

    # With no release list, so a refusal that fails cannot go further.
    check "upgrade from a checkout is refused" fails_with "runs from a checkout" \
        with_releases missing.json "$root/claude-sync" upgrade
    check "upgrade of a file an RPM installed is refused" fails_with "upgrade it with dnf" \
        with_releases missing.json env PATH="$up/rpm:$up/shim:$PATH" "$up/install/claude-sync" upgrade
    check "a download that fails its SHA-256 check is refused" fails_with "SHA-256" upgrade_here bad.json
    check "  leaving the installed file as it was" cmp -s "$up/install/claude-sync" "$up/old/claude-sync"
    check "a download that is another version is refused" fails_with "is not version 0.4.1" \
        upgrade_here wrong.json
    check "  leaving the installed file as it was" cmp -s "$up/install/claude-sync" "$up/old/claude-sync"
    check "upgrade without the list of releases fails" fails_with "cannot get the list of claude-sync's releases" \
        upgrade_here missing.json
    check "a release with no files is refused" fails_with "release v0.4.1 has no claude-sync or claude-sync.sha256" \
        upgrade_here no-assets.json
    check "a download that fails is refused" \
        fails_with "cannot download file://$up/gone/releases/download/v0.4.1/claude-sync" upgrade_here gone.json
    check "  leaving the installed file as it was" cmp -s "$up/install/claude-sync" "$up/old/claude-sync"
    check "  and no download behind" [ "$(ls -A "$up/install")" = claude-sync ]

    CLAUDE_SYNC_NAME=$n "$up/old/claude-sync" setup --volume "$vol_n" --private >/dev/null
    CLAUDE_SYNC_NAME=$p "$up/old/claude-sync" setup --volume "$vol_p" --gui-port 8484 --sync-port 22100 >/dev/null
    id_n=$(docker exec -u "$owner_n" "$n" syncthing device-id)
    check "setup stamps the instance with its version" [ "$(stamp_of "$n")" = 0.4.0 ]
    check "a newer claude-sync says the instance needs its setup" \
        fails_with "last set up by claude-sync 0.4.0; run CLAUDE_SYNC_NAME=$n claude-sync setup" \
        env CLAUDE_SYNC_NAME="$n" "$new" pair not-a-device-id
    check "  and so does unpair" \
        fails_with "last set up by claude-sync 0.4.0; run CLAUDE_SYNC_NAME=$n claude-sync setup" \
        env CLAUDE_SYNC_NAME="$n" "$new" unpair not-a-device-id
    check "setup with no target reapplies to the instance's own" env CLAUDE_SYNC_NAME="$n" "$up/old/claude-sync" setup
    CLAUDE_SYNC_NAME=$hu "$new" setup >/dev/null 2>&1 && status=0 || status=$?
    check "  and where there is none, prints usage" [ "$status" = 2 ]
    check "  and with a name that is not valid, says so" fails_with "CLAUDE_SYNC_NAME must be" \
        env CLAUDE_SYNC_NAME=Not-Valid "$new" setup
    check "  and where docker cannot be reached, says so" fails_with "docker cannot be reached" \
        with_releases missing.json env CLAUDE_SYNC_TEST_DOCKER_DOWN=1 CLAUDE_SYNC_NAME="$n" "$new" setup

    # A failed upgrade goes on to the checks, which say what it left undone.
    out=$(upgrade_here releases.json) || true
    check "upgrade says a newer breaking release is out" grep -qF "claude-sync 0.5.0 is out" <<<"$out"
    check "  with its release notes" grep -qF "file://$up/releases/tag/v0.5.0" <<<"$out"
    check "  and installs the newest that is not breaking" \
        [ "$("$up/install/claude-sync" version)" = "claude-sync 0.4.1" ]
    check "  a new file in place of the old, never rewriting it" cmp -s "$up/held" "$up/old/claude-sync"
    check "  leaving no download behind" [ "$(ls -A "$up/install")" = claude-sync ]
    check "the new version reapplies itself to each instance" [ "$(stamp_of "$n")" = 0.4.1 ]
    check "  and the other" [ "$(stamp_of "$p")" = 0.4.1 ]
    check "  with its ignore list" stignore_installed "$mount_n"
    check "  and its compose file" [ -z "$(docker inspect -f '{{index .Config.Labels "claude-sync-test-old"}}' "$n")" ]
    check "  keeping the device ID" [ "$(docker exec -u "$owner_n" "$n" syncthing device-id)" = "$id_n" ]
    check "  a private instance private" [ "$(network_options "$n" "$owner_n")" = '[false,false,false]' ]
    check "  and the ports given to setup" listens "$p" 8484
    check "  both" [ "$(sync_port "$p" "$owner_p")" = 22100 ]

    docker exec -u "$owner_n" "$n" sh -c 'echo 0.4.0 >/var/syncthing/config/claude-sync-version'
    docker exec -u "$owner_p" "$p" sh -c 'echo 0.4.0 >/var/syncthing/config/claude-sync-version'
    out=$(with_releases releases.json env CLAUDE_SYNC_TEST_REFUSE="$n" "$up/install/claude-sync" upgrade 2>&1) &&
        status=0 || status=$?
    check "upgrade goes on past an instance whose setup fails" [ "$(stamp_of "$p")" = 0.4.1 ]
    check "  then fails" [ "$status" != 0 ]
    check "  naming it" grep -qF "setup failed for instance $n;" <<<"$out"
    check "  which keeps its old stamp" [ "$(stamp_of "$n")" = 0.4.0 ]
    docker exec -u "$owner_p" "$p" sh -c 'echo 0.4.0 >/var/syncthing/config/claude-sync-version'
    out=$(with_releases releases.json env CLAUDE_SYNC_TEST_REFUSE="$n $p" "$up/install/claude-sync" upgrade 2>&1) ||
        true
    check "upgrade names every instance whose setup fails" grep -qF "setup failed for instances $n $p;" <<<"$out"

    docker stop "$p" >/dev/null
    out=$(upgrade_here releases.json) && status=0 || status=$?
    check "upgrade again reapplies an instance an older version set up" [ "$(stamp_of "$n")" = 0.4.1 ]
    check "  succeeding" [ "$status" = 0 ]
    check "  naming it" grep -qF "to instance $n" <<<"$out"
    check "  says it leaves a stopped instance be" grep -qF "$p is stopped" <<<"$out"
    check "  and does" [ "$(docker inspect -f '{{.State.Running}}' "$p")" = false ]
    out=$(upgrade_here releases.json) && status=0 || status=$?
    check "upgrade with nothing to do reapplies nothing" fails grep -qF "to instance" <<<"$out"
    check "  succeeding" [ "$status" = 0 ]
    check "  and says every running instance runs it" \
        grep -qF "Every running instance already runs claude-sync 0.4.1" <<<"$out"
    out=$(env CLAUDE_SYNC_NAME="$n" "$new" pair not-a-device-id 2>&1) || true
    check "  so pair no longer says the instance needs its setup" fails grep -qF "last set up by" <<<"$out"
    check "  getting on to the device ID" grep -qF "not a device ID" <<<"$out"

    # As an instance set up by 0.1.1 or earlier.
    docker exec -u "$owner_n" "$n" rm /var/syncthing/config/claude-sync-version
    check "an instance with no stamp counts as set up by an older claude-sync" \
        fails_with "last set up by an older claude-sync; run CLAUDE_SYNC_NAME=$n claude-sync setup" \
        env CLAUDE_SYNC_NAME="$n" "$new" pair not-a-device-id
    # Where the stamp goes, a directory, which setup cannot write to.
    docker exec -u "$owner_n" "$n" mkdir /var/syncthing/config/claude-sync-version
    check "setup says when it cannot record the version" \
        fails_with "cannot record the version in instance $n" env CLAUDE_SYNC_NAME="$n" "$new" setup
    docker exec -u "$owner_n" "$n" rmdir /var/syncthing/config/claude-sync-version
    out=$(upgrade_here releases.json) && status=0 || status=$?
    check "upgrade reapplies an instance with no stamp" [ "$(stamp_of "$n")" = 0.4.1 ]
    check "  succeeding" [ "$status" = 0 ]
    check "  naming it" grep -qF "to instance $n" <<<"$out"
    docker exec -u "$owner_n" "$n" sh -c 'echo dev >/var/syncthing/config/claude-sync-version'
    check "an instance a checkout set up counts as older too" \
        fails_with "last set up by claude-sync dev; run CLAUDE_SYNC_NAME=$n claude-sync setup" \
        env CLAUDE_SYNC_NAME="$n" "$new" pair not-a-device-id
    out=$(with_releases releases.json env CLAUDE_SYNC_TEST_DOCKER_DOWN=1 "$up/install/claude-sync" upgrade 2>&1) &&
        status=0 || status=$?
    check "upgrade when docker cannot list the instances fails" [ "$status" != 0 ]
    check "  saying so" grep -qF "docker cannot list the instances in containers" <<<"$out"
    check "  and not that there is none" fails grep -qF "no instance is set up" <<<"$out"
    check "  leaving them as they were" [ "$(stamp_of "$n")" = dev ]
    docker stop "$n" >/dev/null
    # Syncthing state that no container uses, labelled as setup labels it.
    docker volume create --label claude-sync=config "$s-config" >/dev/null
    out=$(upgrade_here releases.json) && status=0 || status=$?
    check "  which it does not say with none running" fails grep -qF "Every running instance" <<<"$out"
    check "  succeeding" [ "$status" = 0 ]
    check "upgrade names Syncthing state no container uses" \
        grep -qF "Volume $s-config holds the Syncthing state of instance $s," <<<"$out"

    echo "# upgrade, on the host's Syncthing"
    docker run -d --name "$hu" --network "$net" --user user --entrypoint env "$host_image" \
        -u STHOMEDIR -u STGUIADDRESS HOME=/home/user syncthing serve --no-browser >/dev/null
    docker exec -u 0 "$hu" mkdir -p /opt/releases /home/user/bin
    docker exec -u 0 "$hu" chown user /home/user/bin
    docker cp -q "$up/releases/download" "$hu:/opt/releases/"
    releases_json file:///opt | docker exec -i -u 0 "$hu" sh -c 'cat >/opt/releases/releases.json'
    docker cp -q "$up/old/claude-sync" "$hu:/home/user/bin/"
    docker exec -u 0 "$hu" chown user /home/user/bin/claude-sync
    docker cp -q "$root/stignore" "$hu:/opt/stignore"
    wait_for as_user "$hu" syncthing cli show version
    as_user "$hu" mkdir claude
    as_user "$hu" bin/claude-sync setup --path claude --use-host-syncthing >/dev/null
    check "list shows the host's Syncthing" grep -qE "^\* claude-sync +host Syncthing +directory /home/user/claude\$" \
        <<<"$(as_user "$hu" bin/claude-sync list)"
    check "setup stamps the host's Syncthing too" \
        [ "$(as_user "$hu" cat .local/state/syncthing/claude-sync-version)" = 0.4.0 ]
    check "a newer claude-sync says the host's Syncthing needs its setup" \
        fails_with "last set up by claude-sync 0.4.0; run claude-sync setup to apply 0.4.1" \
        as_user "$hu" bash /opt/releases/download/v0.4.1/claude-sync pair not-a-device-id
    check "upgrade there" as_user "$hu" env CLAUDE_SYNC_RELEASES_API=file:///opt/releases/releases.json \
        timeout 300 bin/claude-sync upgrade
    check "  installs the release" [ "$(as_user "$hu" bin/claude-sync version)" = "claude-sync 0.4.1" ]
    check "  and reapplies it to the folder" as_user "$hu" cmp -s claude/.stignore /opt/stignore
    check "  stamping it" [ "$(as_user "$hu" cat .local/state/syncthing/claude-sync-version)" = 0.4.1 ]
    check "setup with no target reapplies there too" as_user "$hu" timeout 300 bin/claude-sync setup
    as_user "$hu" bin/claude-sync uninstall >/dev/null
    check "uninstall removes the stamp" fails as_user "$hu" test -e .local/state/syncthing/claude-sync-version
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

# The calls the stub systemctl got since the last reset, apart from is-system-running, which
# changes nothing.
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
    cp "$bin" "$tm/other/claude-sync"
    [[ -n ${CLAUDE_SYNC_BIN:-} ]] || cp "$root"/compose*.yaml "$root/stignore" "$tm/other/"
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
    claude_sync "$u" setup --no-backup >/dev/null
    check "  and with none, does nothing" [ -z "$(systemctl_calls)" ]
    claude_sync "$u" setup --backup-dir "$tm/backups" >/dev/null
    claude_sync "$u" backup "$tm/backups" >/dev/null
    check "uninstall without systemd's user manager says so" \
        fails_with "cannot reach systemd's user manager to remove $u-backup.timer" \
        env SYSTEMCTL_STATE=offline CLAUDE_SYNC_NAME="$u" "$bin" uninstall
    check "  removing nothing" docker container inspect "$u"
    mkdir "$tm/kept"
    cp -p -- "$service" "$timer" "$tm/kept/"
    rm -f -- "$SYSTEMCTL_CALLS"
    claude_sync "$u" uninstall >/dev/null
    check "uninstall removes the daily backup" [ -z "$(ls -A "$units")" ]
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
    docker cp -q "$bin" "$y:/opt/claude-sync/"
    [[ -n ${CLAUDE_SYNC_BIN:-} ]] || docker cp -q "$root/stignore" "$y:/opt/claude-sync/"
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
    check "  or adding the folder" fails grep -qx claude-sync <<<"$(as_user "$y" syncthing cli config folders list)"
    y_sync setup --path claude --use-host-syncthing --backup-dir backups >/dev/null
    check "setup --use-host-syncthing --backup-dir installs the daily backup, DIR made absolute" \
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
    y_sync setup --backup-dir backups >/dev/null
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

run_group chain
run_group instances
run_group stuck
run_group refusals
run_group upgrade
run_group backups
run_group timer
run_group select
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
