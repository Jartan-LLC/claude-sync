# shellcheck shell=bash
# group_stuck, the names of what it makes, and the helpers only it uses.

readonly j=${prefix}j l=${prefix}l
readonly vol_j=${prefix}j-data vol_l=${prefix}l-data
readonly owner_j=8901:8901 owner_l=9012:9012
readonly mount_j=type=volume,src=$vol_j mount_l=type=volume,src=$vol_l
own_instances "$j" "$l"
own_volumes "$vol_j" "$vol_l"

# Whether a node's Syncthing is scanning the folder, or waiting to.
scanning() {
    [[ $(folder_status "$1" "$2" | jq -r .state) == scan* ]]
}

# J: a first scan setup does not wait for, and a join stuck under an old ignore list.
group_stuck() {
    echo "# setup, while Syncthing's first scan runs"
    # A sparse file takes Syncthing far longer to hash than these checks, and no disk space.
    in_target "$mount_j" "truncate -s 64G /t/big && chown -R $owner_j /t"
    out=$(claude_sync "$j" setup --volume "$vol_j" --private)
    check "setup returns while Syncthing still scans" scanning "$j" "$owner_j"
    check "  and says so, with the web UI's address" \
        grep -qF "see progress at http://$(st "$j" "$owner_j" config gui raw-address get)" <<<"$out"
    check "setup again returns too" claude_sync "$j" setup --volume "$vol_j" --private
    check "  before the scan ends" scanning "$j" "$owner_j"
    claude_sync "$j" uninstall >/dev/null
    docker volume rm "$vol_j" >/dev/null
    docker volume create "$vol_j" >/dev/null

    echo "# pair, a join stuck on this device's own ignored files"
    # A copy with every (?d) taken out, which leaves .in_use without one as in 0.1.0:
    # Syncthing cannot remove J's own plugin version while its .in_use is there, so J's
    # join cannot finish.
    mkdir "$scratch/old"
    copy_checkout "$scratch/old"
    sed 's/^(?d)//' "$root/stignore" >"$scratch/old/stignore"
    j_plugin=plugins/cache/market/j-only/1.0.0
    in_target "$mount_j" "mkdir -p /t/$j_plugin && echo j >/t/$j_plugin/plugin.json && \
        echo j >/t/$j_plugin/.in_use && chown -R $owner_j /t"
    env CLAUDE_SYNC_NAME="$j" "$scratch/old/claude-sync" setup --volume "$vol_j" --private >/dev/null
    id_j=$(docker exec -u "$owner_j" "$j" syncthing device-id)
    claude_sync "$l" setup --volume "$vol_l" --private >/dev/null
    id_l=$(docker exec -u "$owner_l" "$l" syncthing device-id)
    pair_bounded "$l" "$id_j" --address "tcp://$j:22000" --keep >/dev/null
    check "J's join does not finish under that list" cut_off env CLAUDE_SYNC_NAME="$j" timeout 15 \
        "$scratch/old/claude-sync" pair "$id_l" --address "tcp://$l:22000"
    check "setup applies this version's ignore list" claude_sync "$j" setup --volume "$vol_j" --private
    # Syncthing reloads the list on its own at a later pull, but only minutes later, so a
    # join that finishes within this timeout shows setup applied it.
    check "  and the join then finishes at once" env CLAUDE_SYNC_NAME="$j" timeout 30 \
        "$bin" pair "$id_l" --address "tcp://$l:22000"
    check "  discarding J's own plugin version" in_target "$mount_j" "[ ! -e /t/$j_plugin ]"
    check "  into J's trash can" in_target "$mount_j" "[ -e /t/.stversions/$j_plugin/plugin.json ]"
}
