# shellcheck shell=bash
# A node's Syncthing, its target and its container, as the groups read them.

# Root shell with a target mounted at /t.
in_target() {
    docker run --rm --entrypoint sh --mount "$1,dst=/t" "$image" -c "$2"
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

owned_by() {
    [[ $(in_target "$1" "stat -c %u:%g /t/$2") == "$3" ]]
}

stignore_installed() {
    in_target "$1" 'cat /t/.stignore' | cmp -s - "$root/stignore"
}

network_options() {
    st "$1" "$2" config options dump-json | jq -c '[.globalAnnounceEnabled, .relaysEnabled, .natEnabled]'
}

# A command as `user` on a host fixture CONTAINER.
as_user() {
    docker exec -u user -w /home/user "$1" env -u STHOMEDIR -u STGUIADDRESS HOME=/home/user "${@:2}"
}

# A node's sync port, from its listen addresses.
sync_port() {
    st "$1" "$2" config options dump-json |
        jq -r '.listenAddresses[] | select(startswith("tcp://")) | sub(".*:"; "")'
}

listens() {
    docker exec "$1" nc -z 127.0.0.1 "$2"
}

# The version an instance's container was last set up by.
stamp_of() {
    docker exec "$1" cat /var/syncthing/config/claude-sync-version
}
