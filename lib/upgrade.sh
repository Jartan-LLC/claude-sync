# shellcheck shell=bash
# Versions: the release list, the version stamp and upgrade.

# The version of claude-sync that last set an instance up, in its config volume beside the
# companion, or beside the config file of the Syncthing on this host.
readonly stamp=claude-sync-version
# GitHub's list of releases; the tests point it at a file.
readonly releases_api=${CLAUDE_SYNC_RELEASES_API:-https://api.github.com/repos/Jartan-LLC/claude-sync/releases?per_page=100}
readonly rpm_upgrade="upgrade it with dnf as you installed it, then run CLAUDE_SYNC_NAME=NAME claude-sync setup for each running instance NAME that claude-sync list shows"
# Set by check_releases.
releases="" release_safe="" release_breaking=""

# Matches a version such as 0.4.1, v0.4.1, 0.4.1-rc.1 or, as an RPM gives it, 0.4.1~rc.1,
# into BASH_REMATCH: major, minor and patch at 1 to 3, the pre-release part at 4.
parse_version() {
    [[ $1 =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+)([-~].+)?$ ]]
}

# Whether version A comes before version B, as SemVer orders them, except that two
# pre-releases of one version are not ordered: only a release follows its pre-releases.
version_older() {
    local a b i
    parse_version "$1" || return 1
    a=("${BASH_REMATCH[@]:1}")
    parse_version "$2" || return 1
    b=("${BASH_REMATCH[@]:1}")
    for i in 0 1 2; do
        if ((10#${a[i]} != 10#${b[i]})); then
            ((10#${a[i]} < 10#${b[i]}))
            return
        fi
    done
    [[ -n ${a[3]} && -z ${b[3]} ]]
}

# Whether going from version A to the later version B is breaking by the project's rule
# (CONTRIBUTING.md, Releasing): a new major version, or a new minor version while the
# major is 0.
version_breaking() {
    local a b
    parse_version "$1" || return 1
    a=("${BASH_REMATCH[@]:1}")
    parse_version "$2" || return 1
    b=("${BASH_REMATCH[@]:1}")
    ((10#${a[0]} != 10#${b[0]} || (10#${a[0]} == 0 && 10#${a[1]} != 10#${b[1]})))
}

# Fetches the list of releases into releases, which release_url reads, then sets
# release_safe to the newest release after this version that is not breaking, and
# release_breaking to the newest that is, each a tag or empty. Pre-releases are left out.
# Its arguments go to curl. Fails when it cannot fetch the list.
check_releases() {
    local tag
    release_safe="" release_breaking=""
    releases=$(curl -fsSL "$@" -- "$releases_api") || return 1
    # grep, as the list may come on one line or many, and users need no jq.
    while IFS= read -r tag; do
        [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        version_older "$claude_sync_version" "$tag" || continue
        if ! version_breaking "$claude_sync_version" "$tag"; then
            if [[ -z $release_safe ]] || version_older "$release_safe" "$tag"; then release_safe=$tag; fi
        elif [[ -z $release_breaking ]] || version_older "$release_breaking" "$tag"; then
            release_breaking=$tag
        fi
    done < <(grep -o '"tag_name": *"[^"]*"' <<<"$releases" | sed 's/.*"\([^"]*\)"$/\1/')
}

# The URL, from the list in releases, of the release TAG's notes, or with FILE, of that
# file of the release.
release_url() {
    local tag=${1//./\\.} pattern
    if (($# == 2)); then
        pattern="\"browser_download_url\": *\"[^\"]*/$tag/${2//./\\.}\""
    else
        pattern="\"html_url\": *\"[^\"]*/releases/tag/$tag\""
    fi
    grep -m 1 -o "$pattern" <<<"$releases" | sed 's/.*"\([^"]*\)"$/\1/'
}

# The file in which an instance whose Syncthing runs in PLACE, container or host, records
# its version; for a container, a path inside it.
stamp_file() {
    local config
    case $1 in
        container) echo "/var/syncthing/config/$stamp" ;;
        host) config=$(host_config_file) && echo "${config%/*}/$stamp" ;;
        *) return 1 ;;
    esac
}

# The version of claude-sync that last set up the instance NAME, whose Syncthing runs in
# PLACE, container or host. Fails when there is none: it predates the stamp, or its
# container is not running.
instance_version() {
    local file
    file=$(stamp_file "$2") || return 1
    case $2 in
        container) docker exec "$1" cat "$file" 2>/dev/null ;;
        host) cat -- "$file" 2>/dev/null ;;
    esac
}

# Records this version in the instance NAME, whose Syncthing runs in PLACE, once it is set
# up.
write_stamp() {
    local file
    file=$(stamp_file "$2") || die "cannot record the version in instance $1"
    case $2 in
        container) docker exec -i -u "$owner" "$1" sh -c "cat >$file" <<<"$claude_sync_version" ;;
        host) printf '%s\n' "$claude_sync_version" >"$file" ;;
    esac || die "cannot record the version in instance $1"
}

# Whether an instance that claude-sync version STAMP set up needs this version's setup.
# An empty STAMP, from before the stamp, or one that is not a version, as `dev` from a
# checkout, says nothing, so that instance does. A claude-sync that is not a version
# itself, as `dev`, counts no instance as needing it.
stale() {
    parse_version "$claude_sync_version" || return 1
    [[ -z $1 ]] || ! parse_version "$1" || version_older "$1" "$claude_sync_version"
}

# The claude-sync that last set up the instance NAME, whose Syncthing runs in PLACE, then,
# when it needs this version's setup, the command that applies it. Fails when it does not.
set_up_by() {
    local version text="an older claude-sync"
    version=$(instance_version "$1" "$2") || version=""
    [[ -z $version ]] || text="claude-sync $version"
    if stale "$version"; then
        echo "$text; run $(setup_command "$1") to apply $claude_sync_version"
    else
        echo "$text"
        return 1
    fi
}

# Tells when an older claude-sync set this instance up.
warn_stale() {
    local place=container text
    [[ $mode != host ]] || place=host
    text=$(set_up_by "$name" "$place") || return 0
    printf 'claude-sync: this instance was last set up by %s\n' "$text" >&2
}

# The file this claude-sync runs from, symlinks resolved.
installed_file() {
    readlink -f -- "$claude_sync_file"
}

# The RPM package that installed FILE. Fails when none did.
rpm_package() {
    command -v rpm >/dev/null && rpm -qf -- "$1" 2>/dev/null
}

upgrade() {
    (($# == 0)) || die "upgrade takes no arguments"
    [[ $claude_sync_version != dev ]] ||
        die "this claude-sync runs from a checkout (version dev); update it with git, then run setup to apply it"
    local file package
    [[ -f $claude_sync_file ]] || die "this claude-sync is not running from a file; save it to a file and run that"
    file=$(installed_file)
    if package=$(rpm_package "$file"); then
        die "$file belongs to the RPM package $package: $rpm_upgrade"
    fi
    command -v curl >/dev/null || die "curl is required"
    command -v sha256sum >/dev/null || die "sha256sum is required"
    check_releases || die "cannot get the list of claude-sync's releases from $releases_api"
    if [[ -n $release_safe ]]; then
        install_release "$release_safe" "$file"
        echo "Installed claude-sync ${release_safe#v} in place of $claude_sync_version."
        # The new version applies itself, and tells of any breaking release. It does not exec
        # again unless a newer release came out between the two fetches of the list:
        # install_release checked that it is release_safe, the newest release that is not
        # breaking.
        exec "$file" upgrade
    fi
    if [[ -n $release_breaking ]]; then
        printf 'claude-sync %s is out. It is a breaking release, so upgrade leaves it to you; its release notes say how to upgrade: %s\n' \
            "${release_breaking#v}" "$(release_url "$release_breaking")"
    fi
    apply_everywhere "$file"
}

# Downloads the release TAG's claude-sync, checks it against the release's SHA-256, and puts
# it in place of FILE as a new file, so a command still running the old one is unaffected.
install_release() {
    local tag=$1 file=$2 url sums tmp want
    { url=$(release_url "$tag" claude-sync) && sums=$(release_url "$tag" claude-sync.sha256); } ||
        die "release $tag has no claude-sync or claude-sync.sha256 to download"
    # In FILE's directory, so the move is a rename that replaces FILE at once.
    tmp=$(mktemp -- "${file%/*}/.claude-sync.XXXXXX") || die "cannot write to ${file%/*}, where claude-sync is"
    # shellcheck disable=SC2064 # expanded now: tmp is local
    trap "rm -f -- $(printf %q "$tmp")" EXIT
    curl -fsSL -o "$tmp" -- "$url" || die "cannot download $url"
    want=$(curl -fsSL -- "$sums") || die "cannot download $sums"
    [[ $(sha256sum <"$tmp") == "${want%% *} "* ]] ||
        die "the claude-sync downloaded from $url does not match the release's SHA-256; nothing was changed"
    chmod 755 "$tmp"
    # A file that gave another version would find this release newer than itself again.
    [[ $(bash "$tmp" version) == "claude-sync ${tag#v}" ]] ||
        die "the claude-sync downloaded from $url is not version ${tag#v}; nothing was changed"
    mv -f -- "$tmp" "$file"
}

# Runs FILE's setup, with no target, for every running instance that an older version set
# up, carrying on past one that fails.
apply_everywhere() {
    local file=$1 all instance status version unlisted="" found="" running="" applied="" failed=()
    all=$(instances) || unlisted=1
    while IFS=$'\t' read -r instance status; do
        [[ -n $instance ]] || continue
        found=1
        case $status in
            stopped)
                printf 'Instance %s is stopped, so upgrade leaves it stopped; %s starts it with claude-sync %s.\n' \
                    "$instance" "$(setup_command "$instance")" "$claude_sync_version"
                continue
                ;;
            state-only)
                printf 'Volume %s-config holds the Syncthing state of instance %s, which no container of claude-sync uses; %s --volume NAME or --path DIR uses it again.\n' \
                    "$instance" "$instance" "$(setup_command "$instance")"
                continue
                ;;
        esac
        # What is left, container or host, is also where the instance's Syncthing runs, the
        # place instance_version and setup's write_stamp take.
        running=1
        version=$(instance_version "$instance" "$status") || version=""
        stale "$version" || continue
        applied=1
        printf 'Applying claude-sync %s to instance %s:\n' "$claude_sync_version" "$instance"
        # Its stdin would otherwise be the rest of the list.
        CLAUDE_SYNC_NAME=$instance "$file" setup </dev/null || failed+=("$instance")
    done <<<"$all"
    if [[ -n $unlisted ]]; then
        # A daemon that is not running, or a user outside the docker group, would otherwise
        # pass for a host with no instance in a container.
        printf 'claude-sync: docker cannot list the instances in containers, so none of those was upgraded; once docker works, rerun claude-sync upgrade\n' >&2
    elif [[ -z $found ]]; then
        echo "claude-sync $claude_sync_version is installed; no instance is set up on this host yet."
    elif [[ -n $running && -z $applied ]]; then
        echo "Every running instance already runs claude-sync $claude_sync_version."
    fi
    case ${#failed[@]} in
        0) [[ -z $unlisted ]] || exit 1 ;;
        1) die "setup failed for instance ${failed[0]}; fix what it says, then rerun claude-sync upgrade" ;;
        *) die "setup failed for instances ${failed[*]}; fix what each says, then rerun claude-sync upgrade" ;;
    esac
}
