# shellcheck shell=bash
# The daily backup's systemd user units.

# Whether this user has a systemd user manager to run the daily backup. Read from the state
# it prints, as its exit status is not 0 for a degraded manager, one with a failed unit, and
# some containers have a systemctl that only prints a notice.
user_systemd() {
    case $(systemctl --user is-system-running 2>/dev/null) in
        running | degraded | starting | initializing | maintenance) ;;
        *) return 1 ;;
    esac
}

# systemctl --user ARGS, silent unless it fails.
user_systemctl() {
    local out
    out=$(systemctl --user "$@" 2>&1) || die "systemctl --user $* failed: $out"
}

# Where systemctl, run with this environment, looks for this user's units. A relative
# XDG_CONFIG_HOME is ignored, as the XDG spec says.
user_unit_dir() {
    if [[ ${XDG_CONFIG_HOME:-} == /* ]]; then
        echo "$XDG_CONFIG_HOME/systemd/user"
    else
        echo "${HOME:?}/.config/systemd/user"
    fi
}

# VALUE as one double-quoted word of a unit's command line, where systemd reads \ and " as
# escapes, and % and $ as specifiers and variables.
unit_quote() {
    local s=${1//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//%/%%}
    s=${s//\$/\$\$}
    printf '"%s"\n' "$s"
}

# The value that unit_quote quoted, given without its quotes. A newline stands in for \ on
# the way, which works as setup refuses a DIR with one.
unit_unquote() {
    local s=${1//\\\\/$'\n'}
    s=${s//\\\"/\"}
    s=${s//$'\n'/\\}
    s=${s//%%/%}
    printf '%s\n' "${s//\$\$/\$}"
}

# This instance's daily backup units, as their path without .service or .timer.
backup_unit() {
    echo "$(user_unit_dir)/$name-backup"
}

# The DIR this instance's daily backup writes to. Its service unit is the only record of it:
# the daily backup is set up while that file exists. Fails when there is none.
scheduled_backup_dir() {
    local line
    line=$(grep -m 1 '^ExecStart=' "$(backup_unit).service" 2>/dev/null) || return 1
    # The first `" backup "` ends the quoted claude-sync: every " inside a quoted value has a
    # \ before it.
    line=${line#*\" backup \"}
    unit_unquote "${line%\"}"
}

# Applies setup's BACKUP to this instance's daily backup: a DIR installs it there, off
# removes it, and empty keeps it, rewritten for this claude-sync. Runs before write_stamp: a
# failure leaves the instance stale, so upgrade sets it up again.
schedule_backup() {
    local dir=$1 asked="" path unit bin header service timer saved="" ext was_enabled=""
    [[ -z $1 ]] || asked=1
    case $dir in
        off)
            unschedule_backup
            return
            ;;
        '')
            dir=$(scheduled_backup_dir) || return 0
            # Only a warning, as upgrade runs this for every instance. A target set up again
            # since DIR was given can hold it.
            (check_outside_synced_folder "$dir") ||
                printf 'claude-sync: the daily backup into %s fails each day until what is above is fixed, or %s --backup-dir gives it another DIR\n' \
                    "$dir" "$(setup_command "$name")" >&2
            ;;
        *)
            # Checked now, or each daily run would fail where nobody looks.
            check_outside_synced_folder "$dir"
            mkdir -p -- "$dir"
            ;;
    esac
    path=$(backup_unit)
    unit=${path##*/}
    check_running_from_file
    bin=$(installed_file)
    # Not setup_command, which changes with the selection: the units would change with it,
    # and setup reloads units that changed.
    header="# Written by claude-sync setup, which replaces it; CLAUDE_SYNC_NAME=$name claude-sync setup --no-backup removes it."
    service="$header
[Unit]
Description=claude-sync backup of instance $name

[Service]
Type=oneshot
Environment=CLAUDE_SYNC_NAME=$name
ExecStart=$(unit_quote "$bin") backup $(unit_quote "$dir")"
    timer="$header
[Unit]
Description=Daily claude-sync backup of instance $name

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target"
    if [[ $(cat -- "$path.service" 2>/dev/null) != "$service" ||
        $(cat -- "$path.timer" 2>/dev/null) != "$timer" ]]; then
        # Checked before writing: with the files written and not reloaded, the next setup
        # would find nothing changed and not reload them either.
        user_systemd ||
            die "cannot reach systemd's user manager to update $unit.timer; run $(setup_command "$name") again in a login session as $(id -un)"
        mkdir -p -- "${path%/*}"
        # The units this replaces, put back when writing them or systemd fails below: units it
        # never loaded or enabled would pass for installed, and the next setup would find
        # nothing to change. Not on SIGINT or SIGTERM, which would need a trap beside setup's
        # EXIT trap: one between the write and the reload leaves systemd on the old units
        # until it next reloads.
        saved=$(mktemp -d -t claude-sync.XXXXXX)
        for ext in service timer; do
            [[ ! -e $path.$ext ]] || cp -p -- "$path.$ext" "$saved/" || {
                rm -rf -- "$saved"
                exit 1
            }
        done
    fi
    if [[ -n $asked && -e $path.timer ]] && systemctl --user is-enabled --quiet "$unit.timer" 2>/dev/null; then
        was_enabled=1
    fi
    if ! (
        # set -e is off in an if's condition, so each failure exits by hand.
        [[ -z $saved ]] || {
            printf '%s\n' "$service" >"$path.service" &&
                printf '%s\n' "$timer" >"$path.timer" &&
                user_systemctl daemon-reload
        } || exit 1
        # Only when asked: a timer the user disabled stays so through setup and upgrade.
        [[ -z $asked ]] || user_systemctl enable --now "$unit.timer"
    ); then
        # enable --now enables the timer before starting it, so a failed start leaves it
        # enabled. Before the put-back, while the units it enabled are on disk.
        if [[ -n $asked && -z $was_enabled ]]; then
            systemctl --user disable "$unit.timer" >/dev/null 2>&1 || true
        fi
        if [[ -n $saved ]]; then
            for ext in service timer; do
                if [[ -e $saved/$unit.$ext ]]; then
                    mv -- "$saved/$unit.$ext" "$path.$ext"
                else
                    rm -f -- "$path.$ext"
                fi
            done
            rm -rf -- "$saved"
            # Best effort, as the failure is reported above: systemd may hold the units this
            # run wrote.
            systemctl --user daemon-reload >/dev/null 2>&1 || true
        fi
        exit 1
    fi
    [[ -z $saved ]] || rm -rf -- "$saved"
    # Said only of an enabled timer: one the user disabled does not back up.
    [[ -n $asked ]] || systemctl --user is-enabled --quiet "$unit.timer" 2>/dev/null || return 0
    printf 'Backs up to %s daily; systemctl --user start %s backs up now, and journalctl --user -u %s shows how each backup went.\n' \
        "$dir" "$unit" "$unit"
}

# Whether this instance has a daily backup, even one left half removed.
has_scheduled_backup() {
    local path
    path=$(backup_unit)
    [[ -e $path.service || -e $path.timer ]]
}

# Dies when this instance has a daily backup and systemd's user manager, which removes it,
# cannot be reached. Called before anything else changes, so that the command does not stop
# halfway.
check_unschedule() {
    has_scheduled_backup || return 0
    user_systemd ||
        die "cannot reach systemd's user manager to remove $name-backup.timer; run this again in a login session as $(id -un)"
}

# Removes this instance's daily backup, if it has one. Its archives stay.
unschedule_backup() {
    local path unit dir
    has_scheduled_backup || return 0
    check_unschedule
    path=$(backup_unit)
    unit=${path##*/}
    dir=$(scheduled_backup_dir) || dir=""
    [[ ! -e $path.timer ]] || user_systemctl disable --now "$unit.timer"
    rm -f -- "$path.service" "$path.timer"
    user_systemctl daemon-reload
    echo "Removed the daily backup${dir:+ to $dir}; its archives stay."
}
