#!/usr/bin/env bash
# Exercise normal task display sources without disks, network, or a real task.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
funcs="$overlay/usr/share/pxeos/lib/funcs.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
umask 077
checks=0
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains(){ grep -Fq -- "$2" "$1" || fail "$3"; checks=$((checks+1)); }
absent(){ ! grep -Fq -- "$2" "$1" || fail "$3"; checks=$((checks+1)); }
. "$overlay/usr/share/pxeos/lib/message-format.sh"
for function in rootpxe_task_console_failure rootpxe_redact_diagnostic rootpxe_utf8_safe_prefix rootpxe_layout_apply_failed rootpxe_layout_readback_failed rootpxe_activate_lvm_vg; do
    eval "$(sed -n "/^${function}() {$/,/^}$/p" "$funcs")"
done
declare -A rootpxe_task_log_state=()
task_token=fixture-only-token
rootpxe_task_log_append(){ printf '%s\n' "$1" >>"$tmp/task.log"; }
rootpxe_console_message(){ printf '[%s] %s\n' "$1" "$2"; }
rootpxe_task_log_notice(){ printf '[INFO] Task log: available.\n'; }
rootpxe_run_logged_mutation(){
    printf '%s\n' "$*" >>"$tmp/native.trace"
    case " $* " in *' -ay '*) return 23;; *) return 0;; esac
}
if rootpxe_activate_lvm_vg fixture-vg-uuid vg_fixture >"$tmp/lvm.out" 2>&1; then
    fail 'LVM activation failure became success'
else
    status=$?
fi
[[ $status == 23 ]] || fail 'LVM activation status changed'
checks=$((checks+1))
contains "$tmp/lvm.out" '[ERROR] Volume group activation failed' 'LVM error did not use the short display'
absent "$tmp/lvm.out" 'vg_fixture' 'LVM group name leaked to the console'
contains "$tmp/task.log" 'Volume group activation failed: vg_fixture (exit 23).' 'LVM raw diagnostic was lost'
contains "$tmp/native.trace" ' -an ' 'LVM failure no longer deactivates the group'

rootpxe_cleanup_deployment_partition_file(){ printf 'layout-cleanup\n' >>"$tmp/layout.trace"; }
rootpxe_log_publish(){ return 0; }
rootpxe_stage(){ printf '%s|%s\n' "$1" "$2" >>"$tmp/stage.trace"; }
printf 'fixture native stderr\n' >"$tmp/sfdisk.stderr"
if rootpxe_layout_apply_failed SFDISK_WRITE_FAILED native_failure "$tmp/sfdisk.stderr" >"$tmp/layout.out" 2>&1; then
    fail 'layout failure became success'
else
    status=$?
fi
[[ $status == 1 ]] || fail 'layout failure status changed'
checks=$((checks+1))
contains "$tmp/layout.out" '[ERROR] Partition table write failed' 'layout did not use the short display'
absent "$tmp/layout.out" 'SFDISK_WRITE_FAILED' 'layout code leaked to the console'
absent "$tmp/layout.out" '/tmp/log/' 'layout diagnostic path leaked to the console'
layout_raw='Deployment layout apply failed: SFDISK_WRITE_FAILED (native_failure); diagnostics: /tmp/log/sfdisk-write.log'
contains "$tmp/task.log" "$layout_raw" 'layout raw diagnostic was lost'
contains "$tmp/stage.trace" "layout_apply|$layout_raw" 'layout stage callback original changed'
absent "$tmp/stage.trace" 'PXEOS_STAGE=' 'display diagnostic replaced the layout callback'
contains "$tmp/layout.trace" 'layout-cleanup' 'layout cleanup was skipped'

: >"$tmp/layout.trace"
if rootpxe_layout_readback_failed partition_geometry >"$tmp/readback.out" 2>&1; then
    fail 'layout readback failure became success'
else
    status=$?
