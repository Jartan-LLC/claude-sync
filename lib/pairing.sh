# shellcheck shell=bash
# Pairing, joining and unpairing, and the companion that applies the unpaired list.

# Devices unpaired anywhere, one empty file per device ID in the synced folder, so every
# device sees them and unpairs of different devices never touch the same file.
readonly unpaired_dir=.claude-sync-unpaired
# The companion's file in the config volume.
readonly companion=claude-sync-companion
# Syncthing also accepts other spellings of an ID, but its CLI and the checks here match
# only this one, as setup prints it.
readonly id_re='^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$'

# Removes the devices on the unpaired list from this device's Syncthing. In a container,
# the start command (compose.yaml) runs it in a loop beside Syncthing, since introductions
# would bring an unpaired device back. Kept POSIX: it runs in the image's shell. Its
# arguments are DIR, the list's directory, and FOLDER, claude-sync's folder ID.
companion_script() {
    cat <<'EOF'
apply() {
    [ -d "$1" ] || return 0
    self=$(syncthing device-id 2>/dev/null)
    { [ -n "$self" ] && devices=$(syncthing cli config devices list 2>/dev/null); } || return 0
    for d in $devices; do
        # Syncthing would re-create this device's own entry, losing its name.
        [ "$d" != "$self" ] && [ -e "$1/$d" ] || continue
        # Either may have gone already, removed by another pass of this script.
        syncthing cli config folders "$2" devices "$d" delete 2>/dev/null || :
        # A device that also syncs other folders of this Syncthing stays for those.
        shared=""
        for f in $(syncthing cli config folders list); do
            if [ "$f" != "$2" ] && syncthing cli config folders "$f" devices list | grep -qxF "$d"; then
                shared=1
            fi
        done
        [ -n "$shared" ] || syncthing cli config devices "$d" delete 2>/dev/null || :
    done
    return 0
}
apply "$1" "$2"
EOF
}

apply_unpaired() {
    if [[ $mode == host ]]; then
        companion_script | sh -s "$folder_path/$unpaired_dir" "$folder_id"
    else
        companion_script | docker exec -i -u "$owner" "$name" sh -s "$folder_path/$unpaired_dir" "$folder_id"
    fi
}

# Takes ID off the unpaired list, so the device can be paired again. The deletion is
# indexed, and so offered to the other devices, before pair introduces the device, or
# their companions would remove it again on its way in.
forget_unpaired() {
    # shellcheck disable=SC2016 # expanded by sh
    in_folder '[ -e "$1" ] && rm "$1"' sh "$folder_path/$unpaired_dir/$1" || return 0
    rest "/rest/db/scan?folder=$folder_id" -X POST >/dev/null || die "cannot reach Syncthing $where"
    wait_folder_started
}

