#!/usr/bin/env bash
# Local directories and small real processes only; no NAS or block devices.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d /tmp/pxeos-capture-direct.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -f $lib/capture-direct.sh ]] || fail capture-direct-runtime-missing
sed "s@/storage@${tmp}/storage@g" "${PXEOS_CAPTURE_DIRECT_TEST_LIB:-$lib/capture-direct.sh}" >"$tmp/capture-direct.sh"
. "$tmp/capture-direct.sh"
eval "$(sed -n '/^rootpxe_safe_relative_path() {/,/^}/p' "$lib/funcs.sh")"
imgType=n
eval "$(sed -n '/^rootpxe_directory_size_bytes() {/,/^}/p' "$lib/funcs.sh")"
taskid=4 progress_attempt=7 macWinSafe=000c29129138 img=1
rootpxe_require_task_context(){ :; }
rootpxe_capture_begin_publish(){ [[ ${publish_denied:-no} != yes ]]; }
rootpxe_wait_for_writers(){ [[ ${writer_failed:-no} != yes ]]; }
rootpxe_capture_publish_metadata(){ [[ -s $1/.rootpxe-partition-inventory.json ]]; }
mkdir -p "$tmp/storage/1"
printf OLD >"$tmp/storage/1/old.img"
trace="$tmp/prepare-trace"
stat(){ printf 'stat %s\n' "$*" >>"$trace"; command stat "$@"; }
find(){ printf 'find %s\n' "$*" >>"$trace"; command find "$@"; }
rootpxe_capture_direct_prepare || fail missing-dev-not-created
! grep -Fq "$tmp/storage/1" "$trace" || fail prepare-read-old-target
[[ -d $tmp/storage/dev/$macWinSafe && -f $tmp/storage/1/old.img ]] || fail wrong-mac-layout
[[ ! -e $tmp/storage/dev/4 ]] || fail task-attempt-layout-retained
printf PARTIAL >"$imagePath/.hidden"
printf PARTIAL >"$imagePath/partial.img"
rootpxe_capture_direct_prepare || fail retry-prepare
[[ ! -e $imagePath/.hidden && ! -e $imagePath/partial.img && -f $tmp/storage/1/old.img ]] || fail retry-did-not-clear-own-mac
printf NEW >"$imagePath/new.img"
printf '{"version":1}' >"$imagePath/.rootpxe-partition-inventory.json"
writer_failed=yes
if rootpxe_capture_direct_finalize; then fail failed-writer-published; fi
[[ $(cat "$tmp/storage/1/old.img") == OLD ]] || fail failed-writer-touched-old-target
writer_failed=no publish_denied=yes
if rootpxe_capture_direct_finalize; then fail rejected-finalizing-published; fi
[[ $(cat "$tmp/storage/1/old.img") == OLD ]] || fail aborted-capture-touched-old-target
publish_denied=no
rootpxe_capture_direct_finalize || fail complete-capture-not-published
[[ $(cat "$tmp/storage/1/new.img") == NEW && ! -e $tmp/storage/1/old.img && ! -e $tmp/storage/dev/$macWinSafe ]] || fail replacement-merged-old-content
[[ $rootpxe_capture_published_attempt == 7 ]] || fail publication-not-bound-to-attempt
# Run the actual split writer supervisor, not a hand-written mock pipeline.
rootpxe_capture_direct=yes
rootpxe_capture_direct_prepare
for function in uploadFormat rootpxe_prepare_capture_output_path; do
    eval "$(sed -n "/^$function() {/,/^}/p" "$lib/funcs.sh")"
done
handleError(){ fail "$*"; }
imgFormat=4 PIGZ_COMP=''
mkfifo "$tmp/cancel.fifo"
uploadFormat "$tmp/cancel.fifo" "$imagePath/split.img"
pipeline=$rootpxe_last_writer_pid
setsid yes CAPTURE >"$tmp/cancel.fifo" & rootpxe_capture_producer_pid=$!
children=''
for iteration in {1..100}; do
    children=$(cat "/proc/$pipeline/task/$pipeline/children" 2>/dev/null || true)
    [[ -z $children ]] || break
    sleep 0.01
