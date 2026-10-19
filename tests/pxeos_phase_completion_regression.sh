#!/usr/bin/env bash
# Only simulated leaves: no disks, mounts, service or network callbacks.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
tmp=$(mktemp -d /tmp/rootpxe-phase-completion.XXXXXX)
cleanup_fixture() {
    [[ $tmp =~ ^/tmp/rootpxe-phase-completion\.[[:alnum:]]{6}$ && -d $tmp && ! -L $tmp ]] || return 1
    rm -rf -- "$tmp"
}
trap cleanup_fixture EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
source "$overlay/usr/share/pxeos/lib/cloud-init.sh"
source "$overlay/usr/share/pxeos/lib/linux-hostname.sh"
trace="$tmp/trace"
rootpxe_stage(){ printf '%s|%s\n' "$1" "$2" >>"$trace"; }
rootpxe_linux_hostname_task_valid(){ return 0; }
rootpxe_cloud_init_policy_enabled(){ return 1; }
rootpxe_validate_linux_hostname(){ return 0; }
rootpxe_linux_select_unique_root_for_targets(){ rootpxe_linux_selected_disk=fixture; rootpxe_linux_selected_candidate=fixture; }
rootpxe_verify_disk_permit_binding(){ return 0; }
rootpxe_linux_hostname_process_root(){ [[ $hostname_failure == no ]] || return 1; rootpxe_linux_hostname_verified=$hostname_verified; }
hostName=fixture hostname_failure=no hostname_verified=no
rootpxe_apply_linux_hostname_for_targets fixture
grep -qx 'customizing_hostname|Linux hostname configured' "$trace" || fail hostname_success_completion_missing
hostname_verified=yes
: >"$trace"
rootpxe_apply_linux_hostname_for_targets fixture
grep -qx 'customizing_hostname|Linux hostname configured' "$trace" || fail verified_hostname_completion_missing
hostname_failure=yes
: >"$trace"
if rootpxe_apply_linux_hostname_for_targets fixture; then fail hostname_failure_accepted; fi
! grep -q 'Linux hostname configured' "$trace" || fail hostname_failure_completed
rootpxe_cloud_init_configured(){ [[ $cloud_enabled == yes ]]; }
rootpxe_cloud_init_private_valid(){ return 0; }
rootpxe_cloud_init_install_for_targets(){ [[ $cloud_failure != install ]]; }
rootpxe_cloud_init_cleanup_private(){ [[ $cloud_failure != cleanup ]]; }
taskType=deploy osid=50 cloud_enabled=yes cloud_failure=no disks=fixture
: >"$trace"
rootpxe_apply_cloud_init
grep -qx 'cloud_init|Cloud-init configuration installed' "$trace" || fail cloud_success_completion_missing
for cloud_failure in install cleanup; do
    : >"$trace"
    if rootpxe_apply_cloud_init; then fail cloud_failure_accepted; fi
    ! grep -q 'Cloud-init configuration installed' "$trace" || fail cloud_failure_completed
done
cloud_enabled=no cloud_failure=no
: >"$trace"
rootpxe_apply_cloud_init
[[ ! -s $trace ]] || fail disabled_cloud_completed
mkdir "$tmp/image"
printf '{}\n' >"$tmp/inventory"
run_imgcomplete(){ (
    dmidecode(){ printf 'fixture-uuid\n'; }
    rootpxe_require_task_context(){ return 0; }
    rootpxe_deployment_identity_policy_enabled(){ return 1; }
    rootpxe_build_partition_inventory(){ rootpxe_partition_inventory_file="$tmp/inventory"; }
    rootpxe_capture_publish_metadata(){ return 0; }
    rootpxe_finalize_capture(){ [[ $capture_failure == no ]]; }
    handleError(){ printf 'error\n' >>"$trace"; exit 77; }
    rootpxe_task_curl(){ printf 'finish\n' >>"$trace"; printf '{"success":true}\n'; }
    rootpxe_clear_capture_marker(){ return 0; }
    rootpxe_cleanup_task_json(){ :; }
    rootpxe_capture_resume_cleanup(){ :; }
    rootpxe_console_message(){ :; }
    dots(){ :; }
    debugPause(){ :; }
    taskid=71 task_token=fixture mac=fixture web=fixture type=up imgType=P hd=fixture imagePath="$tmp/image" mc=no
    source "$overlay/bin/pxeos.imgcomplete"
); }
capture_failure=no rootpxe_capture_resume_published=0
: >"$trace"
run_imgcomplete
grep -qx 'finalizing|captured image finalized' "$trace" || fail capture_success_completion_missing
[[ $(grep -n 'captured image finalized' "$trace" | cut -d: -f1) -lt $(grep -n '^finish$' "$trace" | cut -d: -f1) ]] || fail capture_completion_after_finish
capture_failure=yes
: >"$trace"
if run_imgcomplete; then fail capture_failure_accepted; fi
! grep -q 'captured image finalized\|^finish$' "$trace" || fail capture_failure_completed
capture_failure=no rootpxe_capture_resume_published=1
: >"$trace"
run_imgcomplete
grep -qx 'finalizing|captured image finalized' "$trace" || fail verified_published_resume_completion_missing
[[ $(grep -n 'captured image finalized' "$trace" | cut -d: -f1) -lt $(grep -n '^finish$' "$trace" | cut -d: -f1) ]] || fail resume_completion_after_finish
printf 'PASS: phase completion 10 simulated success/failure/order cases\n'