pair() {
    local id="" keep="" address=dynamic
    while (($#)); do
        case $1 in
            --keep) keep=1 ;;
            --address)
                (($# >= 2)) || die "$1 needs a value"
                address=$2
                shift
                ;;
            -*) die "unknown argument: $1" ;;
            *)
                [[ -z $id ]] || die "unknown argument: $1"
                id=$1
                ;;
        esac
        shift
    done
    if [[ -z $id ]]; then
        usage_error
    fi
    check_instance
    detect_mode

    [[ $id =~ $id_re ]] || die "not a device ID: $id; copy it as setup printed it"
    local self
    self=$(syncthing_run device-id)
    [[ $id != "$self" ]] || die "that is this device's own ID; give the other device's"
    [[ $address != dynamic || $(st config options global-ann-enabled get) == true ]] ||
        die "this device is private: give the other device's --address, such as tcp://HOST:22000"
    # Also keeps the address safe to put in the JSON below.
    local address_re='^[a-z0-9]+://[^"\\[:space:][:cntrl:]]+$' at="" there=""
    if [[ $address != dynamic ]]; then
        [[ $address =~ $address_re ]] || die "not an address: $address; give one such as tcp://HOST:22000"
        local port
        port=$(sync_port) || die "cannot reach Syncthing $where"
        at=" --address $address" there=" --address tcp://THIS-HOST:$port"
    fi

    # Before the folder changes below, so a bad ID changes nothing. A device added here but
    # not yet shared with gets no data.
    local devices known="" err
    devices=$(st config devices list)
    if grep -qxF -- "$id" <<<"$devices"; then
        known=1
    fi
    local syncing
    syncing=$(st config folders "$folder_id" devices list 2>/dev/null | grep -cvxF -- "$self") || true
    # A joining device's folder never sends its changes, so the ID could not leave the list.
    # shellcheck disable=SC2016 # expanded by sh
    if in_folder '[ -e "$1" ]' sh "$folder_path/$unpaired_dir/$id" &&
        [[ $(st config folders "$folder_id" type get 2>/dev/null) == receiveonly ]]; then
        die "$id is on the list of unpaired devices, which this joining device cannot change; pair it from a device that already syncs first"
    fi
    forget_unpaired "$id"
    # A device set up again on files that list it would otherwise unpair itself everywhere.
    # One that still syncs with others was unpaired on purpose, and taking it off the list
    # there would undo that through any device that has not dropped it yet.
    ((syncing != 0)) || forget_unpaired "$self"
    err=$(st config devices add --device-id "$id" --addresses "$address" 2>&1) ||
        die "cannot add device $id: $err"
    # Adding a known device changes nothing (Syncthing 2.1.6), so a corrected address is
    # set here.
    if [[ -n $known && $address != dynamic ]]; then
        rest "/rest/config/devices/$id" -X PATCH -H 'Content-Type: application/json' \
            -d "{\"addresses\": [\"$address\"]}" >/dev/null || die "cannot set the address of $id"
    fi

    # A device syncing with no other yet is the one being added, so it joins; receive-only
    # means a join was interrupted.
    local type sharing shared join=""
    type=$(st config folders "$folder_id" type get 2>/dev/null) || die "no $folder_id folder; run setup first"
    sharing=$(st config folders "$folder_id" devices list)
    shared=$(grep -cvxF -- "$self" <<<"$sharing") || true
    if [[ $type == receiveonly && -n $keep ]]; then
        # Ends the interrupted join without discarding anything, as --keep promises.
        st config folders "$folder_id" type set sendreceive
    elif [[ $type == receiveonly ]]; then
        join=1
    elif ((shared == 0)) && [[ -z $keep ]]; then
        join=1
        # In Syncthing 2.1.6, files indexed while send-receive are still sent as this
        # device's changes after a switch to receive-only.
        # Re-added receive-only, the folder indexes them as local changes, which are never
        # sent and are undone once caught up.
        st config folders "$folder_id" delete
        add_folder receiveonly
    fi

    # Every device introduces the devices it syncs with to the others, so a device can
    # join through any of them. An introducer's devices join every folder shared with it,
    # so on the host's Syncthing a device sharing other folders is not made one.
    if [[ $mode == host ]] && shares_other_folder "$id"; then
        printf '%s also syncs other folders with this Syncthing, so claude-sync does not make it an introducer: pair this device with each of the others too.\n' "$id"
    else
        st config devices "$id" introducer set true
    fi
    prints_line "$id" st config folders "$folder_id" devices list ||
        st config folders "$folder_id" devices add --device-id "$id"
    if [[ -z $join ]]; then
        printf 'Paired with %s. If not done yet, run there: claude-sync pair %s%s\n' "$id" "$self" "$there"
        return
    fi

    join_wait "$id" "$self" "$there" first
    # Joining devices with no files would only discard this device's: likely the first
    # pairing of a new set, missing --keep. Read twice, since the other device's index can
    # arrive just after it starts sharing. Nothing here was sent while receive-only, so
    # undoing the pairing restores the device as it was.
    if nothing_to_join && sleep 5 && nothing_to_join; then
        st config folders "$folder_id" devices "$id" delete
        [[ -n $known ]] || st config devices "$id" delete
        st config folders "$folder_id" type set sendreceive
        die "$id has no files to join, so joining would only discard this device's; undone, nothing was discarded. If this device's files are the ones to start from, rerun: claude-sync pair $id$at --keep"
    fi
    # Undo what changed here, then wait for the undone files to be pulled again: switching
    # to send-receive before they arrive would send this device's copies. Repeated while
    # something here, such as a running Claude Code, keeps changing files.
    set_trash_can
    local status rounds
    for ((rounds = 1; ; rounds++)); do
        undo_changes
        join_wait "$id" "$self" "$there"
        status=$(folder_status) || die "cannot reach Syncthing $where; rerun to finish the join"
        [[ $(field receiveOnlyTotalItems <<<"$status") != 0 ]] || break
        ((rounds < 5)) || die "files here keep changing during the join; stop Claude Code on this device and rerun"
    done
    st config folders "$folder_id" type set sendreceive
    printf 'Joined through %s; this device now syncs both ways.\n' "$id"
}

