# shellcheck shell=bash
# group_upgrade, the names of what it makes, and the helpers only it uses.

readonly n=${prefix}n p=${prefix}p s=${prefix}s hu=${prefix}hu
readonly held=${prefix}held recreated=${prefix}recreated named=${prefix}named
readonly vol_n=${prefix}n-data vol_p=${prefix}p-data vol_named=${prefix}named-home
readonly owner_n=1357:1357 owner_p=2468:2468
readonly mount_n=type=volume,src=$vol_n mount_p=type=volume,src=$vol_p
own_instances "$n" "$p" "$s"
own_containers "$hu" "$held" "$recreated" "$named"
own_volumes "$vol_n" "$vol_p" "$vol_named"

# The newest releases in LIST, to the 0.4.0 build: the one that is not breaking and the
# one that is.
newest_releases() {
    # shellcheck disable=SC2016 # expanded by the inner bash
    CLAUDE_SYNC_RELEASES_API="file://$up/releases/$1" bash -c \
        'source "$1" help >/dev/null && check_releases && echo "$release_safe $release_breaking"' _ "$up/old/claude-sync"
}

# CMD with the fake releases in LIST. Upgrade acts on every instance on the Docker daemon
# and in the runner's own Syncthing, which may hold real ones, and the other groups run
# beside it, so it runs with the shims for docker and syncthing.
with_releases() {
    env PATH="$up/shim:$PATH" CLAUDE_SYNC_RELEASES_API="file://$up/releases/$1" \
        timeout 600 "${@:2}"
}

# upgrade of the 0.4.0 build run from no file, as fileless's HOW, with no release list.
upgrade_fileless() {
    PATH="$up/shim:$PATH" CLAUDE_SYNC_RELEASES_API="file://$up/releases/missing.json" \
        fileless "$1" "$up/old/claude-sync" upgrade
}

# upgrade as installed in $up/install, with the fake releases in LIST.
upgrade_here() {
    with_releases "$1" "$up/install/claude-sync" upgrade
}

