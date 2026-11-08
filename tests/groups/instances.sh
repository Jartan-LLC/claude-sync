# shellcheck shell=bash
# group_instances and the helpers only it uses.

# claude-sync for an instance in the listener's network namespace, where another program
# holds Syncthing's default ports.
beside() {
    local node=$1
    shift
    CLAUDE_SYNC_COMPOSE_OVERRIDE=$root/tests/compose.busy.yaml CLAUDE_SYNC_NAME=$node \
        timeout 300 "$bin" "$@"
}

listens_soon() {
    local i
    for ((i = 0; i < 20; i++)); do
        listens "$@" && return 0
        sleep 1
    done
    return 1
}

# Two instances on one host, beside a program that holds the default ports.
group_instances() {
    echo "# several instances on one host"
    # E and G share a listener's network namespace, as two instances on one host where another
    # program holds Syncthing's default ports.
    docker run -d --name "$listener" --network "$net" --entrypoint sh "$image" \
        -c '(while true; do nc -l -p 22000 >/dev/null; done) &
            while true; do nc -l -p 8384 >/dev/null; done' >/dev/null
    wait_for listens "$listener" 8384
    wait_for listens "$listener" 22000
    check "a busy port asked for is refused" fails_with "port 8384 is in use" \
        beside "$e" setup --volume "$vol_e" --gui-port 8384
    check "  leaving no Syncthing state" fails docker volume inspect "$e-config"
    check "  nor writing to the target" in_target "type=volume,src=$vol_e" '[ ! -e /t/.stignore ]'
    out=$(beside "$e" setup --volume "$vol_e" --private)
    check "setup starts beside the busy default ports" grep -qF "This device ID" <<<"$out"
    check "  as a healthy container" [ "$(docker inspect -f '{{.State.Health.Status}}' "$e")" = healthy ]
    port_e=$(sync_port "$e" "$owner_e")
    check "  on another sync port" [ "${port_e:-22000}" != 22000 ]
    check "  and says which ports it uses" grep -qF "sync port $port_e" <<<"$out"
    check "  and why" grep -qF "Another program holds Syncthing's default" <<<"$out"
    out=$(beside "$g" setup --volume "$vol_g" --private --gui-port 8484 --sync-port 22100)
    check "--gui-port fixes the web UI port" listens "$g" 8484
    check "--sync-port fixes the sync port" [ "$(sync_port "$g" "$owner_g")" = 22100 ]
    check "  and Syncthing listens on it" wait_for listens "$g" 22100
    check "  and setup says so" grep -qF "127.0.0.1:8484" <<<"$out"
    check "setup again keeps the ports" beside "$g" setup --volume "$vol_g"
    check "  the web UI port" listens "$g" 8484
    check "  and the sync port" [ "$(sync_port "$g" "$owner_g")" = 22100 ]
    check "  and asking for them again is no clash" \
        beside "$g" setup --volume "$vol_g" --gui-port 8484 --sync-port 22100
    check "a busy port asked for again is refused" fails_with "port 8384 is in use" \
        beside "$g" setup --volume "$vol_g" --gui-port 8384
    check "  and the instance keeps its own" listens "$g" 8484
    check "the web UI on the sync port is refused" fails_with "would both be 22100" \
        beside "$g" setup --volume "$vol_g" --gui-port 22100
    check "  and the web UI stays put" listens "$g" 8484
    check "the sync port moving onto the web UI's" \
        beside "$g" setup --volume "$vol_g" --gui-port 8585 --sync-port 8484
    check "  puts the web UI on its new port" listens "$g" 8585
    # Syncthing retries a failed listener only after about a minute.
    check "  so the sync port binds without waiting for a retry" listens_soon "$g" 8484
    check "an exact swap of the two ports" beside "$g" setup --volume "$vol_g" --gui-port 8484 --sync-port 8585
    check "  keeps Syncthing's API in reach" st "$g" "$owner_g" show version
    check "  and the sync port binds once Syncthing retries" wait_for listens "$g" 8585
    check "a target another instance syncs is refused" fails_with "container $e already syncs $vol_e" \
        beside "$k" setup --volume "$vol_e"
    check "  creating no Syncthing state" fails docker volume inspect "$k-config"
    id_e=$(docker exec -u "$owner_e" "$e" syncthing device-id)
    id_g=$(docker exec -u "$owner_g" "$g" syncthing device-id)
    # Started before G accepts, so the join prints what to run there, with E's own sync port.
    CLAUDE_SYNC_COMPOSE_OVERRIDE=$root/tests/compose.busy.yaml CLAUDE_SYNC_NAME=$e timeout 300 \
        "$bin" pair "$id_g" --address "tcp://$listener:$(sync_port "$g" "$owner_g")" >"$scratch/join-e.out" 2>&1 &
    joining=$!
    check "pair names this instance's sync port" \
        wait_for grep -qF "tcp://THIS-HOST:$port_e" "$scratch/join-e.out"
    beside "$g" pair "$id_e" --address "tcp://$listener:$port_e" --keep >/dev/null
    check "E joins through G" wait "$joining"
    check "  and gets G's claude.json" [ "$(in_target "type=volume,src=$vol_e" 'cat /t/claude.json')" = "g claude.json" ]
    check "  moving its own file to the trash can" in_target "type=volume,src=$vol_e" '[ -e /t/.stversions/e-only.md ]'
    beside "$e" uninstall >/dev/null
    check "uninstalling E removes E" fails docker container inspect "$e"
    check "  and leaves G running" [ "$(docker inspect -f '{{.State.Running}}' "$g")" = true ]
    check "  with its folder" [ "$(st "$g" "$owner_g" config folders list)" = claude-sync ]
    beside "$g" uninstall >/dev/null
    docker rm --force -v "$listener" >/dev/null
}
