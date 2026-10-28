#!/usr/bin/env bash
set -euo pipefail
umask 077
root=$(cd "$(dirname "$0")/.." && pwd)
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
tmp=$(mktemp -d /tmp/pxeos-cloud-init-permit.XXXXXX)
cleanup_fixture(){
    local cleanup_result=0
    [[ $tmp =~ ^/tmp/pxeos-cloud-init-permit\.[A-Za-z0-9]{6}$ && -d $tmp && ! -L $tmp ]] || return 1
    if declare -F rootpxe_cloud_init_cleanup_private >/dev/null; then rootpxe_cloud_init_cleanup_private || cleanup_result=1; fi
    rm -rf -- "$tmp" || cleanup_result=1
    return "$cleanup_result"
}
trap cleanup_fixture EXIT
. "$root/tests/storage-test-support.sh"
storage_test_load
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
case $(uname -s) in MINGW*|MSYS*) rootpxe_ci_fixture_jq=$(command -v jq.exe); jq(){ "$rootpxe_ci_fixture_jq" -b "$@"; };; esac
body(){ sed -n "/^$1() {\$/,/^}\$/p" "$funcs"; }
for function in rootpxe_clear_disk_permit rootpxe_disk_stable_identity rootpxe_plan_deploy_disk_operation rootpxe_plan_mpa_disk_permits rootpxe_request_disk_permit_for_target rootpxe_request_disk_permit_batch rootpxe_wait_for_disk_permit rootpxe_record_disk_permit_binding rootpxe_verify_disk_permit_binding rootpxe_bind_granted_deploy_targets; do
    eval "$(body "$function")"
done
declare -F rootpxe_bind_granted_deploy_targets >/dev/null || fail 'first-deploy binding entry is missing'
. "${funcs%/*}/cloud-init.sh"
. "${funcs%/*}/linux-hostname.sh"
. "${funcs%/*}/deployment-identity.sh"
case $(uname -s) in MINGW*|MSYS*)
    rootpxe_ci_is_root(){ return 0; }
    rootpxe_ci_stat(){ local owner=0 mode=700; [[ -d $1 ]] || mode=600; case $1 in /tmp/rootpxe-cloud-init.*|/tmp/rootpxe-cloud-meta.*|/tmp/rootpxe-cloud-network.*|/tmp/rootpxe-cloud-vendor.*) owner=$EUID;; esac; printf '%s:0:%s:%s\n' "$owner" "$mode" "$(command stat -c '%h' -- "$1")"; }
;; esac
# All target roots are private ordinary fixture files. A non-root Linux
# runner cannot chown them to image UID 0; emulate only that target metadata
# boundary, retaining real payload ownership/inode/hash checks and file I/O.
if [[ $EUID != 0 && ${OSTYPE:-} != msys* && ${OSTYPE:-} != cygwin* ]]; then
    rootpxe_ci_is_root(){ [[ $EUID == 0 || ( -n ${fixture_root:-} && ( ${root:-} == "$fixture_root" || ${root:-} == "$fixture_root/"* ) ) ]]; }
    rootpxe_ci_stat(){
        local info
        info=$(command stat -c '%u:%g:%a:%h' -- "$1") || return 1
        if [[ -n ${fixture_root:-} && ( $1 == "$fixture_root" || $1 == "$fixture_root/"* ) ]]; then
            printf '0:0:%s\n' "${info#*:*:}"
        else printf '%s\n' "$info"; fi
    }
    chown(){
        local target=${@: -1}
        if [[ $1 == 0:0 && -n ${fixture_root:-} && -O $target && ! -L $target && ( $target == "$fixture_root" || $target == "$fixture_root/"* ) ]]; then
            return 0
        fi
        command chown "$@"
    }
