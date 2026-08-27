#!/usr/bin/env bash
# Only temporary mocks are used; no host disk or network is touched.
set -euo pipefail
root=$(cd $(dirname $0)/.. && pwd)
overlay=$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay
funcs=$overlay/usr/share/pxeos/lib/funcs.sh
checkin=$overlay/bin/pxeos.checkin
download=$overlay/bin/pxeos.download
fail() { echo "FAIL: $*" >&2; exit 1; }
grep -Fq rootpxe_normalize_compression_level "$checkin" || fail parser
grep -Fq rootpxe_find_windows_system_partition "$funcs" || fail selector
grep -Fq 'rootpxe_apply_hostname_for_disk "$hd"' "$funcs" || fail complete-hostname-dispatch
grep -Fq RESUME_TARGET_IDENTITY_UNAVAILABLE "$download" || fail resume

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p $tmp/mock $tmp/ntfs
: >$tmp/jq-args
export JQ_ARGS_LOG=$tmp/jq-args
cat >$tmp/mock/jq <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'-cS '*)
    for last; do :; done
    cat "$last"
    exit 0 ;;
  *'--rawfile rows'*)
    if [[ ${SCHEMA_KIND:-} == mbr-v2 ]]; then
      echo '{"version":2,"partitionTable":"mbr","originalDiskBytes":102400000,"logicalSectorBytes":512,"physicalSectorBytes":512,"minDeployBytes":3145728,"partitions":[{"number":1,"startSectors":2048,"originalSectors":8192,"minSectors":3976,"typeGuid":"0x5","flags":[],"role":"extended_container","resizable":false,"fs":"","uuid":"","partuuid":"","artifact":"","kind":"extended","logicalNumbers":[5,6],"ebrReservedSectors":2},{"number":5,"startSectors":2050,"originalSectors":2048,"minSectors":2048,"typeGuid":"0x83","flags":[],"role":"data","resizable":true,"fs":"ntfs","uuid":"swap-uuid","partuuid":"swap-partuuid","artifact":"d1p5.img","kind":"logical","parentNumber":1},{"number":6,"startSectors":5000,"originalSectors":1024,"minSectors":1024,"typeGuid":"0x82","flags":[],"role":"swap","resizable":false,"fs":"swap","uuid":"swap-uuid","partuuid":"swap-partuuid","artifact":"","kind":"logical","parentNumber":1}]}'
    elif [[ $BLKTYPE == swap ]]; then echo '{"version":1,"partitionTable":"mbr","originalDiskBytes":102400000,"logicalSectorBytes":512,"physicalSectorBytes":512,"minDeployBytes":1572864,"partitions":[{"number":2,"startSectors":2048,"originalSectors":1024,"minSectors":1024,"typeGuid":"82","flags":[],"role":"swap","resizable":false,"fs":"swap","uuid":"swap-uuid","partuuid":"swap-partuuid","artifact":""}]}' ; else echo '{}' ; fi
    exit 0 ;;
  *'-n '*) echo "$*" >>$JQ_ARGS_LOG; echo '[]'; exit 0 ;;
  *'type == "object"'*) exit 0 ;;
  *'.deploymentLayout != null'*|*'.originalSchema != null'*) exit 1 ;;
  *'role == "other"'*) exit 0 ;;
  *'.wait'*) echo false ;;
  *'.message'*) echo ok ;;
  *'retryAfterSec'*) echo 5 ;;
  *'.error'*) exit 0 ;;
  *'taskId'*) echo 42 ;;
  *'executionToken'*) echo token ;;
  *'.type'*) echo deploy ;;
  *'pxeType'*) echo down ;;
  *'.mac'*) echo 00:11:22:33:44:55 ;;
  *'imagePath'*) echo images/demo ;;
  *'imgType'*) echo n ;;
  *'imgPartitionType'*) echo all ;;
  *'.osid'*) echo 9 ;;
  *'imgFormat'*) echo 5 ;;
  *'compressionLevel'*) echo $COMP ;;
  *'.shutdown'*) echo 0 ;;
  *'.storage.protocol'*) echo smb ;;
  *'.storage.server'*) echo server ;;
  *'.storage.export'*|*'.storage.share'*) echo storage ;;
  *'smb.username'*) echo user ;;
  *'smb.password'*) echo password ;;
  *'smb.domain'*) echo WORKGROUP ;;
  *'hostName'*) echo PXEHOST ;;
  *'changeHostname'*) echo true ;;
  *'resumeStage'*) echo customizing_hostname ;;
  *'schemaRevision'*) echo 2 ;;
  *'.schemaHash // empty'*) echo $SCHEMAHASH ;;
  *'schemaHash'*) echo hash ;;
  *'.logicalSectorBytes'*) echo $SCHEMA_SECTOR ;;
  *) cat ;;