done
[[ -n $children ]] || fail pipeline-children-not-started
[[ $(ps -o pgid= -p "$pipeline" | tr -d ' ') == "$pipeline" ]] || fail writer-pid-is-not-process-group
producer=$rootpxe_capture_producer_pid
rootpxe_capture_direct_quiesce
for pid in "$producer" "$pipeline" $children; do ! kill -0 "$pid" 2>/dev/null || fail cancel-left-pipeline-process-alive; done
[[ $rootpxe_capture_stopped == yes ]] || fail pipeline-stop-unconfirmed
# A real compressor failure survives split's success; producer failures survive wait.
(
    mkdir "$tmp/failing-bin"
    printf '#!/bin/bash\ncat >/dev/null\nexit 7\n' >"$tmp/failing-bin/pigz"
    chmod 700 "$tmp/failing-bin/pigz"
    PATH="$tmp/failing-bin:$PATH";imgFormat=2
    eval "$(sed -n '/^rootpxe_wait_for_writer() {/,/^}/p' "$lib/funcs.sh")"
    uploadFormat "$tmp/failing.fifo" "$imagePath/failed.img"
    writer=$rootpxe_last_writer_pid
    rootpxe_capture_run_producer bash -c 'printf input >"$1"' fixture "$tmp/failing.fifo"
    status=0;rootpxe_wait_for_writer "$writer" || status=$?
    [[ $status == 7 && $(cat "$tmp/storage/1/new.img") == NEW ]] || fail compressor-failure-hidden-or-published
    status=0;rootpxe_capture_run_producer bash -c 'exit 8' || status=$?
    [[ $status == 8 && $(cat "$tmp/storage/1/new.img") == NEW ]] || fail producer-failure-hidden-or-published
)
# Exercise the real response parser: legacy and nonzero NFS never reach mount.
(
    checkin="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.checkin"
    for function in rootpxe_json_get_string rootpxe_json_get_text rootpxe_json_assign rootpxe_json_assign_text rootpxe_validate_json_storage rootpxe_apply_json_checkin; do
        eval "$(sed -n "/^$function() {/,/^}/p" "$checkin")"
    done
    rootpxe_cloud_init_cleanup_private(){ :; }
    rootpxe_multicast_reset(){ :; }
    rootpxe_apply_json_deployment_identity_policy(){ :; }
    rootpxe_apply_json_partition_inventory(){ :; }
    rootpxe_multicast_apply_transport_mode(){ :; }
    rootpxe_apply_json_cloud_init(){ :; }
    document='{"taskId":4,"type":"capture","pxeType":"up","mac":"000c29129138","executionToken":"fixture","progressAttempt":7,"img":"1","imgType":"n","imgPartitionType":"all","osid":50,"imgFormat":4,"protocol":"nfs","storageip":"fixture","exportPath":"/images","captureProtocol":"mac-direct-v1","captureAccess":{"captureProtocol":"mac-direct-v1","attempt":7,"storageNonce":"11111111111111111111111111111111","nfsUid":0,"nfsGid":0}}'
    rootpxe_apply_json_checkin "$document" || fail direct-response-parser
    for filter in 'del(.captureProtocol)' '.captureAccess.captureProtocol="legacy"' '.captureAccess.attempt=6' '.captureAccess.nfsUid=1000'; do
        if rootpxe_apply_json_checkin "$(jq -c "$filter" <<<"$document")";then fail incompatible-response-accepted;fi
    done
)
# Real error reporter must retain the first error and suppress EXIT stop ACK.
for function in rootpxe_error_report rootpxe_cleanup_session; do
    eval "$(sed -n "/^$function() {/,/^}/p" "$lib/funcs.sh")"
