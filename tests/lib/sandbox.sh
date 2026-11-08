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

# Containers first, then the image and volumes they use, then the network: Docker refuses
# to remove a volume or image in use, and `|| true` would hide it.
cleanup() {
    local x
    for x in "${registered_containers[@]}"; do
        guard "$x"
        docker rm --force -v "$x" >/dev/null 2>&1 || true
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