fi
rootpxe_require_task_context(){ return 0; }
rootpxe_storage_path(){ printf '%s\n' "$tmp"; }
readlink(){ if [[ $1 == -f && ${@: -1} == /dev/fixture* ]]; then printf '%s\n' "${@: -1}"; else command readlink "$@"; fi; }
stat(){ if [[ $1 == -c && $2 == %r && ${@: -1} == /dev/fixture* ]]; then printf '101\n'; else command stat "$@"; fi; }
rootpxe_ci_device_is_block(){ [[ $1 == /dev/fixture* ]]; }
udevadm(){ [[ $* == *'/dev/fixtureA'* ]] && printf 'ID_SERIAL=HW_A\n' || printf 'ID_SERIAL=HW_B\n'; }
blockdev(){ [[ $1 != --getss ]] && printf '4096\n' || printf '512\n'; }
rootpxe_plan_disk_operation(){ :; }
rootpxe_validate_image_sector_metadata(){ :; }
rootpxe_nvme_format_scope_prepare(){ :; }
rootpxe_task_curl(){ printf '{"granted":true,"targetId":"%s","operation":"%s"}\n200' "$rootpxe_planned_target_id" "$rootpxe_planned_disk_operation"; }
rootpxe_fixed_restore_disk_facts(){ printf '1|4096\n'; }
pxeapi=https://fixture.invalid/ taskid=1 task_token=private mac=001122334455 type=down mc=no
printf 'sector-size: 512\n' >"$tmp/d1.partitions"
printf 'fixture' >"$tmp/d1.mbr"
for mode in network-only vendor-only single mpa; do
    unset rootpxe_disk_permit_disk_map_file rootpxe_disk_permit_bindings_file
    hd=/dev/fixtureA disks=/dev/fixtureA imgType=$mode
    [[ $mode != network-only && $mode != vendor-only ]] || imgType=single
    fixture_root="$tmp/target-$mode"
    mkdir -p "$fixture_root/etc/cloud" "$fixture_root/usr/bin" "$fixture_root/var/lib/cloud"
    printf '#!/bin/sh\nexit 99\n' >"$fixture_root/usr/bin/cloud-init"
    chmod +x "$fixture_root/usr/bin/cloud-init"
    printf '# image prepared by cloud-init\n' >"$fixture_root/etc/cloud/cloud.cfg"
    printf 'original-hostname\n' >"$fixture_root/etc/hostname"
    taskType=deploy osid=50
    userdata=$'#cloud-config\n# 不执行\nruncmd: []\n'
    network='' network_hash='' vendor='' vendor_hash=''
    if [[ $mode == network-only || $mode == mpa ]]; then
        [[ $mode != network-only ]] || userdata=''
        network=$'version: 2\r\nethernets:\r\n  enp1s0:\r\n    dhcp4: true\r\n'
        printf '%s' "$network" >"$tmp/network-$mode"
        network_hash=$(rootpxe_ci_hash "$tmp/network-$mode")
    fi
    if [[ $mode == vendor-only || $mode == mpa ]]; then
        vendor=$'#cloud-config\r\n# 供应方配置不得执行或输出\r\nruncmd: []\r\n'
        printf '%s' "$vendor" >"$tmp/vendor-$mode"
        vendor_hash=$(rootpxe_ci_hash "$tmp/vendor-$mode")
    fi
    printf '%s' "$userdata" >"$tmp/data-$mode"
    hash=$(rootpxe_ci_hash "$tmp/data-$mode")
    metadata=$'instance-id: "manual-frozen-instance"\r\nlocal-hostname: image-name\r\n'
    printf '%s' "$metadata" >"$tmp/meta-$mode"
    meta_hash=$(rootpxe_ci_hash "$tmp/meta-$mode")
    payload=$(jq -cn --arg data "$userdata" --arg hash "$hash" --arg meta "$metadata" --arg metaHash "$meta_hash" --arg network "$network" --arg networkHash "$network_hash" --arg vendor "$vendor" --arg vendorHash "$vendor_hash" '{type:"deploy",osid:50,cloudInitUserData:$data,cloudInitUserDataSha256:$hash,cloudInitMetaData:$meta,cloudInitMetaDataSha256:$metaHash,cloudInitNetworkConfig:$network,cloudInitNetworkConfigSha256:$networkHash,cloudInitVendorData:$vendor,cloudInitVendorDataSha256:$vendorHash}')
    # source 真实 checkin 主流程，只替换绝对库位置、控制面与设备盘点边界。
    checkin_copy="$tmp/checkin-$mode"
    awk '/^\. \/usr\/share\// {print ":"; next} /(^|[[:space:]])pxeos_checkin_runtime_setup$/ {print ":"; next} {print}' "${funcs%/usr/share/*}/bin/pxeos.checkin" >"$checkin_copy"
    checkin_body=$(jq -c '.taskId=1 | .executionToken="private" | .pxeType="down" | .img="fixture" | .imgType="mps" | .imgPartitionType="all" | .imgFormat=5 | .compressionLevel=6 | .shutdown=false | .changeHostname=false | .protocol="nfs" | .storageip="192.0.2.1" | .exportPath="/fixture" | .deploymentIdentityPolicy={version:1,systemIdentity:{sysprep:false},cloudInit:true}' <<<"$payload")
    checkin_body=$(storage_test_context_json "$checkin_body") || fail 'current storage fixture context'
    storage_test_reset_context || fail 'isolated storage context cleanup'
    storage_test_patch_parser "$checkin_copy"
    rootpxe_task_curl(){ printf '%s\n200' "$checkin_body"; }
    rootpxe_console_message(){ :; }
    rootpxe_require_identity(){ :; }
    rootpxe_multicast_reset(){ :; }
    rootpxe_multicast_apply_transport_mode(){ :; }
    rootpxe_multicast_runtime_ready(){ return 1; }
    rootpxe_deployment_identity_windows_hostname_capability_installed(){ return 1; }
    rootpxe_deployment_identity_windows_sysprep_capability_installed(){ return 1; }
    rootpxe_deployment_identity_linux_hostname_capability_installed(){ return 0; } # 仅模拟已配齐工具的PXEOS，非宿主MSYS能力。
    rootpxe_validate_smb_export(){ printf '%s' "$1"; }
    rootpxe_prepare_smb_credentials(){ :; }
    rootpxe_send_disk_health(){ :; }
    rootpxe_safe_relative_path(){ printf '%s' "$1"; }
    rootpxe_normalize_mac(){ printf '%s' "$1"; }
    rootpxe_cleanup_session(){ rootpxe_cloud_init_cleanup_private; }
    dmidecode(){ printf '00000000-0000-0000-0000-000000000000'; }
    debugPause(){ :; }
    rootpxe_stage(){ :; }
    capone=0 rootpxe_api=https://fixture.invalid/ storageip='' export_path='' macWinSafe=001122334455
    . "$checkin_copy" || fail "$mode real sourced checkin"
    if [[ $mode == network-only ]]; then [[ -n ${cloudInitNetworkConfigFile:-} ]] || fail 'real sourced network-only checkin lost private network file'; fi
    if [[ $mode == vendor-only || $mode == mpa ]]; then [[ -n ${cloudInitVendorDataFile:-} ]] || fail 'real sourced vendor checkin lost private vendor file'; fi
    trap cleanup_fixture EXIT
    trap - INT TERM
    if [[ $mode == network-only ]]; then
        no_policy=$(jq -c 'del(.deploymentIdentityPolicy)' <<<"$checkin_body")
        storage_test_reset_context || fail 'isolated missing-policy context cleanup'
        rootpxe_apply_json_checkin "$no_policy" >"$tmp/checkin-rejection" 2>&1 && fail 'real checkin accepted network payload without frozen identity policy'
        [[ ! -s $tmp/checkin-rejection ]] || fail 'real checkin rejection leaked network data'
        [[ -z ${cloudInitUserDataFile:-} && -z ${cloudInitNetworkConfigFile:-} && -z ${rootpxe_disk_permit_disk_map_file:-} && ! -e $fixture_root/var/lib/cloud/seed ]] || fail 'missing-policy checkin reached private handles, permission or installer'
        storage_test_apply_json_checkin "$checkin_body" || fail 'real checkin could not restore complete frozen policy'
    fi
    imgType=$mode
    [[ $mode != network-only && $mode != vendor-only ]] || imgType=single
    rootpxe_task_curl(){ printf '%s\n' "$@" >"$tmp/permit-request"; printf '{"granted":true,"targetId":"%s","operation":"%s"}\n200' "$rootpxe_planned_target_id" "$rootpxe_planned_disk_operation"; }
    if [[ $mode == mpa ]]; then rootpxe_plan_mpa_disk_permits "$tmp" || fail 'MPA1 planning failed'; else rootpxe_plan_deploy_disk_operation "$hd" "$tmp/d1.partitions"; fi
    rootpxe_wait_for_disk_permit "$rootpxe_planned_target_id" "$rootpxe_planned_disk_operation" || fail 'real scalar grant failed'
    grep -Fqx 'cloudInitCapability=linux-nocloud-v5' "$tmp/permit-request" || fail 'real disk permit request used obsolete capability'
    grep -Fqx 'deploymentIdentityProtocolVersions=[1]' "$tmp/permit-request" || fail 'permit protocol versions missing'
    capabilities=$(sed -n 's/^deploymentIdentityCapabilities=//p' "$tmp/permit-request")
    jq -e 'type=="array" and index("linux-hostname-offline-v1")!=null' <<<"$capabilities" >/dev/null || fail 'permit offline hostname capability missing'
    rootpxe_bind_granted_deploy_targets || fail "$mode permit map not registered"
    rootpxe_verify_disk_permit_binding "$hd" deploy_write || fail "$mode real verify failed"
    phase_file="$tmp/phases-$mode"
    rootpxe_find_linux_root_filesystem(){ printf '/dev/fixtureAp1|ext4|||\n'; }
    rootpxe_ci_mount_root(){ ci_mounted_root="$fixture_root"; printf '%s\n' "$4" >>"$phase_file"; }
    mountpoint(){ return 1; }
    rootpxe_stage(){ :; }
    rootpxe_apply_cloud_init || fail "$mode real NoCloud installer/permit chain"
    [[ $(<"$tmp/phases-$mode") == $'ro\nrw' ]] || fail 'read-only preflight must precede the only write mount'
    cmp -s "$tmp/data-$mode" "$fixture_root/var/lib/cloud/seed/nocloud/user-data" || fail "$mode seed bytes"
    cmp -s "$tmp/meta-$mode" "$fixture_root/var/lib/cloud/seed/nocloud/meta-data" || fail "$mode manual metadata bytes"
    expected_files=2
    if [[ -n $network_hash ]]; then
        cmp -s "$tmp/network-$mode" "$fixture_root/var/lib/cloud/seed/nocloud/network-config" || fail 'network-only raw bytes'
        expected_files=$((expected_files + 1))
    else [[ ! -e $fixture_root/var/lib/cloud/seed/nocloud/network-config ]] || fail 'empty network generated a seed file'; fi
    if [[ -n $vendor_hash ]]; then
        cmp -s "$tmp/vendor-$mode" "$fixture_root/var/lib/cloud/seed/nocloud/vendor-data" || fail 'vendor-data raw bytes'
        expected_files=$((expected_files + 1))
    else [[ ! -e $fixture_root/var/lib/cloud/seed/nocloud/vendor-data ]] || fail 'empty vendor generated a seed file'; fi
    [[ $(find "$fixture_root/var/lib/cloud/seed/nocloud" -maxdepth 1 -type f | wc -l) == "$expected_files" ]] || fail "$mode expected seed file count"
    [[ $(<"$fixture_root/etc/hostname") == original-hostname ]] || fail 'offline Linux hostname changed'
    [[ $rootpxe_deployment_identity_cloud_init_result == true ]] || fail "$mode injection receipt not set"
    rootpxe_apply_json_cloud_init "$payload" || fail 'same-task private response'
    rootpxe_apply_cloud_init || fail 'same-task readonly NoCloud receipt'
    [[ $(<"$phase_file") == $'ro\nrw\nro' ]] || fail 'same seed mounted writable'
    mkdir "$fixture_root/var/lib/cloud/instances"
    rootpxe_apply_json_cloud_init "$payload" || fail 'cache fixture private response'
    rootpxe_apply_cloud_init && fail 'cached image accepted'
    [[ $rootpxe_cloud_init_error == cloud_init_cache_not_clean && $(<"$phase_file") == $'ro\nrw\nro\nro' ]] || fail 'cache did not fail in readonly preflight'
    rootpxe_cloud_init_cleanup_private
    rootpxe_verify_disk_permit_binding /dev/fixtureB deploy_write && fail 'wrong disk accepted'
    rootpxe_verify_disk_permit_binding "$hd" capture_read_write && fail 'wrong operation accepted'
    printf 'corrupt\n' >"$rootpxe_disk_permit_disk_map_file"
    rootpxe_verify_disk_permit_binding "$hd" deploy_write && fail 'corrupt map accepted'
    rm -- "$rootpxe_disk_permit_disk_map_file"
    rootpxe_verify_disk_permit_binding "$hd" deploy_write && fail 'missing map accepted'
