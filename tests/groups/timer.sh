# shellcheck shell=bash
# group_timer, the names of what it makes, and the helpers only it uses.

readonly u=${prefix}u y=${prefix}y vol_u=${prefix}u-data owner_u=8642:8642
own_instances "$u"
own_containers "$y"
own_volumes "$vol_u"

# The calls the stub systemctl got since the last reset, apart from is-system-running and
# is-enabled, which change nothing.
systemctl_calls() {
    grep -v -e '^--user is-system-running$' -e '^--user is-enabled ' "$SYSTEMCTL_CALLS" 2>/dev/null || true
}

# U, then the host fixture Y: the daily backup's units, with a stub systemctl that logs its
# calls and a config directory of this group's, so no check reaches the real systemd or the
# runner's ~/.config.
group_timer() {
    docker volume create "$vol_u" >/dev/null
    in_target "type=volume,src=$vol_u" "chown $owner_u /t"
    local tm=$scratch/timer
    mkdir -p "$tm/bin" "$tm/other"
    export XDG_CONFIG_HOME=$tm/config SYSTEMCTL_CALLS=$tm/calls PATH=$tm/bin:$PATH
    local units=$XDG_CONFIG_HOME/systemd/user
    local service=$units/$u-backup.service timer=$units/$u-backup.timer
    # SYSTEMCTL_STATE is the user manager's, which is-system-running prints with the status
    # SYSTEMCTL_STATUS; offline fails every call, as a manager that cannot be reached does.
    # SYSTEMCTL_FAIL names one command that fails.
    cat >"$tm/bin/systemctl" <<'EOF'
#!/bin/sh
echo "$*" >>"$SYSTEMCTL_CALLS"
state=${SYSTEMCTL_STATE:-running}
[ "$state" != offline ] || exit 1
if [ "$2" = "${SYSTEMCTL_FAIL:-}" ]; then
    echo "Failed to $2" >&2
    exit 1
fi
if [ "$*" = "--user is-system-running" ]; then
    echo "$state"
    exit "${SYSTEMCTL_STATUS:-0}"
fi
EOF
    chmod +x "$tm/bin/systemctl"
    # A docker that finds setup's probe in the container's synced folder, as for a DIR in it,
    # which no directory here is.
    mkdir "$tm/probe-bin"
    cat >"$tm/probe-bin/docker" <<EOF
#!/bin/sh
if [ "\$1" = exec ] && [ "\$5" = find ]; then
    echo "\$6/\$8"
    exit 0
fi
exec "$(command -v docker)" "\$@"
EOF
    chmod +x "$tm/probe-bin/docker"
    # A DIR holding what systemd reads as escapes, specifiers and variables in a unit, and
    # how the unit quotes it.
    # shellcheck disable=SC2016 # the $ is part of the name
    local odd=$tm/'back ups/a"b\c%h$e' odd_quoted=\"$tm/'back ups/a\"b\\c%%h$$e"'
    local real_bin
    real_bin=$(readlink -f -- "$bin")

    echo "# setup --backup-dir"
    check "--backup-dir with --no-backup is refused" fails_with "only one of --backup-dir or --no-backup" \
        claude_sync "$u" setup --volume "$vol_u" --backup-dir "$tm/backups" --no-backup
    check "  and so is --no-backup with --backup-dir" fails_with "only one of --backup-dir or --no-backup" \
        claude_sync "$u" setup --volume "$vol_u" --no-backup --backup-dir "$tm/backups"
    check "--backup-dir with no value is refused" fails_with "--backup-dir needs a value" \
        claude_sync "$u" setup --volume "$vol_u" --backup-dir
    check "a DIR containing a newline is refused" fails_with "paths containing a newline are not supported" \
        claude_sync "$u" setup --volume "$vol_u" --backup-dir "$tm/a"$'\n'"b"
    check "--backup-dir without systemd's user manager is refused" fails_with "needs systemd's user manager" \
        env SYSTEMCTL_STATE=offline CLAUDE_SYNC_NAME="$u" "$bin" setup --volume "$vol_u" --backup-dir "$tm/backups"
    check "  before setting anything up" fails docker container inspect "$u"
    check "  as with a systemctl that prints a notice in place of a state" \
        fails_with "needs systemd's user manager" env SYSTEMCTL_STATE='"systemd" is not running in this container' \
        CLAUDE_SYNC_NAME="$u" "$bin" setup --volume "$vol_u" --backup-dir "$tm/backups"
    check "  writing no unit" [ ! -e "$units" ]
    # A single file, as fileless runs it: a checkout's claude-sync from no file stops before
    # setup.
    mkdir "$tm/one"
    "$root/packaging/build.sh" 0.0.0-test "$tm/one/claude-sync"
    setup_fileless() {
        CLAUDE_SYNC_NAME=$u fileless "$1" "$tm/one/claude-sync" setup "${@:2}"
    }
    rm -f -- "$SYSTEMCTL_CALLS"
    for how in stdin string procsub; do
        check "setup --backup-dir run from no file ($how) is refused" fails_with "not running from a file" \
            setup_fileless "$how" --volume "$vol_u" --backup-dir "$tm/fileless"
    done
    check "  before setting anything up" fails docker container inspect "$u"
    check "  or making Syncthing state" fails docker volume inspect "$u-config"
    check "  or asking systemd anything" [ ! -e "$SYSTEMCTL_CALLS" ]
    check "  or making DIR" [ ! -e "$tm/fileless" ]
    check "  while the same file run as a file gets past that check" fails_with "needs systemd's user manager" \
        env SYSTEMCTL_STATE=offline CLAUDE_SYNC_NAME="$u" "$tm/one/claude-sync" setup --volume "$vol_u" \
        --backup-dir "$tm/fileless"
    rm -f -- "$SYSTEMCTL_CALLS"
    claude_sync "$u" setup --volume "$vol_u" >/dev/null
    check "setup without --backup-dir writes no unit" [ ! -e "$units" ]
    check "  and calls no systemctl" [ -z "$(systemctl_calls)" ]
    check "in a container, a DIR in the synced folder is refused" fails_with "is in the synced folder" \
        env PATH="$tm/probe-bin:$PATH" CLAUDE_SYNC_NAME="$u" "$bin" setup --backup-dir "$tm/synced"
    check "  writing no unit" [ ! -e "$units" ]
    check "  and not making DIR" [ ! -e "$tm/synced" ]
    docker exec -u "$owner_u" "$u" rm /var/syncthing/config/claude-sync-version
    rm -f -- "$SYSTEMCTL_CALLS"
    check "setup stops when systemd fails to enable the timer" \
        fails_with "systemctl --user enable --now $u-backup.timer failed: Failed to enable" \
        env SYSTEMCTL_FAIL=enable CLAUDE_SYNC_NAME="$u" "$bin" setup --backup-dir "$tm/backups"
    check "  before recording its version" fails stamp_of "$u"
    # The checks below that $units is empty would pass on a directory that is not there.
    check "  after making the unit directory" [ -d "$units" ]
    check "  removing the units it wrote" [ -z "$(ls -A "$units")" ]
    check "  after disabling the timer, which enable may have left enabled" [ "$(systemctl_calls)" = "--user daemon-reload
--user enable --now $u-backup.timer
--user disable $u-backup.timer
--user daemon-reload" ]
    out=$(claude_sync "$u" setup)
    check "  so that setup after it does not say it backs up" fails grep -qF "Backs up to" <<<"$out"
    mkdir "$tm/tmp"
    ln -s "$tm/missing/timer" "$timer"
    check "setup stops when it cannot write the units" fails_with "No such file or directory" \
        env TMPDIR="$tm/tmp" CLAUDE_SYNC_NAME="$u" "$bin" setup --backup-dir "$tm/backups"
    check "  removing those it wrote" [ -z "$(ls -A "$units")" ]
    check "  and its temporary directory" [ -z "$(ls -A "$tm/tmp")" ]
    rm -f -- "$SYSTEMCTL_CALLS"

    out=$(claude_sync "$u" setup --backup-dir "$odd")
    check "setup --backup-dir with no target installs the daily backup" \
        grep -qxF "Environment=CLAUDE_SYNC_NAME=$u" "$service"
    check "  running this claude-sync's backup into DIR, each one quoted word for systemd" \
        grep -qxF "ExecStart=\"$real_bin\" backup $odd_quoted" "$service"
    check "  daily" grep -qxF OnCalendar=daily "$timer"
    check "  catching up a day missed while logged out" grep -qxF Persistent=true "$timer"
    check "  once enabled" grep -qxF WantedBy=timers.target "$timer"
    check "  which it is, after systemd reloads the units" [ "$(systemctl_calls)" = "--user daemon-reload
--user enable --now $u-backup.timer" ]
    check "  making DIR" [ -d "$odd" ]
    check "  and saying where it backs up" grep -qF "Backs up to $odd daily" <<<"$out"

    echo "# setup again"
    local units_before
    units_before=$(cat "$service" "$timer")
    rm -f -- "$SYSTEMCTL_CALLS"
    check "setup --backup-dir stops when systemd fails to enable the timer for a new DIR" \
        fails_with "systemctl --user enable --now $u-backup.timer failed" \
        env SYSTEMCTL_FAIL=enable CLAUDE_SYNC_NAME="$u" "$bin" setup --backup-dir "$tm/elsewhere"
    check "  putting back the units it replaced" [ "$(cat "$service" "$timer")" = "$units_before" ]
    check "  and reloading them" [ "$(systemctl_calls)" = "--user daemon-reload
--user enable --now $u-backup.timer
--user daemon-reload" ]
    rm -f -- "$SYSTEMCTL_CALLS"
    out=$(claude_sync "$u" setup)
    check "setup with no target keeps the daily backup" [ "$(cat "$service" "$timer")" = "$units_before" ]
    check "  calling no systemctl, with nothing to change" [ -z "$(systemctl_calls)" ]
    check "  and reads DIR back, to say where it backs up" grep -qF "Backs up to $odd daily" <<<"$out"
    check "setup run from no file is refused when it keeps a daily backup" fails_with "not running from a file" \
        setup_fileless stdin
    check "  before any work, printing nothing" [ -z "$(setup_fileless stdin 2>/dev/null)" ]
    check "  and keeping its units" [ "$(cat "$service" "$timer")" = "$units_before" ]
    out=$(env SYSTEMCTL_FAIL=is-enabled CLAUDE_SYNC_NAME="$u" "$bin" setup)
    check "  which it does not say of a timer the user disabled" fails grep -qF "Backs up to" <<<"$out"
    claude_sync "$u" setup --volume "$vol_u" >/dev/null
    check "setup with the target keeps it too" [ "$(cat "$service" "$timer")" = "$units_before" ]
    out=$(env PATH="$tm/probe-bin:$PATH" CLAUDE_SYNC_NAME="$u" "$bin" setup 2>&1) && status=0 || status=$?
    check "setup that finds the kept DIR in the synced folder goes on" [ "$status" = 0 ]
    check "  warning that the daily backup fails" grep -qF "the daily backup into $odd fails each day" <<<"$out"
    check "  and keeping it" [ "$(cat "$service" "$timer")" = "$units_before" ]
    copy_under_test "$tm/other"
    check "setup by another claude-sync stops when systemd fails to reload the units" \
        fails_with "systemctl --user daemon-reload failed" \
        env SYSTEMCTL_FAIL=daemon-reload CLAUDE_SYNC_NAME="$u" "$tm/other/claude-sync" setup
    check "  putting back the units it replaced" [ "$(cat "$service" "$timer")" = "$units_before" ]
    rm -f -- "$SYSTEMCTL_CALLS"
    CLAUDE_SYNC_NAME=$u "$tm/other/claude-sync" setup >/dev/null
    check "setup by another claude-sync points the backup at it" \
        grep -qxF "ExecStart=\"$tm/other/claude-sync\" backup $odd_quoted" "$service"
    check "  reloading the units without enabling the timer again" \
        [ "$(systemctl_calls)" = "--user daemon-reload" ]
    check "a degraded user manager runs the backup too" env SYSTEMCTL_STATE=degraded SYSTEMCTL_STATUS=1 \
        CLAUDE_SYNC_NAME="$u" "$bin" setup --backup-dir "$tm/backups"
    check "  moving it to the new DIR" grep -qxF "ExecStart=\"$real_bin\" backup \"$tm/backups\"" "$service"

    echo "# --no-backup and uninstall"
    check "--no-backup without systemd's user manager says so" \
        fails_with "cannot reach systemd's user manager to remove $u-backup.timer" \
        env SYSTEMCTL_STATE=offline CLAUDE_SYNC_NAME="$u" "$bin" setup --no-backup
    check "  keeping the units" ls -- "$service" "$timer"
    rm -f -- "$SYSTEMCTL_CALLS"
    out=$(claude_sync "$u" setup --no-backup)
    check "setup --no-backup removes the daily backup" [ -z "$(ls -A "$units")" ]
    check "  disabling the timer, then reloading" [ "$(systemctl_calls)" = "--user disable --now $u-backup.timer
--user daemon-reload" ]
    check "  saying so" grep -qF "Removed the daily backup to $tm/backups;" <<<"$out"
    rm -f -- "$SYSTEMCTL_CALLS"
    check "  and with none, needs no user manager" \
        env SYSTEMCTL_STATE=offline CLAUDE_SYNC_NAME="$u" "$bin" setup --no-backup
    check "  calling no systemctl" [ -z "$(systemctl_calls)" ]
    claude_sync "$u" setup --backup-dir "$tm/backups" >/dev/null
    claude_sync "$u" backup "$tm/backups" >/dev/null
    check "uninstall without systemd's user manager says so" \
        fails_with "cannot reach systemd's user manager to remove $u-backup.timer" \
        env SYSTEMCTL_STATE=offline CLAUDE_SYNC_NAME="$u" "$bin" uninstall
    check "  removing nothing" docker container inspect "$u"
    mkdir "$tm/kept"
    cp -p -- "$service" "$timer" "$tm/kept/"
    check "uninstall that systemd fails to finish says to run it again" \
        fails_with "run CLAUDE_SYNC_NAME=$u claude-sync uninstall again" \
        env SYSTEMCTL_FAIL=disable CLAUDE_SYNC_NAME="$u" "$bin" uninstall
    check "  keeping the units" ls -- "$service" "$timer"
    rm -f -- "$SYSTEMCTL_CALLS"
    claude_sync "$u" uninstall >/dev/null
    check "uninstall run again, with the container gone, removes the daily backup" [ -z "$(ls -A "$units")" ]
    check "  disabling the timer" grep -qxF -- "--user disable --now $u-backup.timer" <<<"$(systemctl_calls)"
    check "  leaving the archives" [ "$(files_in "$tm/backups")" = 1 ]
    # As left by an instance removed outside claude-sync.
    cp -p -- "$tm/kept/"* "$units/"
    out=$(claude_sync "$u" setup --no-backup)
    check "setup --no-backup removes the daily backup of an instance that is gone" [ -z "$(ls -A "$units")" ]
    check "  saying so" grep -qF "Removed the daily backup to $tm/backups;" <<<"$out"

    echo "# --backup-dir with --use-host-syncthing"
    start_host_fixture "$y"
    docker exec -u 0 "$y" mkdir /opt/claude-sync
    stage=$(mktemp -d -p "$scratch")
    copy_under_test "$stage"
    chmod 755 "$stage"
    docker cp -q "$stage/." "$y:/opt/claude-sync"
    as_user "$y" mkdir stub claude
    docker cp -q "$tm/bin/systemctl" "$y:/home/user/stub/"
    # In the fixture's own ~/.config, with no XDG_CONFIG_HOME.
    y_sync() {
        # shellcheck disable=SC2016 # expanded by the fixture's shell
        as_user "$y" sh -c 'PATH=/home/user/stub:$PATH SYSTEMCTL_CALLS=/home/user/calls exec "$@"' sh \
            timeout 300 /opt/claude-sync/claude-sync "$@"
    }
    check "a DIR in the synced folder is refused" fails_with "is in the synced folder" \
        y_sync setup --path claude --use-host-syncthing --backup-dir claude/backups
    check "  writing no unit" fails as_user "$y" test -e .config/systemd/user/claude-sync-backup.service
    local folders
    folders=$(as_user "$y" syncthing cli config folders list)
    check "  or adding the folder" fails grep -qx claude-sync <<<"$folders"
    # A relative XDG_CONFIG_HOME, which user_unit_dir ignores.
    # shellcheck disable=SC2016 # expanded by the fixture's shell
    as_user "$y" XDG_CONFIG_HOME=config sh -c 'PATH=/home/user/stub:$PATH SYSTEMCTL_CALLS=/home/user/calls exec "$@"' \
        sh timeout 300 /opt/claude-sync/claude-sync setup --path claude --use-host-syncthing --backup-dir backups >/dev/null
    check "setup --use-host-syncthing --backup-dir installs the daily backup in ~/.config, DIR made absolute" \
        as_user "$y" grep -qxF 'ExecStart="/opt/claude-sync/claude-sync" backup "/home/user/backups"' \
        .config/systemd/user/claude-sync-backup.service
    check "  for the default instance" as_user "$y" grep -qxF Environment=CLAUDE_SYNC_NAME=claude-sync \
        .config/systemd/user/claude-sync-backup.service
    check "  enabling it" as_user "$y" grep -qxF -- "--user enable --now claude-sync-backup.timer" calls
    local y_units=.config/systemd/user/claude-sync-backup
    units_before=$(as_user "$y" cat "$y_units.service" "$y_units.timer")
    y_sync setup >/dev/null
    check "setup there keeps it" [ "$(as_user "$y" cat "$y_units.service" "$y_units.timer")" = "$units_before" ]
    # Another instance selected, as upgrade finds it when it sets up each instance by name.
    as_user "$y" mkdir -p .config/claude-sync
    as_user "$y" sh -c 'echo other >.config/claude-sync/instance'
    # shellcheck disable=SC2016 # expanded by the fixture's shell
    as_user "$y" CLAUDE_SYNC_NAME=claude-sync sh -c 'PATH=/home/user/stub:$PATH SYSTEMCTL_CALLS=/home/user/calls exec "$@"' \
        sh timeout 300 /opt/claude-sync/claude-sync setup >/dev/null
    check "  as it does with another instance selected" \
        [ "$(as_user "$y" cat "$y_units.service" "$y_units.timer")" = "$units_before" ]
    as_user "$y" rm .config/claude-sync/instance
    y_sync setup --no-backup >/dev/null
    check "setup --no-backup there removes it" [ -z "$(as_user "$y" ls -A .config/systemd/user)" ]
    # shellcheck disable=SC2088 # the ~ is for setup to expand
    y_sync setup --backup-dir '~/backups' >/dev/null
    check "setup --backup-dir expands a leading ~" as_user "$y" grep -qxF \
        'ExecStart="/opt/claude-sync/claude-sync" backup "/home/user/backups"' "$y_units.service"
    y_sync uninstall >/dev/null
    check "uninstall there removes it" fails as_user "$y" test -e "$y_units.timer"
}