esac
EOF
cat >$tmp/mock/blockdev <<'EOF'
#!/usr/bin/env bash
case "$1" in --getss) echo ${TEST_SECTOR:-512} ;; --getpbsz) echo 512 ;; --getsize64) echo 102400000 ;; *) exit 1 ;; esac
EOF
cat >$tmp/mock/blkid <<'EOF'
#!/usr/bin/env bash
for last; do :; done
if [[ ${MODE:-} == linux_lvm && $last == /dev/vg0/root ]]; then
    case " $* " in *' TYPE '*) echo ext4 ;; esac
    exit 0
fi
case " $* " in *' TYPE '*) echo "$BLKTYPE" ;; *' UUID '*) echo swap-uuid ;; *' PARTUUID '*) echo swap-partuuid ;; esac
EOF
cat >$tmp/mock/ntfs-3g <<'EOF'
#!/usr/bin/env bash
part=$3
mount=$4
rm -rf "$mount"
mkdir -p "$mount"
if [[ ($MODE == unique && $part == /dev/mock2) || $MODE == ambiguous || (($MODE == hostname_xml || $MODE == hostname_absent || $MODE == hostname_invalid) && $part == /dev/mock2) ]]; then
    mkdir -p "$mount/Windows/System32/config"
    : >"$mount/Windows/System32/config/SYSTEM"
fi
if [[ $MODE == hostname_xml || $MODE == hostname_invalid ]]; then
    mkdir -p "$mount/Windows/System32/Sysprep"
    if [[ $MODE == hostname_invalid ]]; then
        printf '<unattend>invalid' >"$mount/Windows/System32/Sysprep/unattend.xml"
    else
        printf '<unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup"><ComputerName>OLD</ComputerName></component></settings></unattend>' >"$mount/Windows/System32/Sysprep/unattend.xml"
    fi
fi
EOF
cat >$tmp/mock/umount <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >$tmp/mock/mount <<'EOF'
#!/usr/bin/env bash
device=${@: -2:1}
mount=${!#}
printf '%s\n' "$*" >>$MOUNT_TRACE
rm -rf "$mount"
mkdir -p "$mount"
make_linux_root() {
    mkdir -p "$mount/etc" "$mount/usr/lib"
    printf 'PXE-OLD\n' >"$mount/etc/hostname"
    printf '127.0.1.1 PXE-OLD old.example\n10.0.0.1 PXE-OLD.example\n# PXE-OLD comment\n' >"$mount/etc/hosts"
    printf 'NAME=mock\n' >"$mount/etc/os-release"
}
case ${MODE:-} in
    linux_ext|linux_readback_fail|linux_symlink)
        [[ $device == /dev/mockroot ]] && make_linux_root
        ;;
    linux_new_hostname)
        [[ $device == /dev/mockroot ]] && { make_linux_root; rm -f "$mount/etc/hostname"; }
        ;;
    linux_relative_osrelease)
        [[ $device == /dev/mockroot ]] && { make_linux_root; rm -f "$mount/etc/os-release"; printf 'NAME=mock\n' >"$mount/usr/lib/os-release"; ln -s ../usr/lib/os-release "$mount/etc/os-release"; }
        ;;
    linux_lvm)
        [[ $device == /dev/vg0/root ]] && make_linux_root
        ;;
    linux_multiple)
        [[ $device == /dev/mockroot || $device == /dev/mockroot2 ]] && make_linux_root
        ;;
esac
if [[ ${MODE:-} == linux_symlink && -d $mount/etc ]]; then
    rm -f "$mount/etc/hostname"
    ln -s /etc/hostname "$mount/etc/hostname"
fi
EOF
cat >$tmp/mock/pvs <<'EOF'
#!/usr/bin/env bash
if [[ ${MODE:-} == linux_lvm || ${MODE:-} == linux_lvm_all_active || ${MODE:-} == linux_lvm_mixed ]]; then
    case " $* " in
        *'pv_name,vg_uuid'*) printf ' /dev/mockpv vg-uuid-0\n' ;;
        *) printf ' /dev/mockpv vg0 vg-uuid-0\n' ;;
    esac
