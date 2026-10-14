#!/usr/bin/env bash
# 请求全部由 curl 函数替身处理；无网络、FIFO 或真实设备。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
library="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/task-http.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -r $library ]] || fail 'task HTTP private-body wrapper missing'
. "$library"
token_fixture='fixture-token+/= value'
json_fixture=$'{"token":"fixture-token+/= value","message":"中文\\nline"}'
native_rc=0 http_status=200
curl() {
    local item next file='' header=''
    printf '%s\n' "$@" >"$tmp/argv"
    while (( $# )); do
        item=$1; shift
        case $item in
            --data-urlencode)
                next=$1; shift
                [[ $next == token@* ]] || fail 'token was not sent by private file'
                file=${next#token@}; command cat "$file" >"$tmp/token"
                printf '%s' "${file%/*}" >"$tmp/request-dir"
                ;;
            --data-binary)
                next=$1; shift; [[ $next == @* ]] || fail 'inline JSON body remained in argv'
                file=${next#@}; command cat "$file" >"$tmp/json"
                printf '%s' "${file%/*}" >"$tmp/request-dir"
                ;;
            --dump-header) header=$1; shift ;;
        esac
    done
    [[ -n $header ]] || fail 'redirect status cannot be observed'
    printf 'HTTP/1.1 %s Fixture\r\n\r\n' "$http_status" >"$header"
    if [[ ${signal_test:-no} == yes ]]; then kill -TERM "$BASHPID"; fi
    command cat >"$tmp/stdin"
    printf 'RESPONSE'
    return "$native_rc"
}
printf 'input\000bytes\n' >"$tmp/input"
printf '%s' "$token_fixture" >"$tmp/expected-token"
saved_parent_exit=$(trap -p EXIT); saved_parent_umask=$(umask)
rootpxe_task_curl -Lks --data-urlencode "token=$token_fixture" https://example.invalid/ <"$tmp/input" >"$tmp/output"
cmp -s "$tmp/input" "$tmp/stdin" || fail 'wrapper consumed or changed stdin'
cmp -s "$tmp/expected-token" "$tmp/token" || fail 'form token bytes changed or newline added'
! grep -Fq "$token_fixture" "$tmp/argv" || fail 'token still present in curl argv'
! grep -Eq '(^-L|^--location)' "$tmp/argv" || fail 'redirect following still enabled'
[[ $(cat "$tmp/output") == RESPONSE ]] || fail 'native response changed'
[[ ! -e $(cat "$tmp/request-dir") ]] || fail 'successful request body not cleaned'
[[ $(trap -p EXIT) == "$saved_parent_exit" && $(umask) == "$saved_parent_umask" ]] || fail 'request changed parent trap/umask'
printf '%s' "$json_fixture" >"$tmp/expected-json"
rootpxe_task_curl -ks --data-binary "$json_fixture" https://example.invalid/ </dev/null >"$tmp/output"
cmp -s "$tmp/expected-json" "$tmp/json" || fail 'JSON bytes changed or newline added'
[[ ! -s $tmp/stdin ]] || fail 'EOF changed'
[[ ! -e $(cat "$tmp/request-dir") ]] || fail 'JSON body not cleaned'
native_rc=7 rc=0
rootpxe_task_curl --data-urlencode "token=$token_fixture" https://example.invalid/ </dev/null >"$tmp/output" || rc=$?
[[ $rc == 7 && ! -e $(cat "$tmp/request-dir") ]] || fail 'native error status/cleanup changed'
native_rc=0 http_status=307 rc=0
rootpxe_task_curl --data-urlencode "token=$token_fixture" https://example.invalid/ </dev/null >"$tmp/output" || rc=$?
[[ $rc != 0 && ! -e $(cat "$tmp/request-dir") ]] || fail 'redirect accepted or leaked body'
http_status='' rc=0
rootpxe_task_curl --data-urlencode "token=$token_fixture" https://example.invalid/ </dev/null >"$tmp/output" || rc=$?
[[ $rc != 0 && ! -e $(cat "$tmp/request-dir") ]] || fail 'empty/invalid HTTP header accepted'
http_status=200
rootpxe_task_curl --proto '=https' --proto-redir '=https' --max-redirs 0 --pinnedpubkey 'sha256//fixture-pin' --data-urlencode "token=$token_fixture" https://example.invalid/ </dev/null >"$tmp/output"
grep -Fxq -- '--pinnedpubkey' "$tmp/argv" && grep -Fxq -- 'sha256//fixture-pin' "$tmp/argv" && grep -Fxq -- '=https' "$tmp/argv" || fail 'manual pin/protocol options changed'
http_status=200 signal_test=yes rc=0
rootpxe_task_curl --data-urlencode "token=$token_fixture" https://example.invalid/ </dev/null >"$tmp/output" || rc=$?
[[ $rc == 143 && ! -e $(cat "$tmp/request-dir") ]] || fail 'TERM did not stop/clean request'
signal_test=no
saved_mktemp=$(declare -f mktemp || true)
mktemp() { return 9; }
rm -f "$tmp/argv"; rc=0
rootpxe_task_curl --data-urlencode "token=$token_fixture" https://example.invalid/ </dev/null || rc=$?
[[ $rc != 0 && ! -e $tmp/argv ]] || fail 'temporary directory failure reached curl'
unset -f mktemp
[[ -z $saved_mktemp ]] || eval "$saved_mktemp"
printf 'PASS: private HTTP form/JSON bytes, argv/stdin, success/error/redirect/signal/setup cleanup\n'
case ${OSTYPE:-} in msys*|cygwin*) printf 'NOTE: native Linux 0700/0600 permissions require Linux verification.\n' ;; esac
