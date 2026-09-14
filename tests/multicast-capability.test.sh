#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lib="$repo_root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/multicast.sh"

udp-receiver() {
    [[ ${1:-} == --help ]] || return 1
    printf '%s\n' 'udp-receiver --nokbd --portbase --ttl --mcast-rdv-address --start-timeout --receive-timeout'
}
curl() { return 0; }

jq() {
    case "$*" in
        *'transportMode'*) printf '%s\n' "${MOCK_MODE:-unicast}" ;;
        *'multicastProtocolVersion'*) printf '%s\n' "${MOCK_VERSION:-}" ;;
        *) return 1 ;;
    esac
}

source "$lib"
rootpxe_multicast_runtime_ready=yes
taskType=deploy
MOCK_MODE=multicast MOCK_VERSION=1 rootpxe_multicast_apply_transport_mode '{}' 
[[ $mc == yes && $multicastProtocolVersion == 1 ]]
MOCK_MODE=unicast rootpxe_multicast_apply_transport_mode '{}'
[[ $mc == no && ${multicastProtocolVersion:-} == '' ]]
taskType=capture
if MOCK_MODE=multicast MOCK_VERSION=1 rootpxe_multicast_apply_transport_mode '{}'; then
    echo 'capture accepted multicast' >&2
    exit 1
fi
echo 'multicast capability mock regression passed'

test_image_root=$(mktemp -d)
mkdir -p "$test_image_root/images"
printf 'a' >"$test_image_root/images/root.img.000"
printf 'b' >"$test_image_root/images/root.img.001"
mapfile -t split_paths < <(rootpxe_multicast_artifact_paths "$test_image_root" images/root.img)
[[ ${split_paths[*]} == 'images/root.img.000 images/root.img.001' ]]
echo 'multicast manifest mock regression passed'