done
rootpxe_failure_begin(){ :; }
rootpxe_failure_remaining(){ printf 60; }
rootpxe_bound_callback_message(){ printf '%s' "$1"; }
rootpxe_task_multicast_form_args(){ rootpxe_task_multicast_args=(); }
rootpxe_cleanup_smb_credentials(){ :; }
rootpxe_cleanup_task_json(){ :; }
rootpxe_task_curl(){ printf '%s\n' "$*" >>"$tmp/callbacks"; printf '{"accepted":true}\n200'; }
rootpxe_capture_released=no rootpxe_capture_stopped=yes
pxeapi=https://fixture/ task_token=fixture mac=$macWinSafe
rootpxe_error_report ORIGINAL_COMPRESSION_ERROR COMPRESSION_FAILED
[[ $rootpxe_capture_released == yes ]] || fail original-error-release-not-recorded
rootpxe_cleanup_session
[[ $(wc -l <"$tmp/callbacks") == 1 ]] || fail exit-overwrote-original-error
# The actual successful finish-marker cleanup also suppresses any later ACK.
eval "$(sed -n '/^rootpxe_clear_capture_marker() {/,/^}/p' "$lib/storage-io.sh")"
rootpxe_capture_direct_prepare
rootpxe_capture_released=no
rootpxe_clear_capture_marker
rootpxe_cleanup_session
[[ $(wc -l <"$tmp/callbacks") == 1 && ! -e $imagePath/.rootpxe-capture-taskid ]] || fail successful-finish-sent-error
# A successful direct finish stays successful if only its marker unlink fails.
(
    type=up imgType=n hd=/dev/fixture disks="" rootpxe_capture_released=no
    rootpxe_partition_inventory_file="$tmp/finish-inventory.json"
    rootpxe_original_schema_file="$tmp/finish-schema.json"
    printf '{}\n' >"$rootpxe_partition_inventory_file";printf '{}\n' >"$rootpxe_original_schema_file"
    rootpxe_deployment_identity_policy_enabled(){ return 1; }
    rootpxe_build_partition_inventory(){ :; };rootpxe_build_original_schema(){ :; }
    rootpxe_capture_publish_metadata(){ :; };rootpxe_finalize_capture(){ :; }
    rootpxe_stage(){ :; };rootpxe_clear_capture_marker(){ return 1; }
    rootpxe_task_console_failure(){ printf '%s\n' "$*" >>"$tmp/finish-marker-warning"; }
    rootpxe_console_message(){ :; };dots(){ :; };debugPause(){ :; }
    rootpxe_capture_resume_cleanup(){ :; }
    rootpxe_storage_recover_until_clean(){ fail direct-finish-entered-legacy-recovery; }
    rootpxe_task_curl(){ [[ ${*: -1} == https://fixture/finish ]] || fail unexpected-direct-finish-callback;printf '{"success":true}'; }
    . "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.imgcomplete"
    rootpxe_cleanup_session
    [[ $rootpxe_capture_released == yes && -s $tmp/finish-marker-warning ]] || fail marker-error-lost-confirmed-release
)
# Trigger TERM in the actual XFS rw mount -> umount window with native substitutes.
sed -n '/^rootpxe_xfs_capture_preflight() {/,/^}/p' "$lib/funcs.sh" >"$tmp/xfs-preflight.sh"
cat >"$tmp/xfs-cancel.sh" <<'XFS'
set -euo pipefail
. "$TEST_CAPTURE_LIB"
. "$TEST_XFS_LIB"
rootpxe_capture_direct=yes rootpxe_capture_released=no rootpxe_capture_stopped=no
writer_pids=()
rootpxe_require_task_context(){ :; }
rootpxe_task_curl(){ [[ ! -e $TEST_XFS_STATE/mounted ]] || { echo 'FAIL: ACK before XFS unmount' >&2;exit 1; };printf ACK >"$TEST_XFS_STATE/ack";printf '{"accepted":true}'; }
mktemp(){ command mktemp -d "$TEST_XFS_STATE/rootpxe-xfs-capture.XXXXXX"; }
findmnt(){ return 1; }
xfs_repair(){ :; }
mountpoint(){ [[ -e $TEST_XFS_STATE/mounted ]]; }
mount(){ printf '%s' "${@: -1}" >"$TEST_XFS_STATE/mounted";[[ ${TEST_XFS_CANCEL:-yes} != yes ]] || kill -TERM $$; }
umount(){ [[ ${TEST_UNMOUNT_FAIL:-no} != yes ]] || return 1;rm -f "$TEST_XFS_STATE/mounted";printf UMOUNT >"$TEST_XFS_STATE/unmounted"; }
trap 'rootpxe_capture_direct_stop_ack || true; exit 0' TERM
pxeapi=https://fixture/ taskid=4 task_token=fixture mac=fixture
if [[ ${TEST_XFS_CANCEL:-yes} == no ]];then
 if rootpxe_xfs_capture_preflight /dev/fixture;then
  [[ -z ${rootpxe_capture_xfs_mountpoint:-} && ! -e $TEST_XFS_STATE/mounted ]] || exit 1
  exit 0
 fi
 exit 1
fi
if rootpxe_xfs_capture_preflight /dev/fixture; then exit 9; else exit 9; fi
XFS
export TEST_CAPTURE_LIB="$tmp/capture-direct.sh" TEST_XFS_LIB="$tmp/xfs-preflight.sh" TEST_XFS_STATE="$tmp/xfs-state"
mkdir "$TEST_XFS_STATE"
TEST_XFS_CANCEL=no bash "$tmp/xfs-cancel.sh"
rm -f "$TEST_XFS_STATE/unmounted"
bash "$tmp/xfs-cancel.sh"
[[ -e $TEST_XFS_STATE/ack && -e $TEST_XFS_STATE/unmounted && ! -e $TEST_XFS_STATE/mounted ]] || fail cancelled-xfs-mount-left-before-ack
rm -f "$TEST_XFS_STATE/ack" "$TEST_XFS_STATE/unmounted"
TEST_UNMOUNT_FAIL=yes bash "$tmp/xfs-cancel.sh"
[[ ! -e $TEST_XFS_STATE/ack && -e $TEST_XFS_STATE/mounted ]] || fail failed-xfs-unmount-released-capture
# The failed mock leaves only an empty owned fixture directory, no real mount.
mock_mount=$(cat "$TEST_XFS_STATE/mounted");rmdir "$mock_mount"
# The real TERM cleanup must not wait for Enter before quiesce/ACK in debug mode.
cat >"$tmp/term-cleanup.sh" <<'TERM_CLEANUP'
set -u
set +m
. "$TEST_CAPTURE_LIB"
for function in killStatusReporter rootpxe_cleanup_session debugPause;do
 eval "$(sed -n "/^$function() {/,/^}/p" "$TEST_FUNCS_LIB")"
done
eval "$(sed -n '/^rootpxe_upload_cleanup_session() {/,/^}/p' "$TEST_UPLOAD_ENTRY")"
rootpxe_cleanup_smb_credentials(){ :; };rootpxe_cleanup_task_json(){ :; }
rootpxe_console_prompt(){ :; }
rootpxe_capture_direct=yes rootpxe_capture_released=no isdebug=yes
pxeapi=https://fixture/ taskid=4 task_token=fixture mac=fixture
sleep 120 & statusReporter=$!
writer_pids=()
all_pids=("$statusReporter")
for process in "${all_pids[@]}";do
 for iteration in {1..100};do [[ $(cat /proc/$process/comm 2>/dev/null || true) != sleep ]] || break;sleep 0.01;done
done
rootpxe_task_curl(){
 for process in "${all_pids[@]}";do ! kill -0 "$process" 2>/dev/null || return 1;done
 [[ ${rootpxe_capture_stopped:-no} == yes ]] || return 1
 printf ACK >>"$TEST_TERM_ACK"
 printf '{"accepted":true}'
}
trap rootpxe_upload_cleanup_session EXIT
trap 'rootpxe_upload_cleanup_session;exit 143' TERM
kill -TERM $$
exit 9
TERM_CLEANUP
export TEST_FUNCS_LIB="${PXEOS_CAPTURE_DIRECT_TEST_FUNCS_LIB:-$lib/funcs.sh}" TEST_UPLOAD_ENTRY="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.upload" TEST_TERM_ACK="$tmp/term-ack"
mkfifo "$tmp/term-input"
(
 exec {term_input_fd}<>"$tmp/term-input"
 term_fixture_pid=''
 trap 'if [[ -n $term_fixture_pid ]];then kill -TERM "$term_fixture_pid" 2>/dev/null || true;wait "$term_fixture_pid" 2>/dev/null || true;fi;exec {term_input_fd}>&-' EXIT
 term_status=0
 timeout -k 1 2 bash -c 'fd=$1;exec {fd}>&-;exec bash "$2"' fixture "$term_input_fd" "$tmp/term-cleanup.sh" <"$tmp/term-input" &
 term_fixture_pid=$!
 wait "$term_fixture_pid" || term_status=$?
 term_fixture_pid=''
 [[ $term_status == 143 && $(cat "$TEST_TERM_ACK" 2>/dev/null) == ACK ]] || fail "direct-TERM-cleanup-needed-Enter-or-ACK-not-after-wait: exit=$term_status"
)
# Legacy/deployment debug behavior remains interactive at the same call site.
(
 eval "$(sed -n '/^killStatusReporter() {/,/^}/p' "$lib/funcs.sh")"
 rootpxe_capture_direct=no statusReporter=123
 kill(){ :; };wait(){ :; };debugPause(){ printf legacy >"$tmp/legacy-pause"; }
 killStatusReporter
 [[ $(cat "$tmp/legacy-pause") == legacy ]] || fail legacy-sampler-cleanup-pause-changed
)
# Source the real direct mount entry with only the native mount replaced.
(
 sed "s|/storage|$tmp/storage|g" "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.mount" >"$tmp/direct-mount.sh"
 rootpxe_capture_direct=yes storage_server=192.0.2.1 storage_export=/capture-fixture
 mountpoint(){ return 1; }
 rootpxe_run_logged_typed_native(){ printf '%s\n' "$@" >"$tmp/mount-args"; }
 rootpxe_cleanup_smb_credentials(){ :; }
 for version in auto 4.1;do
  protocol=nfs rootpxe_capture_nfs_version=$version
  . "$tmp/direct-mount.sh"
  options=$(awk '$0=="-o" {getline;print;exit}' "$tmp/mount-args")
  [[ ,$options, == *,rw,* && ,$options, == *,proto=tcp,* && ,$options, == *,nolock,* ]] || fail "capture-NFS-missing-nolock-or-existing-flags: $version"
  if [[ $version == auto ]];then [[ ,$options, != *,vers=*, ]] || fail auto-version-policy-changed
  else [[ ,$options, == *,vers=4.1,* ]] || fail fixed-version-policy-changed;fi
 done
 protocol=smb storage_export=capture-fixture rootpxe_capture_smb_version=3.1.1 smb_credentials_file="$tmp/fixture-credentials"
 . "$tmp/direct-mount.sh"
 grep -Fxq mount.cifs "$tmp/mount-args" || fail SMB-mount-command-changed
 options=$(awk '$0=="-o" {getline;print;exit}' "$tmp/mount-args")
 [[ ,$options, == *,vers=3.1.1,* && ,$options, != *,nolock,* ]] || fail NFS-option-leaked-into-SMB
)
printf 'PASS: direct MAC prepare/retry/replace; real pipe child stop; error/finish ACK; XFS cleanup; debug TERM sampler-wait/quiesce/ACK without Enter\n'