elif [[ ${MODE:-} == linux_lvm_external ]]; then
    case " $* " in
        *'pv_name,vg_uuid'*) printf ' /dev/mockpv vg-uuid-0\n /dev/externalpv vg-uuid-0\n' ;;
        *) printf ' /dev/mockpv vg0 vg-uuid-0\n /dev/externalpv vg0 vg-uuid-0\n' ;;
    esac
fi
EOF
cat >$tmp/mock/lvs <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *'lv_active'*)
        case ${MODE:-} in
            linux_lvm_all_active) printf ' active\n active\n' ;;
            linux_lvm_mixed) printf ' active\n inactive\n' ;;
            *) printf ' inactive\n inactive\n' ;;
        esac
        ;;
    *'lv_path'*) [[ ${MODE:-} == linux_lvm ]] && printf ' /dev/vg0/root\n' ;;
esac
EOF
cat >$tmp/mock/vgchange <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>$LVM_TRACE
EOF
cat >$tmp/mock/cat <<'EOF'
#!/usr/bin/env bash
if [[ ${MODE:-} == linux_readback_fail && $# -eq 1 && $1 == */linuxroot/etc/hostname ]]; then
    printf 'WRONG\n'
    exit 0
fi
exec /bin/cat "$@"
EOF
cat >$tmp/mock/chmod <<'EOF'
#!/usr/bin/env bash
printf 'chmod:%s\n' "$*" >>$HOSTMODE_TRACE
EOF
cat >$tmp/mock/chown <<'EOF'
#!/usr/bin/env bash
printf 'chown:%s\n' "$*" >>$HOSTMODE_TRACE
EOF
cat >$tmp/mock/xmlstarlet <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *' count('* )
    [[ ${MODE:-} == hostname_invalid ]] && exit 1
    echo 1 ;;
  *' string('* )
    for last; do :; done
    grep -Fq PXEHOST "$last" && echo PXEHOST ;;
  *' ed '*)
    for last; do :; done
    printf '<updated>PXEHOST</updated>' >"$last" ;;
  *) exit 1 ;;
