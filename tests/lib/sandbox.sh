# shellcheck shell=bash
# The suite touches only objects with its prefix, and the anonymous volume of a container with
# its prefix: guard refuses others, cleanup removes them.

guard() {
    [[ $1 == "$prefix"* ]] || {
        echo "refusing to touch $1" >&2
        exit 1
    }
}

# The containers and volumes the groups make, each registered once by the group file that
# names it, so two groups cannot pick the same name. cleanup removes them, and a failed run
# logs the containers. -g keeps them global when this file is sourced inside a function.
declare -gA registered=()
declare -ga registered_containers=() registered_volumes=()

# register LIST NAME...: adds each NAME to LIST, registered_containers or registered_volumes.
# A call in a subshell, such as inside a group_* function, would not reach cleanup.
register() {
    local -n list=$1
    local name
    shift
    ((BASH_SUBSHELL == 0)) || {
        echo "$* registered in a subshell, which cleanup does not see" >&2
        exit 1
    }
    for name; do
        [[ -z ${registered[$name]:-} ]] || {
            echo "$name is registered twice" >&2
            exit 1
        }
        registered[$name]=1
        list+=("$name")
    done
}

# Each NAME is an instance: its container and its config volume.
own_instances() {
    local name
    for name; do
        register registered_containers "$name"
        register registered_volumes "$name-config"
    done
}

own_containers() {
    register registered_containers "$@"
}

own_volumes() {
    register registered_volumes "$@"
}

# The volume Docker made for the image's VOLUME, /var/syncthing, in container NAME, as long as
# NAME mounts it there; nothing when NAME mounts something else there. Apart from claude-sync's
# own anonymous_volume, so that cleanup does not depend on the code under test.
anonymous_mount() {
    local volume
    volume=$(docker container inspect \
        --format '{{range .Mounts}}{{if and (eq .Type "volume") (eq .Destination "/var/syncthing")}}{{.Name}}{{end}}{{end}}' "$1") ||
        return
    [[ -n $volume ]] || return 0
    # shellcheck disable=SC2016 # a Go template's variables
    docker volume inspect \
        --format '{{range $key, $_ := .Labels}}{{if eq $key "com.docker.volume.anonymous"}}{{$.Name}}{{end}}{{end}}' "$volume"
}

# Removes container NAME and its anonymous volume, which docker rm -v leaves once Compose has
# recreated the container: Compose hands the volume on to the new container by name. The
# volume has a hash for a name, not the prefix; read from NAME's own mounts, it is this run's.
remove_container() {
    local volume
    guard "$1"
    volume=$(anonymous_mount "$1" 2>/dev/null) || true
    docker rm --force -v "$1" >/dev/null 2>&1 || true
    [[ -n $volume ]] || return 0
    docker volume inspect "$volume" >/dev/null 2>&1 || return 0
    docker volume rm "$volume" >/dev/null || echo "cleanup left volume $volume, container $1's anonymous volume" >&2
}

# Containers first, then the image and volumes they use, then the network: Docker refuses
# to remove a volume or image in use, and `|| true` would hide it.
cleanup() {
    local x
    for x in "${registered_containers[@]}"; do
        remove_container "$x"
    done
    guard "$host_image"
    docker image rm "$host_image" >/dev/null 2>&1 || true
    for x in "${registered_volumes[@]}"; do
        guard "$x"
        docker volume rm "$x" >/dev/null 2>&1 || true
    done
    guard "$net"
    docker network rm "$net" >/dev/null 2>&1 || true
}
