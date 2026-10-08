#!/usr/bin/env bash
# Integration tests: claude-sync against real Syncthing containers on throwaway targets.
# Every container, volume, network and image this keeps is named claude-sync-test-*, and cleanup
# refuses anything else: a dev container may share the host's live Docker daemon, where a
# real ~/.claude volume lives.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly root
readonly prefix=claude-sync-test-
readonly net=${prefix}net a=${prefix}a b=${prefix}b c=${prefix}c d=${prefix}d
readonly listener=${prefix}listener foreign=${prefix}foreign h=${prefix}h host_image=${prefix}host
readonly vol_a=${prefix}a-data vol_b=${prefix}b-data vol_missing=${prefix}missing
readonly vol_root=${prefix}root-data vol_c=${prefix}c-data vol_d=${prefix}d-data
# Not Syncthing's default 1000, so a match proves the owner was read from the target.
readonly owner_a=1234:1234 owner_b=2345:2345 owner_c=3456:3456 owner_d=4567:4567
readonly mount_a=type=volume,src=$vol_a mount_b=type=volume,src=$vol_b mount_c=type=volume,src=$vol_c
image=$(sed -n 's/^ *image: *//p' "$root/compose.yaml")
readonly image
[[ -n $image ]] || {
    echo "no image in compose.yaml" >&2
    exit 1
}
readonly bad_name=${prefix}BAD
export CLAUDE_SYNC_COMPOSE_OVERRIDE=$root/tests/compose.test.yaml
# claude-sync looks for a Syncthing of the user running it on this host; pointed at an
# empty home, it never reaches a developer's own.
export STHOMEDIR=/nonexistent/${prefix}home
unset STCONFDIR STDATADIR STGUIADDRESS STGUIAPIKEY

for tool in docker jq cmp; do
    command -v "$tool" >/dev/null || {
        echo "tests/integration.sh needs $tool" >&2
        exit 1
    }
done

# Synthetic ~/.claude: real filename shapes, no real data. The look-alikes in `synced`
# (lockfiles, .tmp-like names, nested daemon/ and ide/) must not be caught by ignore rules.
readonly task=tasks/3570ff36-0222-44b7-8023-47d964bf700c
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
    fi
}

fails() {
    ! "$@" >/dev/null 2>&1
}

