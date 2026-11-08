# shellcheck shell=bash
# group_status, the names of what it makes, and the helpers only it uses.

readonly sx=${prefix}sx sy=${prefix}sy sz=${prefix}sz vol_sx=${prefix}sx-data vol_sy=${prefix}sy-data
readonly owner_sx=1470:1470 owner_sy=2580:2580
own_instances "$sx" "$sy" "$sz"
own_volumes "$vol_sx" "$vol_sy"

# status of instance NODE from the 0.4.0 build in $sdir, with the fake releases in LIST.
status_of() {
    CLAUDE_SYNC_RELEASES_API="file://$sdir/$2" CLAUDE_SYNC_NAME=$1 "$sdir/claude-sync" status
}

# Whether status of NODE prints a line that matches the extended regular expression RE.
status_says() {
    status_of "$1" releases.json | grep -E -- "$2" >/dev/null
}

# SX and SY: what status shows of an instance as it pairs and stops; SZ: of the host's own
# Syncthing.
group_status() {
    echo "# status"
    # This group's files; the helpers above use it.
    sdir=$scratch/status
    mkdir -p "$sdir/rpm" "$sdir/down" "$sdir/no-exec"
    "$root/packaging/build.sh" 0.4.0 "$sdir/claude-sync"
    releases_json "file://$sdir" >"$sdir/releases.json"
    # shellcheck disable=SC2016 # expanded by the fake rpm
    printf '#!/bin/sh\n[ "$1" = -qf ] && echo claude-sync-0.4.0-1.noarch\n' >"$sdir/rpm/rpm"
    printf '#!/bin/sh\nexit 1\n' >"$sdir/down/docker"
    # docker as it is when the container answers inspect but not exec.
    # shellcheck disable=SC2016 # expanded by the shim
    printf '#!/bin/sh\n[ "$1" = exec ] && exit 1\nexec %s "$@"\n' "$(command -v docker)" >"$sdir/no-exec/docker"
    chmod +x "$sdir/rpm/rpm" "$sdir/down/docker" "$sdir/no-exec/docker"

    out=$(status_of "$sx" releases.json) && status=0 || status=$?
    check "status of an instance not set up says how to set it up" grep -qF \
        "not set up on this host; CLAUDE_SYNC_NAME=$sx claude-sync setup --volume NAME or --path DIR sets it up" <<<"$out"
    check "  succeeding" [ "$status" = 0 ]
    check "  naming what chose the instance" grep -qE "^Instance: +$sx, named by CLAUDE_SYNC_NAME\$" <<<"$out"
    check "  with the installed version" grep -qE '^Installed: +claude-sync 0\.4\.0$' <<<"$out"
    check "  the newest release that is not breaking, with how to upgrade" \
        grep -qE '^Newer release: +claude-sync 0\.4\.1; run claude-sync upgrade$' <<<"$out"
    check "  and the newest breaking one, with its notes" grep -qF \
        "claude-sync 0.5.0, a breaking release; its release notes say how to upgrade: file://$sdir/releases/tag/v0.5.0" \
        <<<"$out"
    check "  and says nothing on stderr" [ -z "$(status_of "$sx" releases.json 2>&1 >/dev/null)" ]
    check "status when docker cannot be reached says so" fails_with "docker cannot be reached" \
        env PATH="$sdir/down:$PATH" CLAUDE_SYNC_RELEASES_API="file://$sdir/releases.json" \
        CLAUDE_SYNC_NAME="$sx" "$sdir/claude-sync" status
    check "status takes no arguments" fails_with "status takes no arguments" \
        claude_sync "$sx" status --volume "$vol_sx"

    docker volume create "$vol_sx" >/dev/null
    docker volume create "$vol_sy" >/dev/null
    # A conflict copy, and one in the trash can, which is an old version, not a conflict.
    in_target "type=volume,src=$vol_sx" "echo x >/t/notes.md &&
        echo older >/t/notes.sync-conflict-20261107-120000-AAAAAAA.md && mkdir /t/.stversions &&
        echo old >/t/.stversions/notes.sync-conflict-20261101-120000-AAAAAAA.md && chown -R $owner_sx /t"
    in_target "type=volume,src=$vol_sy" "chown $owner_sy /t"
    claude_sync "$sx" setup --volume "$vol_sx" --private >/dev/null 2>&1
    claude_sync "$sy" setup --volume "$vol_sy" --private >/dev/null 2>&1
    id_sx=$(docker exec -u "$owner_sx" "$sx" syncthing device-id)
    id_sy=$(docker exec -u "$owner_sy" "$sy" syncthing device-id)
    claude_sync "$sx" pair "$id_sy" --keep --address "tcp://$sy:22000" >/dev/null 2>&1
    pair_bounded "$sy" "$id_sx" --address "tcp://$sx:22000" >/dev/null 2>&1

    config_sx=$(st "$sx" "$owner_sx" config dump-json)
    out=$(status_of "$sx" releases.json) && status=0 || status=$?
    check "status of a running instance succeeds" [ "$status" = 0 ]
    check "  shows where Syncthing runs" grep -qE "^Syncthing: +in container $sx\$" <<<"$out"
    check "  what it syncs" grep -qE "^Syncs: +volume $vol_sx\$" <<<"$out"
    check "  its web UI" grep -qE '^Web UI: +http://127\.0\.0\.1:8384$' <<<"$out"
    check "  this device's ID" grep -qE "^Device ID: +$id_sx\$" <<<"$out"
    check "  the sync port" grep -qE '^Sync port: +22000$' <<<"$out"
    check "  that it is private" grep -qE '^Network: +private$' <<<"$out"
    check "  the conflict copies, leaving out the trash can" grep -qE '^Conflict copies: +1$' <<<"$out"
    local set_up_by=${CLAUDE_SYNC_BIN_VERSION:-dev}
    check "  which claude-sync set it up, with the setup that applies this version" grep -qE \
        "^Set up by: +claude-sync ${set_up_by//./\\.}; run CLAUDE_SYNC_NAME=$sx claude-sync setup to apply 0\.4\.0\$" <<<"$out"
    check "  and the paired device by its ID" grep -qE "^  (.* )?$id_sy\$" <<<"$out"
    check "  changing nothing in Syncthing" [ "$(st "$sx" "$owner_sx" config dump-json)" = "$config_sx" ]
    check "status shows the folder's state" wait_for status_says "$sx" '^Folder: +idle$'
    check "  and a paired device connected, how, and all it has" \
        wait_for status_says "$sx" "^    connected directly at [^ ]+:22000; has 100% of the folder\$"
    out=$(status_of "$sx" missing.json) && status=0 || status=$?
    check "status without the list of releases says it could not check" \
        grep -qE '^Newer release: +could not check$' <<<"$out"
    check "  and shows the rest" grep -qE "^Device ID: +$id_sx\$" <<<"$out"
    check "  succeeding" [ "$status" = 0 ]
    check "status of an RPM install says to upgrade with dnf" \
        grep -qE '^Newer release: +claude-sync 0\.4\.1; upgrade it with dnf' \
        <<<"$(env PATH="$sdir/rpm:$PATH" CLAUDE_SYNC_RELEASES_API="file://$sdir/releases.json" \
            CLAUDE_SYNC_NAME="$sx" "$sdir/claude-sync" status)"
    # The checkout's own script, whatever claude-sync the suite tests.
    out=$(CLAUDE_SYNC_RELEASES_API="file://$sdir/releases.json" CLAUDE_SYNC_NAME="$sx" "$root/claude-sync" status)
    check "status from a checkout leaves out the release check" fails grep -qE '^Newer release:' <<<"$out"
    check "status fails when the Syncthing in a running container does not answer" \
        fails_with "cannot reach Syncthing in container $sx" \
        env PATH="$sdir/no-exec:$PATH" CLAUDE_SYNC_RELEASES_API="file://$sdir/releases.json" \
        CLAUDE_SYNC_NAME="$sx" "$sdir/claude-sync" status

    # Syncthing's replies for a device through a relay, one that does not share the folder,
    # and one whose completion does not parse.
    cat >"$sdir/replies.sh" <<'EOF'
