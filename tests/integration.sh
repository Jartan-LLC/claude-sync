#!/usr/bin/env bash
# Integration tests: claude-sync against real Syncthing containers on throwaway targets.
# Every Docker object this creates is named claude-sync-test-*, and cleanup refuses
# anything else: a dev container may share the host's live Docker daemon, where a
# real ~/.claude volume lives.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly root
readonly prefix=claude-sync-test-
readonly net=${prefix}net a=${prefix}a b=${prefix}b
readonly vol_a=${prefix}a-data vol_b=${prefix}b-data vol_missing=${prefix}missing
# Not Syncthing's default 1000, so a match proves the owner was read from the target.
readonly owner_a=1234:1234 owner_b=2345:2345
readonly mount_a=type=volume,src=$vol_a mount_b=type=volume,src=$vol_b
image=$(sed -n 's/^ *image: *//p' "$root/compose.yaml")
readonly image
export CLAUDE_SYNC_COMPOSE_OVERRIDE=$root/tests/compose.test.yaml

# Synthetic ~/.claude: real filename shapes, no real data.
readonly synced=(
    settings.json
    claude.json
    projects/-work-demo/memory/note.md
    projects/-work-demo/0b6c1f9e-4d2a-4c8e-9f3b-2a7d5e8c1b40.jsonl
    skills/demo/SKILL.md
)
readonly ignored=(
    .credentials.json
    sessions/4242.json
    sessions/4242.key
    ide/4242.lock
    plugins/cache/market/demo/1.0.0/.in_use
    todos.lock
    settings.json.tmp.4242.1700000000
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

folder_status() {
    docker exec -u "$2" "$1" sh -c \
        'curl -fsS -H "X-API-Key: $(syncthing cli config gui apikey get)" \
            "http://127.0.0.1:8384/rest/db/status?folder=claude-sync"'
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

relative_path_resolved() {
    local err
    err=$(cd "$root" && CLAUDE_SYNC_NAME=$a ./claude-sync setup --path "${prefix}missing" 2>&1 >/dev/null) &&
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
    for x in "$a" "$b"; do
        guard "$x"
        docker rm --force "$x" >/dev/null 2>&1 || true
    done
    for x in "$a-config" "$b-config" "$vol_a" "$vol_b" "$vol_missing"; do
        guard "$x"
        docker volume rm "$x" >/dev/null 2>&1 || true
    done
    guard "$net"
    docker network rm "$net" >/dev/null 2>&1 || true
}

cleanup
trap cleanup EXIT

docker network create "$net" >/dev/null
docker volume create "$vol_a" >/dev/null
docker volume create "$vol_b" >/dev/null
fixture="cd /t"
for f in "${synced[@]}" "${ignored[@]}"; do
    fixture+=" && mkdir -p \"\$(dirname '$f')\" && echo 'fixture $f' >'$f'"
done
in_target "$mount_a" "$fixture && chown -R $owner_a /t"
in_target "$mount_b" "chown $owner_b /t"

echo "# setup rejects missing targets"
check "a missing volume is rejected" fails claude_sync "$a" setup --volume "$vol_missing"
check "  and is not created" fails docker volume inspect "$vol_missing"
check "no container is left behind" fails docker container inspect "$a"

echo "# setup --volume"
out=$(claude_sync "$a" setup --volume "$vol_a")
id_a=$(docker exec -u "$owner_a" "$a" syncthing device-id)
check "prints this device's ID" grep -qF "This device ID: $id_a" <<<"$out"
check "Syncthing writes as the volume's owner" wait_for owned_by "$mount_a" .stfolder "$owner_a"
check ".stignore is the repo's stignore" stignore_installed "$mount_a"
check "trash can versioning, 14 days" trash_can_14_days "$a" "$owner_a"

echo "# setup --volume, again"
out=$(claude_sync "$a" setup --volume "$vol_a")
check "keeps the device ID" grep -qF "This device ID: $id_a" <<<"$out"
check "keeps exactly one folder" [ "$(st "$a" "$owner_a" config folders list)" = claude-sync ]
check "keeps trash can versioning" trash_can_14_days "$a" "$owner_a"

# A real --path run would need a directory on the Docker host, which is not this filesystem
# when the daemon is shared from outside a dev container. Path mode differs from volume
# mode only in its compose overlay and path handling, which these check without a mount.
echo "# setup --path"
check "a missing directory is rejected" fails claude_sync "$a" setup --path "/nonexistent/$prefix$$"
check "a relative path is made absolute" relative_path_resolved
check "the overlay bind-mounts the directory" path_overlay_renders

echo "# setup --volume, second device"
claude_sync "$b" setup --volume "$vol_b" >/dev/null
id_b=$(docker exec -u "$owner_b" "$b" syncthing device-id)
check "Syncthing writes as the volume's owner" wait_for owned_by "$mount_b" .stfolder "$owner_b"

echo "# ignore list, across two devices"
st "$a" "$owner_a" config devices add --device-id "$id_b" --addresses "tcp://$b:22000"
st "$a" "$owner_a" config folders claude-sync devices add --device-id "$id_b"
st "$b" "$owner_b" config devices add --device-id "$id_a" --addresses "tcp://$a:22000"
st "$b" "$owner_b" config folders claude-sync devices add --device-id "$id_a"
if wait_for synced_to_b; then
    for f in "${synced[@]}"; do
        check "syncs $f" [ "$(in_target "$mount_b" "cat '/t/$f'")" = "fixture $f" ]
    done
    check "received files belong to B's owner" owned_by "$mount_b" settings.json "$owner_b"
    for f in "${ignored[@]}"; do
        check "ignores $f" in_target "$mount_b" "[ ! -e '/t/$f' ]"
    done
else
    check "B catches up with A" false
fi

echo "# uninstall"
before=$(snapshot "$mount_a")
claude_sync "$a" uninstall >/dev/null
check "removes the container" fails docker container inspect "$a"
check "removes Syncthing's state volume" fails docker volume inspect "$a-config"
check "keeps the synced volume" docker volume inspect "$vol_a"
check "leaves the synced data byte-identical" [ "$(snapshot "$mount_a")" = "$before" ]
check "succeeds when there is nothing to remove" claude_sync "$a" uninstall

((failures == 0)) || {
    echo "$failures check(s) failed" >&2
    exit 1
}
echo "all checks passed"
