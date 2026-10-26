#!/usr/bin/env bash
# 仅使用私有普通文件与设备/XML边界替身，不执行模板正文或目标程序。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
funcs="$lib/funcs.sh"
checkin="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.checkin"
tmp=$(mktemp -d /tmp/pxeos-template-injection.XXXXXX)
cleanup_fixture(){
    [[ $tmp =~ ^/tmp/pxeos-template-injection\.[A-Za-z0-9]{6}$ && -d $tmp && ! -L $tmp ]] || return 1
    rootpxe_cloud_init_cleanup_private || return 1
    rm -rf -- "$tmp"
}
trap cleanup_fixture EXIT
. "$root/tests/storage-test-support.sh"
storage_test_load
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
case $(uname -s) in MINGW*|MSYS*) jq_real=$(command -v jq.exe); jq(){ "$jq_real" -b "$@"; };; esac
. "$lib/cloud-init.sh"
. "$lib/linux-hostname.sh"
. "$lib/deployment-identity.sh"
case $(uname -s) in MINGW*|MSYS*)
    rootpxe_ci_stat(){ printf '%s:0:600:%s\n' "$EUID" "$(command stat -c '%h' -- "$1")"; }
    printf 'SKIP: MSYS native private owner/mode; inode/hash/link checks remain real\n'
;; esac
for name in rootpxe_validate_windows_hostname rootpxe_resolve_casefold_directory rootpxe_resolve_windows_sysprep_unattend_path rootpxe_apply_windows_hostname completeTasking; do
    sed -n "/^$name() {\$/,/^}\$/p" "$funcs" |
        sed -e "s|/ntfs|$tmp/ntfs|g" -e 's|\. /bin/pxeos.imgcomplete|rootpxe_fixture_imgcomplete|g' >>"$tmp/functions"
