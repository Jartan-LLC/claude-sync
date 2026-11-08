# shellcheck shell=bash
# Where the instance's Syncthing runs, how to reach it, and what --private and --public set.

readonly folder_id=claude-sync
# The image's home. The image declares it a VOLUME, so Docker gives each container an
# anonymous volume there.
readonly container_home=/var/syncthing
# Syncthing's config and the synced folder inside the container, under that home. The
# compose files take them from write_compose_files.
readonly container_config=$container_home/config container_folder=$container_home/claude
# The synced folder as Syncthing sees it; with --use-host-syncthing, the directory itself.
folder_path=$container_folder
readonly trash_days=14
readonly default_gui_port=8384 default_sync_port=22000
readonly label=claude-sync=config
owner=""
# Set by use_host for the Syncthing on this host. Reads name, so lib/instances.sh is listed
# before this file.
mode=container where="in container $name" api_url="" api_key="" api_tls=()

syncthing_run() {
    if [[ $mode == host ]]; then
        syncthing "$@"
    else
        docker exec -u "$owner" "$name" syncthing "$@"
    fi
}

st() {
    syncthing_run cli "$@"
}

# The running instance's REST API at PATH, then extra curl options, for what
# `syncthing cli` does not cover.
rest() {
    if [[ $mode == host ]]; then
        local path=$1
        shift
        # The key goes on stdin, since other users can read a process's arguments.
        curl -fsS "${api_tls[@]}" "$@" -K - "$api_url$path" <<<"header = \"X-API-Key: $api_key\""
        return
    fi
    # shellcheck disable=SC2016 # expanded by the container's shell
    docker exec -u "$owner" "$name" sh -c \
        'path=$1; shift
        curl -fsS "$@" -H "X-API-Key: $(syncthing cli config gui apikey get)" \
            "http://$(syncthing cli config gui raw-address get)$path"' \
        sh "$@"
}

# A top-level KEY of the REST API's JSON. The API prints one key per line, so sed reads it
# and users need no jq.
field() {
    sed -n "s/^  \"$1\": \(.*\)\$/\1/p" | sed 's/,$//; s/^"\(.*\)"$/\1/'
}

# The object under KEY, at any depth of the REST API's JSON, with its keys where field
# reads them.
object() {
    local line lead indent="" found=""
    while IFS= read -r line; do
        if [[ -z $found ]]; then
            lead=${line%%[! ]*}
            [[ ${line#"$lead"} != "\"$1\": {" ]] || found=1 indent=$lead
        elif [[ $line == "$indent}" || $line == "$indent}," ]]; then
            return 0
        else
            printf '%s\n' "${line#"$indent"}"
        fi
    done
}

folder_status() {
    rest "/rest/db/status?folder=$folder_id"
}

# Dies with Syncthing's own message when it cannot run the folder, such as an ignore
# pattern it rejects. Syncthing loads the ignore list after starting and before it scans or
# pulls, so any later state means the folder runs; a scan or sync under way is not waited
# for. Dies too when Syncthing's API never answers.
wait_folder_started() {
    local i status state reached=""
    for ((i = 0; i < 120; i++)); do
        if status=$(folder_status); then
            reached=1
        else
            status=""
            ((i < 15)) || [[ -n $reached ]] || die "cannot reach Syncthing $where"
        fi
        state=$(field state <<<"$status")
        case $state in
            error) die "Syncthing cannot sync the folder: $(field error <<<"$status")" ;;
            starting) ;;
            ?*) return 0 ;;
        esac
        sleep 1
    done
}

# Has Syncthing load the ignore list as its web UI does: saved, applied at once and scanned
# in the background. A written .stignore alone waits for the folder's next scan or pull.
load_ignores() {
    local lines answer err
    # One JSON string per line; the list holds no control characters.
    lines=$(asset stignore | sed 's/[\\"]/\\&/g; s/.*/"&"/' | paste -sd, -)
    answer=$(rest "/rest/db/ignores?folder=$folder_id" -X POST -H 'Content-Type: application/json' \
        -d "{\"ignore\": [$lines]}") || die "cannot reach Syncthing $where"
    err=$(field error <<<"$answer")
    [[ $err == null ]] || die "Syncthing cannot use the ignore list: $err"
}

