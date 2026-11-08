# shellcheck shell=bash
# group_chain, the names of what it makes, and the helpers only it uses.

readonly a=${prefix}a b=${prefix}b c=${prefix}c d=${prefix}d h=${prefix}h
readonly vol_a=${prefix}a-data vol_b=${prefix}b-data vol_c=${prefix}c-data vol_d=${prefix}d-data
# Not Syncthing's default 1000, so a match proves the owner was read from the target.
readonly owner_a=1234:1234 owner_b=2345:2345 owner_c=3456:3456 owner_d=4567:4567
readonly mount_a=type=volume,src=$vol_a mount_b=type=volume,src=$vol_b mount_c=type=volume,src=$vol_c
own_instances "$a" "$b" "$c" "$d"
own_containers "$h"
own_volumes "$vol_a" "$vol_b" "$vol_c" "$vol_d"

# HTTP status of A's index entry for a file: 200 when indexed, 404 when not.
index_status() {
    rest "$a" "$owner_a" "/rest/db/file?folder=claude-sync&file=$1" -s -o /dev/null -w '%{http_code}'
}

synced_to_b() {
    local a_local b_status
    a_local=$(folder_status "$a" "$owner_a" | jq .localTotalItems)
    b_status=$(folder_status "$b" "$owner_b")
    jq -e --argjson want "$a_local" \
        '.state == "idle" and .needTotalItems == 0 and .globalTotalItems == $want' \
        <<<"$b_status"
}

