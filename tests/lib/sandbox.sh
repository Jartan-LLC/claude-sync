# shellcheck shell=bash
# The suite touches only objects with its prefix: guard refuses others, cleanup removes them.

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
# NAME mounts it there; nothing when another kind of mount is there.
anonymous_volume() {
    local volume
    volume=$(docker container inspect \
        --format '{{range .Mounts}}{{if and (eq .Type "volume") (eq .Destination "/var/syncthing")}}{{.Name}}{{end}}{{end}}' "$1") ||
        return
    [[ -z $volume ]] && return
    # shellcheck disable=SC2016 # a Go template's variables
    docker volume inspect \
        --format '{{range $key, $_ := .Labels}}{{if eq $key "com.docker.volume.anonymous"}}{{$.Name}}{{end}}{{end}}' "$volume"
}

remove_container() {
    guard "$1"
    docker rm --force -v "$1" >/dev/null 2>&1 || true
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
