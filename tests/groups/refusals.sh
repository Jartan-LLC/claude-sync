# shellcheck shell=bash
# group_refusals, the names of what it makes, and the helpers only it uses.

readonly m=${prefix}m bad_name=${prefix}BAD foreign=${prefix}foreign
readonly vol_m=${prefix}m-data vol_root=${prefix}root-data vol_missing=${prefix}missing
readonly owner_m=5678:5678
readonly mount_m=type=volume,src=$vol_m
own_instances "$m" "$bad_name" "$foreign"
own_volumes "$vol_m" "$vol_root" "$vol_missing"

relative_path_resolved() {
    local err
    err=$(cd "$root" && CLAUDE_SYNC_NAME=$m "$bin" setup --path "${prefix}missing" 2>&1 >/dev/null) &&
        return 1
    grep -qxF "claude-sync: cannot read $root/${prefix}missing" <<<"$err"
}

path_overlay_renders() {
    CLAUDE_SYNC_NAME=$a CLAUDE_SYNC_UID=1 CLAUDE_SYNC_GID=1 CLAUDE_SYNC_TARGET=/srv/claude \
        CLAUDE_SYNC_CONFIG_PATH=/var/syncthing/config CLAUDE_SYNC_FOLDER_PATH=/var/syncthing/claude \
        CLAUDE_SYNC_COMPANION_PATH=/var/syncthing/config/claude-sync-companion \
        CLAUDE_SYNC_UNPAIRED_PATH=/var/syncthing/claude/.claude-sync-unpaired \
        docker compose -f "$root/compose.yaml" -f "$root/compose.path.yaml" config --format json |
        jq -e '.services.syncthing.volumes | any(
            .type == "bind" and .source == "/srv/claude" and .target == "/var/syncthing/claude")'
}

# Whether SCRIPT, or else the claude-sync under test, gives out FILE as this checkout has
# it, including the compose overlay for --path, which no test runs in a container.
carries() {
    # shellcheck disable=SC2016 # expanded by the inner bash
    bash -c 'source "$1" help >/dev/null && asset "$2"' _ "${2:-$bin}" "$1" | cmp -s - "$root/$1"
}