done
. "$tmp/functions"
awk '/^rootpxe_json_get_string\(\)/,/^checkin_rootpxe\(\)/{if($0 ~ /^checkin_rootpxe\(\)/) exit; print}' "$checkin" >"$tmp/parser"
storage_test_patch_parser "$tmp/parser"
. "$tmp/parser"
rootpxe_stage(){ :; }
rootpxe_run_logged_typed_native(){ shift 2; "$@"; }
rootpxe_multicast_apply_transport_mode(){ :; }
rootpxe_multicast_runtime_ready(){ return 1; }
rootpxe_deployment_identity_windows_hostname_capability_installed(){ return 0; }
rootpxe_deployment_identity_windows_sysprep_capability_installed(){ return 0; }
rootpxe_deployment_identity_linux_hostname_capability_installed(){ return 0; }
write_linux_payload(){
    taskType=deploy osid=50 changeHostname=true hostName=TASK-NAME
    printf '{"version":1,"systemIdentity":{"sysprep":false},"cloudInit":true}\n' >"$tmp/policy"
    deploymentIdentityPolicyFile="$tmp/policy"
    printf 'instance-id: fixed-operator-id\nlocal-hostname: fixed.example\ncustom-key: allowed-native-metadata\n' >"$tmp/meta"
    printf '#cloud-config\nhostname: fixed-user-name\npreserve_hostname: true\n' >"$tmp/user"
    printf '#cloud-config\nhostname: fixed-vendor-name\n' >"$tmp/vendor"
    [[ ${1:-} != empty ]] || : >"$tmp/user"
    payload=$(jq -cn --rawfile data "$tmp/user" --rawfile meta "$tmp/meta" --rawfile vendor "$tmp/vendor" \
        --arg hash "$(rootpxe_ci_hash "$tmp/user")" --arg metaHash "$(rootpxe_ci_hash "$tmp/meta")" --arg vendorHash "$(rootpxe_ci_hash "$tmp/vendor")" \
        '{type:"deploy",osid:50,cloudInitUserData:$data,cloudInitUserDataSha256:$hash,cloudInitMetaData:$meta,cloudInitMetaDataSha256:$metaHash,cloudInitVendorData:$vendor,cloudInitVendorDataSha256:$vendorHash,cloudInitNetworkConfig:"",cloudInitNetworkConfigSha256:""}')
}
test_capabilities(){
    taskid=1 task_token=private-token lmac=001122334455
    rootpxe_write_checkin_json_payload "$tmp/request" || fail 'template checkin request rejected'
    jq -e '.cloudInitCapability=="linux-nocloud-v5" and (.deploymentIdentityCapabilities|index("windows-sysprep-template-v2")!=null) and (.deploymentIdentityCapabilities|index("windows-sysprep-v1")==null)' "$tmp/request" >/dev/null || fail 'template capability versions missing or obsolete'
    [[ $(grep -Fc 'cloudInitCapability=linux-nocloud-v5' "$funcs") == 2 ]] || fail 'scalar/batch template capabilities diverged'
}
test_windows(){
    mkdir -p "$tmp/source/Windows/System32/Sysprep"
    printf '{"version":1,"systemIdentity":{"sysprep":true},"cloudInit":false}\n' >"$tmp/policy"
    deploymentIdentityPolicyFile="$tmp/policy"
    rootpxe_deployment_initialization_private_file="$tmp/private"
    changeHostname=true hostName=TASK-NAME
    ntfs-3g(){ mkdir -p "${@: -1}"; cp -a "$tmp/source/." "${@: -1}/"; }
    umount(){ return 0; }
    rootpxe_change_hostname_registry(){ fail 'Sysprep template reached registry naming'; }
    xml(){
        printf '%s\n' "$1" >>"$tmp/xml-calls"
        case $1 in
            val) [[ ${XML_FAIL:-} != yes ]];;
            sel) if [[ $* == *'count('* ]]; then printf 'amd64|1\n'; else printf '%s\n' "$hostName"; fi;;
            ed) printf '<unattend>client-forced-name</unattend>' >"${@: -1}";;
            *) return 1;;
        esac
    }
    for shape in fixed missing; do
        if [[ $shape == fixed ]]; then
            frozen='<unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"><ComputerName>FIXED-NAME</ComputerName></component></settings></unattend>'
        else frozen='<unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"/></settings></unattend>'; fi
        printf '%s' "$frozen" >"$tmp/expected.xml"
        jq -cn --arg xml "$frozen" '{version:1,unattendXml:$xml}' >"$tmp/private"
        rootpxe_deployment_identity_hostname_result=true rootpxe_deployment_identity_sysprep_result=false
        rootpxe_apply_windows_hostname "$tmp/source" || fail "$shape frozen XML injection rejected"
        cmp -s "$tmp/expected.xml" "$tmp/ntfs/Windows/System32/Sysprep/unattend.xml" || fail 'fixed ComputerName or missing-name template was overwritten'
        [[ $rootpxe_deployment_identity_hostname_result == false && $rootpxe_deployment_identity_sysprep_result == true ]] || fail 'template XML fabricated hostname receipt'
    done
    ! grep -Eq '^(sel|ed)$' "$tmp/xml-calls" || fail 'frozen XML was selected/edited for a client name'
    hostName='ignored.management.fqdn'
    rootpxe_apply_windows_hostname "$tmp/source" || fail 'fixed template validated unused management hostname'
    XML_FAIL=yes
    rootpxe_apply_windows_hostname "$tmp/source" && fail 'invalid XML template accepted'
    return 0
}
test_linux_freeze(){
    write_linux_payload
    rootpxe_apply_json_cloud_init "$payload" || fail 'fixed instance-id/native metadata rejected'
    cmp -s "$tmp/user" "$cloudInitUserDataFile" && cmp -s "$tmp/vendor" "$cloudInitVendorDataFile" && cmp -s "$tmp/meta" "$cloudInitMetaDataFile" || fail 'client rendered frozen Linux files'
    rootpxe_cloud_init_install_for_targets(){ return 0; }
    rootpxe_deployment_identity_hostname_result=true
    rootpxe_apply_cloud_init || fail 'frozen Linux injection rejected'
    [[ $rootpxe_deployment_identity_hostname_result == false && $rootpxe_deployment_identity_cloud_init_result == true ]] || fail 'Cloud template fabricated hostname receipt'
}
test_linux_empty(){
    write_linux_payload empty
    rootpxe_apply_json_cloud_init "$payload" || fail 'name switch required platform user-data fields'
    [[ -f $cloudInitUserDataFile && ! -s $cloudInitUserDataFile ]] || fail 'empty frozen user-data changed'
}
test_checkin(){
    write_linux_payload empty
    response=$(jq -c '.taskId=1 | .executionToken="private" | .pxeType="down" | .img="fixture" | .imgType="mps" | .imgPartitionType="all" | .imgFormat=5 | .compressionLevel=6 | .shutdown=false | .changeHostname=true | .hostName="ignored.management.fqdn" | .protocol="nfs" | .storageip="192.0.2.1" | .exportPath="/fixture" | .deploymentIdentityPolicy={version:1,systemIdentity:{sysprep:false},cloudInit:true}' <<<"$payload")
    rootpxe_linux_hostname_task_valid(){ fail 'Cloud template checked unused management hostname'; }
    storage_test_apply_json_checkin "$response" || fail 'frozen checkin rejected independent template names'
    cmp -s "$tmp/meta" "$cloudInitMetaDataFile" || fail 'checkin rewrote fixed instance-id'
}
test_dispatch(){
    write_linux_payload
    type=down capone=0 hd=/dev/fixture disks=/dev/fixture
    rootpxe_deployment_identity_sysprep_result=false
    killStatusReporter(){ :; }
    rootpxe_partition_progress_flush(){ :; }
    rootpxe_deployment_identity_request_plan(){ :; }
    rootpxe_deployment_identity_request_private(){ fail 'Linux requested Windows template'; }
    rootpxe_apply_hostname_for_disk(){ printf 'forbidden\n' >>"$tmp/hostname-calls"; }
    rootpxe_apply_cloud_init(){ rootpxe_deployment_identity_hostname_result=false; rootpxe_deployment_identity_cloud_init_result=true; }
    rootpxe_deployment_identity_report_result(){ [[ $1 == false && $2 == false && $3 == true ]] || fail 'restore template receipt changed'; }
    rootpxe_fixture_imgcomplete(){ :; }
    handleError(){ fail "$*"; }
    completeTasking || fail 'template restore completion rejected'
    [[ ! -e $tmp/hostname-calls ]] || fail 'restore tail called independent hostname branch for Cloud template'
}
case ${1:-all} in
    all) test_capabilities; test_windows; test_linux_empty; test_linux_freeze; test_checkin; test_dispatch;;
    caps) test_capabilities;;
    windows) test_windows;;
    linux-empty) test_linux_empty;;
    linux-freeze) test_linux_freeze;;
    checkin) test_checkin;;
    dispatch) test_dispatch;;
    *) fail 'unknown scenario';;
esac
printf 'PASS: frozen template injection %s\n' "${1:-all}"