# Tells that Syncthing is still at work on the folder. Only a hint, so it says nothing
# when Syncthing does not answer.
tell_busy() {
    local status
    status=$(folder_status) || return 0
    [[ $(field state <<<"$status") == idle ]] ||
        echo "Syncthing is still scanning or syncing your files; see progress at $(web_ui)."
}

# Syncthing's web UI, for messages.
web_ui() {
    if [[ $mode == host ]]; then
        echo "$api_url"
    else
        echo "http://$(st config gui raw-address get)"
    fi
}

add_folder() {
    st config folders add --id "$folder_id" --label claude --path "$folder_path" --type "$1"
    set_trash_can
}

# Applies the ignore list just written to an existing folder, or adds the folder.
ensure_folder() {
    if prints_line "$folder_id" st config folders list; then
        load_ignores
    else
        add_folder sendreceive
    fi
}

set_trash_can() {
    st config folders "$folder_id" versioning type set trashcan
    st config folders "$folder_id" versioning params set cleanoutDays "$trash_days"
}

# Whether container NAME exists; false, not an error, when docker is not installed.
container_exists() {
    command -v docker >/dev/null && docker container inspect "$1" >/dev/null 2>&1
}

# Whether docker is installed but does not answer: no daemon, or no permission to reach it.
docker_unreachable() {
    command -v docker >/dev/null && ! docker info >/dev/null 2>&1
}

running() {
    [[ $(docker container inspect --format '{{.State.Running}}' "$1" 2>/dev/null) == true ]]
}

gui_port() {
    local address
    address=$(st config gui raw-address get) || return
    echo "${address##*:}"
}

# The port of the first TCP listen address; Syncthing's "default" means 22000.
sync_port() {
    local options line re='"tcp[46]?://[^"]*:([0-9]+)"'
    options=$(st config options dump-json) || return
    while IFS= read -r line; do
        if [[ $line =~ $re ]]; then
            echo "${BASH_REMATCH[1]}"
            return
        fi
    done <<<"$options"
    echo "$default_sync_port"
}

ours_volume() {
    [[ $(docker volume inspect --format "{{index .Labels \"${label%=*}\"}}" "$1") == "${label#*=}" ]]
}

