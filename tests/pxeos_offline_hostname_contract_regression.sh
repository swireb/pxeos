#!/usr/bin/env bash
# Exercise the production wrapper without a target disk or a real registry.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$tmp/ntfs/Windows/System32/config"
touch "$tmp/ntfs/Windows/System32/config/SYSTEM"
# Only the mount path is relocated; the wrapper body is copied verbatim.
awk '/^rootpxe_change_hostname_registry\(\)/ { found=1 } found { print } found && /^}/ { exit }' "$funcs" |
    sed "s|/ntfs|$tmp/ntfs|g" >"$tmp/wrapper.sh"
source "$tmp/wrapper.sh"
changeHostname=true hostName=AFTER inspect_failure=false write_paths_failure=false verify_failure=false
rootpxe-offline-identities(){
    if [[ $1 == windows-hostname-inspect ]]; then
        printf 'ControlSet001\nControlSet002\n'
        [[ $inspect_failure == false ]]
    elif [[ $1 == windows-hostname-write-paths ]]; then
        [[ $write_paths_failure == false ]] || return 1
        printf '%s\n' \
            '\ControlSet001\services\Tcpip\Parameters\NV Hostname' \
            '\ControlSet001\services\Tcpip\Parameters\Hostname' \
            '\ControlSet001\Control\ComputerName\ComputerName\ComputerName' \
            '\ControlSet002\SERVICES\TCPIP\PARAMETERS\nv hostname' \
            '\ControlSet002\SERVICES\TCPIP\PARAMETERS\HOSTNAME' \
            '\ControlSet002\CONTROL\COMPUTERNAME\COMPUTERNAME\computername'
    else
        printf 'verify\n' >>"$tmp/verify-calls"
        [[ $verify_failure == false ]]
    fi
}
reged(){
    local input
    input=$(</dev/stdin)
    printf '%s\n' "$input" >>"$tmp/reged-calls"
    [[ $input != *ActiveComputerName* ]] || return 3
    [[ $input == *ControlSet001* && $input == *ControlSet002* ]] || return 3
    return 2
}
rootpxe_change_hostname_registry /dev/fake || fail offline-hive-without-volatile-key
grep -Fq '\ControlSet001\services\Tcpip\Parameters\NV Hostname' "$tmp/reged-calls" || fail preserved-services-case
grep -Fq '\ControlSet002\SERVICES\TCPIP\PARAMETERS\HOSTNAME' "$tmp/reged-calls" || fail preserved-value-case
rm "$tmp/reged-calls"
rm -f "$tmp/verify-calls"
set +e
( set -e; rootpxe_change_hostname_registry /dev/fake )
errexit_rc=$?
set -e
[[ $errexit_rc -eq 0 ]] || fail reged-status-two-under-errexit
[[ -s $tmp/verify-calls ]] || fail reged-status-two-skipped-readback
rm -f "$tmp/reged-calls" "$tmp/verify-calls"
inspect_failure=true
if rootpxe_change_hostname_registry /dev/fake; then fail partial-inspection-accepted; fi
[[ $rootpxe_initialization_failure_reason == windows_hostname_hive_inspection_failed ]] || fail inspection-reason
[[ ! -e $tmp/reged-calls ]] || fail inspector-failure-started-write
inspect_failure=false verify_failure=true
if rootpxe_change_hostname_registry /dev/fake; then fail failed-readback-accepted; fi
[[ $rootpxe_initialization_failure_reason == windows_hostname_readback_failed ]] || fail readback-reason
verify_failure=false
rm -f "$tmp/reged-calls"
write_paths_failure=true
if rootpxe_change_hostname_registry /dev/fake; then fail incomplete-write-paths-accepted; fi
[[ $rootpxe_initialization_failure_reason == windows_hostname_hive_inspection_failed ]] || fail write-paths-reason
[[ ! -e $tmp/reged-calls ]] || fail write-paths-failure-started-write
write_paths_failure=false
reged(){ cat >/dev/null; return 3; }
if rootpxe_change_hostname_registry /dev/fake; then fail failed-write-accepted; fi
[[ $rootpxe_initialization_failure_reason == windows_hostname_registry_write_failed ]] || fail write-reason
for name in rootpxe_validate_windows_hostname rootpxe_apply_windows_hostname; do
    awk -v name="$name" '$0 ~ "^" name "\\(\\)" { found=1 } found {print} found && /^}/ {exit}' "$funcs" |
        sed -e "s|/tmp/ntfs-mount-output|$tmp/mount-output|g" -e "s|/ntfs|$tmp/ntfs|g" >>"$tmp/initialization.sh"
done
source "$tmp/initialization.sh"
rootpxe_stage(){ :; }
umount(){ return 0; }
ntfs-3g(){ return 1; }
if rootpxe_apply_windows_hostname /dev/fake; then fail mount-failure-accepted; fi
[[ $rootpxe_initialization_failure_reason == windows_system_mount_failed ]] || fail mount-reason
ntfs-3g(){ return 0; }
reged(){ cat >/dev/null; return 0; }
umount(){ return 1; }
if rootpxe_apply_windows_hostname /dev/fake; then fail unmount-failure-accepted; fi
[[ $rootpxe_initialization_failure_reason == windows_system_unmount_failed ]] || fail unmount-reason
umount(){ return 0; }
rootpxe_apply_windows_hostname /dev/fake || fail complete-hostname-initialization
[[ ${rootpxe_deployment_identity_hostname_result:-} == true && -z ${rootpxe_initialization_failure_reason:-} ]] || fail initialization-result
printf 'PASS: offline hostname wrapper contracts\n'