fails_with() {
    local message=$1 out
    shift
    out=$("$@" 2>&1) && return 1
    grep -qF -- "$message" <<<"$out"
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
    CLAUDE_SYNC_NAME=$node "$root/claude-sync" "$@"
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

trusts() {
    [ "$(st "$1" "$2" config devices "$3" introducer get)" = true ]
}

# A command as `user` on the host fixture, where Syncthing runs without a container, with
# its own defaults rather than the image's.
on_host() {
    docker exec -u user -w /home/user "$h" env -u STHOMEDIR -u STGUIADDRESS HOME=/home/user "$@"
}

host_sync() {
    on_host timeout 300 /opt/claude-sync/claude-sync "$@"
}

host_introducer() {
    on_host syncthing cli config devices "$1" introducer get
}

host_has_folder() {
    on_host syncthing cli config folders list | grep -qx claude-sync
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

# Without .stfolder, Syncthing's marker, which it deletes along with the folder.
host_idle() {
    # shellcheck disable=SC2016 # expanded by the fixture's shell
    on_host sh -c 'curl -kfsS -H "X-API-Key: $(syncthing cli config gui apikey get)" \
        "https://127.0.0.1:8384/rest/db/status?folder=claude-sync"' |
        jq -e '.state == "idle" and .needTotalItems == 0'
}

host_snapshot() {
    on_host sh -c 'cd claude && find . -path ./.stfolder -prune -o -print | sort &&
        find . -path ./.stfolder -prune -o -type f -exec sha256sum {} + | sort'
}

# A joining device's pair blocks until caught up; a bound turns a hang into a failure.
# Not for a background pair: killing a backgrounded function leaves timeout and pair
# running, so background `timeout ... claude-sync pair` itself.
pair_bounded() {
    local node=$1
    shift
    CLAUDE_SYNC_NAME=$node timeout 300 "$root/claude-sync" pair "$@"
}

relative_path_resolved() {
    local err
    err=$(cd "$root" && CLAUDE_SYNC_NAME=$c ./claude-sync setup --path "${prefix}missing" 2>&1 >/dev/null) &&
        return 1
    grep -qxF "claude-sync: cannot read $root/${prefix}missing" <<<"$err"
}

path_overlay_renders() {
    CLAUDE_SYNC_NAME=$a CLAUDE_SYNC_UID=1 CLAUDE_SYNC_GID=1 CLAUDE_SYNC_TARGET=/srv/claude \
        docker compose -f "$root/compose.yaml" -f "$root/compose.path.yaml" config --format json |
        jq -e '.services.syncthing.volumes | any(
            .type == "bind" and .source == "/srv/claude" and .target == "/var/syncthing/claude")'
}

snapshot() {
    in_target "$1" 'cd /t && find . | sort && find . -type f -exec sha256sum {} + | sort'
}

cleanup() {
    local x
    for x in "$a" "$b" "$c" "$d" "$h" "$bad_name" "$listener" "$foreign"; do
        guard "$x"
        docker rm --force -v "$x" >/dev/null 2>&1 || true
    done
    guard "$host_image"
    docker image rm "$host_image" >/dev/null 2>&1 || true
    for x in "$a-config" "$b-config" "$c-config" "$d-config" "$bad_name-config" "$foreign-config" \
        "$vol_a" "$vol_b" "$vol_c" "$vol_d" "$vol_missing" "$vol_root"; do
        guard "$x"
        docker volume rm "$x" >/dev/null 2>&1 || true
    done
    guard "$net"
    docker network rm "$net" >/dev/null 2>&1 || true
}

on_exit() {
    local status=$? node job
    for job in $(jobs -p); do
        kill "$job" 2>/dev/null || true
    done
    if ((status != 0)); then
        for node in "$a" "$b" "$c" "$d" "$h"; do
            docker logs --tail 30 "$node" 2>&1 | sed "s/^/[$node] /" || true
        done
        [[ ! -s $scratch/join.out ]] || sed 's/^/[join] /' "$scratch/join.out"
    fi
    cleanup
    [[ -z $scratch ]] || rm -rf -- "$scratch"
}

scratch=""
cleanup
# -E carries the trap into functions; the subshell test skips command substitutions in
# check arguments, which fail on purpose.
set -E
trap '((BASH_SUBSHELL == 0)) && echo "aborted at tests/integration.sh:$LINENO${FUNCNAME:+ in ${FUNCNAME[0]}, called from line ${BASH_LINENO[0]}}" >&2' ERR
trap on_exit EXIT

docker network create "$net" >/dev/null
docker volume create "$vol_a" >/dev/null
docker volume create "$vol_b" >/dev/null
docker volume create "$vol_root" >/dev/null
docker volume create "$vol_c" >/dev/null
docker volume create "$vol_d" >/dev/null
in_target "$mount_c" "chown $owner_c /t"
fixture="cd /t"
for f in "${synced[@]}" "${ignored[@]}"; do
    fixture+=" && mkdir -p \"\$(dirname '$f')\" && echo 'fixture $f' >'$f'"
done
in_target "$mount_a" "$fixture && chown -R $owner_a /t"
in_target "$mount_b" "chown $owner_b /t"
in_target "type=volume,src=$vol_d" "chown $owner_d /t"

echo "# setup rejects bad input"
check "a missing volume is rejected" fails_with "no Docker volume named $vol_missing" \
    claude_sync "$a" setup --volume "$vol_missing"
check "  and is not created" fails docker volume inspect "$vol_missing"
check "a root-owned target is rejected" fails_with "owned by root" claude_sync "$a" setup --volume "$vol_root"
check "  and nothing is written to it" in_target "type=volume,src=$vol_root" '[ ! -e /t/.stignore ]'
check "an invalid CLAUDE_SYNC_NAME is rejected" fails_with CLAUDE_SYNC_NAME \
    claude_sync "$bad_name" setup --volume "$vol_a"
check "  and creates no volume" fails docker volume inspect "$bad_name-config"
# A missing volume, so a broken name check still stops before creating anything unprefixed.
check "a one-character CLAUDE_SYNC_NAME is rejected" fails_with CLAUDE_SYNC_NAME \
    claude_sync x setup --volume "$vol_missing"
docker run -d --name "$listener" --entrypoint sh "$image" \
    -c 'while true; do nc -l -p 8384 >/dev/null; done' >/dev/null
wait_for docker exec "$listener" nc -z 127.0.0.1 8384
check "a busy port is refused" fails_with "port 8384 is in use" \
    env CLAUDE_SYNC_COMPOSE_OVERRIDE="$root/tests/compose.busy.yaml" \
    CLAUDE_SYNC_NAME="$c" "$root/claude-sync" setup --volume "$vol_c"
check "  suggesting the Syncthing already there" fails_with "--use-host-syncthing" \
    env CLAUDE_SYNC_COMPOSE_OVERRIDE="$root/tests/compose.busy.yaml" \
    CLAUDE_SYNC_NAME="$c" "$root/claude-sync" setup --volume "$vol_c"
check "  and leaves no Syncthing state" fails docker volume inspect "$c-config"
check "  nor writes to the target" in_target "$mount_c" '[ ! -e /t/.stignore ]'
docker rm --force -v "$listener" >/dev/null
check "no container or state is left behind" fails docker container inspect "$a"
check "  nor Syncthing state" fails docker volume inspect "$a-config"

echo "# setup --volume --private"
out=$(claude_sync "$a" setup --volume "$vol_a" --private)
id_a=$(docker exec -u "$owner_a" "$a" syncthing device-id)
check "prints this device's ID" grep -qF "This device ID: $id_a" <<<"$out"
check "Syncthing writes as the volume's owner" wait_for owned_by "$mount_a" .stfolder "$owner_a"
check ".stignore is the repo's stignore" stignore_installed "$mount_a"
check "trash can versioning, 14 days" trash_can_14_days "$a" "$owner_a"
check "no global discovery, relays or NAT traversal" \
    [ "$(network_options "$a" "$owner_a")" = '[false,false,false]' ]

echo "# setup --volume, again"
out=$(claude_sync "$a" setup --volume "$vol_a")
check "keeps the device ID" grep -qF "This device ID: $id_a" <<<"$out"
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

# A real --path run would need a directory on the Docker host, which is not this filesystem
# when the tests run in a dev container that shares the host's daemon. Path mode differs from volume
# mode only in its compose overlay and path handling, which these check without a mount.
echo "# setup --path"
check "a missing directory is rejected" fails_with "cannot read /nonexistent/$prefix$$" \
    claude_sync "$c" setup --path "/nonexistent/$prefix$$"
check "a path with a comma is rejected" fails_with comma claude_sync "$c" setup --path /tmp/a,b
check "a relative path is made absolute" relative_path_resolved
check "the overlay bind-mounts the directory" path_overlay_renders

echo "# setup fails when Syncthing cannot run the folder"
# A scratch copy of the checkout, so the broken ignore list never touches the repo's.
scratch=$(mktemp -d -t "${prefix}XXXXXX")
cp "$root/claude-sync" "$root"/compose*.yaml "$root/stignore" "$scratch"
echo '*.bad[0-9a-f]' >>"$scratch/stignore"
check "an ignore list Syncthing rejects fails setup with its error" fails_with "invalid pattern" \
    env CLAUDE_SYNC_NAME="$c" "$scratch/claude-sync" setup --volume "$vol_c" --private
claude_sync "$c" uninstall >/dev/null

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
check "a join cut off while waiting" fails env CLAUDE_SYNC_NAME="$b" timeout 10 \
    "$root/claude-sync" pair "$id_a" --address "tcp://$a:22000"
check "  leaves B's folder receive-only" [ "$(folder_type "$b" "$owner_b")" = receiveonly ]
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

echo "# pair, the first device of a new set without --keep"
# C's claude.json is newer than A's, so Syncthing's newest-wins rule alone would pick C's.
in_target "$mount_c" "echo 'c claude.json' >/t/claude.json && \
    echo c >/t/c-only.md && chown -R $owner_c /t"
claude_sync "$c" setup --volume "$vol_c" --private >/dev/null
id_c=$(docker exec -u "$owner_c" "$c" syncthing device-id)
# C, with files, and D, with none, both pair with no other device yet: both join, and
# only --keep on C would give D anything to join.
claude_sync "$d" setup --volume "$vol_d" --private >/dev/null
id_d=$(docker exec -u "$owner_d" "$d" syncthing device-id)
CLAUDE_SYNC_NAME=$d timeout 300 "$root/claude-sync" pair "$id_c" --address "tcp://$c:22000" >/dev/null 2>&1 &
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
CLAUDE_SYNC_NAME=$c timeout 300 "$root/claude-sync" pair "$id_a" --address "tcp://$a:22000" \
    >"$scratch/join.out" 2>&1 &
joining=$!
check "a join says what to run on the device it joins through" \
    wait_for grep -qF "claude-sync pair $id_c" "$scratch/join.out"
check "  and waits for it" kill -0 "$joining"
check "  and leaves C's files alone meanwhile" [ "$(in_target "$mount_c" 'cat /t/claude.json')" = "c claude.json" ]
pair_bounded "$a" "$id_c" --address "tcp://$c:22000" >/dev/null
check "C joins once A accepts" wait "$joining"
check "C gets A's claude.json" [ "$(in_target "$mount_c" 'cat /t/claude.json')" = "fixture claude.json" ]
check "C's own file is discarded" in_target "$mount_c" '[ ! -e /t/c-only.md ]'
check "  into C's trash can" in_target "$mount_c" '[ -e /t/.stversions/c-only.md ]'
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
check "D's join cut off while waiting" fails env CLAUDE_SYNC_NAME="$d" timeout 10 \
    "$root/claude-sync" pair "$id_b" --address "tcp://$b:22000"
check "  leaves D's folder receive-only" [ "$(folder_type "$d" "$owner_d")" = receiveonly ]
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
docker build -q -t "$host_image" --build-arg IMAGE="$image" -f "$root/tests/host.Dockerfile" \
    "$root/tests" >/dev/null
docker run -d --name "$h" --network "$net" --user user --entrypoint env "$host_image" \
    -u STHOMEDIR -u STGUIADDRESS HOME=/home/user syncthing serve --no-browser >/dev/null
docker exec -u 0 "$h" mkdir /opt/claude-sync
docker cp -q "$root/claude-sync" "$h:/opt/claude-sync/"
docker cp -q "$root/stignore" "$h:/opt/claude-sync/"
wait_for on_host syncthing cli show version
id_h=$(on_host syncthing device-id)
# The user's own Syncthing: folders of their own, one shared with B, private options, and
# a web UI address with no host.
on_host mkdir claude photos photos/sub notes other tilde
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
on_host syncthing cli config gui raw-address set :8384
host_before=$(host_config)
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
check "  and one around another folder" fails_with "already syncs" \
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
check ".stignore is the repo's stignore" on_host cmp -s claude/.stignore /opt/claude-sync/stignore
check "trash can versioning, 14 days" host_trash_can_14_days
check "setup again, naming the directory another way" host_sync setup --path ./claude/ --use-host-syncthing
check "  and refuses a different directory" fails_with "already set up for /home/user/claude" \
    host_sync setup --path other --use-host-syncthing
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
on_host syncthing cli config gui raw-use-tls set true
wait_for on_host curl -kfs https://127.0.0.1:8384/rest/noauth/health
check "pair reaches a web UI that uses TLS" \
    host_sync pair "$id_a" --address "tcp://$a:22000"
host_before=$(host_config)

echo "# uninstall, on the host's Syncthing"
wait_for host_idle
before=$(host_snapshot)
devices=$(on_host syncthing cli config devices list | sort)
host_sync uninstall >/dev/null
check "removes claude-sync's folder" fails host_has_folder
check "keeps the devices it paired" [ "$(on_host syncthing cli config devices list | sort)" = "$devices" ]
check "keeps the user's other folders and options" [ "$(host_config)" = "$host_before" ]
check "leaves the synced data byte-identical" [ "$(host_snapshot)" = "$before" ]
check "Syncthing keeps running" on_host syncthing cli show version
check "pair afterwards is refused" fails_with "run setup first" host_sync pair "$id_a"

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

((failures == 0)) || {
    echo "$failures check(s) failed" >&2
    exit 1
}
echo "all checks passed"