ours_container() {
    [[ $(docker container inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$1") == "$1" ]]
}

# The volume the existing container NAME has at the image's home, if it has Docker's
# anonymous label, as the volume Docker makes for the image's VOLUME does; Compose may have
# handed that volume on to NAME when it recreated the container. Nothing for another volume.
anonymous_volume() {
    local volume
    volume=$(docker container inspect --format "{{range .Mounts}}{{if and (eq .Type \"volume\") (eq .Destination \"$container_home\")}}{{.Name}}{{end}}{{end}}" "$1")
    [[ -n $volume ]] || return 0
    # shellcheck disable=SC2016 # a Go template's variables
    docker volume inspect --format '{{range $key, $_ := .Labels}}{{if eq $key "com.docker.volume.anonymous"}}{{$.Name}}{{end}}{{end}}' "$volume"
}

# The volume name or host path the existing container NAME syncs, if any.
current_target() {
    docker container inspect --format "{{range .Mounts}}{{if eq .Destination \"$folder_path\"}}{{if eq .Type \"volume\"}}{{.Name}}{{else}}{{.Source}}{{end}}{{end}}{{end}}" \
        "$1" 2>/dev/null
}

host_config_file() {
    command -v syncthing >/dev/null || return 1
    syncthing paths 2>/dev/null | sed -n '/^Configuration file:/{n;s/^[[:space:]]*//p;}'
}

# Whether this user has a Syncthing on this host, running or not: its config file exists.
host_syncthing_configured() {
    local config
    config=$(host_config_file) || return 1
    [[ -f $config ]]
}

# This user's Syncthing's folders, as ID, a tab and path per line, read from its config
# file so they are found whether that Syncthing runs or not.
host_folders() {
    local config tab=$'\t'
    config=$(host_config_file) || return 0
    # A folder with no ID is the defaults block's template for new folders. The tab is put
    # in by bash, as not every sed reads \t.
    sed -n "s/^ *<folder id=\"\\([^\"][^\"]*\\)\" [^>]*path=\"\\([^\"]*\\)\".*/\\1$tab\\2/p" "$config" |
        sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e 's/&#34;/"/g' \
            -e "s/&apos;/'/g" -e "s/&#39;/'/g" -e 's/&amp;/\&/g'
}

# The path of claude-sync's folder in this user's Syncthing; empty when it has none.
host_folder_path() {
    local tab=$'\t'
    host_folders | sed -n "s/^$folder_id$tab//p"
}

# Points the helpers at the Syncthing running as this user on this host.
use_host() {
    mode=host where="on this host"
    command -v syncthing >/dev/null || die "Syncthing is not installed on this host"
    command -v curl >/dev/null || die "curl is required"
    local address
    { address=$(st config gui raw-address get) && api_key=$(st config gui apikey get); } 2>/dev/null ||
        die "cannot reach the Syncthing on this host; is it running as $(id -un)?"
    # An address with no host listens on all of them.
    [[ $address != :* ]] || address=127.0.0.1$address
    api_url=http://$address
    if [[ $(st config gui raw-use-tls get) == true ]]; then
        # Its certificate is self-signed.
        api_url=https://$address api_tls=(-k)
    fi
}

# The UID:GID that the container NAME runs Syncthing as.
container_owner() {
    local env
    env=$(docker container inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$1") || return
    echo "$(sed -n 's/^PUID=//p' <<<"$env"):$(sed -n 's/^PGID=//p' <<<"$env")"
}

# Container mode when claude-sync's container exists, else the Syncthing this user has
# configured on this host.
detect_mode() {
    if container_exists "$name"; then
        { running "$name" && ours_container "$name"; } || die "Syncthing is not running in container $name; run setup first"
        owner=$(container_owner "$name")
        warn_stale
    elif [[ $name == "$default_name" ]] && host_syncthing_configured; then
        use_host
        folder_path=$(st config folders "$folder_id" path get 2>/dev/null) ||
            die "claude-sync is not set up on this device; run setup first"
        warn_stale
        # No companion runs beside this Syncthing, so every command that acts on it applies
        # the list.
        apply_unpaired
    else
        die "claude-sync is not set up on this device; run setup first"
    fi
}

# Runs the sh SCRIPT with ARGS where the synced folder is: in the container, or here.
in_folder() {
    if [[ $mode == host ]]; then
        sh -c "$@"
    else
        docker exec -u "$owner" "$name" sh -c "$@"
    fi
}

set_network() {
    local network=$1
    # Left as it is when neither is given, so re-running setup never makes a device public.
    if [[ -n $network ]]; then
        local option on=true
        [[ $network == public ]] || on=false
        for option in global-ann-enabled relays-enabled natenabled; do
            st config options "$option" set "$on"
        done
    fi
}

# public or private, as setup's --public and --private set them, or each option as it is.
network_setting() {
    local discovery relays nat
    { discovery=$(st config options global-ann-enabled get) && relays=$(st config options relays-enabled get) &&
        nat=$(st config options natenabled get); } || return
    case $discovery$relays$nat in
        truetruetrue) echo public ;;
        falsefalsefalse) echo private ;;
        *) printf 'global discovery %s, relays %s, NAT traversal %s\n' "$(on_off "$discovery")" \
            "$(on_off "$relays")" "$(on_off "$nat")" ;;
    esac
}

on_off() {
    if [[ $1 == true ]]; then echo on; else echo off; fi
}
