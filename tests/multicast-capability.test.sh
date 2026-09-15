#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lib="${MULTICAST_LIB:-$repo_root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/multicast.sh}"

udp-receiver() {
    [[ ${1:-} == --help ]] || return 1
    printf '%s\n' "${MOCK_HELP_TEXT-udp-receiver --nokbd --portbase --ttl --mcast-rdv-address --start-timeout --receive-timeout}"
    return "${MOCK_HELP_EXIT:-0}"
}
curl() { return 0; }

jq() {
    case "$*" in
        *'transportMode'*) printf '%s\n' "${MOCK_MODE:-unicast}" ;;
        *'multicastSessionId'*) printf '%s\n' "${MOCK_SESSION:-}" ;;
        *'waitTimeoutSec'*) printf '%s\n' "${MOCK_TIMEOUT:-}" ;;
        *) return 1 ;;
    esac
}

source "$lib"
assert_receiver_capable() {
    if ! rootpxe_multicast_receiver_capable; then
        echo 'udp-receiver capability unexpectedly rejected' >&2
        exit 1
    fi
}
assert_receiver_rejected() {
    if rootpxe_multicast_receiver_capable; then
        echo 'udp-receiver capability unexpectedly accepted' >&2
        exit 1
    fi
}

MOCK_HELP_EXIT=0 assert_receiver_capable
MOCK_HELP_EXIT=1 assert_receiver_capable
MOCK_HELP_EXIT=2 assert_receiver_rejected
MOCK_HELP_EXIT=126 assert_receiver_rejected
MOCK_HELP_EXIT=127 assert_receiver_rejected
for required_flag in --nokbd --portbase --ttl --mcast-rdv-address --start-timeout --receive-timeout; do
    help_text="udp-receiver --nokbd --portbase --ttl --mcast-rdv-address --start-timeout --receive-timeout"
    help_text=${help_text/"$required_flag"/}
    MOCK_HELP_EXIT=1 MOCK_HELP_TEXT="$help_text" assert_receiver_rejected
done
MOCK_HELP_EXIT=1 MOCK_HELP_TEXT='' assert_receiver_rejected
unset MOCK_HELP_EXIT MOCK_HELP_TEXT
rootpxe_multicast_runtime_ready=yes
taskType=deploy
MOCK_MODE=multicast MOCK_SESSION=manual-session-1 MOCK_TIMEOUT=300 rootpxe_multicast_apply_transport_mode '{}'
[[ $mc == yes && $multicastSessionId == manual-session-1 && $multicastWaitTimeoutSec == 300 ]]
MOCK_MODE=multicast MOCK_SESSION=manual-session-1 MOCK_TIMEOUT=86400 rootpxe_multicast_apply_transport_mode '{}'
[[ $mc == yes && $multicastWaitTimeoutSec == 86400 ]]
if MOCK_MODE=multicast MOCK_SESSION=manual-session-1 MOCK_TIMEOUT=86401 rootpxe_multicast_apply_transport_mode '{}'; then
    echo 'wait timeout above one day was accepted' >&2
    exit 1
fi
MOCK_MODE=unicast rootpxe_multicast_apply_transport_mode '{}'
[[ $mc == no && ${multicastSessionId:-} == '' ]]
taskType=capture
if MOCK_MODE=multicast MOCK_SESSION=manual-session-1 MOCK_TIMEOUT=300 rootpxe_multicast_apply_transport_mode '{}'; then
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
