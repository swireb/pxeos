#!/usr/bin/env bash
# Mock children and private regular files only; no DHCP/network/device command.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
tmp=$(mktemp -d /tmp/pxeos-nonblocking-log.XXXXXX)
owner=$BASHPID; owned_pids=()
cleanup(){
    [[ $BASHPID == "$owner" ]] || return 0
    # Even a child-not-ready failure can happen after its PID was recorded.
    # These four exact files are created only by this fixture's own children.
    for owned_tag in boot-stdio boot-extra mutation-stdio mutation-extra; do
        [[ ! -f $tmp/pid-$owned_tag ]] || owned_pids+=("$(<"$tmp/pid-$owned_tag")")
    done
    for owned_pid in "${owned_pids[@]}"; do [[ $owned_pid =~ ^[0-9]+$ ]] && { kill -0 "$owned_pid" 2>/dev/null && kill -TERM "$owned_pid" 2>/dev/null || true; }; done
    [[ $tmp == /tmp/pxeos-nonblocking-log.* && -d $tmp && ! -L $tmp && -O $tmp ]] && rm -rf -- "$tmp"
}
trap cleanup EXIT
. "$root/tests/task-log-test-support.sh"
task_log_test_load_helpers "$lib/funcs.sh"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
node(){ for ((n=0;n<250;n++)); do [[ -f $1 ]] && return 0; sleep .02; done; return 1; }
read -r -d '' client <<'CLIENT' || true
set -euo pipefail
dir=$1; tag=$2; writer=$3; shift 3
printf '%s\n' "$*" >"$dir/args-$tag"
IFS= read -r input; printf '%s\n' "$input" >"$dir/stdin-$tag"
bash -c '
    set -euo pipefail
    dir=$1; tag=$2; writer=$3
    exec </dev/null >/dev/null 2>&1
    printf "%s\n" "$BASHPID" >"$dir/pid-$tag"
    [[ -z $writer ]] || printf "INHERITED_PIPE_WRITER\n" >&"$writer"
    printf ready >"$dir/ready-$tag"
    IFS= read -r release <"$dir/gate-$tag"
    printf done >"$dir/done-$tag"
' _ "$dir" "$tag" "$writer" &
exit 0
CLIENT
for kind in boot mutation; do
    for mode in stdio extra; do
        tag=$kind-$mode
        mkfifo "$tmp/gate-$tag"
        (
            rootpxe_task_log_initialize
            native_called=no
            native(){
                native_called=yes
                if [[ $mode == extra ]]; then
                    command bash -c "$client" _ "$tmp" "$tag" "${rootpxe_boot_log_fd:-${rootpxe_task_log_native_fd:-}}" "$@"
                else
                    printf '%s\n' "$*" >"$tmp/args-$tag"
                    IFS= read -r input; printf '%s\n' "$input" >"$tmp/stdin-$tag"
                    printf 'PARENT_NATIVE_DETAIL\n'
                    ( printf '%s\n' "$BASHPID" >"$tmp/pid-$tag"; printf ready >"$tmp/ready-$tag"; IFS= read -r release <"$tmp/gate-$tag"; printf 'LATE_CHILD_DETAIL\n'; printf done >"$tmp/done-$tag" ) &
                fi
                return 0
            }
            if [[ $kind == boot ]]; then rootpxe_log_boot_run dhcp.log dhcp:eth0 foreground-append native -i eth0 --now < <(printf 'STDIN_SENTINEL\n');
            else rootpxe_run_logged_mutation native_mock /dev/mock native -i eth0 --now < <(printf 'STDIN_SENTINEL\n'); fi
            [[ $native_called == yes ]] || exit 92
            printf 0 >"$tmp/returned-$tag"
        ) >"$tmp/out-$tag" 2>"$tmp/err-$tag" & runner=$!
        owned_pids+=("$runner")
        node "$tmp/ready-$tag" || fail "child-not-ready:$tag"
        owned_pids+=("$(<"$tmp/pid-$tag")")
        returned=yes; node "$tmp/returned-$tag" || returned=no
        # Always release this exact mock writer, including on the red path.
        printf 'release\n' >"$tmp/gate-$tag"
        wait "$runner"
        node "$tmp/done-$tag" || fail "child-not-released:$tag"
        [[ $returned == yes ]] || fail "logger-waited-for-daemon:$tag"
        [[ $(<"$tmp/args-$tag") == '-i eth0 --now' && $(<"$tmp/stdin-$tag") == STDIN_SENTINEL ]] || fail "native-contract:$tag"
        printf 'PASS: %s returns before owned daemon release\n' "$tag"
    done
done
printf 'Nonblocking log: PASS\n'
