# shellcheck shell=bash
# Creating, re-applying and removing an instance.

compose_files=()
probe_error=""

compose() {
    docker compose -p "$name" "${compose_files[@]}" "$@"
}

# Whether PORT is free on the service's network, which is the host's even when
# claude-sync itself runs in a container: 0 free, 1 in use, 2 unknown (see probe_error).
port_free() {
    local probe
    # nc's own status is echoed so a failing `compose run` cannot pass for a free port.
    # shellcheck disable=SC2016 # expanded by the container's shell
    probe=$(compose run --rm --no-deps --entrypoint sh syncthing \
        -c 'nc -z 127.0.0.1 "$1"; echo "nc=$?"' sh "$1" 2>&1 </dev/null) || true
    case ${probe##*$'\n'} in
        nc=1) return 0 ;;
        nc=0) return 1 ;;
        *)
            probe_error=$probe
            return 2
            ;;
    esac
}

# Another container from a Syncthing image, running or stopped, that mounts TARGET, a
# volume name or a host path, if any.
target_taken_by() {
    local cname cimage mounts
    while IFS='|' read -r cname cimage mounts; do
        cname=${cname#/}
        [[ $cname != "$name" && $cimage == *syncthing* ]] || continue
        if [[ ";$mounts" == *";$1;"* ]]; then
            echo "$cname"
            return
        fi
    done < <(docker ps -aq | xargs -r docker container inspect --format \
        '{{.Name}}|{{.Config.Image}}|{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{else}}{{.Source}}{{end}};{{end}}' 2>/dev/null)
}

# Sets kind and target to this instance's, and host for one in the Syncthing on this host,
# for setup with no target. Fails when there is no instance.
current_setup() {
    if container_exists "$name"; then
        ours_container "$name" || die "container $name was not created by claude-sync"
        target=$(current_target "$name")
        [[ -n $target ]] || die "container $name syncs nothing; run uninstall, then setup with --volume or --path"
        kind=volume
        [[ $(docker container inspect --format "{{range .Mounts}}{{if eq .Destination \"$folder_path\"}}{{.Type}}{{end}}{{end}}" \
            "$name") != bind ]] || kind=path
        return 0
    fi
    [[ $name == "$default_name" ]] || return 1
    target=$(host_folder_path)
    [[ -n $target ]] || return 1
    kind=path host=1
}

setup() {
    # backup: empty to keep the daily backup as it is, off, or the absolute DIR to back up to.
    local kind="" target="" network="" host="" want_gui="" want_sync="" backup=""
    while (($#)); do
        case $1 in
            --volume | --path)
                [[ -z $kind ]] || die "give only one of --volume or --path"
                (($# >= 2)) || die "$1 needs a value"
                kind=${1#--} target=$2
                shift 2
                ;;
            --private | --public)
                [[ -z $network || $network == "${1#--}" ]] || die "give only one of --private or --public"
                network=${1#--}
                shift
                ;;
            --use-host-syncthing)
                host=1
                shift
                ;;
            --gui-port | --sync-port)
                (($# >= 2)) || die "$1 needs a value"
                if ! [[ $2 =~ ^[1-9][0-9]{3,4}$ ]] || (($2 < 1024 || $2 > 65535)); then
                    die "not a port: $2; give one from 1024 to 65535"
                fi
                if [[ $1 == --gui-port ]]; then want_gui=$2; else want_sync=$2; fi
                shift 2
                ;;
            --backup-dir)
                [[ $backup != off ]] || die "give only one of --backup-dir or --no-backup"
                [[ -n ${2:-} ]] || die "$1 needs a value"
                [[ $2 != *$'\n'* ]] || die "paths containing a newline are not supported"
                backup=$(clean_path "$(expand_home "$2")")
                shift 2
                ;;
            --no-backup)
                [[ $backup != /* ]] || die "give only one of --backup-dir or --no-backup"
                backup=off
                shift
                ;;
            *) die "unknown argument: $1" ;;
        esac
    done
    check_instance
    # Here as well as in schedule_backup, so that setup refuses before it changes anything.
    if backup_dir_to_schedule "$backup" >/dev/null; then
        check_running_from_file
    fi
    if [[ $backup == /* ]] && ! user_systemd; then
        die "--backup-dir needs systemd's user manager (systemctl --user), which is not running for $(id -un) here; schedule CLAUDE_SYNC_NAME=$name claude-sync backup DIR another way, such as with cron"
    fi
    [[ $backup != off ]] || check_unschedule
    if [[ -z $kind ]] && ! current_setup; then
        # A daemon that is not running would otherwise pass for no instance in a container.
        if docker_unreachable; then
            die "docker cannot be reached, so setup cannot tell whether instance $name runs in a container; once docker works, rerun $(setup_command "$name")"
        fi
        # An instance removed outside claude-sync leaves its timer firing at nothing.
        if [[ $backup == off ]] && has_scheduled_backup; then
            unschedule_backup
            return
        fi
        usage_error
    fi
    [[ -z $want_gui || $want_gui != "$want_sync" ]] || die "--gui-port and --sync-port need different ports"
    if [[ -n $host ]]; then
        [[ $kind == path ]] || die "--use-host-syncthing works only with --path: a Syncthing on the host cannot reach a Docker volume"
        [[ -z $network ]] || die "--$network changes how all of a Syncthing's folders connect; with --use-host-syncthing, set them in that Syncthing"
        [[ -z $want_gui$want_sync ]] || die "--gui-port and --sync-port change that Syncthing's own ports; with --use-host-syncthing, set them in that Syncthing"
        # One Syncthing holds one claude-sync folder, so names would not keep instances apart.
        if [[ $name != "$default_name" ]]; then
            [[ $name_from != selection ]] ||
                die "--use-host-syncthing sets up only the default instance, $default_name; run claude-sync use $default_name first"
            local selected fix="leave CLAUDE_SYNC_NAME unset"
            if selected=$(selected_instance) && [[ $selected != "$default_name" ]]; then
                fix+=" and run claude-sync use $default_name first"
            fi
            die "CLAUDE_SYNC_NAME names claude-sync's own containers; with --use-host-syncthing, $fix"
        fi
        setup_host "$target" "$backup"
        return
    fi
    setup_container "$kind" "$target" "$network" "$want_gui" "$want_sync" "$backup"
}

setup_container() {
    local kind=$1 target=$2 network=$3 want_gui=$4 want_sync=$5 backup=$6
    command -v docker >/dev/null || die "Docker is required"
    if [[ $kind == path ]]; then
        [[ $target != *$'\n'* ]] || die "paths containing a newline are not supported"
        target=$(clean_path "$target")
    fi
    check_host_folders "$kind" "$target"

    local mount
    if [[ $kind == volume ]]; then
        check_volume "$target"
        mount="type=volume,src=$target,dst=/target"
    else
        # Not checked with -d: Docker resolves the path on its host, which is not this
        # filesystem when claude-sync runs inside a container sharing the host's daemon.
        # --mount takes comma-separated fields, with no quoting for a comma in a value.
        [[ $target != *,* ]] || die "paths containing a comma are not supported: $target"
        mount="type=bind,src=$target,dst=/target"
    fi

    local current
    current=$(current_target "$name") || current=""
    [[ -z $current || $current == "$target" ]] || die "already set up for $current; run uninstall first"
    # Two Syncthings on one target would each sync it as a device of its own.
    local taken
    taken=$(target_taken_by "$target")
    [[ -z $taken ]] || die "container $taken already syncs $target; give this instance another target"

    local image
    image=$(compose_image)
    owner=$(read_owner "$image" "$mount" "$target")

    local created_config=""
    if docker volume inspect "$name-config" >/dev/null 2>&1; then
        ours_volume "$name-config" || die "volume $name-config exists but was not created by claude-sync"
    else
        docker volume create --label "$label" "$name-config" >/dev/null
        created_config=1
    fi
    # A new volume's root belongs to root and the image chowns only its home directory,
    # so without this Syncthing cannot write its config as the target's owner.
    docker run --rm --entrypoint chown --mount "type=volume,src=$name-config,dst=/config" \
        "$image" -R "$owner" /config
    companion_script | docker run --rm -i --user "$owner" --entrypoint sh \
        --mount "type=volume,src=$name-config,dst=/config" "$image" -c 'cat >"/config/$1"' sh "$companion"

    export CLAUDE_SYNC_UID=${owner%:*} CLAUDE_SYNC_GID=${owner#*:} CLAUDE_SYNC_TARGET=$target
    write_compose_files "$kind"

    # A port asked for must be free, unless this instance already has it.
    local port status
    for port in $want_gui $want_sync; do
        if running "$name" && [[ $port == "$(gui_port)" || $port == "$(sync_port)" ]]; then
            continue
        fi
        status=0
        port_free "$port" || status=$?
        if ((status != 0)); then
            [[ -z $created_config ]] || docker volume rm "$name-config" >/dev/null
            ((status == 1)) || die "cannot check port $port: $probe_error"
            die "port $port is in use; choose another"
        fi
    done

    # Written before Syncthing first scans the folder, so ignored files are never indexed.
    asset stignore | docker run --rm -i --user "$owner" --entrypoint sh --mount "$mount" "$image" \
        -c 'cat >/target/.stignore'

    compose up --detach --wait --wait-timeout 120 --quiet-pull

    move_ports "$want_gui" "$want_sync"

    ensure_folder
    set_network "$network"
    wait_folder_started

    local gui sync
    { gui=$(gui_port) && sync=$(sync_port); } || die "cannot reach Syncthing in container $name"
    printf 'Syncthing is running in container %s, web UI on 127.0.0.1:%s, sync port %s.\n' \
        "$name" "$gui" "$sync"
    tell_busy
    # A new config volume is Syncthing's first start, when it takes free ports in place of
    # busy defaults.
    if [[ -n $created_config ]] && { [[ -z $want_gui && $gui != "$default_gui_port" ]] ||
        [[ -z $want_sync && $sync != "$default_sync_port" ]]; }; then
        echo "Another program holds Syncthing's default web UI or sync port, so this instance uses a free one instead."
        if [[ $kind == path && $name == "$default_name" ]]; then
            echo "If that program is your own Syncthing, run uninstall, then setup again with --use-host-syncthing to use it."
        fi
    fi
    printf 'This device ID: %s\n' "$(docker exec -u "$owner" "$name" syncthing device-id)"
    schedule_backup "$backup"
    write_stamp "$name" container
}

check_host_folders() {
    local kind=$1 target=$2
    # Under the default name, pair, unpair, backup and uninstall would act on a container
    # instead of the Syncthing that already syncs claude-sync's folder. With --path, under any
    # name, the container would also be a second device on files a folder of that Syncthing
    # syncs.
    if host_syncthing_configured; then
        local fid fpath real_target=""
        [[ $kind != path ]] || real_target=$(real_path "$target")
        while IFS=$'\t' read -r fid fpath; do
            if [[ $fid == "$folder_id" && $name == "$default_name" ]]; then
                [[ $kind == volume ]] ||
                    die "already set up in the Syncthing on this host; add --use-host-syncthing, or run uninstall first"
                die "the Syncthing on this host already syncs claude-sync's folder; to sync this volume beside it, set CLAUDE_SYNC_NAME to another name"
            elif [[ $kind == path ]] && paths_overlap "$real_target" "$(real_path "$fpath")"; then
                die "this host's Syncthing folder $fid already syncs $fpath, which overlaps $target; choose another directory"
            fi
        done < <(host_folders)
    fi
}

# Writes the compose files for KIND to a new temporary directory, sets compose_files to
# them and exports the paths inside the container that they read. Also sets the EXIT trap,
# replacing any other, so the directory lasts until exit.
write_compose_files() {
    local kind=$1
    export CLAUDE_SYNC_CONFIG_PATH=$container_config CLAUDE_SYNC_FOLDER_PATH=$container_folder \
        CLAUDE_SYNC_COMPANION_PATH=$container_config/$companion \
        CLAUDE_SYNC_UNPAIRED_PATH=$container_folder/$unpaired_dir
    # Compose reads only files; setup_container's port checks and `up` use them.
    local compose_dir
    compose_dir=$(mktemp -d -t claude-sync.XXXXXX)
    # shellcheck disable=SC2064 # expanded now: compose_dir is local
    trap "rm -rf -- $(printf %q "$compose_dir")" EXIT
    asset compose.yaml >"$compose_dir/compose.yaml"
    asset "compose.$kind.yaml" >"$compose_dir/compose.$kind.yaml"
    compose_files=(-f "$compose_dir/compose.yaml" -f "$compose_dir/compose.$kind.yaml")
    [[ -z ${CLAUDE_SYNC_COMPOSE_OVERRIDE:-} ]] || compose_files+=(-f "$CLAUDE_SYNC_COMPOSE_OVERRIDE")
}

check_volume() {
    # `docker run --mount` would silently create a missing volume.
    docker volume inspect "$1" >/dev/null 2>&1 || die "no Docker volume named $1"
}

compose_image() {
    local image
    image=$(asset compose.yaml | sed -n 's/^ *image: *//p')
    [[ -n $image ]] || die "no image in compose.yaml"
    echo "$image"
}

# Prints the UID:GID that owns a target, or dies if it cannot read the target or root owns
# it. Takes IMAGE, the MOUNT that puts the target at /target, and TARGET, the target's name
# in messages.
read_owner() {
    local owner
    owner=$(docker run --rm --entrypoint stat --mount "$2" "$1" -c %u:%g /target) ||
        die "cannot read $3"
    # Files written as root are files Claude Code cannot change.
    [[ ${owner%:*} != 0 ]] || die "$3 is owned by root; chown it to the user who runs Claude Code"
    echo "$owner"
}

move_ports() {
    local want_gui=$1 want_sync=$2
    # A web UI on the sync port would leave nothing to reach Syncthing through, so the two
    # are checked as they will end up. The web UI moves first when the sync port takes its
    # port, or the sync listener would wait on Syncthing's retry; not in an exact swap,
    # where the web UI would move onto the port the sync listener still holds and setup
    # would lose the API.
    local gui sync current_gui
    { current_gui=$(gui_port) && gui=${want_gui:-$current_gui} && sync=${want_sync:-$(sync_port)}; } ||
        die "cannot reach Syncthing in container $name"
    [[ $gui != "$sync" ]] || die "the web UI and sync ports would both be $gui; choose different ones"
    if [[ $sync == "$current_gui" && $gui != "$(sync_port)" ]]; then
        move_gui_port "$want_gui"
        move_sync_port "$want_sync"
    else
        move_sync_port "$want_sync"
        move_gui_port "$want_gui"
    fi
}

# Moves the sync port to PORT, if given and new.
move_sync_port() {
    [[ -n $1 && $1 != "$(sync_port)" ]] || return 0
    # Replaces all listen addresses; the relay one is Syncthing's default, and --private
    # keeps relays off through its own option.
    rest /rest/config/options -X PATCH -H 'Content-Type: application/json' \
        -d "{\"listenAddresses\": [\"tcp://:$1\", \"quic://:$1\", \"dynamic+https://relays.syncthing.net/endpoint\"]}" \
        >/dev/null || die "cannot set the sync port"
}

# Moves the web UI to PORT, if given and new.
move_gui_port() {
    [[ -n $1 && $1 != "$(gui_port)" ]] || return 0
    # The web UI moves at once, so this call may not get its answer.
    st config gui raw-address set "127.0.0.1:$1" 2>/dev/null || true
    wait_reachable || die "Syncthing's web UI did not come up on port $1"
}

# After an exact port swap, Syncthing's API takes tens of seconds to come back.
wait_reachable() {
    local i
    for ((i = 0; i < 60; i++)); do
        st show version >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

setup_host() {
    local target=$1 backup=$2
    [[ -d $target ]] || die "no directory $target"
    # Stored absolute, without a trailing slash or `..`.
    target=$(cd -- "$target" && pwd)
    if container_exists "$name"; then
        die "already set up in container $name; run uninstall first"
    fi
    use_host
    local version
    version=$(st show version | field version)
    if ! [[ $version =~ ^v([0-9]+)\. ]] || ((BASH_REMATCH[1] < 2)); then
        die "this host runs Syncthing $version; claude-sync needs Syncthing 2 or newer"
    fi
    local id path real real_target
    # A folder inside or around another would sync the same files twice, and the join's
    # undo would reach the other folder's devices.
    real_target=$(real_path "$target")
    while IFS= read -r id; do
        path=$(st config folders "$id" path get)
        real=$(real_path "$path")
        if [[ $id == "$folder_id" ]]; then
            [[ $real == "$real_target" ]] || die "already set up for $path; run uninstall first"
        elif paths_overlap "$real_target" "$real"; then
            die "this host's Syncthing folder $id already syncs $path, which overlaps $target; choose another directory"
        fi
    done < <(st config folders list)
    folder_path=$target
    # Here as well as in schedule_backup, so that a refused DIR leaves the folder unadded.
    [[ $backup != /* ]] || check_outside_synced_folder "$backup"

    # Before the folder is added, as in setup.
    asset stignore >"$target/.stignore"
    ensure_folder
    wait_folder_started
    apply_unpaired
    tell_busy

    printf 'The Syncthing on this host syncs %s.\nThis device ID: %s\n' "$target" "$(syncthing_run device-id)"
    schedule_backup "$backup"
    write_stamp "$name" host
}

uninstall() {
    (($# == 0)) || die "uninstall takes no arguments"
    check_instance
    local container="" volume=""
    if command -v docker >/dev/null; then
        if docker container inspect "$name" >/dev/null 2>&1; then
            ours_container "$name" || die "container $name was not created by claude-sync; not removing it"
            container=1
        fi
        if docker volume inspect "$name-config" >/dev/null 2>&1; then
            ours_volume "$name-config" || die "volume $name-config was not created by claude-sync; not removing it"
            volume=1
        fi
    fi
    check_unschedule
    if [[ -n $container ]]; then
        # -v: the image declares a volume, left behind otherwise. Volumes mounted by name,
        # such as the synced one, are kept.
        docker rm --force -v "$name" >/dev/null
        echo "Removed container $name."
    fi
    if [[ -n $volume ]]; then
        docker volume rm "$name-config" >/dev/null
        echo "Removed volume $name-config (this device's Syncthing identity)."
    fi
    if [[ -z $container && $name == "$default_name" ]] && host_syncthing_configured; then
        use_host
        if prints_line "$folder_id" st config folders list; then
            folder_path=$(st config folders "$folder_id" path get)
            apply_unpaired
            st config folders "$folder_id" delete
            local file
            file=$(stamp_file host) && rm -f -- "$file"
            echo "Removed the $folder_id folder from the Syncthing on this host; its other folders stay, and so do its devices, apart from unpaired ones that share no other folder."
        fi
    fi
    # The container may be gone by now, and nothing runs uninstall again as upgrade does setup.
    # A trap, not `|| die`, which would turn set -e off inside unschedule_backup.
    # shellcheck disable=SC2064 # expanded now: name is checked
    trap "echo 'claude-sync: the daily backup of instance $name is not removed yet; run CLAUDE_SYNC_NAME=$name claude-sync uninstall again' >&2" EXIT
    unschedule_backup
    trap - EXIT
    echo "The synced files are untouched."
    if [[ $(selected_instance) == "$name" ]]; then
        rm -f -- "$(selection_file)"
        echo "Instance $name is no longer selected; later commands act on the default instance, $default_name."
    fi
}