# N, P and the host fixture HU: instances set up by one build, reapplied by a newer one.
group_upgrade() {
    echo "# upgrade"
    docker volume create "$vol_n" >/dev/null
    docker volume create "$vol_p" >/dev/null
    in_target "$mount_n" "chown $owner_n /t"
    in_target "$mount_p" "chown $owner_p /t"
    # This group's files, apart from the other groups' in $scratch; the helpers above use it.
    up=$scratch/upgrade
    # 0.4.0, the build installed: a copy whose ignore list and compose file differ from this
    # checkout's, so the reapply shows. 0.4.1, the release: this checkout.
    mkdir -p "$up/old-src/packaging" "$up/old" "$up/install" "$up/shim" "$up/rpm" \
        "$up/releases/download/v0.4.1" "$up/bad/releases/download/v0.4.1" \
        "$up/wrong/releases/download/v0.4.1"
    copy_checkout "$up/old-src"
    cp "$root/packaging/build.sh" "$up/old-src/packaging"
    echo '// the old ignore list' >>"$up/old-src/stignore"
    sed -i 's/^    restart: unless-stopped$/&\n    labels: [claude-sync-test-old=1]/' "$up/old-src/compose.yaml"
    "$up/old-src/packaging/build.sh" 0.4.0 "$up/old/claude-sync"
    "$root/packaging/build.sh" 0.4.1 "$up/releases/download/v0.4.1/claude-sync"
    (cd "$up/releases/download/v0.4.1" && sha256sum claude-sync >claude-sync.sha256)
    echo "0000000000000000000000000000000000000000000000000000000000000000  claude-sync" \
        >"$up/bad/releases/download/v0.4.1/claude-sync.sha256"
    # A release whose file says it is another version.
    "$root/packaging/build.sh" 0.4.9 "$up/wrong/releases/download/v0.4.1/claude-sync"
    (cd "$up/wrong/releases/download/v0.4.1" && sha256sum claude-sync >claude-sync.sha256)
    releases_json "file://$up" >"$up/releases/releases.json"
    releases_json "file://$up" "file://$up/bad" >"$up/releases/bad.json"
    releases_json "file://$up/wrong" >"$up/releases/wrong.json"
    # A release with no files, and one whose claude-sync is not there, though its SHA-256 is.
    releases_json "file://$up" | sed '/browser_download_url/d' >"$up/releases/no-assets.json"
    releases_json "file://$up/gone" "file://$up" >"$up/releases/gone.json"
    # Tags in no version order, as GitHub lists releases by date: neither the first nor the
    # last of each kind is the newest.
    cat >"$up/releases/order.json" <<'EOF'
[
  {"tag_name": "v0.4.2"}, {"tag_name": "v0.5.0"}, {"tag_name": "v0.4.3"},
  {"tag_name": "v0.6.0"}, {"tag_name": "v0.4.1"}, {"tag_name": "v0.5.1"}
]
EOF
    readonly new=$up/releases/download/v0.4.1/claude-sync
    cp "$up/old/claude-sync" "$up/install/claude-sync"
    # A second name for the installed file: a rewrite in place would show through it.
    ln "$up/install/claude-sync" "$up/held"
    # Lists only N's, P's and S's volumes, as `volume ls -q` gives them; S has no container.
    # Under any other instance's name, or under one of the names in CLAUDE_SYNC_TEST_REFUSE,
    # which makes that instance's setup fail, it lets through only reads and commands run in
    # N's and P's containers. With CLAUDE_SYNC_TEST_DOCKER_DOWN set, every command fails, as
    # with a daemon that is not running.
    cat >"$up/shim/docker" <<EOF
#!/usr/bin/env bash
real=$(command -v docker) n=$n p=$p s=$s
EOF
    cat >>"$up/shim/docker" <<'EOF'
if [[ -n ${CLAUDE_SYNC_TEST_DOCKER_DOWN:-} ]]; then
    echo "docker shim: cannot connect to the Docker daemon" >&2
    exit 1
fi
if [[ $1 == volume && $2 == ls ]]; then
    "$real" "$@" | grep -xF -e "$n-config" -e "$p-config" -e "$s-config" || true
    exit
fi
ours() { [[ $1 == "$n" || $1 == "$p" ]]; }
if ours "${CLAUDE_SYNC_NAME:-}" && [[ " ${CLAUDE_SYNC_TEST_REFUSE:-} " != *" $CLAUDE_SYNC_NAME "* ]]; then
    exec "$real" "$@"
fi
[[ $1 == inspect || $1 == ps || ($1 =~ ^(container|volume|image)$ && $2 == inspect) ]] && exec "$real" "$@"
[[ $1 == exec ]] && ours "$2" && exec "$real" "$@"
echo "docker shim: refusing docker $* under CLAUDE_SYNC_NAME=${CLAUDE_SYNC_NAME:-}" >&2
exit 97
EOF
    # No Syncthing on this host as far as upgrade can tell, so it never finds the runner's.
    printf '#!/bin/sh\nexit 1\n' >"$up/shim/syncthing"
    fake_rpm "$up/rpm"
    chmod +x "$up/shim/docker" "$up/shim/syncthing"

    check "a new minor version while the major is 0 is breaking" calls version_breaking 0.4.0 0.5.0
    check "  a new patch version is not" fails calls version_breaking 0.4.0 0.4.9
    check "  nor a new minor version from 1" fails calls version_breaking 1.4.0 1.9.0
    check "  but a new major version is" calls version_breaking 1.4.0 2.0.0
    check "versions compare by number" calls version_older 0.9.0 0.10.0
    check "  a pre-release before its release" calls version_older 0.4.0-rc.1 0.4.0
    check "  also as an RPM writes it" calls version_older 0.4.0~rc.1 0.4.0
    check "  and a version not before itself" fails calls version_older 0.4.0 0.4.0
    check "the newest release of each kind is picked, whatever the list's order" \
        [ "$(newest_releases order.json)" = "v0.4.3 v0.6.0" ]

    # With no release list, so a refusal that fails cannot go further.
    check "upgrade from a checkout is refused" fails_with "runs from a checkout" \
        with_releases missing.json "$root/claude-sync" upgrade
    for how in stdin string procsub; do
        check "upgrade run from no file ($how) is refused" fails_with "not running from a file" \
            upgrade_fileless "$how"
    done
    check "upgrade of a file an RPM installed is refused" fails_with "upgrade it with sudo dnf upgrade --refresh claude-sync," \
        with_releases missing.json env PATH="$up/rpm:$up/shim:$PATH" "$up/install/claude-sync" upgrade
    check "a download that fails its SHA-256 check is refused" fails_with "SHA-256" upgrade_here bad.json
    check "  leaving the installed file as it was" cmp -s "$up/install/claude-sync" "$up/old/claude-sync"
    check "a download that is another version is refused" fails_with "is not version 0.4.1" \
        upgrade_here wrong.json
    check "  leaving the installed file as it was" cmp -s "$up/install/claude-sync" "$up/old/claude-sync"
    check "upgrade without the list of releases fails" fails_with "cannot get the list of claude-sync's releases" \
        upgrade_here missing.json
    check "a release with no files is refused" fails_with "release v0.4.1 has no claude-sync or claude-sync.sha256" \
        upgrade_here no-assets.json
    check "a download that fails is refused" \
        fails_with "cannot download file://$up/gone/releases/download/v0.4.1/claude-sync" upgrade_here gone.json
    check "  leaving the installed file as it was" cmp -s "$up/install/claude-sync" "$up/old/claude-sync"
    check "  and no download behind" [ "$(ls -A "$up/install")" = claude-sync ]

    CLAUDE_SYNC_NAME=$n "$up/old/claude-sync" setup --volume "$vol_n" --private >/dev/null
    CLAUDE_SYNC_NAME=$p "$up/old/claude-sync" setup --volume "$vol_p" --gui-port 8484 --sync-port 22100 >/dev/null
    container_p=$(docker container inspect --format '{{.Id}}' "$p")
    id_n=$(docker exec -u "$owner_n" "$n" syncthing device-id)
    check "setup stamps the instance with its version" [ "$(stamp_of "$n")" = 0.4.0 ]
    check "a newer claude-sync says the instance needs its setup" \
        fails_with "last set up by claude-sync 0.4.0; run CLAUDE_SYNC_NAME=$n claude-sync setup" \
        env CLAUDE_SYNC_NAME="$n" "$new" pair not-a-device-id
    check "  and so does unpair" \
        fails_with "last set up by claude-sync 0.4.0; run CLAUDE_SYNC_NAME=$n claude-sync setup" \
        env CLAUDE_SYNC_NAME="$n" "$new" unpair not-a-device-id
    check "setup with no target reapplies to the instance's own" env CLAUDE_SYNC_NAME="$n" "$up/old/claude-sync" setup
    CLAUDE_SYNC_NAME=$hu "$new" setup >/dev/null 2>&1 && status=0 || status=$?
    check "  and where there is none, prints usage" [ "$status" = 2 ]
    check "  and with a name that is not valid, says so" fails_with "CLAUDE_SYNC_NAME must be" \
        env CLAUDE_SYNC_NAME=Not-Valid "$new" setup
    check "  and where docker cannot be reached, says so" fails_with "docker cannot be reached" \
        with_releases missing.json env CLAUDE_SYNC_TEST_DOCKER_DOWN=1 CLAUDE_SYNC_NAME="$n" "$new" setup

    # A failed upgrade goes on to the checks, which say what it left undone.
    out=$(upgrade_here releases.json) || true
    check "upgrade says a newer breaking release is out" grep -qF "claude-sync 0.5.0 is out" <<<"$out"
    check "  with its release notes" grep -qF "file://$up/releases/tag/v0.5.0" <<<"$out"
    check "  and installs the newest that is not breaking" \
        [ "$("$up/install/claude-sync" version)" = "claude-sync 0.4.1" ]
    check "  a new file in place of the old, never rewriting it" cmp -s "$up/held" "$up/old/claude-sync"
    check "  leaving no download behind" [ "$(ls -A "$up/install")" = claude-sync ]
    check "the new version reapplies itself to each instance" [ "$(stamp_of "$n")" = 0.4.1 ]
    check "  and the other" [ "$(stamp_of "$p")" = 0.4.1 ]
    check "  with its ignore list" stignore_installed "$mount_n"
    check "  and its compose file" [ -z "$(docker inspect -f '{{index .Config.Labels "claude-sync-test-old"}}' "$n")" ]
    check "  keeping the device ID" [ "$(docker exec -u "$owner_n" "$n" syncthing device-id)" = "$id_n" ]
    check "  a private instance private" [ "$(network_options "$n" "$owner_n")" = '[false,false,false]' ]
    check "  and the ports given to setup" listens "$p" 8484
    check "  both" [ "$(sync_port "$p" "$owner_p")" = 22100 ]

    docker exec -u "$owner_n" "$n" sh -c 'echo 0.4.0 >/var/syncthing/config/claude-sync-version'
    docker exec -u "$owner_p" "$p" sh -c 'echo 0.4.0 >/var/syncthing/config/claude-sync-version'
    out=$(with_releases releases.json env CLAUDE_SYNC_TEST_REFUSE="$n" "$up/install/claude-sync" upgrade 2>&1) &&
        status=0 || status=$?
    check "upgrade goes on past an instance whose setup fails" [ "$(stamp_of "$p")" = 0.4.1 ]
    check "  then fails" [ "$status" != 0 ]
    check "  naming it" grep -qF "setup failed for instance $n;" <<<"$out"
    check "  which keeps its old stamp" [ "$(stamp_of "$n")" = 0.4.0 ]
    docker exec -u "$owner_p" "$p" sh -c 'echo 0.4.0 >/var/syncthing/config/claude-sync-version'
    out=$(with_releases releases.json env CLAUDE_SYNC_TEST_REFUSE="$n $p" "$up/install/claude-sync" upgrade 2>&1) ||
        true
    check "upgrade names every instance whose setup fails" grep -qF "setup failed for instances $n $p;" <<<"$out"

    docker stop "$p" >/dev/null
    out=$(upgrade_here releases.json) && status=0 || status=$?
    check "upgrade again reapplies an instance an older version set up" [ "$(stamp_of "$n")" = 0.4.1 ]
    check "  succeeding" [ "$status" = 0 ]
    check "  naming it" grep -qF "to instance $n" <<<"$out"
    check "  says it leaves a stopped instance be" grep -qF "$p is stopped" <<<"$out"
    check "  and does" [ "$(docker inspect -f '{{.State.Running}}' "$p")" = false ]
    out=$(upgrade_here releases.json) && status=0 || status=$?
    check "upgrade with nothing to do reapplies nothing" fails grep -qF "to instance" <<<"$out"
    check "  succeeding" [ "$status" = 0 ]
    check "  and says every running instance runs it" \
        grep -qF "Every running instance already runs claude-sync 0.4.1" <<<"$out"
    out=$(env CLAUDE_SYNC_NAME="$n" "$new" pair not-a-device-id 2>&1) || true
    check "  so pair no longer says the instance needs its setup" fails grep -qF "last set up by" <<<"$out"
    check "  getting on to the device ID" grep -qF "not a device ID" <<<"$out"

    # As an instance set up by 0.1.1 or earlier.
    docker exec -u "$owner_n" "$n" rm /var/syncthing/config/claude-sync-version
    check "an instance with no stamp counts as set up by an older claude-sync" \
        fails_with "last set up by an older claude-sync; run CLAUDE_SYNC_NAME=$n claude-sync setup" \
        env CLAUDE_SYNC_NAME="$n" "$new" pair not-a-device-id
    # Where the stamp goes, a directory, which setup cannot write to.
    docker exec -u "$owner_n" "$n" mkdir /var/syncthing/config/claude-sync-version
    check "setup says when it cannot record the version" \
        fails_with "cannot record the version in instance $n" env CLAUDE_SYNC_NAME="$n" "$new" setup
    docker exec -u "$owner_n" "$n" rmdir /var/syncthing/config/claude-sync-version
    out=$(upgrade_here releases.json) && status=0 || status=$?
    check "upgrade reapplies an instance with no stamp" [ "$(stamp_of "$n")" = 0.4.1 ]
    check "  succeeding" [ "$status" = 0 ]
    check "  naming it" grep -qF "to instance $n" <<<"$out"
    docker exec -u "$owner_n" "$n" sh -c 'echo dev >/var/syncthing/config/claude-sync-version'
    check "an instance a checkout set up counts as older too" \
        fails_with "last set up by claude-sync dev; run CLAUDE_SYNC_NAME=$n claude-sync setup" \
        env CLAUDE_SYNC_NAME="$n" "$new" pair not-a-device-id
    out=$(with_releases releases.json env CLAUDE_SYNC_TEST_DOCKER_DOWN=1 "$up/install/claude-sync" upgrade 2>&1) &&
        status=0 || status=$?
    check "upgrade when docker cannot list the instances fails" [ "$status" != 0 ]
    check "  saying so" grep -qF "docker cannot list the instances in containers" <<<"$out"
    check "  and not that there is none" fails grep -qF "no instance is set up" <<<"$out"
    check "  leaving them as they were" [ "$(stamp_of "$n")" = dev ]
    docker stop "$n" >/dev/null
    # Syncthing state that no container uses, labelled as setup labels it.
    docker volume create --label claude-sync=config "$s-config" >/dev/null
    out=$(upgrade_here releases.json) && status=0 || status=$?
    check "  which it does not say with none running" fails grep -qF "Every running instance" <<<"$out"
    check "  succeeding" [ "$status" = 0 ]
    check "upgrade names Syncthing state no container uses" \
        grep -qF "Volume $s-config holds the Syncthing state of instance $s," <<<"$out"

    echo "# uninstall, of a container upgrade recreated"
    check "upgrade recreated P" [ "$(docker container inspect --format '{{.Id}}' "$p")" != "$container_p" ]
    anonymous_p=$(anonymous_mount "$p")
    claude_sync "$p" uninstall >/dev/null
    check "removes the container's anonymous volume" fails docker volume inspect "${anonymous_p:?}"
    anonymous_n=$(anonymous_mount "$n")
    # At /var/syncthing, where cleanup finds it should a check below stop the run.
    docker create --name "$held" --mount "type=volume,src=${anonymous_n:?},dst=/var/syncthing" "$image" >/dev/null
    out=$(claude_sync "$n" uninstall 2>&1) && status=0 || status=$?
    check "fails when another container uses that volume" [ "$status" != 0 ]
    check "  naming it" grep -qF "kept volume $anonymous_n" <<<"$out"
    check "  and how to remove it" grep -qF "docker volume rm $anonymous_n" <<<"$out"
    check "  which stays" docker volume inspect "$anonymous_n"
    check "  and removes the rest of the instance" fails docker volume inspect "$n-config"
    remove_container "$held"

    echo "# a container Compose recreated, to claude-sync and the suite's cleanup"
    # As Compose leaves it: the anonymous volume mounted by name.
    handed=$(docker volume create --label com.docker.volume.anonymous)
    docker create --name "$recreated" --mount "type=volume,src=$handed,dst=/var/syncthing" "$image" >/dev/null
    docker volume create "$vol_named" >/dev/null
    docker create --name "$named" --mount "type=volume,src=$vol_named,dst=/var/syncthing" "$image" >/dev/null
    check "claude-sync finds the anonymous volume of a container Compose recreated" \
        [ "$(calls anonymous_volume "$recreated")" = "$handed" ]
    check "  but not a volume mounted there that is not anonymous" [ -z "$(calls anonymous_volume "$named")" ]
    remove_container "$recreated"
    check "the suite's cleanup removes it" fails docker container inspect "$recreated"
    check "  and its anonymous volume" fails docker volume inspect "$handed"
    remove_container "$named"
    check "  and keeps one mounted there that is not anonymous" docker volume inspect "$vol_named"

    echo "# upgrade, on the host's Syncthing"
    start_host_fixture "$hu"
    docker exec -u 0 "$hu" mkdir -p /opt/releases /home/user/bin
    docker exec -u 0 "$hu" chown user /home/user/bin
    docker cp -q "$up/releases/download" "$hu:/opt/releases/"
    releases_json file:///opt | docker exec -i -u 0 "$hu" sh -c 'cat >/opt/releases/releases.json'
    docker cp -q "$up/old/claude-sync" "$hu:/home/user/bin/"
    docker exec -u 0 "$hu" chown user /home/user/bin/claude-sync
    docker cp -q "$root/stignore" "$hu:/opt/stignore"
    as_user "$hu" mkdir claude
    as_user "$hu" bin/claude-sync setup --path claude --use-host-syncthing >/dev/null
    check "list shows the host's Syncthing" grep -qE "^\* claude-sync +host Syncthing +directory /home/user/claude\$" \
        <<<"$(as_user "$hu" bin/claude-sync list)"
    check "setup stamps the host's Syncthing too" \
        [ "$(as_user "$hu" cat .local/state/syncthing/claude-sync-version)" = 0.4.0 ]
    check "a newer claude-sync says the host's Syncthing needs its setup" \
        fails_with "last set up by claude-sync 0.4.0; run claude-sync setup to apply 0.4.1" \
        as_user "$hu" bash /opt/releases/download/v0.4.1/claude-sync pair not-a-device-id
    check "upgrade there" as_user "$hu" env CLAUDE_SYNC_RELEASES_API=file:///opt/releases/releases.json \
        timeout 300 bin/claude-sync upgrade
    check "  installs the release" [ "$(as_user "$hu" bin/claude-sync version)" = "claude-sync 0.4.1" ]
    check "  and reapplies it to the folder" as_user "$hu" cmp -s claude/.stignore /opt/stignore
    check "  stamping it" [ "$(as_user "$hu" cat .local/state/syncthing/claude-sync-version)" = 0.4.1 ]
    check "setup with no target reapplies there too" as_user "$hu" timeout 300 bin/claude-sync setup
    as_user "$hu" bin/claude-sync uninstall >/dev/null
    check "uninstall removes the stamp" fails as_user "$hu" test -e .local/state/syncthing/claude-sync-version
}
