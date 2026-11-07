#!/usr/bin/env bash
# Exercise Windows path resolution and system-volume selection with local
# directory fixtures only; no block device or real mount is used.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_fail(){ if "$@" >/dev/null 2>&1; then fail "expected rejection: $*"; fi; }
for name in rootpxe_resolve_casefold_directory rootpxe_resolve_casefold_file rootpxe_resolve_windows_system_hive rootpxe_resolve_windows_sysprep_unattend_path rootpxe_find_windows_system_partition rootpxe_validate_windows_hostname rootpxe_apply_windows_hostname; do
    awk -v name="$name" '$0 ~ "^" name "\\(\\)" { found=1 } found {print} found && /^}/ {exit}' "$funcs" |
        sed "s|/ntfs|$tmp/ntfs|g" >>"$tmp/functions.sh"
done
source "$tmp/functions.sh"

# The production probe sees NTFS partitions, but its mounts are directory copies.
getPartitions(){ parts=$probe_parts; }
fsTypeSetting(){ fstype=ntfs; }
rootpxe_run_logged_typed_native(){ shift 2; "$@"; }
ntfs-3g(){
    [[ $1 == -o && $2 == ro && $4 == "$tmp/ntfs" ]] || return 1
    cp -a "$3/." "$4/"
}
umount(){
    [[ $1 == "$tmp/ntfs" ]] || return 1
    find "$tmp/ntfs" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}
mkdir -p "$tmp/volumes/system/wInDoWs/sYsTeM32/cOnFiG" "$tmp/volumes/recovery/Recovery/WindowsRE"
touch "$tmp/volumes/system/wInDoWs/sYsTeM32/cOnFiG/sYsTeM"
probe_parts="$tmp/volumes/recovery $tmp/volumes/system"
selected=$(rootpxe_find_windows_system_partition /dev/fake) || fail mixed-case-system-volume-not-found
[[ $selected == "$tmp/volumes/system" ]] || fail recovery-selected-as-system

probe_parts="$tmp/volumes/recovery"
rc=0; rootpxe_find_windows_system_partition /dev/fake >/dev/null || rc=$?
[[ $rc -eq 10 ]] || fail no-candidate-status
mkdir -p "$tmp/volumes/second/Windows/System32/config"
touch "$tmp/volumes/second/Windows/System32/config/SYSTEM"
probe_parts="$tmp/volumes/system $tmp/volumes/second"
rc=0; rootpxe_find_windows_system_partition /dev/fake >/dev/null || rc=$?
[[ $rc -eq 11 ]] || fail ambiguous-system-volume-status

for variant in Windows/System32/config/SYSTEM Windows/System32/config/system windows/system32/config/system WINDOWS/SYSTEM32/CONFIG/SYSTEM wInDoWs/sYsTeM32/cOnFiG/sYsTeM; do
    fixture="$tmp/paths/${variant//\//-}"
    mkdir -p "$fixture/${variant%/*}"
    touch "$fixture/$variant"
    resolved=$(rootpxe_resolve_windows_system_hive "$fixture") || fail "cannot resolve $variant"
    [[ $resolved == "$fixture/$variant" ]] || fail "lost actual case for $variant"
done

# Preserve the same unique, regular-file and non-symlink rules as the
# existing Sysprep directory resolver.
fixture="$tmp/unsafe"
mkdir -p "$fixture/Windows/System32/config"
expect_fail rootpxe_resolve_windows_system_hive "$fixture"
mkdir "$fixture/Windows/System32/config/SYSTEM"
expect_fail rootpxe_resolve_windows_system_hive "$fixture"
rmdir "$fixture/Windows/System32/config/SYSTEM"
touch "$tmp/outside-hive"
ln -s "$tmp/outside-hive" "$fixture/Windows/System32/config/SYSTEM"
expect_fail rootpxe_resolve_windows_system_hive "$fixture"
rm "$fixture/Windows/System32/config/SYSTEM"
touch "$fixture/Windows/System32/config/SYSTEM" "$fixture/Windows/System32/config/system"
expect_fail rootpxe_resolve_windows_system_hive "$fixture"
rm "$fixture/Windows/System32/config/system"
mkdir "$fixture/windows"
expect_fail rootpxe_resolve_windows_system_hive "$fixture"
rmdir "$fixture/windows"
mv "$fixture/Windows/System32/config" "$tmp/outside-config"
ln -s "$tmp/outside-config" "$fixture/Windows/System32/config"
expect_fail rootpxe_resolve_windows_system_hive "$fixture"
ln -s "$tmp/volumes/system" "$tmp/root-link"
expect_fail rootpxe_resolve_windows_system_hive "$tmp/root-link"

# Existing Sysprep resolution must still preserve a mixed-case existing XML
# name and choose unattend.xml when no answer file is present.
fixture="$tmp/sysprep"
mkdir -p "$fixture/wInDoWs/sYsTeM32/sYsPrEp"
touch "$fixture/wInDoWs/sYsTeM32/sYsPrEp/UnAtTeNd.XmL"
[[ $(rootpxe_resolve_windows_sysprep_unattend_path "$fixture") == "$fixture/wInDoWs/sYsTeM32/sYsPrEp/UnAtTeNd.XmL" ]] || fail sysprep-existing-case
rm "$fixture/wInDoWs/sYsTeM32/sYsPrEp/UnAtTeNd.XmL"
[[ $(rootpxe_resolve_windows_sysprep_unattend_path "$fixture") == "$fixture/wInDoWs/sYsTeM32/sYsPrEp/unattend.xml" ]] || fail sysprep-new-path

# Exercise production Sysprep file handling with mount and XMLStarlet stand-ins.
# This checks path selection and frozen bytes, not real XML validation or Setup.
touch "$fixture/wInDoWs/sYsTeM32/sYsPrEp/UnAtTeNd.XmL"
deploymentIdentityPolicyFile="$tmp/policy.json"
rootpxe_deployment_initialization_private_file="$tmp/private.json"
printf '%s\n' '{"systemIdentity":{"sysprep":true}}' >"$deploymentIdentityPolicyFile"
xml_payload='<unattend><ComputerName>FROZEN</ComputerName></unattend>'
jq -n --arg xml "$xml_payload" '{unattendXml:$xml}' >"$rootpxe_deployment_initialization_private_file"
rootpxe_stage(){ :; }
umount(){ return 0; }
ntfs-3g(){
    [[ $1 == -o && $2 == remove_hiberfile,rw && $4 == "$tmp/ntfs" ]] || return 1
    find "$tmp/ntfs" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    cp -a "$3/." "$4/"
}
xml(){ [[ $1 == val && $2 == -w && -f $3 ]]; }
reged(){ fail sysprep-invoked-direct-registry-writer; }
changeHostname=true; hostName=UNUSED
rootpxe_apply_windows_hostname "$fixture" || fail sysprep-mixed-case-injection
[[ $(cat "$tmp/ntfs/wInDoWs/sYsTeM32/sYsPrEp/UnAtTeNd.XmL") == "$xml_payload" ]] || fail sysprep-changed-frozen-xml
[[ ! -e "$tmp/ntfs/wInDoWs/sYsTeM32/sYsPrEp/unattend.xml" ]] || fail sysprep-created-second-answer-file
[[ $rootpxe_deployment_identity_hostname_result == false && $rootpxe_deployment_identity_sysprep_result == true ]] || fail sysprep-result
printf 'PASS: Windows casefold paths and system-volume selection\n'
