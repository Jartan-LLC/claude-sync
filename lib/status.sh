# shellcheck shell=bash
# The status report.

# Prints LABEL and VALUE as a line of status.
show() {
    printf '%-17s%s\n' "$1:" "$2"
}

# Shows how the instance is set up, how it syncs, and whether a newer release is out. It
# only reads, so it never starts a stopped container, and does not use detect_mode, which
# applies the unpaired list to the Syncthing on this host.
status() {
    (($# == 0)) || die "status takes no arguments"
    check_name
    local instance=$name place="" runs syncs="" id folders folder="" info="" set_up="" devices=""
    [[ $name == "$default_name" ]] || instance+=", $(name_source)"
    locate_syncthing
    if [[ -n $place ]]; then
        { id=$(syncthing_run device-id) && folders=$(st config folders list); } || die "cannot reach Syncthing $where"
        # The web UI can remove the folder, and Syncthing then refuses its status and its
        # devices, which would read as Syncthing not answering.
        if grep -qxF -- "$folder_id" <<<"$folders"; then
            { folder=$(folder_status) && devices=$(device_status "$id"); } || die "cannot reach Syncthing $where"
        fi
        info=$(instance_lines "$id" "$folder") || die "cannot reach Syncthing $where"
        set_up=$(set_up_by "$name" "$place") || true
    fi
    show Instance "$instance"
    show Syncthing "$runs"
    [[ -z $syncs ]] || show Syncs "$syncs"
    [[ -z $info ]] || printf '%s\n' "$info"
    show Installed "claude-sync $claude_sync_version"
    [[ -z $set_up ]] || show "Set up by" "$set_up"
    release_status
    [[ -z $devices ]] || printf '%s\n' "$devices"
}

# Where the instance's Syncthing runs, for status: sets RUNS, SYNCS when it is set up, and
# PLACE, container or host, when its Syncthing runs there, pointing the helpers at it.
locate_syncthing() {
    local kind="" target="" host=""
    if ! current_setup; then
        if command -v docker >/dev/null && ! docker info >/dev/null 2>&1; then
            die "docker cannot be reached, so status cannot tell whether instance $name runs in a container; once docker works, rerun claude-sync status"
        fi
        runs="not set up on this host; $(setup_command "$name") --volume NAME or --path DIR sets it up"
        return
    fi
    syncs="volume $target"
    [[ $kind == volume ]] || syncs="directory $target"
    if [[ -n $host ]]; then
        if syncthing cli config gui apikey get >/dev/null 2>&1; then
            use_host
            folder_path=$target place=host runs="your own, on this host"
        else
            runs="your own, on this host, not running as $(id -un); start it"
        fi
    elif running; then
        owner=$(container_owner "$name") || die "cannot inspect container $name"
        place=container runs="in container $name"
    else
        runs="in container $name, stopped; $(setup_command "$name") starts it"
    fi
}

# Status lines of a running instance, all but the devices, for this device's ID and the
# folder's STATUS from Syncthing, empty when Syncthing does not have the folder. Fails when
# its Syncthing does not answer.
instance_lines() {
    local ui port network folder=$2 state paused conflicts
    { ui=$(web_ui) && port=$(sync_port) && network=$(network_setting); } || return
    state=$(field state <<<"$folder")
    if [[ -z $folder ]]; then
        state="not in Syncthing; $(setup_command "$name") adds it again"
    elif [[ $state == error ]]; then
        state="error: $(field error <<<"$folder")"
    elif [[ -z $state ]]; then
        # Syncthing gives no state for a folder it does not run.
        paused=$(st config folders "$folder_id" paused get) || return
        state="not running"
        [[ $paused != true ]] || state=paused
    fi
    conflicts=$(conflict_copies) || conflicts="could not search the synced folder; the message above says why"
    show "Web UI" "$ui"
    show "Device ID" "$1"
    show "Sync port" "$port"
    show Network "$network"
    show Folder "$state"
    show "Conflict copies" "$conflicts"
}

# The number of conflict copies in the synced folder. Fails when find cannot search all of
# it, so a count is never short.
conflict_copies() {
    local list
    # Trash can copies left out: they are old versions, not conflicts left to resolve.
    # shellcheck disable=SC2016 # expanded by sh
    list=$(in_folder 'cd "$1" && find . -path ./.stversions -prune -o -name "*.sync-conflict-*" -print' \
        sh "$folder_path") || return
    if [[ -z $list ]]; then echo 0; else grep -c '' <<<"$list"; fi
}

# The devices the folder is shared with, short of this device, whose ID is SELF.
device_status() {
    local list connections stats id ids=()
    { list=$(st config folders "$folder_id" devices list) && connections=$(rest /rest/system/connections) &&
        stats=$(rest /rest/stats/device); } || return
    while IFS= read -r id; do
        [[ -z $id || $id == "$1" ]] || ids+=("$id")
    done <<<"$list"
    if ((${#ids[@]} == 0)); then
        show Devices none
        return
    fi
    echo "Devices:"
    for id in "${ids[@]}"; do
        device_line "$id" "$connections" "$stats" || return
    done
}

# The device ID's name and ID, how this device reaches it, and how much of the folder it
# has, from Syncthing's CONNECTIONS and device STATS.
device_line() {
    local device_name connection seen="" text completion percent
    device_name=$(st config devices "$1" name get) || return
    printf '  %s\n' "${device_name:+$device_name }$1"
    connection=$(object "$1" <<<"$2")
    if [[ $(field connected <<<"$connection") == true ]]; then
        text="connected $(connection_kind "$(field type <<<"$connection")") at $(field address <<<"$connection")"
    else
        seen=$(object "$1" <<<"$3" | field lastSeen)
        # Syncthing's time for never: 1970-01-01, or the last day of 1969 in a time zone
        # west of UTC. Its completion for such a device is 0, which would mislead.
        if [[ -z $seen || $seen == 1970-* || $seen == 1969-* ]]; then
            echo "    not connected, never seen"
            return
        fi
        text="not connected, last seen $seen"
    fi
    # Syncthing refuses it for a folder it does not run, such as a paused one.
    completion=$(rest "/rest/db/completion?folder=$folder_id&device=$1" 2>/dev/null) || completion=""
    percent=$(field completion <<<"$completion")
    if [[ $(field remoteState <<<"$completion") == notSharing ]]; then
        text+="; does not share the folder"
    elif [[ ! $percent =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        text+="; completion unknown"
    else
        text+="; has ${percent%.*}% of the folder"
        # A device not connected: measured from its last index, against the folder as it
        # is now.
        [[ -z $seen ]] || text+=", as far as this device knows"
    fi
    echo "    $text"
}

# How a connection of Syncthing's TYPE, such as tcp-client or relay-server, reaches the
# device.
connection_kind() {
    if [[ $1 == relay-* ]]; then echo "through a relay"; else echo directly; fi
}

# Whether a newer release is out, unless this claude-sync runs from a checkout.
release_status() {
    [[ $claude_sync_version != dev ]] || return 0
    # Bounded, so a network that drops packets cannot hold status up.
    if ! check_releases --max-time 10 2>/dev/null; then
        show "Newer release" "could not check"
        return
    fi
    if [[ -n $release_safe ]]; then
        local how="run claude-sync upgrade"
        ! rpm_package "$(installed_file)" >/dev/null || how=$rpm_upgrade
        show "Newer release" "claude-sync ${release_safe#v}; $how"
    fi
    if [[ -n $release_breaking ]]; then
        show "Newer release" "claude-sync ${release_breaking#v}, a breaking release; its release notes say how to upgrade: $(release_url "$release_breaking")"
    fi
    [[ -n $release_safe$release_breaking ]] || show "Newer release" none
}