done
rootpxe_task_curl(){ printf '%s\n' "$@" >"$tmp/batch-request"; printf '{"granted":true,"targets":[{"targetId":"ID_A","operation":"deploy_write"},{"targetId":"ID_B","operation":"deploy_write"}]}\n200'; }
rootpxe_request_disk_permit_batch ID_A deploy_write ID_B deploy_write || fail 'real batch capability request rejected'
grep -Fqx 'cloudInitCapability=linux-nocloud-v5' "$tmp/batch-request" || fail 'batch permit capability missing'
grep -Fqx 'deploymentIdentityProtocolVersions=[1]' "$tmp/batch-request" || fail 'batch permit identity protocol missing'
batch_capabilities=$(sed -n 's/^deploymentIdentityCapabilities=//p' "$tmp/batch-request")
[[ $batch_capabilities == "$capabilities" ]] || fail 'batch/scalar capabilities diverged'
[[ $rootpxe_disk_permit_bindings_file =~ ^/tmp/rootpxe-disk-permits\.[A-Za-z0-9]{6}$ && -f $rootpxe_disk_permit_bindings_file && ! -L $rootpxe_disk_permit_bindings_file ]] || fail 'batch fixture binding path unsafe'
rm -- "$rootpxe_disk_permit_bindings_file"
unset rootpxe_disk_permit_bindings_file
eval "$(declare -f rootpxe_deployment_identity_capabilities_json | sed '1s/rootpxe_deployment_identity_capabilities_json/rootpxe_ci_fixture_capabilities_json/')"
rootpxe_deployment_identity_capabilities_json(){ printf '["hostname",false]\n'; }
rootpxe_task_curl(){ fail 'malformed capability arrays reached HTTP or permission grant'; }
rootpxe_request_disk_permit_for_target ID_A deploy_write >"$tmp/malformed-caps" 2>&1 && fail 'scalar accepted malformed capabilities'
rootpxe_request_disk_permit_batch ID_A deploy_write ID_B deploy_write >>"$tmp/malformed-caps" 2>&1 && fail 'batch accepted malformed capabilities'
[[ ! -s $tmp/malformed-caps && -z ${rootpxe_disk_permit_bindings_file:-} ]] || fail 'malformed capability response leaked data or permission'
unset -f rootpxe_deployment_identity_capabilities_json
eval "$(declare -f rootpxe_ci_fixture_capabilities_json | sed '1s/rootpxe_ci_fixture_capabilities_json/rootpxe_deployment_identity_capabilities_json/')"
rootpxe_find_linux_root_filesystem(){ fail 'empty configuration attempted root/seed inspection'; }
unset deploymentIdentityPolicyFile
for taskType in deploy capture; do osid=50; rootpxe_apply_cloud_init || fail 'empty Linux/capture bypass'; done
printf 'PASS: real v5 JSON checkin, empty/three/four seed files, first single/MPA1 plan-grant-record-verify; disk/map rejection and empty bypass\n'
