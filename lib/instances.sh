# shellcheck shell=bash
# Which instance a command acts on, and which instances this host has.

readonly default_name=claude-sync

# Where `claude-sync use` keeps the selected instance. Fails when there is no home to
# keep it in. A relative XDG_CONFIG_HOME is ignored, as the XDG spec says: the selection
# would follow the working directory.
selection_file() {
    local dir=${HOME:+$HOME/.config}
    [[ ${XDG_CONFIG_HOME:-} != /* ]] || dir=$XDG_CONFIG_HOME
    [[ -n $dir ]] || return 1
    echo "$dir/claude-sync/instance"
}

# The instance `claude-sync use` selected. Fails when none is. For a file that is empty or
# cannot be read it prints nothing, which check_name refuses: falling back to the default
# would let uninstall remove claude-sync unannounced.
selected_instance() {
    local file
    file=$(selection_file) && [[ -e $file ]] || return 1
    head -n 1 -- "$file" 2>/dev/null || true
}

# What chose the instance: CLAUDE_SYNC_NAME, which wins so neither scripts nor upgrade's
# setup of each instance follow a selection, then the selection, else the default.
if [[ -n ${CLAUDE_SYNC_NAME:-} ]]; then
    name_from=variable
elif CLAUDE_SYNC_NAME=$(selected_instance); then
    name_from=selection
else
    CLAUDE_SYNC_NAME=$default_name name_from=default
fi
readonly name_from
# Exported for compose.yaml.
export CLAUDE_SYNC_NAME
readonly name=$CLAUDE_SYNC_NAME

# Compose's project-name rule, plus Docker's two-character minimum for container names,
# since an instance's name is both.
valid_name() {
    [[ $1 =~ ^[a-z0-9][a-z0-9_-]+$ ]]
}

check_name() {
    valid_name "$name" && return 0
    if [[ $name_from == selection ]]; then
        die "$(selection_file) does not hold a valid instance name; select one again with claude-sync use NAME"
    fi
    die "CLAUDE_SYNC_NAME must be two or more lowercase letters, digits, '-' or '_', starting with a letter or digit: $name"
}

# What chose an instance other than the default, for messages.
name_source() {
    if [[ $name_from == selection ]]; then
        echo "selected with claude-sync use"
    else
        echo "named by CLAUDE_SYNC_NAME"
    fi
}

# For a command that acts on the instance: refuses an invalid name, then says which
# instance it acts on, and what chose it, when it is not the default.
check_instance() {
    check_name
    [[ $name != "$default_name" ]] || return 0
    printf 'claude-sync: acting on instance %s, %s\n' "$name" "$(name_source)" >&2
}

# This host's claude-sync instances, one per line as the instance's name, a tab and its
# status: container (running), stopped (its container is not running), state-only (its
# Syncthing state is left but no container of claude-sync's uses it) or host
# (claude-sync's folder in the Syncthing of this user on this host, which is always the
# default name's). Fails, after listing the rest, when docker cannot list the volumes.
instances() {
    local volumes volume instance unlisted=0
    if command -v docker >/dev/null; then
        if volumes=$(docker volume ls -q --filter "label=$label"); then
            while IFS= read -r volume; do
                instance=${volume%-config}
                [[ $instance != "$volume" ]] || continue
                if ! docker container inspect "$instance" >/dev/null 2>&1 || ! ours_container "$instance"; then
                    printf '%s\tstate-only\n' "$instance"
                elif [[ $(docker container inspect --format '{{.State.Running}}' "$instance") == true ]]; then
                    printf '%s\tcontainer\n' "$instance"
                else
                    printf '%s\tstopped\n' "$instance"
                fi
            done < <(sort <<<"$volumes")
        else
            unlisted=1
        fi
        # setup refuses a host instance beside a container of the default name.
        if docker container inspect "$default_name" >/dev/null 2>&1; then
            return "$unlisted"
        fi
    fi
    if prints_line "$folder_id" cut -f 1 < <(host_folders); then
        printf '%s\thost\n' "$default_name"
    fi
    return "$unlisted"
}

# The command that sets up the instance NAME again, for messages. With a selection, the
# bare command would act on the selected instance.
setup_command() {
    local prefix="CLAUDE_SYNC_NAME=$1 "
    if [[ $1 == "$default_name" ]] && ! selected_instance >/dev/null; then
        prefix=""
    fi
    echo "${prefix}claude-sync setup"
}

# Lists this host's instances, marking the one commands act on.
list() {
    (($# == 0)) || die "list takes no arguments"
    local all unlisted="" instance status width=4 mark state syncs marked="" tab=$'\t'
    all=$(instances) || unlisted=1
    while IFS=$'\t' read -r instance status; do
        ((${#instance} <= width)) || width=${#instance}
    done <<<"$all"
    if [[ -n $all ]]; then
        printf '  %-*s  %-14s  %s\n' "$width" NAME STATE SYNCS
        while IFS=$'\t' read -r instance status; do
            mark=" "
            if [[ $instance == "$name" ]]; then
                mark="*" marked=1
            fi
            case $status in
                container | stopped)
                    state=running
                    [[ $status == container ]] || state=stopped
                    syncs=$(current_target "$instance") || syncs=""
                    if [[ $syncs == /* ]]; then
                        syncs="directory $syncs"
                    elif [[ -n $syncs ]]; then
                        syncs="volume $syncs"
                    fi
                    ;;
                state-only) state="state only" syncs="" ;;
                host)
                    state="host Syncthing"
                    syncs="directory $(host_folders | sed -n "s/^$folder_id$tab//p")"
                    ;;
            esac
            printf '%s %-*s  %-14s  %s\n' "$mark" "$width" "$instance" "$state" "${syncs:--}"
        done <<<"$all"
    fi
    [[ -z $unlisted ]] ||
        die "docker cannot list the instances in containers, so this list leaves them out; once docker works, rerun claude-sync list"
    [[ -n $marked ]] || check_name
    if [[ -z $all ]]; then
        echo "No instance is set up on this host."
    elif [[ -z $marked ]]; then
        echo "Commands act on instance $name, which is not set up on this host."
    fi
}

# Selects the instance later commands act on, when CLAUDE_SYNC_NAME is unset.
use() {
    if (($# != 1)); then
        usage >&2
        exit 2
    fi
    local instance=$1 file all
    file=$(selection_file) ||
        die "neither HOME nor an absolute XDG_CONFIG_HOME is set, so there is nowhere to keep the selection"
    if [[ $instance == "$default_name" ]]; then
        rm -f -- "$file" 2>/dev/null || die "cannot remove $file, which holds the selection"
        echo "Commands now act on the default instance, $default_name."
    else
        all=$(instances) || die "docker cannot list the instances in containers, so use cannot check that $instance is one; once docker works, rerun claude-sync use $instance"
        if ! valid_name "$instance" || ! prints_line "$instance" cut -f 1 <<<"$all"; then
            die "no instance named $instance on this host; claude-sync list shows them"
        fi
        { mkdir -p -- "${file%/*}" && printf '%s\n' "$instance" >"$file"; } 2>/dev/null ||
            die "cannot write the selection to $file"
        echo "Commands now act on instance $instance."
    fi
    if [[ $name_from == variable && $name != "$instance" ]]; then
        echo "CLAUDE_SYNC_NAME is set, so commands run with it still act on instance $name."
    fi
}