fi
[[ $status == 1 ]] || fail 'layout readback failure status changed'
checks=$((checks+1))
[[ $rootpxe_layout_apply_code == LAYOUT_READBACK_FAILED ]] || fail 'layout readback code changed'
checks=$((checks+1))
[[ $rootpxe_layout_apply_reason == sfdisk_partition_geometry ]] || fail 'layout readback reason changed'
checks=$((checks+1))
contains "$tmp/readback.out" '[ERROR] Partition layout verification failed' 'layout readback did not use the short display'
absent "$tmp/readback.out" 'partition_geometry' 'layout readback reason leaked to the console'
contains "$tmp/task.log" 'Deployment layout readback mismatch: partition_geometry' 'layout readback raw diagnostic was lost'
contains "$tmp/stage.trace" 'layout_apply|Deployment layout readback mismatch: partition_geometry' 'layout readback callback original changed'
contains "$tmp/layout.trace" 'layout-cleanup' 'layout readback cleanup was skipped'

(
    type=up rootpxe_capture_resume_published=1 mc=no
    pxeapi=https://example.invalid/service/pxeos/ web=https://example.invalid/service/pxeos/
    taskid=9 task_token=fixture-only-token mac=001122334455
    rootpxe_require_task_context(){ return 0; }
    dmidecode(){ printf 'fixture-system-uuid\n'; }
    rootpxe_deployment_identity_policy_enabled(){ return 1; }
    rootpxe_task_curl(){
        printf '%s\n' "$@" >"$tmp/finish.args"
        printf '{"success":true}'
    }
    rootpxe_clear_capture_marker(){
        rootpxe_capture_marker_clear_error_reason=marker_remove_failed
        return 1
    }
    rootpxe_storage_recover_until_clean(){ printf 'storage-recovered\n' >>"$tmp/finish.trace"; }
    rootpxe_cleanup_task_json(){ printf 'task-json-cleanup\n' >>"$tmp/finish.trace"; }
    rootpxe_capture_resume_cleanup(){ printf 'capture-resume-cleanup\n' >>"$tmp/finish.trace"; }
    dots(){ printf 'dots:%s\n' "$*"; }
    debugPause(){ printf 'debug-pause\n' >>"$tmp/finish.trace"; }
    handleError(){ printf 'unexpected handleError:%s\n' "$*" >&2; exit 97; }
    usleep(){ printf 'unexpected wait:%s\n' "$*" >&2; exit 98; }
    . "$overlay/bin/pxeos.imgcomplete"
) >"$tmp/finish.out" 2>&1 || fail 'capture marker warning changed successful finish'
checks=$((checks+1))
contains "$tmp/finish.out" '[WARN] Storage cleanup is not confirmed. Retrying the original execution.' 'marker cleanup warning did not use the short display'
contains "$tmp/finish.out" '[INFO] Task complete.' 'marker cleanup warning hid task success'
absent "$tmp/finish.out" 'CODE=' 'marker cleanup code leaked to the console'
absent "$tmp/finish.out" '[ERROR]' 'marker cleanup warning became an error'
absent "$tmp/finish.out" 'unexpected' 'marker warning changed error or wait policy'
contains "$tmp/task.log" 'PXEOS_STAGE=finish_notify CODE=CAPTURE_MARKER_CLEAR_FAILED REASON=marker_remove_failed' 'marker raw diagnostic was lost'
contains "$tmp/finish.args" 'result=success' 'marker warning changed the finish result'
[[ $(grep -n -m1 storage-recovered "$tmp/finish.trace" | cut -d: -f1) -lt $(grep -n -m1 task-json-cleanup "$tmp/finish.trace" | cut -d: -f1) ]] || fail 'private context cleared before original storage recovery'
contains "$tmp/finish.trace" 'task-json-cleanup' 'marker warning skipped task cleanup'
contains "$tmp/finish.trace" 'capture-resume-cleanup' 'marker warning skipped resume cleanup'
printf 'PXEOS message sources: %s checks, 0 failures\n' "$checks"
