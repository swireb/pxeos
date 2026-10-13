#!/usr/bin/env bash
# Native text diagnostics only; no device mount or registry operation runs.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
lib="$overlay/usr/share/pxeos/lib"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
if grep -nE '/tmp/(ntfs-(probe|mount)-output|rootpxe-linux-(btrfs-list|probe)-output)' "$lib/funcs.sh" || grep -n '/tmp/mount-output' "$overlay/bin/pxeos.mount" || grep -nE '/tmp/rootpxe-display-(mount|ntfs|reged)-output' "$lib/display-metadata.sh"; then fail dispersed-discovery-diagnostics; fi
grep -q '^rootpxe_run_logged_typed_native() {' "$lib/log-paths.sh" || fail standalone-wrapper
tmp=$(mktemp -d /tmp/pxeos-discovery-log-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
. "$root/tests/task-log-test-support.sh"
. <(sed "s|/tmp/log|$tmp/log|g" "$lib/log-paths.sh")
native(){ printf '%s\n' "$*" >>"$tmp/calls"; printf 'native failure password="FAKE_DISCOVERY_SECRET"\n'; return "${native_rc:-0}"; }
for type in storage-mount.log ntfs-mount.log linux-probe.log metadata-discovery.log; do
    native_rc=7; rc=0
    rootpxe_run_logged_typed_native "$type" /dev/mock native -o ro /dev/mock /private/mount >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
    [[ $rc == 7 && ! -s $tmp/stdout && -s $tmp/log/$type ]] || fail "standalone-rc:$type"
    grep -q 'native failure' "$tmp/log/$type" || fail "native-detail:$type"
    ! grep -q FAKE_DISCOVERY_SECRET "$tmp/log/$type" || fail "secret:$type"
done
[[ $(wc -l <"$tmp/calls") == 4 ]] || fail native-argv-count
grep -qx -- '-o ro /dev/mock /private/mount' "$tmp/calls" || fail native-argv
saved_publish=$(declare -f rootpxe_log_publish)
rootpxe_log_publish(){ return 1; }
native_rc=0
rootpxe_run_logged_typed_native metadata-discovery.log /dev/mock native publish-fault >"$tmp/stdout" 2>"$tmp/stderr"
[[ ! -s $tmp/stdout ]] || fail protocol-stdout
grep -q unavailable "$tmp/stderr" || fail sink-notice
grep -q publish-fault "$tmp/calls" || fail sink-skipped-native
eval "$saved_publish"
grep -Fq '"$export_file"' "$lib/display-metadata.sh" || fail registry-export-protocol
printf 'Fixed discovery log: PASS\n'
