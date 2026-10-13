#!/usr/bin/env bash
# Maintenance mount diagnostics: native calls are mocked; no real mount or
# interactive maintenance command is executed.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
chpass="$overlay/bin/pxeos.chpass"
chntpw="$overlay/bin/pxeos.chntpw"
photorec="$overlay/bin/pxeos.photorec"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
check(){ "$@" || fail "$*"; }

for script in "$chpass" "$chntpw" "$photorec"; do
    check test -f "$script"
    ! grep -qE '/tmp/(ntfs-mount-output|mount-output)' "$script" || fail "legacy-path:$script"
    ! grep -q 'Reason:.*cat ' "$script" || fail "raw-reason:$script"
    grep -q 'rootpxe_run_logged_typed_native' "$script" || fail "typed-wrapper:$script"
done
grep -q 'rootpxe_run_logged_typed_native ntfs-mount.log' "$chpass" || fail chpass-type
grep -q 'rootpxe_run_logged_typed_native ntfs-mount.log' "$chntpw" || fail chntpw-type
grep -q 'rootpxe_run_logged_typed_native storage-mount.log' "$photorec" || fail photorec-type

# Evaluate the exact production wrapper invocation lines with a mock wrapper
# and mock native commands, preserving argv and native exit status.
calls=()
native_name=''
native_args=()
native_rc=0
rootpxe_run_logged_typed_native() {
    local type="$1" target="$2"; shift 2
    calls+=("$type|$target|$*")
    native_name=$1
    shift
    native_args=("$@")
    "$native_name" "${native_args[@]}"
}
ntfs-3g() { return "$native_rc"; }
mount() { return "$native_rc"; }

part=/dev/sda1
native_rc=17
rc=0
eval "$(sed -nE 's/^[[:space:]]*(rootpxe_run_logged_typed_native ntfs-mount\.log.*)$/\1/p' "$chpass" | head -n 1)" || rc=$?
check test "$rc" = 17
check test "$native_name" = ntfs-3g
check test "${native_args[*]}" = '-o remove_hiberfile,rw /dev/sda1 /chntpw'
check test "${calls[0]}" = 'ntfs-mount.log|/dev/sda1|ntfs-3g -o remove_hiberfile,rw /dev/sda1 /chntpw'

calls=(); native_rc=23; rc=0
eval "$(sed -nE 's/^[[:space:]]*(rootpxe_run_logged_typed_native ntfs-mount\.log.*)$/\1/p' "$chntpw" | head -n 1)" || rc=$?
check test "$rc" = 23
check test "$native_name" = mount
check test "${native_args[*]}" = '-o rw /dev/sda1 /ntfs'
check test "${calls[0]}" = 'ntfs-mount.log|/dev/sda1|mount -o rw /dev/sda1 /ntfs'

storage=server:/share
calls=(); native_rc=31; rc=0
eval "$(sed -nE 's/^[[:space:]]*(rootpxe_run_logged_typed_native storage-mount\.log.*)$/\1/p' "$photorec" | head -n 1)" || rc=$?
check test "$rc" = 31
check test "$native_name" = mount
check test "${native_args[*]}" = '-o nolock server:/share /storage'
check test "${calls[0]}" = 'storage-mount.log|server:/share|mount -o nolock server:/share /storage'

# Existing failure/cleanup and interactive boundaries remain present.
grep -q 'handleError "Could not mount \$part (\$0)"' "$chpass" || fail chpass-failure-boundary
grep -q 'handleError "Could not mount \$part (\$0)"' "$chntpw" || fail chntpw-failure-boundary
grep -q 'chntpw "\$sam"' "$chpass" || fail chpass-interactive-call
grep -q 'chntpw -u "\$winuser" "\$sam"' "$chntpw" || fail chntpw-interactive-call
grep -q 'photorec \$part' "$photorec" || fail photorec-call
grep -q '/bin/pxeos.nonimgcomplete' "$chntpw" || fail chntpw-completion
grep -q '/bin/pxeos.nonimgcomplete' "$photorec" || fail photorec-completion

# Real helper smoke: only the native command is mocked.  No mount, password
# tool, or PhotoRec process is started.
tmp=$(mktemp -d /tmp/pxeos-maintenance-log-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
. "$root/tests/task-log-test-support.sh"
. <(sed "s|/tmp/log|$tmp/log|g" "$overlay/usr/share/pxeos/lib/log-paths.sh")
smoke_native_rc=7
smoke_calls="$tmp/native-calls"
maintenance_native() {
    printf 'NAME=maintenance_native ARGS=%s\n' "$*" >>"$smoke_calls"
    printf 'mount diagnostic token=maintenance-secret\n'
    return "$smoke_native_rc"
}
: >"$smoke_calls"
smoke_rc=0
rootpxe_run_logged_typed_native ntfs-mount.log /dev/ntfs maintenance_native -o rw /dev/ntfs /mnt >"$tmp/stdout" || smoke_rc=$?
check test "$smoke_rc" = 7
check test ! -s "$tmp/stdout"
grep -Fxq 'NAME=maintenance_native ARGS=-o rw /dev/ntfs /mnt' "$smoke_calls" || fail smoke-native-argv
check test -f "$tmp/log/ntfs-mount.log"
check test "$(stat -c %a "$tmp/log/ntfs-mount.log")" = 600
! grep -q maintenance-secret "$tmp/log/ntfs-mount.log" || fail smoke-secret-leak
check test "$(find "$tmp/log" -name '.raw.*' -print | wc -l)" = 0

smoke_native_rc=0
: >"$smoke_calls"
rootpxe_run_logged_typed_native storage-mount.log /srv/storage maintenance_native -o nolock server:/share /storage >"$tmp/stdout"
check test ! -s "$tmp/stdout"
grep -Fxq 'NAME=maintenance_native ARGS=-o nolock server:/share /storage' "$smoke_calls" || fail smoke-storage-argv
check test -f "$tmp/log/storage-mount.log"
check test "$(stat -c %a "$tmp/log/storage-mount.log")" = 600
check test "$(find "$tmp/log" -name '.raw.*' -print | wc -l)" = 0

saved_publish=$(declare -f rootpxe_log_publish)
rootpxe_log_publish(){ return 1; }
smoke_native_rc=13
: >"$smoke_calls"
smoke_rc=0
rootpxe_run_logged_typed_native ntfs-mount.log /dev/ntfs maintenance_native -o rw /dev/ntfs /mnt >"$tmp/stdout" 2>"$tmp/publish-failure" || smoke_rc=$?
check test "$smoke_rc" = 13
check test ! -s "$tmp/stdout"
grep -Fxq 'NAME=maintenance_native ARGS=-o rw /dev/ntfs /mnt' "$smoke_calls" || fail smoke-publish-native-skipped
grep -q unavailable "$tmp/publish-failure" || fail smoke-publish-failure-notice
check test "$(find "$tmp/log" -name '.raw.*' -print | wc -l)" = 0
eval "$saved_publish"

printf 'Fixed maintenance log: PASS\n'
