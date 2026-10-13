#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d /tmp/pxeos-log-snapshot.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
. "$root/tests/task-log-test-support.sh"
task_log_test_load_helpers "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
rootpxe_task_log_initialize
rootpxe_log_raw_file; raw=$rootpxe_log_raw_path
real_dd=$(type -P dd)
dd(){
    local count='' arg
    for arg; do [[ $arg != count=* ]] || count=${arg#count=}; done
    [[ $count =~ ^[0-9]+$ && $count -le 131072 ]] || return 90
    printf '%s\n' "$count" >>"$tmp/read-budget"
    "$real_dd" "$@"
}
eval "$(declare -f rootpxe_log_redact | sed '1s/rootpxe_log_redact/rootpxe_snapshot_real_redact/')"
rootpxe_log_redact(){ printf call >>"$tmp/redact-budget"; rootpxe_snapshot_real_redact "$@"; }
awk 'BEGIN{for(i=0;i<65000;i++)print "x"; printf "LAST_SHORT_ERROR"}' >"$raw"
rootpxe_log_publish fat-fsck.log "$raw" snapshot
grep -q LAST_SHORT_ERROR "$tmp/log/fat-fsck.log" || fail tail-error
grep -q TRUNCATED "$tmp/log/fat-fsck.log" || fail marker-lost
[[ $(wc -c <"$tmp/redact-budget") == 4 && $(wc -l <"$tmp/read-budget") == 1 ]] || fail unbounded-work
[[ $(wc -c <"$tmp/log/fat-fsck.log") -le 65536 ]] || fail entry-size
printf '%s\n' 'storage_password="unfinished secret fragment' "execution_token='unfinished second fragment" '{"credential_suffix":"unfinished third fragment' >"$raw"
printf 'LAST_NATIVE_ERROR' >>"$raw"
rootpxe_log_publish fat-fsck.log "$raw" partial
! grep -Eq 'secret fragment|second fragment|third fragment' "$tmp/log/fat-fsck.log" || fail partial-secret
grep -q LAST_NATIVE_ERROR "$tmp/log/fat-fsck.log" || fail nonnewline-tail
printf '%s\n' 'api_secret: "unfinished fourth fragment' "'api_secret': 'unfinished fifth fragment" >"$raw"
rootpxe_log_publish fat-fsck.log "$raw" colon
! grep -Eq 'fourth fragment|fifth fragment' "$tmp/log/fat-fsck.log" || fail colon-partial-secret
printf '%064000d' 0 >"$raw"
start=$SECONDS
rootpxe_log_publish fat-fsck.log "$raw" long-safe-line
[[ $((SECONDS-start)) -lt 10 ]] || fail long-line-redaction-budget
truncate -s 1073741824 "$raw"
printf '\nLAST_LARGE_ERROR\n' | "$real_dd" of="$raw" oflag=seek_bytes seek=1073741800 conv=notrunc status=none
rootpxe_log_publish fat-fsck.log "$raw" sparse
grep -q LAST_LARGE_ERROR "$tmp/log/fat-fsck.log" || fail sparse-tail
[[ $(tail -n 1 "$tmp/read-budget") == 131072 && $(stat -c %s "$raw") == 1073741824 ]] || fail sparse-budget-or-raw-mutation
rm "$raw"
printf 'Log snapshot: PASS\n'
