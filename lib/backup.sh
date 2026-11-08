# shellcheck shell=bash
# Archives: backup, pruning and restore.

backup() {
    local dir="" weekly=4 monthly=6
    while (($#)); do
        case $1 in
            --keep-weekly | --keep-monthly)
                (($# >= 2)) || die "$1 needs a value"
                [[ $2 =~ ^[0-9]{1,4}$ ]] || die "$1 takes a number of archives, from 0 to 9999: $2"
                if [[ $1 == --keep-weekly ]]; then weekly=$((10#$2)); else monthly=$((10#$2)); fi
                shift 2
                ;;
            -*) die "unknown argument: $1" ;;
            *)
                [[ -z $dir ]] || die "unknown argument: $1"
                dir=$1
                shift
                ;;
        esac
    done
    if [[ -z $dir ]]; then
        usage_error
    fi
    # A quoted ~: left as it is, mkdir would make ./~ here and write the archive into it.
    dir=$(expand_home "$dir")
    check_instance
    detect_mode
    # Each archive would sync to every device and hold the ones before it. Checked before
    # mkdir, whose directory would sync too.
    check_outside_synced_folder "$dir"
    mkdir -p -- "$dir"
    local archive tmp
    # remove_stopped_backups and prune match this name's format again, and stop finding the
    # archives if it changes here alone.
    archive=$dir/$name-$(date -u +%Y%m%dT%H%M%SZ).tar.gz
    [[ ! -e $archive ]] || die "$archive already exists; rerun in a second"
    # Written under another name until whole, so no half-written archive passes for one.
    # Redirection, unlike mktemp, gives it the umask's mode: archives are ordinary files,
    # meant to be copied to other devices.
    tmp=$dir/.${archive##*/}.$$
    # shellcheck disable=SC2064 # expanded now: tmp is local
    trap "rm -f -- $(printf %q "$tmp")" EXIT
    write_archive "$tmp"
    mv -- "$tmp" "$archive"
    trap - EXIT
    echo "Backed up to $archive."
    remove_stopped_backups "$dir"
    prune "$dir" "$archive" "$weekly" "$monthly"
}

# Writes a gzip tar of the synced folder to FILE, or dies.
write_archive() {
    local errors status=0
    # FILE is opened under noclobber: its name can be guessed, so in a DIR that others can
    # write, a file planted at it, or a symlink to one, stops the backup instead of being
    # overwritten.
    if [[ $mode == host ]]; then
        # In English, which only_files_that_changed reads.
        errors=$(set -C; LC_ALL=C tar -C "$folder_path" -czf - . 2>&1 >"$1") || status=$?
    else
        errors=$(set -C; docker exec -u "$owner" "$name" tar -C "$folder_path" -czf - . 2>&1 >"$1") || status=$?
    fi
    [[ -z $errors ]] || printf '%s\n' "$errors" >&2
    if ((status == 1)) && only_files_that_changed "$errors"; then
        status=0
    fi
    ((status == 0)) || die "tar could not archive the synced folder; its message is above"
}

# Dies if DIR, or the directory mkdir -p would make of it, is the synced folder or in it.
check_outside_synced_folder() {
    if [[ $mode == host ]]; then
        path_within "$(planned_path "$1")" "$(real_path "$folder_path")" || return 0
    else
        # The container's folder is a volume or a path on the Docker host, which may not be
        # this machine, so no path here compares with it. A file made in DIR's nearest
        # existing directory is looked for from inside the container instead.
        local probe out errors status=0
        probe=$(nearest_dir "$1")/.$name-probe.$$
        # Made under noclobber, as write_archive makes the archive.
        if ! (set -C; : >"$probe") 2>/dev/null; then
            # Not writable: then backup cannot make DIR or write in it either, and fails there.
            [[ -e $probe || -L $probe ]] || return 0
            die "$probe is in the way; remove it and rerun"
        fi
        # In a subshell, so this EXIT trap leaves the caller's in place.
        out=$(
            # shellcheck disable=SC2064 # expanded now: probe is local
            trap "rm -f -- $(printf %q "$probe")" EXIT
            docker exec -u "$owner" "$name" find "$folder_path" -name "${probe##*/}" 2>&1
        ) || status=$?
        # The paths find matched start with a slash; every other line is a message.
        errors=$(grep -v '^/' <<<"$out") || true
        [[ -z $errors ]] || printf '%s\n' "$errors" >&2
        if ((status == 1)) && only_paths_that_went "$errors"; then
            status=0
        fi
        ((status == 0)) || die "could not search the synced folder for $1; find's message is above"
        grep -q '^/' <<<"$out" || return 0
    fi
    die "$1 is in the synced folder; give backup a directory outside it"
}

# Removes the temporary files that this instance's backups into DIR left there when stopped
# before their EXIT trap ran, by SIGKILL or a power cut. One untouched for a day is no longer
# being written.
remove_stopped_backups() {
    local stopped
    while IFS= read -r stopped; do
        rm -f -- "$stopped"
        echo "Removed $stopped."
    done < <(find "$1" -maxdepth 1 -type f -mmin +1440 \
        -name ".$name-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z.tar.gz.*")
}

# Whether each line tar printed, given as ERRORS, says only that a file changed or went while
# tar read the folder, as Claude Code's and Syncthing's temporary files do. tar exits 1 then
# and still archives the rest of the folder whole. GNU tar says "file changed as we read it"
# or "File removed before we read it"; BusyBox names the file with "No such file or
# directory", then adds "error exit delayed from previous errors". Any other line fails the
# backup, among them GNU's "File shrank", for a file it pads with zeros, and BusyBox's "short
# read", for an archive it cuts short.
only_files_that_changed() {
    ! grep -qvE \
        -e '^tar: \.(/.*)?: (file changed as we read it|File removed before we read it)$' \
        -e "^tar: (\./.*|can't open '\./.*'): No such file or directory\$" \
        -e '^tar: error exit delayed from previous errors$' <<<"$1"
}

# Whether each line find printed, given as ERRORS, says only that a path under the folder
# went while find walked it. BusyBox's find exits 1 for a file that goes between listing its
# directory and reading it, the race that only_files_that_changed passes for tar.
only_paths_that_went() {
    ! grep -qvE "^find: $folder_path/.*: No such file or directory\$" <<<"$1"
}

# Removes this instance's archives in DIR that neither rule keeps: the newest archive of each
# of the last WEEKLY weeks that have one, and the same for the last MONTHLY months. Counting
# only weeks and months with archives means archives never all age out while backups stop.
# The time comes from each name, which copying keeps, unlike the mtime. KEEP, the archive
# just written, always stays.
prune() {
    local dir=$1 keep=$2 weekly=$3 monthly=$4 files i f kept week month
    local last_week="" last_month="" weeks=0 months=0
    local re="^$name-([0-9]{4})([0-9]{2})([0-9]{2})T[0-9]{6}Z\.tar\.gz\$"
    files=("$dir/$name"-*.tar.gz)
    # Newest first: the names sort by time.
    for ((i = ${#files[@]} - 1; i >= 0; i--)); do
        f=${files[i]}
        [[ ${f##*/} =~ $re ]] || continue
        week=$(week_number "${BASH_REMATCH[@]:1}")
        month=${BASH_REMATCH[1]}${BASH_REMATCH[2]}
        kept=""
        [[ $f != "$keep" ]] || kept=1
        if [[ $week != "$last_week" ]]; then
            last_week=$week
            if ((++weeks <= weekly)); then kept=1; fi
        fi
        if [[ $month != "$last_month" ]]; then
            last_month=$month
            if ((++months <= monthly)); then kept=1; fi
        fi
        if [[ -z $kept ]]; then
            rm -- "$f"
            echo "Removed $f."
        fi
    done
}

# The week of the date YYYY MM DD, counted in weeks from Monday to Sunday since 1970: days
# since 1970-01-01, a Thursday, by Howard Hinnant's days_from_civil, in bash alone since
# `date -d` differs between systems.
week_number() {
    local y=$((10#$1)) m=$((10#$2)) d=$((10#$3)) era yoe doy doe
    y=$((y - (m <= 2)))
    era=$((y / 400))
    yoe=$((y - era * 400))
    doy=$(((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1))
    doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
    echo $(((era * 146097 + doe - 719468 + 3) / 7))
}

restore() {
    local archive="" kind="" target=""
    while (($#)); do
        case $1 in
            --volume | --path)
                [[ -z $kind ]] || die "give only one of --volume or --path"
                [[ -n ${2:-} ]] || die "$1 needs a value"
                kind=${1#--} target=$2
                shift 2
                ;;
            -*) die "unknown argument: $1" ;;
            *)
                [[ -z $archive ]] || die "unknown argument: $1"
                archive=$1
                shift
                ;;
        esac
    done
    if [[ -z $archive || -z $kind ]]; then
        usage_error
    fi
    # A quoted ~, as backup takes one: left as it is, --path would make ./~ here and restore
    # into it.
    archive=$(expand_home "$archive")
    [[ $kind == volume ]] || target=$(expand_home "$target")
    [[ -f $archive ]] || die "no file $archive"
    # A volume is written in a container, as the volume's owner; a directory here, with this
    # machine's tar, as the user running claude-sync.
    local untar dest own=()
    if [[ $kind == volume ]]; then
        command -v docker >/dev/null || die "Docker is required"
        check_volume "$target"
        local image owner mount="type=volume,src=$target,dst=/target"
        image=$(compose_image)
        owner=$(read_owner "$image" "$mount" "$target")
        untar=(docker run --rm -i --user "$owner" --mount "$mount" --entrypoint tar "$image")
        dest=/target
    else
        untar=(tar)
        dest=$target
        # tar run by root keeps the archive's owners unless told not to.
        own=(--no-same-owner)
    fi
    # Read through first, so a damaged archive writes nothing, not even --path's DIR.
    "${untar[@]}" -tzf - <"$archive" >/dev/null || die "cannot read $archive as a backup; nothing was restored"
    [[ $kind == volume ]] || mkdir -p -- "$target"
    "${untar[@]}" -xzf - -C "$dest" "${own[@]}" <"$archive" ||
        die "could not restore all of $archive to $target; tar's message is above"
    echo "Restored $archive to $target."
}