trash_can_14_days() {
    st "$1" "$2" config folders claude-sync versioning dump-json |
        jq -e '.type == "trashcan" and .params.cleanoutDays == "14"'
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

forgets() {
    local devices
    devices=$(st "$1" "$2" config devices list) && ! grep -qx "$3" <<<"$devices"
}

introduced_by() {
    st "$1" "$2" config devices "$3" dump-json | jq -r .introducedBy
}

# A fresh exchange of device lists between two nodes, as on a reconnection.
reconnect() {
    st "$1" "$2" config devices "$3" paused set true
    sleep 3
    st "$1" "$2" config devices "$3" paused set false
    sleep 20
}

trusts() {
    [ "$(st "$1" "$2" config devices "$3" introducer get)" = true ]
}

# A command as `user` on the host fixture, with Syncthing's defaults rather than the
# image's settings.
on_host() {
    as_user "$h" "$@"
}

host_sync() {
    on_host timeout 300 /opt/claude-sync/claude-sync "$@"
}

host_introducer() {
    on_host syncthing cli config devices "$1" introducer get
}

# Whether the archive in the host's DIR holds MEMBER.
host_archive_has() {
    on_host sh -c "tar -tzf $1/*.tar.gz" | grep -xF -- "$2" >/dev/null
}

host_has_folder() {
    # Not grep -q, which can cut the list off and so fail the pipeline; see prints_line in
    # claude-sync.
    on_host syncthing cli config folders list | grep -x claude-sync >/dev/null
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

host_idle() {
    # shellcheck disable=SC2016 # expanded by the fixture's shell
    on_host sh -c 'curl -kfsS -H "X-API-Key: $(syncthing cli config gui apikey get)" \
        "https://127.0.0.1:8384/rest/db/status?folder=claude-sync"' |
        jq -e '.state == "idle" and .needTotalItems == 0'
}

# The files of the user's other folders.
host_others() {
    on_host sh -c "find photos notes tilde -type f ! -path '*/.stfolder/*' -exec sha256sum {} + | sort"
}

# Without .stfolder, Syncthing's marker, which it deletes along with the folder.
host_snapshot() {
    on_host sh -c 'cd claude && find . -path ./.stfolder -prune -o -print | sort &&
        find . -path ./.stfolder -prune -o -type f -exec sha256sum {} + | sort'
}

snapshot() {
    in_target "$1" 'cd /t && find . | sort && find . -type f -exec sha256sum {} + | sort'
}

# Devices A to D pairing, joining and unpairing, with the host's own Syncthing.
group_chain() {
    echo "# setup --volume --private"
    out=$(claude_sync "$a" setup --volume "$vol_a" --private)
    id_a=$(docker exec -u "$owner_a" "$a" syncthing device-id)
    check "prints this device's ID" grep -qF "This device ID: $id_a" <<<"$out"
    check "Syncthing writes as the volume's owner" wait_for owned_by "$mount_a" .stfolder "$owner_a"
    check ".stignore is the repo's stignore" stignore_installed "$mount_a"
    check "leaves no compose files behind" no_leftovers
    check "trash can versioning, 14 days" trash_can_14_days "$a" "$owner_a"
    check "no global discovery, relays or NAT traversal" \
        [ "$(network_options "$a" "$owner_a")" = '[false,false,false]' ]

    echo "# setup --volume, again"
    container_a=$(docker inspect -f '{{.Id}}' "$a")
    out=$(claude_sync "$a" setup --volume "$vol_a")
    check "keeps the device ID" grep -qF "This device ID: $id_a" <<<"$out"
    check "keeps the container" [ "$(docker inspect -f '{{.Id}}' "$a")" = "$container_a" ]
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
    check "a join cut off while waiting" cut_off env CLAUDE_SYNC_NAME="$b" timeout 10 \
        "$bin" pair "$id_a" --address "tcp://$a:22000"
    check "  leaves B's folder receive-only" [ "$(folder_type "$b" "$owner_b")" = receiveonly ]
    check "  where unpair refuses until the join ends" fails_with "still joining" claude_sync "$b" unpair "$id_a"
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
    # B's own copies of the ignored files inside these folders, and a half-written file. The
    # first try at deleting the folders past them fails, and Syncthing retries a failed pull
    # only after a minute unless told sooner.
    st "$b" "$owner_b" config folders claude-sync puller-pauses set 2
    own="cd /t"
    for f in "${ignored[@]}" plugins/cache/market/demo/1.0.0/plugin.json.tmp.ab12cd34; do
        case $f in
            plugins/* | ide/* | sessions/* | jobs/*) own+=" && mkdir -p \"\$(dirname '$f')\" && echo b >'$f'" ;;
        esac
    done
    in_target "$mount_b" "$own && chown -R $owner_b plugins ide sessions jobs"
    in_target "$mount_a" "rm -r /t/plugins /t/ide /t/sessions /t/jobs"
    for dir in plugins ide sessions jobs; do
        check "$dir/ deleted on A goes on B despite B's own ignored files in it" \
            wait_for in_target "$mount_b" "[ ! -e /t/$dir ]"
    done

    echo "# pair, the first device of a new set without --keep"
    # C's claude.json is newer than A's, so Syncthing's newest-wins rule alone would pick C's.
    # C's own plugin version holds files the ignore list keeps out of sync.
    c_plugin=plugins/cache/market/c-only/1.0.0
    in_target "$mount_c" "echo 'c claude.json' >/t/claude.json && echo c >/t/c-only.md && \
        mkdir -p /t/$c_plugin && cd /t/$c_plugin && echo c >plugin.json && echo c >.in_use && \
        echo c >plugin.json.tmp.ab12cd34 && echo c >plugin.json.tmp.4242.0123456789ab && chown -R $owner_c /t"
    claude_sync "$c" setup --volume "$vol_c" --private >/dev/null
    id_c=$(docker exec -u "$owner_c" "$c" syncthing device-id)
    # C, with files, and D, with none, both pair with no other device yet: both join, and
    # only --keep on C would give D anything to join.
    claude_sync "$d" setup --volume "$vol_d" --private >/dev/null
    id_d=$(docker exec -u "$owner_d" "$d" syncthing device-id)
    CLAUDE_SYNC_NAME=$d timeout 300 "$bin" pair "$id_c" --address "tcp://$c:22000" >/dev/null 2>&1 &
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
    CLAUDE_SYNC_NAME=$c timeout 300 "$bin" pair "$id_a" --address "tcp://$a:22000" \
        >"$scratch/join-c.out" 2>&1 &
    joining=$!
    check "a join says what to run on the device it joins through" \
        wait_for grep -qF "claude-sync pair $id_c" "$scratch/join-c.out"
    check "  and waits for it" kill -0 "$joining"
    check "  and leaves C's files alone meanwhile" [ "$(in_target "$mount_c" 'cat /t/claude.json')" = "c claude.json" ]
    pair_bounded "$a" "$id_c" --address "tcp://$c:22000" >/dev/null
    check "C joins once A accepts" wait "$joining"
    check "C gets A's claude.json" [ "$(in_target "$mount_c" 'cat /t/claude.json')" = "fixture claude.json" ]
    check "C's own file is discarded" in_target "$mount_c" '[ ! -e /t/c-only.md ]'
    check "  into C's trash can" in_target "$mount_c" '[ -e /t/.stversions/c-only.md ]'
    check "C's own plugin version is discarded, ignored files and all" in_target "$mount_c" "[ ! -e /t/$c_plugin ]"
    check "  into C's trash can" in_target "$mount_c" "[ -e /t/.stversions/$c_plugin/plugin.json ]"
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
    check "D's join cut off while waiting" cut_off env CLAUDE_SYNC_NAME="$d" timeout 10 \
        "$bin" pair "$id_b" --address "tcp://$b:22000"
    check "  leaves D's folder receive-only" [ "$(folder_type "$d" "$owner_d")" = receiveonly ]
    # B on the unpaired list in D's folder, where a joining D could never take it off.
    in_target "type=volume,src=$vol_d" "mkdir /t/.claude-sync-unpaired && touch /t/.claude-sync-unpaired/$id_b &&
        chown -R $owner_d /t/.claude-sync-unpaired"
    check "  where pair refuses a device on the unpaired list" \
        fails_with "pair it from a device that already syncs" pair_bounded "$d" "$id_b" --address "tcp://$b:22000"
    in_target "type=volume,src=$vol_d" "rm -r /t/.claude-sync-unpaired"
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
    docker run -d --name "$h" --network "$net" --user user --entrypoint env "$host_image" \
        -u STHOMEDIR -u STGUIADDRESS HOME=/home/user syncthing serve --no-browser >/dev/null
    docker exec -u 0 "$h" mkdir /opt/claude-sync
    stage=$(mktemp -d -p "$scratch")
    copy_under_test "$stage"
    chmod 755 "$stage"
    docker cp -q "$stage/." "$h:/opt/claude-sync"
    docker cp -q "$root/stignore" "$h:/opt/stignore"
    wait_for on_host syncthing cli show version
    id_h=$(on_host syncthing device-id)
    # The user's own Syncthing: folders of their own, one shared with B, private options, and
    # a web UI address with no host.
    on_host mkdir claude photos photos/sub notes other tilde
    on_host sh -c 'echo p >photos/p.md && echo s >photos/sub/s.md && echo n >notes/n.md && echo t >tilde/t.md'
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
    # Syncthing restarts its web UI at once, so this call may not get its answer.
    on_host syncthing cli config gui raw-address set :8384 2>/dev/null || true
    wait_for on_host sh -c 'syncthing cli config gui raw-address get | grep -qx :8384'
    host_before=$(host_config)
    others_before=$(host_others)
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
    check "  and one around another folder" fails_with "which overlaps /home/user;" \
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
    check ".stignore is the repo's stignore" on_host cmp -s claude/.stignore /opt/stignore
    check "trash can versioning, 14 days" host_trash_can_14_days

    echo "# backup, on the host's Syncthing"
    check "the host's tar is GNU tar" on_host sh -c 'tar --version | grep -q "GNU tar"'
    check "backup archives the folder with this host's tar" host_sync backup backups
    check "  all of it" host_archive_has backups ./h-only.md
    check "restore run by root" docker exec -u 0 "$h" sh -c \
        '/opt/claude-sync/claude-sync restore /home/user/backups/*.tar.gz --path /root/restored'
    check "  gives root the files, not the archive's owner" \
        [ "$(docker exec -u 0 "$h" stat -c %u /root/restored/h-only.md)" = 0 ]
    host_archive=$(on_host sh -c 'ls backups/*.tar.gz')
    # shellcheck disable=SC2088 # given to claude-sync unexpanded, as when quoted
    check "restore expands a quoted ~ in the archive and the directory" \
        host_sync restore "~/$host_archive" --path '~/tilde-restored'
    check "  into the home directory" on_host test -f tilde-restored/h-only.md
    check "  but not a ~ that starts a name" host_sync restore "$host_archive" --path '~restored'
    check "  which stays a name in the working directory" on_host test -f '~restored/h-only.md'
    # shellcheck disable=SC2088 # given to claude-sync unexpanded, as when quoted
    check "backup expands a quoted ~ in its directory" host_sync backup '~/tilde-backups'
    check "  into the home directory" on_host sh -c 'ls tilde-backups/*.tar.gz'
    check "  making no ~ directory" fails on_host test -e '~'
    # A directory that user can neither write in nor chmod.
    docker exec -u 0 "$h" mkdir /home/user/root-owned
    check "a restore that tar cannot finish fails" fails_with "could not restore all of" \
        host_sync restore "$host_archive" --path root-owned
    check "a restore into a volume needs Docker" fails_with "Docker is required" \
        host_sync restore "$host_archive" --volume "$vol_r"
    # Files that come and go as GNU tar reads the folder, set up as in group_backups.
    churn=/home/user/claude/jobs/churn/tmp
    on_host sh -c "mkdir -p $churn && touch /tmp/churning &&
        for i in 1 2 3 4 5; do head -c 5000000 /dev/urandom >$churn/big\$i; done"
    on_host sh -c "i=0; while [ -e /tmp/churning ]; do
        i=\$((i + 1)); echo x >$churn/t\$i; rm -f $churn/t\$((i - 20)); done" &
    churning=$!
    wait_for on_host sh -c "ls $churn | grep -q '^t[0-9]\{3\}'"
    if host_sync backup busy >/dev/null 2>"$scratch/host-busy.err"; then busy=ok; else busy=failed; fi
    on_host rm /tmp/churning
    wait "$churning" || true
    check "backup takes files that go as GNU tar reads the folder" [ "$busy" = ok ]
    check "  after tar found some gone" grep -qF "File removed before we read it" "$scratch/host-busy.err"
    check "  in a whole archive" host_archive_has busy ./jobs/churn/tmp/big5
    on_host rm -r claude/jobs
    # GNU tar, archiving the folder, then exiting 1 with the lines in TAR_SAYS, as when files
    # changed while it read them; unless LC_ALL is C, it says so in German instead, as a GNU tar
    # with translations would, which the fixture's is not. And a tar that fails.
    docker exec -i -u user "$h" sh -c 'mkdir -p /home/user/changing && cat >/home/user/changing/tar &&
        chmod +x /home/user/changing/tar' <<'EOF'
#!/bin/sh
/bin/tar "$@" || exit
if [ "$LC_ALL" = C ]; then
    printf '%s\n' "$TAR_SAYS" >&2
else
    echo 'tar: ./h-only.md: Datei hat sich beim Lesen geändert' >&2
fi
exit 1
EOF
    docker exec -u user "$h" sh -c 'mkdir /home/user/failing && printf "#!/bin/sh\necho partial\nexit 2\n" \
        >/home/user/failing/tar && chmod +x /home/user/failing/tar'
    check "backup passes GNU tar's status 1 for files that changed or went as it read them, in any locale" \
        on_host env PATH=/home/user/changing:/usr/bin:/bin LC_ALL=de_DE.UTF-8 TAR_SAYS="tar: ./h-only.md: file changed as we read it
tar: ./gone.md: File removed before we read it" /opt/claude-sync/claude-sync backup changed
    check "  as an archive" on_host sh -c 'tar -tzf changed/*.tar.gz >/dev/null'
    check "a file that shrank as tar read it fails backup" fails_with "tar could not archive" \
        on_host env PATH=/home/user/changing:/usr/bin:/bin TAR_SAYS="tar: ./h-only.md: file changed as we read it
tar: ./big: File shrank by 10 bytes; padding with zeros" /opt/claude-sync/claude-sync backup shrank
    check "  leaving no archive" [ -z "$(on_host ls -A shrank)" ]
    check "a tar that fails fails backup" fails \
        on_host env PATH=/home/user/failing:/usr/bin:/bin /opt/claude-sync/claude-sync backup failed
    check "  leaving no partial archive" [ -z "$(on_host ls -A failed)" ]
    on_host ln -s claude into-claude
    check "a directory in the folder is refused" fails_with "is in the synced folder" \
        host_sync backup claude/.stfolder
    check "  and the folder itself, through a symlink" fails_with "is in the synced folder" \
        host_sync backup into-claude
    check "  and a directory in it not made yet" fails_with "is in the synced folder" \
        host_sync backup into-claude/new
    check "  without making it" on_host test ! -e claude/new
    check "  leaving no archive in it" [ -z "$(on_host find claude -name '*.tar.gz')" ]
    check "setup again, naming the directory another way" host_sync setup --path ./claude/ --use-host-syncthing
    # A syncthing that pauses after each line of the folder list. claude-sync comes first, so
    # a reader that stops at it exits before the next line and cuts the list off.
    docker exec -i -u user "$h" sh -c 'mkdir /home/user/slow && cat >/home/user/slow/syncthing &&
        chmod +x /home/user/slow/syncthing' <<'EOF'
#!/bin/sh
if [ "$*" = "cli config folders list" ]; then
    /bin/syncthing "$@" | while IFS= read -r line; do echo "$line" && sleep 0.5; done
    exit
fi
exec /bin/syncthing "$@"
EOF
    check "setup again, Syncthing listing folders slowly" on_host env PATH=/home/user/slow:/usr/bin:/bin \
        /opt/claude-sync/claude-sync setup --path claude --use-host-syncthing
    # A curl that never reaches the API, while `syncthing cli` still does.
    docker exec -u user "$h" sh -c 'mkdir /home/user/nocurl && printf "#!/bin/sh\nexit 7\n" >/home/user/nocurl/curl &&
        chmod +x /home/user/nocurl/curl'
    check "setup says when it cannot reach Syncthing's API" fails_with "cannot reach Syncthing" \
        on_host env PATH=/home/user/nocurl:/usr/bin:/bin /opt/claude-sync/claude-sync setup --path claude \
        --use-host-syncthing
    check "  and refuses a different directory" fails_with "already set up for /home/user/claude" \
        host_sync setup --path other --use-host-syncthing
    check "another CLAUDE_SYNC_NAME is refused" fails_with "leave CLAUDE_SYNC_NAME unset" \
        on_host env CLAUDE_SYNC_NAME=work /opt/claude-sync/claude-sync setup --path claude --use-host-syncthing
    check "  and pair under it does not use this Syncthing" fails_with "run setup first" \
        on_host env CLAUDE_SYNC_NAME=work /opt/claude-sync/claude-sync pair "$id_b"
    check "  nor does uninstall" on_host env CLAUDE_SYNC_NAME=work /opt/claude-sync/claude-sync uninstall
    check "  which leaves the folder" host_has_folder
    check "--gui-port is refused" fails_with "set them in that Syncthing" \
        host_sync setup --path claude --use-host-syncthing --gui-port 8484
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
    # Turning on TLS restarts the web UI, so this call may not get its answer. The web UI
    # takes HTTPS with TLS off too, so only reading the setting back shows it took.
    on_host syncthing cli config gui raw-use-tls set true 2>/dev/null || true
    wait_for on_host sh -c 'syncthing cli config gui raw-use-tls get | grep -qx true'
    check "pair reaches a web UI that uses TLS" \
        host_sync pair "$id_a" --address "tcp://$a:22000"
    host_before=$(host_config)

    echo "# unpair"
    check "this device's own ID is refused" fails_with "this device's own ID" claude_sync "$a" unpair "$id_a"
    check "an invalid device ID is refused" fails_with "not a device ID" claude_sync "$a" unpair not-a-device-id
    # The host device pairs with D directly, so no introducer takes D away there, and also
    # shares another folder with it. It knows D by introduction so far, which pairing alone
    # does not change, so D is deleted there first. Until pair has added D and shared the
    # folder with it, the host device does not trust its other introducers: a ClusterConfig
    # from one of them would add D back by introduction. Their connections stay up: a
    # reconnection here would have the host device introduce D to A again just after A's
    # unpair, before the test checks that the unpair removed it.
    check "the host device knows D" \
        wait_for on_host sh -c "syncthing cli config devices list | grep -qx $id_d"
    ids=$(on_host syncthing cli config dump-json |
        jq -r --arg d "$id_d" '.devices[] | select(.introducer and .deviceID != $d) | .deviceID')
    introducers=()
    [[ -z $ids ]] || mapfile -t introducers <<<"$ids"
    for x in "${introducers[@]}"; do
        on_host syncthing cli config devices "$x" introducer set false
    done
    on_host syncthing cli config folders claude-sync devices "$id_d" delete
    on_host syncthing cli config devices "$id_d" delete
    host_sync pair "$id_d" --address "tcp://$d:22000" >/dev/null
    for x in "${introducers[@]}"; do
        on_host syncthing cli config devices "$x" introducer set true
    done
    pair_bounded "$d" "$id_h" --address "tcp://$h:22000" >/dev/null
    on_host syncthing cli config folders photos devices add --device-id "$id_d"
    check "the host device knows D directly" [ -z "$(on_host syncthing cli config devices "$id_d" dump-json | jq -r .introducedBy)" ]
    # A knows D only through an introduction, where removing it by hand alone would not stick.
    check "A knows D only by introduction" [ -n "$(introduced_by "$a" "$owner_a" "$id_d")" ]
    claude_sync "$a" unpair "$id_d" >/dev/null
    check "unpair removes D on A" forgets "$a" "$owner_a" "$id_d"
    check "  and on B, which D paired with" wait_for forgets "$b" "$owner_b" "$id_d"
    check "  and on C" wait_for forgets "$c" "$owner_c" "$id_d"
    check "the list of unpaired devices reaches the host device" \
        wait_for on_host test -e "claude/.claude-sync-unpaired/$id_d"
    check "  which keeps D until claude-sync runs there" \
        on_host sh -c "syncthing cli config folders claude-sync devices list | grep -qx $id_d"
    since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    reconnect "$a" "$owner_a" "$id_h"
    check "the host device, still sharing with D, introduces it to A again" \
        wait_for sh -c "docker logs --since $since $a 2>&1 | grep 'vouched for by introducer' | grep -q device=${id_d:0:7}"
    check "  and A removes it again" wait_for forgets "$a" "$owner_a" "$id_d"
    host_sync pair "$id_a" --address "tcp://$a:22000" >/dev/null
    check "the host device drops D from claude-sync's folder once claude-sync runs there" \
        sh -c "! docker exec -u user $h env -u STHOMEDIR -u STGUIADDRESS HOME=/home/user \
            syncthing cli config folders claude-sync devices list | grep -qx $id_d"
    check "  and keeps it for the other folder they share" \
        on_host sh -c "syncthing cli config devices list | grep -qx $id_d"
    on_host syncthing cli config folders photos devices "$id_d" delete
    on_host syncthing cli config devices "$id_d" delete
    pair_bounded "$b" "$id_d" --address "tcp://$d:22000" >/dev/null
    check "D pairs again" pair_bounded "$d" "$id_b" --address "tcp://$b:22000" --keep
    check "  leaving the list" fails in_target "$mount_b" "[ -e /t/.claude-sync-unpaired/$id_d ]"
    check "  and B keeps it" wait_for knows_device "$b" "$owner_b" "$id_d"
    check "  and A learns of it again" wait_for knows_device "$a" "$owner_a" "$id_d"
    check "  and C" wait_for knows_device "$c" "$owner_c" "$id_d"
    in_target "$mount_b" "echo b >/t/after-unpair.md && chown $owner_b /t/after-unpair.md"
    check "  and D syncs again" wait_for in_target "type=volume,src=$vol_d" '[ -e /t/after-unpair.md ]'

    echo "# uninstall, on the host's Syncthing"
    wait_for on_host test -e claude/after-unpair.md
    wait_for host_idle
    before=$(host_snapshot)
    devices=$(on_host syncthing cli config devices list | sort)
    host_sync uninstall >/dev/null
    check "removes claude-sync's folder" fails host_has_folder
    check "keeps the devices it paired" [ "$(on_host syncthing cli config devices list | sort)" = "$devices" ]
    check "keeps the user's other folders and options" [ "$(host_config)" = "$host_before" ]
    check "  and their files, through setup, pair, unpair and uninstall" [ "$(host_others)" = "$others_before" ]
    check "leaves the synced data byte-identical" [ "$(host_snapshot)" = "$before" ]
    check "Syncthing keeps running" on_host syncthing cli show version
    check "pair afterwards is refused" fails_with "run setup first" host_sync pair "$id_a"

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
}