esac
EOF
chmod +x $tmp/mock/*
sed -e "s|^\. /usr/share/pxeos/lib/partition-funcs.sh|. \"$overlay/usr/share/pxeos/lib/partition-funcs.sh\"|" -e "s|</proc/cmdline|<$tmp/cmdline|" -e "s|/ntfs/|$tmp/ntfs/|g" -e "s| /ntfs\([ ;)]\)| $tmp/ntfs\1|g" -e "s|mountpoint=/linuxroot|mountpoint=$tmp/linuxroot|g" -e "s|/linuxroot/|$tmp/linuxroot/|g" -e "s| /linuxroot\([ ;)]\)| $tmp/linuxroot\1|g" $funcs >$tmp/funcs.sh
: >$tmp/cmdline
: >$tmp/mount-trace
MOUNT_TRACE=$tmp/mount-trace; export MOUNT_TRACE
: >$tmp/hostmode-trace
HOSTMODE_TRACE=$tmp/hostmode-trace; export HOSTMODE_TRACE
export PATH=$tmp/mock:$PATH
ismajordebug=0
isdebug=0
. $tmp/funcs.sh
rootpxe_require_task_context() { return 0; }
rootpxe_require_identity() { return 0; }
# The backend hashes the exact bytes of jq -cS output without its terminal
# newline. Pin a known canonical JSON value so an accidental printf newline
# changes this test's hash rather than silently drifting the task contract.
printf '{"a":1,"b":2}\n' >$tmp/canonical-schema.json
[[ $(rootpxe_canonical_json_hash $tmp/canonical-schema.json) == 43258cff783fe7036d8a43033f830adfc60ec037382473548ac742b888292777 ]] || fail canonical-schema-hash
awk '/^rootpxe_json_get_string\(/{on=1} /^checkin_rootpxe\(/{on=0} on' $checkin >$tmp/json.sh
. $tmp/json.sh
# JSON parser behavior is covered by pxeos_checkin_json_regression.sh with a
# real jq and real fixtures.  This broader disk-flow suite keeps jq mocked.
[[ $(rootpxe_normalize_compression_level 6) == -6 ]] || fail positive-compression
[[ $(rootpxe_normalize_compression_level -7) == -7 ]] || fail negative-compression
rootpxe_normalize_compression_level 23 >/dev/null && fail compression-range
rootpxe_validate_pigz_compression -10 2 && fail gzip-range

# The selected volume must have the fixed SYSTEM hive; an NTFS recovery
# partition occurring first is intentionally skipped.
getPartitions() { parts='/dev/mock1 /dev/mock2'; }
fsTypeSetting() { fstype=ntfs; }
MODE=unique; export MODE
[[ $(rootpxe_find_windows_system_partition /dev/mock) == /dev/mock2 ]] || fail recovery-before-windows
MODE=ambiguous; export MODE
rootpxe_find_windows_system_partition /dev/mock && fail ambiguous-windows

# Windows customization must update only the fixed Sysprep file.  Registry is
# a fallback solely when that file is absent; malformed XML must not fall back.
rootpxe_stage() { printf '%s\n' "$*" >>$tmp/hostname-stage; }
rootpxe_change_hostname_registry() { printf '%s\n' "$1" >>$tmp/registry; }
: >$tmp/registry
MODE=hostname_xml; export MODE
changeHostname=true; hostName=PXEHOST
rootpxe_apply_windows_hostname /dev/mock2 || fail unattend-update
grep -Fq PXEHOST $tmp/ntfs/Windows/System32/Sysprep/unattend.xml || fail unattend-readback
[[ ! -s $tmp/registry ]] || fail unattend-registry-fallback
MODE=hostname_absent; export MODE
rootpxe_apply_windows_hostname /dev/mock2 || fail registry-fallback
grep -Fqx /dev/mock2 $tmp/registry || fail registry-not-called
MODE=hostname_xml; export MODE
osid=9
rootpxe_apply_hostname_for_disk /dev/mock2 || fail windows-dispatch
registry_count=$(wc -l <$tmp/registry)
MODE=hostname_invalid; export MODE
set +e
(
    handleError() { exit 97; }
    rootpxe_apply_windows_hostname /dev/mock2
)
invalid_rc=$?
set -e
[[ $invalid_rc -eq 97 ]] || fail invalid-unattend-result
[[ $(wc -l <$tmp/registry) -eq $registry_count ]] || fail invalid-unattend-registry-fallback

# Linux uses the same deployment hostname contract, but discovers the one
# actual root filesystem rather than selecting a largest/first partition.
rootpxe_stage() { :; }
getPartitions() { parts='/dev/mockboot /dev/mockroot'; }
fsTypeSetting() {
    case $1 in
        /dev/mockboot) fstype=vfat ;;
        /dev/mockroot|/dev/mockroot2) fstype=ext4 ;;
        /dev/mockpv) fstype=LVM2_member ;;
        *) fstype=unknown ;;
    esac
}
: >$tmp/lvm-trace
LVM_TRACE=$tmp/lvm-trace; export LVM_TRACE
changeHostname=true; hostName=linux-node; osid=50
MODE=linux_ext; export MODE
rootpxe_apply_hostname_for_disk /dev/mockdisk || fail linux-ext-hostname
grep -Fqx linux-node $tmp/linuxroot/etc/hostname || fail linux-hostname-write
grep -Fq '127.0.1.1 linux-node old.example' $tmp/linuxroot/etc/hosts || fail linux-hosts-token-replace
grep -Fq '10.0.0.1 PXE-OLD.example' $tmp/linuxroot/etc/hosts || fail linux-hosts-substring
grep -Fq '# PXE-OLD comment' $tmp/linuxroot/etc/hosts || fail linux-hosts-comment
[[ ! -s $tmp/lvm-trace ]] || fail linux-ordinary-vg-activation
[[ ! -s $tmp/hostmode-trace ]] || fail linux-existing-hostname-mode

: >$tmp/hostmode-trace
previous_umask=$(umask)
umask 077
MODE=linux_new_hostname; export MODE
rootpxe_apply_hostname_for_disk /dev/mockdisk || fail linux-new-hostname
umask "$previous_umask"
grep -Fq "chmod:0644 $tmp/linuxroot/etc/hostname" $tmp/hostmode-trace || fail linux-new-hostname-mode
grep -Fq "chown:root:root $tmp/linuxroot/etc/hostname" $tmp/hostmode-trace || fail linux-new-hostname-owner

: >$tmp/mount-trace
fsTypeSetting() {
    case $1 in
        /dev/mockboot) fstype=vfat ;;
        /dev/mockroot) fstype=xfs ;;
        /dev/mockroot2) fstype=ext4 ;;
        /dev/mockpv) fstype=LVM2_member ;;
        *) fstype=unknown ;;
    esac
}
MODE=linux_ext; export MODE
rootpxe_apply_hostname_for_disk /dev/mockdisk || fail linux-xfs-hostname
grep -Fq -- '-o ro,nouuid' $tmp/mount-trace || fail linux-xfs-readonly-nouuid
grep -Fq -- '-o rw,nouuid' $tmp/mount-trace || fail linux-xfs-readwrite-nouuid
fsTypeSetting() {
    case $1 in
        /dev/mockboot) fstype=vfat ;;
        /dev/mockroot|/dev/mockroot2) fstype=ext4 ;;
        /dev/mockpv) fstype=LVM2_member ;;
        *) fstype=unknown ;;
    esac
}

MODE=linux_relative_osrelease; export MODE
[[ $(rootpxe_find_linux_root_filesystem /dev/mockdisk) == /dev/mockroot'|'ext4'|'* ]] || fail linux-relative-osrelease

getPartitions() { parts='/dev/mockpv'; }
MODE=linux_lvm; export MODE
rootpxe_apply_hostname_for_disk /dev/mockdisk || fail linux-lvm-hostname
grep -Fqx linux-node $tmp/linuxroot/etc/hostname || fail linux-lvm-write
[[ $(grep -Fc -- '-ay' $tmp/lvm-trace) -eq 2 ]] || fail linux-lvm-reactivate
[[ $(grep -Fc -- '-an' $tmp/lvm-trace) -eq 2 ]] || fail linux-lvm-cleanup

: >$tmp/lvm-trace
MODE=linux_lvm_all_active; export MODE
[[ $(rootpxe_linux_activate_vg_if_needed /dev/mockdisk vg0 vg-uuid-0) == no ]] || fail linux-lvm-all-active
[[ ! -s $tmp/lvm-trace ]] || fail linux-lvm-all-active-mutate
MODE=linux_lvm_mixed; export MODE
rootpxe_linux_activate_vg_if_needed /dev/mockdisk vg0 vg-uuid-0 && fail linux-lvm-mixed
rootpxe_find_linux_root_filesystem /dev/mockdisk && fail linux-lvm-mixed-root
[[ $? -eq 23 ]] || fail linux-lvm-mixed-root-code

getPartitions() { parts='/dev/mockroot /dev/mockroot2'; }
MODE=linux_multiple; export MODE
rootpxe_find_linux_root_filesystem /dev/mockdisk && fail linux-multiple-root
[[ $? -eq 21 ]] || fail linux-multiple-root-code
getPartitions() { parts='/dev/mockboot'; }
MODE=linux_none; export MODE
rootpxe_find_linux_root_filesystem /dev/mockdisk && fail linux-no-root
[[ $? -eq 20 ]] || fail linux-no-root-code

getPartitions() { parts='/dev/mockroot'; }
MODE=linux_readback_fail; export MODE
set +e
(
    handleError() { exit 97; }
    rootpxe_apply_hostname_for_disk /dev/mockdisk
)
linux_readback_rc=$?
set -e
[[ $linux_readback_rc -eq 97 ]] || fail linux-readback-result

MODE=linux_symlink; export MODE
set +e
(
    handleError() { exit 97; }
    rootpxe_apply_hostname_for_disk /dev/mockdisk
)
linux_symlink_rc=$?
set -e
[[ $linux_symlink_rc -eq 97 ]] || fail linux-symlink-result

getPartitions() { parts='/dev/mockpv'; }
MODE=linux_lvm_external; export MODE
rootpxe_find_linux_root_filesystem /dev/mockdisk && fail linux-external-vg
[[ $? -eq 22 ]] || fail linux-external-vg-code

set +e
(
    handleError() { printf '%s\n' "$1" >$tmp/linux-lvm-attention; exit 97; }
    rootpxe_apply_hostname_for_disk /dev/mockdisk
)
linux_cross_disk_rc=$?
set -e
[[ $linux_cross_disk_rc -eq 97 ]] || fail linux-external-vg-attention-result
grep -Fqx 'PXEOS_STAGE=customizing_hostname CODE=LINUX_ROOT_CROSS_DISK_LVM' $tmp/linux-lvm-attention || fail linux-external-vg-attention

MODE=linux_lvm_mixed; export MODE
set +e
(
    handleError() { printf '%s\n' "$1" >$tmp/linux-lvm-attention; exit 97; }
    rootpxe_apply_hostname_for_disk /dev/mockdisk
)
linux_activation_rc=$?
set -e
[[ $linux_activation_rc -eq 97 ]] || fail linux-lvm-activation-attention-result
grep -Fqx 'PXEOS_STAGE=customizing_hostname CODE=LINUX_ROOT_LVM_ACTIVATION_FAILED' $tmp/linux-lvm-attention || fail linux-lvm-activation-attention

# DOS extended/logical layouts generate Schema v2: the EBR container is a
# derived metadata record with no artifact, while logical image payloads keep
# their parent link.  A primary swap has no d1pN.img by design, but still
# produces a protected non-resizable fact.
logical=$tmp/logical; mkdir -p $logical; : >$logical/d1p5.img; : >$logical/d1p6.img
printf 'label: dos\n/dev/mock1 : start=2048, size=8192, type=5\n/dev/mock5 : start=2050, size=2048, type=83\n/dev/mock6 : start=5000, size=1024, type=82\n' >$logical/d1.partitions
BLKTYPE=ntfs; SCHEMA_KIND=mbr-v2; export BLKTYPE SCHEMA_KIND
rootpxe_build_original_schema /dev/mock $logical || fail mbr-logical-schema-v2
grep -Fq '"version":2' $rootpxe_original_schema_file || fail mbr-logical-schema-version
grep -Fq '"role":"extended_container"' $rootpxe_original_schema_file || fail mbr-container-role
grep -Fq '"kind":"logical"' $rootpxe_original_schema_file || fail mbr-logical-kind
grep -Fq '"parentNumber":1' $rootpxe_original_schema_file || fail mbr-logical-parent
grep -Fq '"ebrReservedSectors":2' $rootpxe_original_schema_file || fail mbr-ebr-reservation
grep -Fq '"typeGuid":"0x5"' $rootpxe_original_schema_file || fail mbr-type-normalization
grep -Fq '"typeGuid":"0x83"' $rootpxe_original_schema_file || fail mbr-logical-type-normalization
grep -Fq '"artifact":""' $rootpxe_original_schema_file || fail mbr-container-artifact
grep -Fq '"minSectors":3976' $rootpxe_original_schema_file || fail mbr-container-minimum
node -e 'const e=2048,l=[{s:2050,m:2048},{s:5000,m:1024}];if(Math.max(...l.map(p=>p.s+p.m-e))!==3976)process.exit(1)' || fail mbr-container-minimum-oracle
grep -Fq '(.startSectors + .minSectors - $part.startSectors)' $funcs || fail mbr-container-minimum-builder
grep -Fq '"lvm"' $rootpxe_original_schema_file && fail mbr-v2-empty-lvm-must-be-omitted
node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1]));const e=s.partitions.find(p=>p.kind==="extended"),l=s.partitions.find(p=>p.kind==="logical");if(!e||!l||"parentNumber" in e||!("ebrReservedSectors" in e)||"ebrReservedSectors" in l||"logicalNumbers" in l)process.exit(1)' "$rootpxe_original_schema_file" || fail mbr-v2-field-boundaries
grep -Fq 'extended container must be derived' $funcs || fail mbr-derived-layout-guard
grep -Fq 'derived extended geometry invalid' $funcs || fail mbr-derived-layout-geometry

badlogical=$tmp/badlogical; mkdir -p $badlogical; : >$badlogical/d1p5.img
printf 'label: dos\n/dev/mock5 : start=4096, size=1024, type=83\n' >$badlogical/d1.partitions
rootpxe_build_original_schema /dev/mock $badlogical && fail mbr-logical-without-parent-schema
unset SCHEMA_KIND

# An extended partition is EBR metadata only.  Even if a stale d1p1.img was
# left in storage, capture must not enqueue a writer and restore must not feed
# it to writeImage.  The EBR marker itself remains available to the legacy
# EBR restore path.
container=$tmp/container; mkdir -p $container; : >$container/d1p1.img
CONTAINER_TRACE=$tmp/container-trace; : >$CONTAINER_TRACE; export CONTAINER_TRACE
getPartitionNumber() { part_number=1; }
getPartType() { parttype=0x85; }
fsTypeSetting() { fstype=ntfs; }
EBRFileName() { ebrfilename="$1/d${2}p${3}.ebr"; }
uploadFormat() { printf 'capture-writer\n' >>$CONTAINER_TRACE; return 1; }
getDiskFromPartition() { disk=/dev/mock; }
runPartprobe() { printf 'partprobe\n' >>$CONTAINER_TRACE; }
writeImage() { printf 'restore-payload\n' >>$CONTAINER_TRACE; return 1; }
imgPartitionType=all; imgType=n; imgFormat=5; osid=50
savePartition /dev/mock1 1 $container all
[[ -f $container/d1p1.ebr ]] || fail extended-capture-ebr-marker
grep -Fq capture-writer $CONTAINER_TRACE && fail extended-capture-stale-payload
restorePartition /dev/mock1 1 $container 0
grep -Fq restore-payload $CONTAINER_TRACE && fail extended-restore-stale-payload
grep -Fq partprobe $CONTAINER_TRACE || fail extended-restore-ebr-path

swapdir=$tmp/swap; mkdir -p $swapdir
printf 'label: dos\n/dev/mock2 : start=2048, size=1024, type=82\n' >$swapdir/d1.partitions
BLKTYPE=swap; export BLKTYPE
rootpxe_build_original_schema /dev/mock $swapdir || fail primary-swap-schema
grep -Fq '"role":"swap"' $rootpxe_original_schema_file || fail swap-role
grep -Fq '"artifact":""' $rootpxe_original_schema_file || fail swap-artifact

# Protected MBR/GPT roles are not a layout resizing target.  Original mode
# preserves each protected partition's size; later partitions may move when
# an earlier allowed data partition is resized.
grep -Fq '== "0xef"' $funcs || fail mbr-efi
grep -Fq '== "0x27"' $funcs || fail mbr-recovery
grep -Fq 'resizable != true' $funcs || fail protected-layout
grep -Fq 'align_down(($available-$used);$alignment)' $funcs || fail remaining-floor
node -e 'const a=512,r=Math.floor((7000-3500)/a)*a;if(r!==3072||r%a)process.exit(1)' || fail remaining-oracle

# Layout target capacity is converted through bytes into source Schema sectors:
# a 102400000-byte 4Kn target remains 200000 512-byte Schema sectors.
schema=$tmp/schema; layoutfile=$tmp/layout
printf '{"logicalSectorBytes":512}\n' >$schema; printf '{}\n' >$layoutfile
SCHEMA_SECTOR=512
SCHEMAHASH=$(rootpxe_canonical_json_hash $schema)
TEST_SECTOR=4096
export SCHEMA_SECTOR SCHEMAHASH TEST_SECTOR
: >$tmp/jq-args
schemaRevision=1; schemaHash=$SCHEMAHASH
rootpxe_validate_deployment_layout /dev/mock $schema $layoutfile || fail target-byte-conversion
grep -Fq -- '--argjson target 200000' $tmp/jq-args || fail target-byte-sector-count

# The runtime jq resolver receives v2 MBR layout snapshots before permit.  In
# this host-only suite jq is mocked, so inspect the actual resolver program
# passed to jq and independently pin the EBR-derived extent arithmetic.
mbr_schema=$tmp/mbr-layout-schema
mbr_layout=$tmp/mbr-layout
printf '{"version":2,"partitionTable":"mbr","logicalSectorBytes":512,"partitions":[{"number":1,"kind":"extended","startSectors":2048,"originalSectors":8192,"ebrReservedSectors":2},{"number":5,"kind":"logical","parentNumber":1,"startSectors":2050,"originalSectors":2048,"minSectors":1024,"resizable":true,"role":"data"}]}' >$mbr_schema
SCHEMAHASH=$(rootpxe_canonical_json_hash $mbr_schema)
printf '{"schemaHash":"%s","partitions":[{"number":1,"mode":"derived"},{"number":5,"mode":"original"}]}' "$SCHEMAHASH" >$mbr_layout
schemaHash=$SCHEMAHASH; schemaRevision=1; SCHEMA_SECTOR=512; TEST_SECTOR=512
: >$tmp/jq-args
rootpxe_validate_deployment_layout /dev/mock $mbr_schema $mbr_layout || fail mbr-derived-layout-prepermit
grep -Fq 'extended container must be derived' $tmp/jq-args || fail mbr-derived-layout-jq-program
node -e 'const logical=[{start:4098,size:2048},{start:8192,size:1024}],ebr=2,start=Math.min(...logical.map(p=>p.start))-ebr,end=Math.max(...logical.map(p=>p.start+p.size));if(start!==4096||end-start!==5120)process.exit(1)' || fail mbr-derived-layout-oracle
TEST_SECTOR=4096; export TEST_SECTOR

# Sector mismatch is rejected before disk permit unless NVMe read-only LBAF
# discovery succeeds.  This never runs nvme format.
printf 'sector-size: 512\n' >$tmp/sector.partitions
rootpxe_disk_stable_identity() { echo disk-id; }
rootpxe_nvme_find_metadata_free_lbaf() { return 1; }
rootpxe_plan_deploy_disk_operation /dev/sda $tmp/sector.partitions && fail nonnvme-mismatch-permit
rootpxe_plan_deploy_disk_operation /dev/nvme0n1 $tmp/sector.partitions && fail nvme-no-lbaf-permit
rootpxe_nvme_find_metadata_free_lbaf() { echo 3; }
rootpxe_plan_deploy_disk_operation /dev/nvme0n1 $tmp/sector.partitions || fail nvme-lbaf-plan
[[ $rootpxe_planned_disk_operation == nvme_format+deploy_write ]] || fail nvme-operation

# Resume is deliberately before layout validation and postinit, and must not
# reinvoke image restoration after a hostname attention retry.  Execute the
# tail with failing mocks for all prohibited operations, not merely a grep.
resume_script=$tmp/resume.sh
awk '/^findHDDInfo$/{on=1} on' $download | sed -e "s|/bin/pxeos.imgcomplete|$tmp/pxeos.imgcomplete|g" -e "s|/storage/postdeployscripts/hook.sh|$tmp/postdeploy-hook|g" >$resume_script
cat >$tmp/pxeos.imgcomplete <<'EOF'
printf '%s\n' complete >>$RESUME_TRACE
EOF
cat >$tmp/postdeploy-hook <<'EOF'
printf '%s\n' hook >>$RESUME_TRACE
EOF
chmod +x $tmp/pxeos.imgcomplete $tmp/postdeploy-hook
: >$tmp/resume-trace
RESUME_TRACE=$tmp/resume-trace; export RESUME_TRACE
findHDDInfo() { hd=/dev/mock2; printf '%s\n' find >>$RESUME_TRACE; }
rootpxe_disk_stable_identity() { echo resume-disk-id; }
rootpxe_wait_for_disk_permit() { printf 'permit:%s:%s\n' "$1" "$2" >>$RESUME_TRACE; }
rootpxe_stage() { printf 'stage:%s\n' "$*" >>$RESUME_TRACE; }
rootpxe_apply_hostname_for_disk() { printf 'hostname:%s:%s\n' "$osid" "$1" >>$RESUME_TRACE; }
rootpxe_run_postinit() { fail resume-postinit; }
rootpxe_validate_deployment_layout() { fail resume-layout; }
rootpxe_apply_deployment_layout() { fail resume-layout-apply; }
rootpxe_plan_deploy_disk_operation() { fail resume-nvme-plan; }
preparePartitions() { fail resume-partition; }
putDataBack() { fail resume-restore; }
resumeStage=customizing_hostname
changeHostname=true
osid=50
imagePath=$tmp/image
imgType=n
imgPartitionType=all
nombr=0
(
    . $resume_script
) || fail resume-execution
grep -Fqx permit:resume-disk-id:deploy_write $tmp/resume-trace || fail resume-permit
grep -Fqx hostname:50:/dev/mock2 $tmp/resume-trace || fail resume-hostname
grep -Fqx hook $tmp/resume-trace || fail resume-hook
grep -Fqx complete $tmp/resume-trace || fail resume-complete

# Keep the ordering assertion as a cheap guard against accidental future
# movement of the early resume branch.
resume=$(grep -n RESUME_TARGET_IDENTITY_UNAVAILABLE $download | cut -d: -f1)
layout=$(grep -n pre_permit_validation_failed $download | cut -d: -f1)
postinit=$(grep -n rootpxe_run_postinit $download | cut -d: -f1)
[[ $resume -lt $layout && $resume -lt $postinit ]] || fail resume-order
echo 'PASS: PXEOS business regression contract'