shares_other_folder() {
    local f
    while IFS= read -r f; do
        [[ $f != "$folder_id" ]] || continue
        prints_line "$1" st config folders "$f" devices list && return 0
    done < <(st config folders list)
    return 1
}

# Until this device has the folder as the device joined through has it. With FIRST, only as
# far as it can before its own changes are undone: a directory deleted there fails to go
# while it holds files of this device's own.
join_wait() {
    local id=$1 self=$2 there=$3 first=${4:-} told="" failures=0 polls=0 remote status state need
    local errors failing
    while :; do
        if ! status=$(folder_status) ||
            ! remote=$(rest "/rest/db/completion?folder=$folder_id&device=$id" | field remoteState); then
            ((++failures < 15)) || die "cannot reach Syncthing $where; rerun to finish the join"
            sleep 2
            continue
        fi
        failures=0
        state=$(field state <<<"$status")
        [[ $state != error ]] || die "Syncthing cannot sync the folder: $(field error <<<"$status")"
        need=$(field needTotalItems <<<"$status")
        if [[ $remote == valid ]]; then
            errors=$(field errors <<<"$status")
            if [[ $state == idle ]]; then
                [[ $need != 0 ]] || return 0
                # All that is left fails to sync: as far as FIRST goes.
                [[ -z $first || $need != "${errors:-0}" ]] || return 0
            fi
            if ((++polls % 15 == 0)) && [[ $need != 0 ]]; then
                failing=""
                [[ ${errors:-0} == 0 ]] || failing=", $errors failing ($(web_ui) shows why)"
                echo "Still syncing: $need files and directories to go$failing."
            fi
        elif [[ -z $told ]]; then
            printf 'Waiting for %s; if not done yet, run there: claude-sync pair %s%s\n' "$id" "$self" "$there"
            told=1
        fi
        sleep 2
    done
}

# Reverts this device's receive-only changes until none are left. Not the CLI's
# folder-override, which leaves a receive-only folder's changes in place (2.1.6).
undo_changes() {
    local status i
    for ((i = 0; ; i++)); do
        status=$(folder_status) || die "cannot reach Syncthing $where; rerun to finish the join"
        [[ $(field receiveOnlyTotalItems <<<"$status") != 0 ]] || return 0
        ((i < 60)) || die "this device's own changes are still not undone after two minutes, so the join cannot finish; Syncthing's web UI at $(web_ui) shows what is left. Until the join finishes, this device gets the other devices' changes but sends none of its own. Rerun to try again."
        rest "/rest/db/revert?folder=$folder_id" -X POST >/dev/null ||
            die "cannot reach Syncthing $where; rerun to finish the join"
        sleep 2
    done
}

# The device joined through has no files, while this device has changes to undo.
nothing_to_join() {
    local status
    status=$(folder_status) || die "cannot reach Syncthing $where; rerun to finish the join"
    [[ $(field globalTotalItems <<<"$status") == 0 && $(field receiveOnlyTotalItems <<<"$status") != 0 ]]
}

unpair() {
    if (($# != 1)); then
        usage_error
    fi
    local id=$1 self
    check_instance
    detect_mode
    [[ $id =~ $id_re ]] || die "not a device ID: $id; copy it as setup printed it"
    self=$(syncthing_run device-id)
    [[ $id != "$self" ]] || die "that is this device's own ID; run unpair with it on another device"
    # A receive-only folder never sends the list, and the join's undo would remove it.
    [[ $(st config folders "$folder_id" type get) != receiveonly ]] ||
        die "this device is still joining; finish that with pair first"
    # shellcheck disable=SC2016 # expanded by sh
    in_folder 'mkdir -p "$1" && : >"$1/$2"' sh "$folder_path/$unpaired_dir" "$id"
    apply_unpaired
    printf 'Unpaired %s here. The other devices drop it as the list of unpaired devices reaches them; one using its own Syncthing does so the next time claude-sync runs there. Once they all refuse %s, it stops syncing; run uninstall on it to remove its state.\n' "$id" "$id"
}
