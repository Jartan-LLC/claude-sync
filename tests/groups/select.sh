# shellcheck shell=bash
# group_select and the helpers only it uses.

# claude-sync as the user runs it, with no CLAUDE_SYNC_NAME, and the docker shim of
# group_select.
unnamed() {
    env -u CLAUDE_SYNC_NAME PATH="$scratch/select:$PATH" "$bin" "$@"
}

# claude-sync with CLAUDE_SYNC_NAME set to NAME, and the docker shim of group_select.
named() {
    env CLAUDE_SYNC_NAME="$1" PATH="$scratch/select:$PATH" "$bin" "${@:2}"
}

# V and W: listing a host's instances and selecting the one commands act on.
group_select() {
    echo "# list and use"
    # A config directory of this group's own, as the groups run in parallel: a command
    # without CLAUDE_SYNC_NAME in another group would otherwise follow this selection.
    export XDG_CONFIG_HOME=$scratch/config-select
    local selection=$XDG_CONFIG_HOME/claude-sync/instance
    # list and use read every instance on the Docker daemon, which may hold real ones, and
    # with no CLAUDE_SYNC_NAME a command acts on the default name, which may be a real
    # instance's. So these run with a shim that lists only V's and W's volumes, and lets
    # through only reads, unless claude-sync acts on V or W. With
    # CLAUDE_SYNC_TEST_DOCKER_DOWN set, every command fails, as with a daemon that is not
    # running.
    mkdir "$scratch/select"
    cat >"$scratch/select/docker" <<EOF
#!/usr/bin/env bash
real=$(command -v docker) v=$v w=$w
EOF
    cat >>"$scratch/select/docker" <<'EOF'
if [[ -n ${CLAUDE_SYNC_TEST_DOCKER_DOWN:-} ]]; then
    echo "docker shim: cannot connect to the Docker daemon" >&2
    exit 1
fi
if [[ $1 == volume && $2 == ls ]]; then
    "$real" "$@" | grep -xF -e "$v-config" -e "$w-config" || true
    exit
fi
[[ ${CLAUDE_SYNC_NAME:-} == "$v" || ${CLAUDE_SYNC_NAME:-} == "$w" ]] && exec "$real" "$@"
[[ $1 == inspect || ($1 =~ ^(container|volume|image)$ && $2 == inspect) ]] && exec "$real" "$@"
echo "docker shim: refusing docker $* under CLAUDE_SYNC_NAME=${CLAUDE_SYNC_NAME:-}" >&2
exit 97
EOF
    chmod +x "$scratch/select/docker"
    docker volume create "$vol_v" >/dev/null
    in_target "type=volume,src=$vol_v" "chown $owner_v /t"

    out=$(unnamed list)
    check "list with no instance says so" grep -qxF "No instance is set up on this host." <<<"$out"
    mkdir -p "${selection%/*}"
    : >"$selection"
    check "  but refuses an empty selection file, naming it" \
        fails_with "$selection does not hold a valid instance name" unnamed list
    rm "$selection"
    mkdir "$selection"
    check "a command refuses a selection file it cannot read, naming it" \
        fails_with "$selection does not hold a valid instance name" unnamed pair not-a-device-id
    check "  and use, unable to remove it, says so" fails_with "cannot remove $selection" unnamed use claude-sync
    rmdir "$selection"
    claude_sync "$v" setup --volume "$vol_v" >/dev/null
    docker volume create --label claude-sync=config "$w-config" >/dev/null
    out=$(unnamed list)
    check "list shows a running instance and what it syncs" grep -qE "^  $v +running +volume $vol_v\$" <<<"$out"
    check "  and one with only its Syncthing state" grep -qE "^  $w +state only +-\$" <<<"$out"
    check "  and that the default, which commands act on, is not set up" \
        grep -qxF "Commands act on instance claude-sync, which is not set up on this host." <<<"$out"

    check "use refuses a name that is not an instance" fails_with "no instance named ${prefix}typo" \
        unnamed use "${prefix}typo"
    check "  selecting nothing" [ ! -e "$selection" ]
    mkdir "$selection"
    check "use says when it cannot write the selection" fails_with "cannot write the selection to $selection" \
        unnamed use "$v"
    rmdir "$selection"
    check "use when docker cannot list the instances fails, saying so" \
        fails_with "so use cannot check that $v is one" \
        env -u CLAUDE_SYNC_NAME CLAUDE_SYNC_TEST_DOCKER_DOWN=1 PATH="$scratch/select:$PATH" "$bin" use "$v"
    check "use with neither HOME nor XDG_CONFIG_HOME fails, saying so" \
        fails_with "nowhere to keep the selection" \
        env -u CLAUDE_SYNC_NAME -u HOME -u XDG_CONFIG_HOME PATH="$scratch/select:$PATH" "$bin" use "$v"
    check "  or with a relative XDG_CONFIG_HOME, which it ignores" fails_with "nowhere to keep the selection" \
        env -C "${selection%/*}" -u CLAUDE_SYNC_NAME -u HOME XDG_CONFIG_HOME=relative PATH="$scratch/select:$PATH" "$bin" use "$v"
    check "use selects an instance" unnamed use "$v"
    check "  in the config directory" [ "$(cat "$selection")" = "$v" ]
    check "  after which messages name the default instance in its setup command" \
        [ "$(calls setup_command claude-sync)" = "CLAUDE_SYNC_NAME=claude-sync claude-sync setup" ]
    check "  which list marks" grep -qE "^\* $v +running" <<<"$(unnamed list)"
    out=$(unnamed pair not-a-device-id 2>&1) || true
    check "a command then acts on it, saying so" \
        grep -qF "acting on instance $v, selected with claude-sync use" <<<"$out"
    check "  and finds it running" grep -qF "not a device ID" <<<"$out"
    out=$(unnamed setup --use-host-syncthing --path "$scratch" 2>&1) || true
    check "setup says so too" grep -qF "acting on instance $v, selected with claude-sync use" <<<"$out"
    check "  and refuses --use-host-syncthing, saying to select the default" \
        grep -qF "run claude-sync use claude-sync first" <<<"$out"
    check "unpair says so too" fails_with "acting on instance $v, selected with claude-sync use" \
        unnamed unpair not-a-device-id

    check "CLAUDE_SYNC_NAME still wins over the selection" grep -qE "^\* $w +state only" <<<"$(named "$w" list)"
    check "  and a command it names says so" \
        fails_with "acting on instance $w, named by CLAUDE_SYNC_NAME" named "$w" pair not-a-device-id
    check "  as backup does" \
        fails_with "acting on instance $w, named by CLAUDE_SYNC_NAME" named "$w" backup "$scratch/w-backups"
    check "  and --use-host-syncthing under it says to clear the selection too" \
        fails_with "leave CLAUDE_SYNC_NAME unset and run claude-sync use claude-sync first" \
        named "$w" setup --use-host-syncthing --path "$scratch"
    check "use with CLAUDE_SYNC_NAME set says it still wins" \
        grep -qF "CLAUDE_SYNC_NAME is set, so commands run with it still act on instance $w." \
        <<<"$(named "$w" use "$v")"
    check "use of the default clears the selection" unnamed use claude-sync
    check "  removing the file" [ ! -e "$selection" ]
    printf '\n%s\n' "$v" >"$selection"
    check "a selection file with no valid name on its first line is refused, naming the file" \
        fails_with "$selection does not hold a valid instance name" unnamed pair not-a-device-id
    unnamed use "$v" >/dev/null
    # A bind source must exist on the Docker host, hence /. The container is never started,
    # so nothing is mounted: list reads only its list of mounts.
    docker create --name "$w" --label "com.docker.compose.project=$w" \
        --mount type=bind,src=/,dst=/var/syncthing/claude,readonly "$image" >/dev/null
    check "list shows what an instance on a directory syncs" \
        grep -qE "^  $w +stopped +directory /\$" <<<"$(unnamed list)"
    out=$(named "$w" uninstall 2>&1)
    check "uninstall of another instance leaves the selection" [ "$(cat "$selection")" = "$v" ]
    check "  and says nothing of it" fails grep -qF "no longer selected" <<<"$out"

    docker stop "$v" >/dev/null
    check "list shows a stopped instance" grep -qE "^\* $v +stopped +volume $vol_v\$" <<<"$(unnamed list)"
    check "list when docker cannot list the instances fails, saying so" \
        fails_with "docker cannot list the instances in containers" \
        env -u CLAUDE_SYNC_NAME CLAUDE_SYNC_TEST_DOCKER_DOWN=1 PATH="$scratch/select:$PATH" "$bin" list
    out=$(unnamed uninstall 2>&1)
    check "uninstall acts on the selected instance" fails docker container inspect "$v"
    check "  and clears the selection" [ ! -e "$selection" ]
    check "  saying later commands act on the default" \
        grep -qF "later commands act on the default instance, claude-sync." <<<"$out"
}
