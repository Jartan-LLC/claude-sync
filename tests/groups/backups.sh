# shellcheck shell=bash
# group_backups, the names of what it makes, and the helpers only it uses.

readonly q=${prefix}q t=${prefix}t
readonly vol_q=${prefix}q-data vol_t=${prefix}t-data vol_r=${prefix}r-data vol_q_missing=${prefix}q-missing
readonly owner_q=4680:4680 owner_t=5791:5791 owner_r=3579:3579
readonly mount_q=type=volume,src=$vol_q mount_t=type=volume,src=$vol_t mount_r=type=volume,src=$vol_r
own_instances "$q" "$t"
own_volumes "$vol_q" "$vol_t" "$vol_r" "$vol_q_missing"
long=projects/-work-$(printf '%060d' 0 | tr 0 x)/memory/a-note-whose-path-is-longer-than-a-tar-header.md
readonly long

# A directory tree as a restore must give it back: each entry's type, mode and path, and each
# file's mtime and contents. Not owners, which come from the target. The same commands run
# on a volume, in the image, and on a directory here.
# shellcheck disable=SC2016 # expanded by sh
readonly tree='cd "$1" && find . -exec stat -c "%A %n" {} + | LC_ALL=C sort &&
    find . -type f -exec stat -c "%Y %n" {} + | LC_ALL=C sort &&
    find . -type f -exec sha256sum {} + | LC_ALL=C sort'

volume_tree() {
    docker run --rm --entrypoint sh --mount "$1,dst=/t" "$image" -c "$tree" sh /t
}

dir_tree() {
    sh -c "$tree" sh "$1"
}

# grep reads all of the listing: -q would stop at the match, and tar, still listing, would
# die of SIGPIPE and fail the pipeline.
in_archive() {
    tar -tzf "$1" | grep -xF -- "$2" >/dev/null
}

# The NAMES still in DIR.
left_of() {
    local dir=$1 name
    shift
    for name; do
        [[ ! -e $dir/$name ]] || echo "$name"
    done
}