st() {
    case $* in
        "config folders claude-sync devices list") printf '%s\n' SELF-ID RELAYED-ID UNSHARED-ID ODD-ID ;;
        "config devices RELAYED-ID name get") echo laptop ;;
        *) echo ;;
    esac
}
rest() {
    case $1 in
        /rest/system/connections) cat <<'JSON' ;;
{
  "connections": {
    "ODD-ID": {
      "address": "192.0.2.3:22000",
      "connected": true,
      "type": "tcp-client"
    },
    "RELAYED-ID": {
      "address": "192.0.2.1:22067",
      "at": "2026-11-07T12:00:00Z",
      "connected": true,
      "paused": false,
      "type": "relay-client"
    },
    "UNSHARED-ID": {
      "address": "192.0.2.2:22000",
      "connected": true,
      "type": "tcp-server"
    }
  },
  "total": {
    "at": "2026-11-07T12:00:00Z",
    "inBytesTotal": 0
  }
}
JSON
        /rest/stats/device) echo '{}' ;;
        *UNSHARED-ID) printf '{\n  "completion": 0,\n  "remoteState": "notSharing"\n}\n' ;;
        *ODD-ID) printf '{\n  "completion": null,\n  "remoteState": "valid"\n}\n' ;;
        *) printf '{\n  "completion": 100,\n  "remoteState": "valid"\n}\n' ;;
    esac
}
EOF
    out=$(calls eval ". $(printf %q "$sdir/replies.sh") && device_status SELF-ID")
    check "status shows a device reached through a relay, by its name" grep -qx '  laptop RELAYED-ID' <<<"$out"
    check "  how" grep -qx '    connected through a relay at 192.0.2.1:22067; has 100% of the folder' <<<"$out"
    check "  one that does not share the folder" \
        grep -qx '    connected directly at 192.0.2.2:22000; does not share the folder' <<<"$out"
    check "  and one whose completion it cannot read" \
        grep -qx '    connected directly at 192.0.2.3:22000; completion unknown' <<<"$out"
    # shellcheck disable=SC2016 # expanded by the inner bash
    check "status shows a network setting other than public or private option by option" \
        [ "$(calls eval 'st() { if [ "$3" = relays-enabled ]; then echo false; else echo true; fi; }; network_setting')" \
        = "global discovery on, relays off, NAT traversal on" ]

    docker stop "$sy" >/dev/null
    check "status shows when a device it no longer reaches was last seen" wait_for status_says "$sx" \
        '^    not connected, last seen [0-9-]+T[0-9:]+Z; has 100% of the folder, as far as this device knows$'
    st "$sx" "$owner_sx" config folders claude-sync paused set true
    check "status of a paused folder says so" wait_for status_says "$sx" '^Folder: +paused$'
    out=$(status_of "$sx" releases.json) && status=0 || status=$?
    check "  with its devices' completion unknown" \
        grep -qE '^    not connected, last seen [0-9-]+T[0-9:]+Z; completion unknown$' <<<"$out"
    check "  succeeding" [ "$status" = 0 ]
    st "$sx" "$owner_sx" config folders claude-sync paused set false
    docker exec -u 0 "$sx" sh -c 'mkdir /var/syncthing/claude/sealed && chmod 700 /var/syncthing/claude/sealed'
    out=$(status_of "$sx" releases.json 2>&1) && status=0 || status=$?
    check "status says when it cannot count the conflict copies" \
        grep -qE '^Conflict copies: +could not search the synced folder; the message above says why$' <<<"$out"
    check "  with find's message" grep -qF "Permission denied" <<<"$out"
    check "  succeeding" [ "$status" = 0 ]
    st "$sx" "$owner_sx" config folders claude-sync delete
    out=$(status_of "$sx" releases.json 2>/dev/null) && status=0 || status=$?
    check "status of an instance whose folder was removed from Syncthing says how to add it again" grep -qE \
        "^Folder: +not in Syncthing; CLAUDE_SYNC_NAME=$sx claude-sync setup adds it again\$" <<<"$out"
    check "  with no devices" fails grep -qE '^Devices:' <<<"$out"
    check "  succeeding" [ "$status" = 0 ]
    check "  and leaves the folder out" fails grep -qx claude-sync <<<"$(st "$sx" "$owner_sx" config folders list)"
    out=$(status_of "$sy" releases.json) && status=0 || status=$?
    check "status of a stopped instance says how to start it" grep -qE \
        "^Syncthing: +in container $sy, stopped; CLAUDE_SYNC_NAME=$sy claude-sync setup starts it\$" <<<"$out"
    check "  succeeding" [ "$status" = 0 ]
    check "  and leaves it stopped" [ "$(docker inspect -f '{{.State.Running}}' "$sy")" = false ]

    echo "# status, on the host's Syncthing"
    docker run -d --name "$sz" --network "$net" --user user --entrypoint env "$host_image" \
        -u STHOMEDIR -u STGUIADDRESS HOME=/home/user syncthing serve --no-browser >/dev/null
    docker cp -q "$sdir/claude-sync" "$sz:/home/user/"
    docker exec -u 0 "$sz" chown user /home/user/claude-sync
    wait_for as_user "$sz" syncthing cli show version
    as_user "$sz" mkdir claude
    as_user "$sz" ./claude-sync setup --path claude --use-host-syncthing >/dev/null
    # A device on the unpaired list, which a command that acts on the instance would remove; SY, stopped, never
    # connects.
    as_user "$sz" syncthing cli config devices add --device-id "$id_sy"
    as_user "$sz" sh -c "mkdir claude/.claude-sync-unpaired && : >claude/.claude-sync-unpaired/$id_sy"
    out=$(as_user "$sz" env CLAUDE_SYNC_RELEASES_API=file:///nonexistent ./claude-sync status)
    check "status shows the host's own Syncthing" grep -qE '^Syncthing: +your own, on this host$' <<<"$out"
    check "  naming the default instance alone" grep -qE '^Instance: +claude-sync$' <<<"$out"
    check "  the directory it syncs" grep -qE '^Syncs: +directory /home/user/claude$' <<<"$out"
    check "  its web UI" grep -qE '^Web UI: +http://127\.0\.0\.1:8384$' <<<"$out"
    check "  that it is public" grep -qE '^Network: +public$' <<<"$out"
    check "  the version that set it up" grep -qE '^Set up by: +claude-sync 0\.4\.0$' <<<"$out"
    check "  and no devices" grep -qE '^Devices: +none$' <<<"$out"
    check "  and leaves the unpaired list unapplied" as_user "$sz" sh -c \
        "syncthing cli config devices list | grep -x $id_sy"
    as_user "$sz" syncthing cli config folders claude-sync devices add --device-id "$id_sy"
    out=$(as_user "$sz" env CLAUDE_SYNC_RELEASES_API=file:///nonexistent ./claude-sync status)
    check "status shows a device never seen, leaving out how much of the folder it has" \
        grep -qx '    not connected, never seen' <<<"$out"
    # The host's Syncthing as it is when not running: its config is there, its cli gets no
    # answer.
    # shellcheck disable=SC2016 # expanded by the shim
    printf '#!/bin/sh\n[ "$1" = cli ] && exit 1\nexec %s "$@"\n' "$(as_user "$sz" sh -c 'command -v syncthing')" |
        docker exec -i -u user -w /home/user "$sz" sh -c 'mkdir down && cat >down/syncthing && chmod +x down/syncthing'
    # shellcheck disable=SC2016 # expanded by the fixture's shell
    out=$(as_user "$sz" sh -c 'PATH=$HOME/down:$PATH CLAUDE_SYNC_RELEASES_API=file:///nonexistent ./claude-sync status') &&
        status=0 || status=$?
    check "status of the host's Syncthing when it is not running says to start it" \
        grep -qE '^Syncthing: +your own, on this host, not running as user; start it$' <<<"$out"
    check "  with what it syncs" grep -qE '^Syncs: +directory /home/user/claude$' <<<"$out"
    check "  succeeding" [ "$status" = 0 ]
}