# Input setup refuses, and objects uninstall refuses, on node M of its own.
group_refusals() {
    echo "# version"
    docker volume create "$vol_root" >/dev/null
    docker volume create "$vol_m" >/dev/null
    in_target "$mount_m" "chown $owner_m /t"
    check "version prints the version" [ "$("$bin" version)" = "claude-sync ${CLAUDE_SYNC_BIN_VERSION:-dev}" ]
    check "  and so does --version" [ "$("$bin" --version)" = "claude-sync ${CLAUDE_SYNC_BIN_VERSION:-dev}" ]
    for f in compose.yaml compose.path.yaml compose.volume.yaml stignore; do
        check "carries $f unchanged" carries "$f"
    done

    # The checkout's own script, whatever claude-sync the suite tests.
    echo "# a checkout's claude-sync"
    mkdir "$scratch/link" "$scratch/lone"
    ln -s "$root/claude-sync" "$scratch/link/claude-sync"
    check "run through a symlink, it prints its help" \
        [ "$("$scratch/link/claude-sync" help)" = "$("$root/claude-sync" help)" ]
    check "  and its version" [ "$("$scratch/link/claude-sync" version)" = "claude-sync dev" ]
    check "  and finds its own files" carries stignore "$scratch/link/claude-sync"
    cp "$root/claude-sync" "$scratch/lone/"
    local out status
    out=$("$scratch/lone/claude-sync" version 2>&1) && status=0 || status=$?
    check "copied without lib/ beside it, it exits 1" [ "$status" = 1 ]
    check "  saying it needs lib/" grep -qF "runs only with lib/ beside it" <<<"$out"
    out=$(fileless stdin "$root/claude-sync" version 2>&1) && status=0 || status=$?
    check "run from stdin, it exits 1" [ "$status" = 1 ]
    check "  saying it runs only as a file" grep -qF "runs only as a file, with lib/ beside it" <<<"$out"

    echo "# setup rejects bad input"
    check "a missing volume is rejected" fails_with "no Docker volume named $vol_missing" \
        claude_sync "$m" setup --volume "$vol_missing"
    check "  and is not created" fails docker volume inspect "$vol_missing"
    check "a root-owned target is rejected" fails_with "owned by root" claude_sync "$m" setup --volume "$vol_root"
    check "  and nothing is written to it" in_target "type=volume,src=$vol_root" '[ ! -e /t/.stignore ]'
    check "an invalid CLAUDE_SYNC_NAME is rejected" fails_with CLAUDE_SYNC_NAME \
        claude_sync "$bad_name" setup --volume "$vol_m"
    check "  and creates no volume" fails docker volume inspect "$bad_name-config"
    # A missing volume, so a broken name check still stops before creating anything unprefixed.
    check "a one-character CLAUDE_SYNC_NAME is rejected" fails_with CLAUDE_SYNC_NAME \
        claude_sync x setup --volume "$vol_missing"
    # With equal ports too, so code that took the empty --path stops before it could set up
    # the working directory.
    check "an empty directory is refused" fails_with "--path needs a value" \
        claude_sync "$m" setup --path "" --gui-port 8500 --sync-port 8500
    check "  and an empty volume" fails_with "--volume needs a value" claude_sync "$m" setup --volume ""
    check "pair refuses an empty address" fails_with "--address needs a value" \
        claude_sync "$m" pair DEVICE-ID --address ""
    check "a port that is not a number is refused" fails_with "not a port" \
        claude_sync "$m" setup --volume "$vol_m" --gui-port http
    check "  and one below 1024" fails_with "not a port" claude_sync "$m" setup --volume "$vol_m" --sync-port 80
    check "  and the same port for both" fails_with "need different ports" \
        claude_sync "$m" setup --volume "$vol_m" --gui-port 8500 --sync-port 8500
    check "  and creates no Syncthing state" fails docker volume inspect "$m-config"
    # A stand-in for this user's Syncthing on the host, stopped: it answers only `paths`, so
    # the checks must read its config file, which write_host_folders writes. The volume and
    # directories do not exist, so even a setup that got past the checks would stop before
    # creating anything.
    mkdir "$scratch/host"
    cat >"$scratch/host/syncthing" <<'EOF'
#!/bin/sh
[ "$*" = paths ] || exit 1
printf 'Configuration file:\n\t%s/config.xml\n' "${0%/*}"
EOF
    chmod +x "$scratch/host/syncthing"
    # The stand-in's folders, as ID and path pairs, the path already escaped for XML.
    write_host_folders() {
        {
            echo '<configuration version="51">'
            # As Syncthing writes it: the template for new folders, with no ID or path.
            printf '    <defaults>\n        <folder id="" label="" path="" type="sendreceive">\n        </folder>\n    </defaults>\n'
            while (($#)); do
                printf '    <folder id="%s" label="x" path="%s" type="sendreceive">\n    </folder>\n' "$1" "$2"
                shift 2
            done
            echo '</configuration>'
        } >"$scratch/host/config.xml"
    }
    # shellcheck disable=SC2329 # called below; ShellCheck cannot follow run_group
    beside_host() {
        env PATH="$scratch/host:$PATH" CLAUDE_SYNC_NAME=claude-sync "$bin" setup "$@"
    }
    readonly elsewhere=/nonexistent/$prefix$$
    write_host_folders claude-sync "$elsewhere/claude"
    check "a volume beside a Syncthing that syncs claude-sync's folder is refused" \
        fails_with "set CLAUDE_SYNC_NAME to another name" beside_host --volume "$vol_missing"
    check "  and a directory, pointing to --use-host-syncthing" fails_with "add --use-host-syncthing" \
        beside_host --path "$elsewhere/other"
    write_host_folders photos "$elsewhere/photos"
    check "  but not beside one without that folder" fails_with "no Docker volume named $vol_missing" \
        beside_host --volume "$vol_missing"
    check "a directory inside a folder of that Syncthing is refused" fails_with "folder photos already syncs" \
        beside_host --path "$elsewhere/photos/sub"
    check "  and one around it" fails_with "folder photos already syncs" beside_host --path "$elsewhere"
    # Under a name of their own: a real claude-sync instance on this Docker daemon, under the
    # default name, would refuse these first.
    check "  but not one beside it" fails_with "cannot read $elsewhere/photos2" \
        env PATH="$scratch/host:$PATH" CLAUDE_SYNC_NAME="$m" "$bin" setup --path "$elsewhere/photos2"
    check "  nor one here, where the folder template's empty path would point" \
        fails_with "cannot read $PWD/${prefix}here" \
        env PATH="$scratch/host:$PATH" CLAUDE_SYNC_NAME="$m" "$bin" setup --path "${prefix}here"
    check "  and under another name too" fails_with "folder photos already syncs" \
        env PATH="$scratch/host:$PATH" CLAUDE_SYNC_NAME="$m" "$bin" setup --path "$elsewhere/photos/sub"
    write_host_folders claude-sync "$elsewhere/claude"
    check "  where claude-sync's own folder there counts as any other" fails_with "folder claude-sync already syncs" \
        env PATH="$scratch/host:$PATH" CLAUDE_SYNC_NAME="$m" "$bin" setup --path "$elsewhere/claude/x"
    write_host_folders music "$elsewhere/rock&amp;roll"
    check "  read with the path's XML escapes undone" fails_with "folder music already syncs" \
        beside_host --path "$elsewhere/rock&roll/live"
    write_host_folders notes "$elsewhere/it&#39;s"
    check "  numeric ones too" fails_with "folder notes already syncs" beside_host --path "$elsewhere/it's/x"
    check "no container or state is left behind" fails docker container inspect "$m"
    check "  nor Syncthing state" fails docker volume inspect "$m-config"

    # A real --path run would need a directory on the Docker host, which is not this
    # filesystem when the tests run in a dev container that shares the host's daemon. Path
    # mode differs from volume mode only in its compose overlay and path handling, which
    # these check without a mount.
    echo "# setup --path"
    check "a missing directory is rejected" fails_with "cannot read /nonexistent/$prefix$$" \
        claude_sync "$m" setup --path "/nonexistent/$prefix$$"
    check "a path with a comma is rejected" fails_with comma claude_sync "$m" setup --path /tmp/a,b
    check "  and one with a newline" fails_with newline claude_sync "$m" setup --path $'/tmp/a\nb'
    check "a relative path is made absolute" relative_path_resolved
    check "  and one spelled loosely is cleaned as Docker does" fails_with "cannot read $root/${prefix}missing" \
        claude_sync "$m" setup --path "$root/./tests/..//${prefix}missing/"
    check "the overlay bind-mounts the directory" path_overlay_renders

    echo "# setup fails when Syncthing cannot run the folder"
    # A scratch copy of the checkout, so the broken ignore list never touches the repo's.
    mkdir "$scratch/broken"
    copy_checkout "$scratch/broken"
    echo '*.bad[0-9a-f]' >>"$scratch/broken/stignore"
    check "an ignore list Syncthing rejects fails setup with its error" fails_with "invalid pattern" \
        env CLAUDE_SYNC_NAME="$m" "$scratch/broken/claude-sync" setup --volume "$vol_m" --private
    check "  and leaves no compose files behind" no_leftovers
    claude_sync "$m" uninstall >/dev/null

    echo "# uninstall refuses what claude-sync did not create"
    # One foreign object at a time, so each refusal can only come from its own check.
    docker run -d --name "$foreign" --entrypoint sleep "$image" 600 >/dev/null
    check "a foreign container is refused" fails_with "container $foreign was not created by claude-sync" \
        claude_sync "$foreign" uninstall
    check "  and survives" docker container inspect "$foreign"
    docker rm --force -v "$foreign" >/dev/null
    docker volume create "$foreign-config" >/dev/null
    check "a foreign volume is refused" fails_with "volume $foreign-config was not created by claude-sync" \
        claude_sync "$foreign" uninstall
    check "  and survives" docker volume inspect "$foreign-config"
}