# Q: backup and restore of a folder with every kind of file, then restore on Q once it is
# paired with T.
group_backups() {
    docker volume create "$vol_q" >/dev/null
    docker volume create "$vol_r" >/dev/null
    docker volume create "$vol_t" >/dev/null
    # Q's fixture adds what an archive must carry as it is: a login only its owner reads, a
    # symlink, a path too long for tar's basic header, and a file in the trash can.
    in_target "$mount_q" "$fixture && chmod 600 .credentials.json && ln -s settings.json link.json &&
    mkdir -p .stversions \"\$(dirname '$long')\" && echo old >.stversions/settings.json && echo long >'$long' &&
    chown -R $owner_q /t"
    in_target "$mount_r" "chown $owner_r /t"
    # Restored modes are the archive's less the umask, as with any tar.
    umask 022
    echo "# backup"
    check "backup before setup is refused" fails_with "run setup first" \
        claude_sync "$q" backup "$scratch/backups"
    claude_sync "$q" setup --volume "$vol_q" --private >/dev/null
    wait_for owned_by "$mount_q" .stfolder "$owner_q"
    original=$(volume_tree "$mount_q")
    # Another umask than the group's, so a mode set by claude-sync cannot match it by chance.
    out=$(umask 027 && claude_sync "$q" backup "$scratch/backups")
    archive=$(find "$scratch/backups" -name '*.tar.gz')
    check "backup writes an archive named after the instance and the time" \
        grep -qxE "$q-[0-9]{8}T[0-9]{6}Z\.tar\.gz" <<<"${archive##*/}"
    check "  and says where" grep -qF "$archive" <<<"$out"
    check "  and nothing else" [ "$(files_in "$scratch/backups")" = 1 ]
    check "  with the umask's default mode" [ "$(stat -c %a "$archive")" = 640 ]
    check "the archive holds the login" in_archive "$archive" ./.credentials.json
    check "  and the trash can" in_archive "$archive" ./.stversions/settings.json
    check "backup leaves the folder as it was" [ "$(volume_tree "$mount_q")" = "$original" ]
    # The folder is a volume, which no directory here is in: this docker runs the search for
    # backup's probe in a directory here instead of the folder, then, with FIND_SAYS set,
    # prints it and exits 1, as BusyBox's find when files went as it searched.
    mkdir -p "$scratch/probe-bin" "$scratch/folder/sub"
    cat >"$scratch/probe-bin/docker" <<EOF
#!/bin/sh
if [ "\$1" = exec ] && [ "\$5" = find ]; then
    shift 6
    find "$scratch/folder" "\$@" || exit
    [ -z "\$FIND_SAYS" ] || { printf '%s\n' "\$FIND_SAYS" >&2; exit 1; }
    exit 0
fi
exec "$(command -v docker)" "\$@"
EOF
    chmod +x "$scratch/probe-bin/docker"
    # shellcheck disable=SC2329 # called below; ShellCheck cannot follow run_group
    backup_in_folder() {
        env PATH="$scratch/probe-bin:$PATH" CLAUDE_SYNC_NAME="$q" "$bin" backup "$@"
    }
    check "a container backup into its synced folder is refused" fails_with "is in the synced folder" \
        backup_in_folder "$scratch/folder/sub"
    check "  and into a directory in it not made yet" fails_with "is in the synced folder" \
        backup_in_folder "$scratch/folder/sub/backups"
    check "  without making it" [ ! -e "$scratch/folder/sub/backups" ]
    check "  or leaving its probe there" [ "$(files_in "$scratch/folder/sub")" = 0 ]
    check "a container backup passes find's status 1 for files that went as it searched" \
        env FIND_SAYS="find: /var/syncthing/claude/jobs/gone: No such file or directory" \
        PATH="$scratch/probe-bin:$PATH" CLAUDE_SYNC_NAME="$q" "$bin" backup "$scratch/searched"
    check "  but not for another error" fails_with "could not search the synced folder" \
        env FIND_SAYS="find: /var/syncthing/claude/jobs: Permission denied" \
        PATH="$scratch/probe-bin:$PATH" CLAUDE_SYNC_NAME="$q" "$bin" backup "$scratch/unsearched"
    # Files that come and go as backup reads the folder, as temporary files do. Beside large
    # files, so tar reads for long enough that files it listed go before it opens them. In a
    # directory Syncthing ignores.
    churn=/var/syncthing/claude/jobs/churn/tmp
    docker exec -u "$owner_q" "$q" sh -c "mkdir -p $churn && touch /tmp/churning &&
        for i in 1 2 3 4 5; do head -c 5000000 /dev/urandom >$churn/big\$i; done"
    docker exec -u "$owner_q" "$q" sh -c "i=0; while [ -e /tmp/churning ]; do
        i=\$((i + 1)); echo x >$churn/t\$i; rm -f $churn/t\$((i - 20)); done" &
    churning=$!
    wait_for docker exec "$q" sh -c "ls $churn | grep -q '^t[0-9]\{3\}'"
    if claude_sync "$q" backup "$scratch/busy" >/dev/null 2>"$scratch/busy.err"; then busy=ok; else busy=failed; fi
    docker exec -u "$owner_q" "$q" rm /tmp/churning
    wait "$churning" || true
    check "backup takes files that go as tar reads the folder" [ "$busy" = ok ]
    check "  after tar found some gone" grep -qF "No such file or directory" "$scratch/busy.err"
    check "  in a whole archive" in_archive "$(find "$scratch/busy" -name '*.tar.gz')" ./jobs/churn/tmp/big5
    in_target "$mount_q" "echo locked >/t/jobs/churn/tmp/locked && chmod 000 /t/jobs/churn/tmp/locked"
    check "a file the folder's owner cannot read fails backup" fails_with "tar could not archive" \
        claude_sync "$q" backup "$scratch/unreadable"
    check "  leaving no partial archive" [ "$(files_in "$scratch/unreadable")" = 0 ]
    in_target "$mount_q" "rm -r /t/jobs/churn"

    echo "# restore"
    # Run as T, which is not set up yet: restore needs no instance.
    check "restore into a fresh volume" claude_sync "$t" restore "$archive" --volume "$vol_r"
    check "  gives back the folder as it was" [ "$(volume_tree "$mount_r")" = "$original" ]
    check "  owned by the volume's owner" owned_by "$mount_r" settings.json "$owner_r"
    check "restore into a fresh directory" claude_sync "$t" restore "$archive" --path "$scratch/restored"
    check "  gives back the folder as it was" [ "$(dir_tree "$scratch/restored")" = "$original" ]
    check "a missing archive is refused" fails_with "no file $scratch/none.tar.gz" \
        claude_sync "$t" restore "$scratch/none.tar.gz" --path "$scratch/restored"
    head -c "$(($(stat -c %s "$archive") / 2))" "$archive" >"$scratch/truncated.tar.gz"
    mkdir "$scratch/untouched"
    check "a truncated archive is refused" fails_with "cannot read $scratch/truncated.tar.gz" \
        claude_sync "$t" restore "$scratch/truncated.tar.gz" --path "$scratch/untouched"
    check "  before writing anything" [ "$(files_in "$scratch/untouched")" = 0 ]
    check "a missing volume is refused" fails_with "no Docker volume named $vol_q_missing" \
        claude_sync "$t" restore "$archive" --volume "$vol_q_missing"
    check "  and is not created" fails docker volume inspect "$vol_q_missing"
    check "a root-owned volume is refused" fails_with "owned by root" \
        claude_sync "$t" restore "$archive" --volume "$vol_t"
    check "a restore with no target prints the usage" misused "Usage:" claude_sync "$t" restore "$archive"
    check "a restore given both a volume and a directory is refused" misused "give only one of" \
        claude_sync "$t" restore "$archive" --volume "$vol_r" --path "$scratch/restored"
    check "a target with no value is refused" misused "--path needs a value" \
        claude_sync "$t" restore "$archive" --path
    check "  and so is an empty one" misused "--path needs a value" \
        claude_sync "$t" restore "$archive" --path ""
    check "  or an empty volume" misused "--volume needs a value" \
        claude_sync "$t" restore "$archive" --volume ""
    check "an unknown flag is refused" misused "unknown argument: --into" \
        claude_sync "$t" restore "$archive" --into "$scratch/restored"

    echo "# backup retention"
    # Empty stand-ins, as backup reads only the names. In 2025, before any run of this test.
    # The 9th of March is a Sunday, the 10th a Monday.
    old=("$q-20250115T120000Z.tar.gz" "$q-20250228T120000Z.tar.gz" "$q-20250309T235959Z.tar.gz"
        "$q-20250310T000000Z.tar.gz" "$q-20250312T120000Z.tar.gz")
    # Another instance's, one whose name starts with this one's, and files of other shapes.
    others=("$t-20250101T000000Z.tar.gz" "$q-work-20250101T000000Z.tar.gz" "$q-20250101.tar.gz" notes.txt)
    mkdir "$scratch/keep-3-3"
    (cd "$scratch/keep-3-3" && touch -- "${old[@]}" "${others[@]}")
    out=$(claude_sync "$q" backup "$scratch/keep-3-3" --keep-weekly 3 --keep-monthly 3)
    check "--keep-weekly 3 --keep-monthly 3 keeps the newest archive of the last 3 weeks and months" \
        [ "$(left_of "$scratch/keep-3-3" "${old[@]}")" = "$(printf '%s\n' "${old[1]}" "${old[2]}" "${old[4]}")" ]
    check "  beside the new one" [ "$(files_in "$scratch/keep-3-3")" = 8 ]
    check "  and says which it removed" grep -qF "$scratch/keep-3-3/${old[3]}" <<<"$out"
    check "  leaving other files alone" [ "$(left_of "$scratch/keep-3-3" "${others[@]}")" = "$(printf '%s\n' "${others[@]}")" ]
    old=("$q-20250115T120000Z.tar.gz" "$q-20250215T120000Z.tar.gz" "$q-20250315T120000Z.tar.gz"
        "$q-20250415T120000Z.tar.gz" "$q-20250515T120000Z.tar.gz" "$q-20250615T120000Z.tar.gz"
        "$q-20250702T120000Z.tar.gz" "$q-20250709T120000Z.tar.gz" "$q-20250716T120000Z.tar.gz"
        "$q-20250723T120000Z.tar.gz")
    mkdir "$scratch/keep-default"
    (cd "$scratch/keep-default" && touch -- "${old[@]}")
    claude_sync "$q" backup "$scratch/keep-default" >/dev/null
    check "by default it keeps 4 weeks and 6 months" \
        [ "$(left_of "$scratch/keep-default" "${old[@]}")" = "$(printf '%s\n' "${old[@]:2:4}" "${old[@]:7}")" ]
    mkdir "$scratch/keep-0-0"
    touch "$scratch/keep-0-0/${old[9]}"
    claude_sync "$q" backup "$scratch/keep-0-0" --keep-weekly 0 --keep-monthly 0 >/dev/null
    check "--keep-weekly 0 --keep-monthly 0 removes every older archive" [ ! -e "$scratch/keep-0-0/${old[9]}" ]
    check "  and keeps the new one" [ "$(files_in "$scratch/keep-0-0")" = 1 ]
    check "a count that is not a number is refused" misused "--keep-weekly takes" \
        claude_sync "$q" backup "$scratch/keep-0-0" --keep-weekly x
    check "  and so is one over 9999" misused "--keep-monthly takes" \
        claude_sync "$q" backup "$scratch/keep-0-0" --keep-monthly 10000
    check "  and one below 0" misused "--keep-weekly takes" \
        claude_sync "$q" backup "$scratch/keep-0-0" --keep-weekly -1
    check "a count of 9999 is taken" claude_sync "$q" backup "$scratch/keep-9999" --keep-weekly 9999
    check "a count with no value is refused" misused "--keep-monthly needs a value" \
        claude_sync "$q" backup "$scratch/keep-0-0" --keep-monthly
    check "an unknown flag is refused" misused "unknown argument: --keep-daily" \
        claude_sync "$q" backup "$scratch/keep-0-0" --keep-daily 3
    check "backup with no directory prints the usage" misused "Usage:" claude_sync "$q" backup
    # A clock that gives the same second for each run, as when backup runs twice within one.
    mkdir "$scratch/fixed-date" "$scratch/same-second"
    printf '#!/bin/sh\necho 20250101T000000Z\n' >"$scratch/fixed-date/date"
    chmod +x "$scratch/fixed-date/date"
    echo stand-in >"$scratch/same-second/$q-20250101T000000Z.tar.gz"
    check "an archive already named for this second is refused" fails_with "already exists; rerun in a second" \
        env PATH="$scratch/fixed-date:$PATH" CLAUDE_SYNC_NAME="$q" "$bin" backup "$scratch/same-second"
    check "  and left as it was" [ "$(cat "$scratch/same-second/$q-20250101T000000Z.tar.gz")" = stand-in ]
    # Temporary files of backups stopped before they could remove them: one untouched since
    # 2025, one still being written, and one of an instance whose name starts with this one's.
    stale=.$q-20250101T000000Z.tar.gz.123 writing=.$q-20250102T000000Z.tar.gz.456
    others_stale=.$q-work-20250101T000000Z.tar.gz.789
    mkdir "$scratch/stopped"
    (cd "$scratch/stopped" && touch -t 202501010000 -- "$stale" "$others_stale" && touch -- "$writing")
    out=$(claude_sync "$q" backup "$scratch/stopped")
    check "backup removes a temporary file that a backup stopped a day ago left" [ ! -e "$scratch/stopped/$stale" ]
    check "  and says so" grep -qF "Removed $scratch/stopped/$stale." <<<"$out"
    check "  keeping one still being written" [ -e "$scratch/stopped/$writing" ]
    check "  and another instance's" [ -e "$scratch/stopped/$others_stale" ]

    echo "# restore, on a paired device"
    in_target "$mount_t" "chown $owner_t /t"
    claude_sync "$t" setup --volume "$vol_t" --private >/dev/null
    id_q=$(docker exec -u "$owner_q" "$q" syncthing device-id)
    id_t=$(docker exec -u "$owner_t" "$t" syncthing device-id)
    pair_bounded "$q" "$id_t" --address "tcp://$t:22000" --keep >/dev/null
    check "T joins Q" pair_bounded "$t" "$id_q" --address "tcp://$q:22000"
    in_target "$mount_q" "echo changed >/t/settings.json && rm /t/claude.json &&
        echo newer >/t/newer.md && chown $owner_q /t/newer.md"
    check "a change and a delete on Q reach T" \
        wait_for in_target "$mount_t" '[ ! -e /t/claude.json ] && grep -qx changed /t/settings.json'
    check "restore over Q's live folder" claude_sync "$q" restore "$archive" --volume "$vol_q"
    check "  gives T the changed file back" \
        wait_for in_target "$mount_t" "grep -qx 'fixture settings.json' /t/settings.json"
    check "  and the deleted one" wait_for in_target "$mount_t" "grep -qx 'fixture claude.json' /t/claude.json"
    check "  and keeps Q's file that the archive lacks" in_target "$mount_q" "grep -qx newer /t/newer.md"
}
