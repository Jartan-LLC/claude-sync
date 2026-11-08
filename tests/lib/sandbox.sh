# shellcheck shell=bash
# The suite touches only objects with its prefix: guard refuses others, cleanup removes them.

guard() {
    [[ $1 == "$prefix"* ]] || {
        echo "refusing to touch $1" >&2
        exit 1
    }
}

cleanup() {
    local x
    for x in "$a" "$b" "$c" "$d" "$e" "$g" "$k" "$j" "$l" "$m" "$n" "$p" "$q" "$t" "$v" "$w" "$h" "$hu" "$sx" "$sy" "$sz" "$u" "$y" \
        "$bad_name" "$listener" "$foreign"; do
        guard "$x"
        docker rm --force -v "$x" >/dev/null 2>&1 || true
    done
    guard "$host_image"
    docker image rm "$host_image" >/dev/null 2>&1 || true
    for x in "$a-config" "$b-config" "$c-config" "$d-config" "$e-config" "$g-config" "$k-config" \
        "$j-config" "$l-config" "$m-config" "$n-config" "$p-config" "$q-config" "$s-config" "$t-config" "$v-config" \
        "$w-config" "$sx-config" "$sy-config" "$u-config" "$bad_name-config" "$foreign-config" "$vol_sx" "$vol_sy" \
        "$vol_a" "$vol_b" "$vol_c" "$vol_d" "$vol_e" "$vol_g" "$vol_j" "$vol_l" "$vol_m" "$vol_n" "$vol_p" \
        "$vol_q" "$vol_r" "$vol_t" "$vol_v" "$vol_u" "$vol_q_missing" "$vol_missing" "$vol_root"; do
        guard "$x"
        docker volume rm "$x" >/dev/null 2>&1 || true
    done
    guard "$net"
    docker network rm "$net" >/dev/null 2>&1 || true
}
