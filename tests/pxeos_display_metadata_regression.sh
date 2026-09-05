#!/usr/bin/env bash
# All cases use temporary files and OS-boundary stubs only.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/display-metadata.sh"
parser="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/windows-display-registry.sh"
tmp="$(mktemp -d /tmp/rootpxe-display-metadata.XXXXXX)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
run() { ( "$@" ); }
load() { . "$parser"; . "$lib"; }
inventory() { printf '%s\n' '{"version":1,"disks":[{"number":1,"sourceDevice":"/dev/mockdisk","partitionTable":"gpt","originalDiskBytes":1048576,"logicalSectorBytes":512,"physicalSectorBytes":4096,"partitions":[{"number":1,"startSectors":2048,"originalSectors":4096,"typeGuid":"C12A7328-F81F-11D2-BA4B-00A0C93EC93B","fs":"ntfs","uuid":"keep","partuuid":"keep-part"},{"number":2,"startSectors":8192,"originalSectors":4096,"typeGuid":"0FC63DAF-8483-4772-8E79-3D69D8477DE4","fs":"ext4","uuid":"data","partuuid":"00112233-4455-6677-8899-aabbccddeeff"}]}]}'; }
last_arg() { local value; for value; do :; done; printf '%s\n' "$value"; }
penultimate_arg() { local previous="" result="" value; for value; do [[ -n $previous ]] && result=$previous; previous=$value; done; printf '%s\n' "$result"; }

case_merge() {
    load; local d="$tmp/merge" inv="$tmp/merge/i.json"; mkdir -p "$d"; inventory >"$inv"
    rootpxe_display_metadata_file="$d/m.json"
    printf '%s\n' '{"mountsCollected":true,"mounts":[{"id":"p:1:2","mountPoint":"/"},{"id":"p:1:2","mountPoint":"/var"}],"drivesCollected":true,"drives":[{"id":"p:1:1","driveLetter":"C:"}],"lvs":[{"uuid":"lv-root"}]}' >"$rootpxe_display_metadata_file"
    rootpxe_display_metadata_merge_inventory "$inv"
    jq -e '.disks[0].partitions[0] | .number==1 and .startSectors==2048 and .originalSectors==4096 and .uuid=="keep" and .partuuid=="keep-part" and .windowsRole=="boot" and .mountPoints==[] and .driveLetters==["C:"]' "$inv" >/dev/null
    jq -e '.disks[0].partitions[1] | .number==2 and .startSectors==8192 and .originalSectors==4096 and .uuid=="data" and .mountPoints==["/","/var"] and .driveLetters==[]' "$inv" >/dev/null
    jq -e '.disks[0].logicalVolumes == [{"uuid":"lv-root","mountPoints":[]}]' "$inv" >/dev/null
}

case_fstab() {
    load; local d="$tmp/fstab" rows="$tmp/fstab/rows"; mkdir -p "$d"; : >"$rows"
    rootpxe_display_metadata_mount_rows="$rows"; rootpxe_display_metadata_root_candidates=""
    rootpxe_linux_mount_options() { printf 'ro,noload\n'; }
    blkid() { local device; device=$(last_arg "$@"); case " $* " in *' UUID '*) case "$device" in /dev/p1) echo root;; /dev/lvhome) echo home;; /dev/lvdata) echo data;; esac;; *' PARTUUID '*) [[ $device == /dev/lvhome ]] && echo hp;; *' LABEL '*) [[ $device == /dev/lvdata ]] && echo 'lv data';; esac; }
    readlink() { case "$2" in /dev/mapper/vg-home|/dev/lvhome) echo /dev/lvhome;; *) command readlink "$@";; esac; }
    mount() { local target; target=$(last_arg "$@"); mkdir -p "$target/etc"; printf '%s\n' 'UUID=root / ext4 defaults 0 1' 'PARTUUID=hp /srv\040data ext4 defaults 0 2' 'LABEL=lv\040data /var ext4 defaults 0 2' '/dev/mapper/vg-home /home ext4 defaults 0 2' >"$target/etc/fstab"; }
    mountpoint() { return 0; }; umount() { rm -rf -- "$1/etc"; }
    rootpxe_display_metadata_collect_fstab /dev/p1 ext4 'p:1:1|/dev/p1 l:lv-home|/dev/lvhome l:lv-data|/dev/lvdata' p:1:1
    [[ $rootpxe_display_metadata_root_candidates == ' p:1:1' ]]
    diff -u <(printf '%s\n' $'p:1:1\tp:1:1\t/' $'p:1:1\tl:lv-home\t/srv data' $'p:1:1\tl:lv-data\t/var' $'p:1:1\tl:lv-home\t/home') "$rows"
    : >"$rows"; rootpxe_display_metadata_root_candidates=""
    mount() { local target; target=$(last_arg "$@"); ln -s "$d" "$target/etc"; }
    rootpxe_display_metadata_collect_fstab /dev/p1 ext4 'p:1:1|/dev/p1' p:1:1
    [[ ! -s $rows && -z $rootpxe_display_metadata_root_candidates ]]
}

case_lvm() {
    local mode="$1" d="$tmp/lvm-$1" inv="$tmp/lvm-$1/i.json"; load; mkdir -p "$d"
    rootpxe_display_metadata_file="$d/m.json"; echo '{"mountsCollected":false,"mounts":[]}' >"$rootpxe_display_metadata_file"
    rootpxe_display_metadata_identities='p:1:1|/dev/p1 p:1:2|/dev/p2'
    rootpxe_lvm_lv_facts_file="$d/lvs"; printf '%s\n' 'root|lv-root|/dev/lvroot|4096' 'home|lv-home|/dev/lvhome|4096' >"$rootpxe_lvm_lv_facts_file"
    rootpxe_display_metadata_lv_readable() { [[ $1 == /dev/lvroot || $1 == /dev/lvhome ]]; }
    rootpxe_linux_root_fstype_supported() { [[ $1 == ext4 ]]; }; rootpxe_linux_mount_options() { echo ro,noload; }
    blkid() { local device; device=$(last_arg "$@"); case " $* " in *' TYPE '*) case "$device" in /dev/p1) [[ $mode == physical || $mode == multi ]] && echo ext4 || echo LVM2_member;; /dev/p2) echo LVM2_member;; /dev/lvroot|/dev/lvhome) echo ext4;; esac;; *' UUID '*) case "$device" in /dev/p1) echo physical;; /dev/lvroot) echo lvroot;; /dev/lvhome) echo lvhome;; esac;; esac; }
    mount() { local target device; target=$(last_arg "$@"); device=$(penultimate_arg "$@"); mkdir -p "$target/etc"; case "$mode:$device" in physical:/dev/p1|multi:/dev/p1) printf '%s\n' 'UUID=physical / ext4 defaults 0 1' 'UUID=lvhome /home ext4 defaults 0 2' >"$target/etc/fstab";; lv:/dev/lvroot|multi:/dev/lvroot) printf '%s\n' 'UUID=lvroot / ext4 defaults 0 1' 'UUID=lvhome /home ext4 defaults 0 2' >"$target/etc/fstab";; *) : >"$target/etc/fstab";; esac; }
    mountpoint() { return 0; }; umount() { rm -rf -- "$1/etc"; }
    rootpxe_display_metadata_collect_lvm; inventory >"$inv"; rootpxe_display_metadata_merge_inventory "$inv"
    case "$mode" in
      physical) jq -e '.disks[0].partitions[0].mountPoints==["/"] and .disks[0].partitions[1].mountPoints==[] and .disks[0].logicalVolumes==[{"uuid":"lv-root","mountPoints":[]},{"uuid":"lv-home","mountPoints":["/home"]}]' "$inv" >/dev/null;;
      lv) jq -e '(.disks[0].partitions|all(.mountPoints==[])) and .disks[0].logicalVolumes==[{"uuid":"lv-root","mountPoints":["/"]},{"uuid":"lv-home","mountPoints":["/home"]}]' "$inv" >/dev/null;;
      multi) jq -e '(.disks[0].partitions|all(has("mountPoints")|not)) and .disks[0].logicalVolumes==[{"uuid":"lv-root"},{"uuid":"lv-home"}]' "$inv" >/dev/null;;
    esac
}

case_windows() {
    local mode="$1" d="$tmp/windows-$1" rows="$tmp/windows-$1/rows" inv="$tmp/windows-$1/i.json"; load; mkdir -p "$d"; : >"$rows"
    rootpxe_display_metadata_disks=/dev/mockdisk; rootpxe_display_metadata_drive_rows="$rows"
    blkid() { local device; device=$(last_arg "$@"); case " $* " in *' TYPE '*) case "$device" in /dev/mockdisk1|/dev/mockdisk2) echo ntfs;; esac;; *' PARTUUID '*) [[ $device == /dev/mockdisk2 ]] && echo 00112233-4455-6677-8899-aabbccddeeff;; esac; }
    ntfs-3g() { local target device; target=$(last_arg "$@"); device=$(penultimate_arg "$@"); [[ $mode == no-hive ]] && return 0; [[ $mode != double-hive && $device == /dev/mockdisk2 ]] && return 0; mkdir -p "$target/WiNdOwS/System32/config"; : >"$target/WiNdOwS/System32/config/SyStEm"; }
    mountpoint() { return 0; }; umount() { [[ $mode == cleanup-fail ]] && return 1; rm -rf -- "$1/WiNdOwS"; }
    reged() { local output; output=$(last_arg "$@"); [[ $mode != reged-fail && $mode != cleanup-fail ]] || return 1; command cat >"$output" <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\MountedDevices]
"\\DosDevices\\C:"=hex:12,34,56,78,00,00,10,00,00,00,00,00
"\\DosDevices\\D:"=hex:44,4d,49,4f,3a,49,44,3a,33,22,11,00,55,44,77,66,88,99,aa,bb,cc,dd,ee,ff
"\\DosDevices\\Z:"=hex:ff,ff,ff,ff,00,00,10,00,00,00,00,00
REG
    }
    sfdisk() { echo 'label-id: 0x78563412'; }
    cat() { { [[ $1 == /sys/class/block/mockdisk1/start ]] || [[ $mode == ambiguous-map && $1 == /sys/class/block/mockdisk2/start ]]; } && echo 2048 || command cat "$@"; }
    if [[ $mode == success ]]; then
      rootpxe_display_metadata_collect_windows 'p:1:1|/dev/mockdisk1 p:1:2|/dev/mockdisk2'
      diff -u <(printf '%s\n' $'p:1:1\tC:' $'p:1:2\tD:') "$rows"
      inventory >"$inv"; rootpxe_display_metadata_file="$d/m.json"
      jq -Rn '[inputs|split("\t")|{id:.[0],driveLetter:.[1]}] as $d|{mountsCollected:false,mounts:[],drivesCollected:true,drives:$d}' <"$rows" >"$rootpxe_display_metadata_file"
      rootpxe_display_metadata_merge_inventory "$inv"; jq -e '.disks[0].partitions[0].driveLetters==["C:"] and .disks[0].partitions[1].driveLetters==["D:"]' "$inv" >/dev/null
    elif [[ $mode == cleanup-fail ]]; then
      if rootpxe_display_metadata_collect_windows 'p:1:1|/dev/mockdisk1'; then return 1; else [[ $? -eq 2 ]]; fi
    else
      if rootpxe_display_metadata_collect_windows 'p:1:1|/dev/mockdisk1 p:1:2|/dev/mockdisk2'; then return 1; else [[ $? -eq 1 ]]; fi; [[ ! -s $rows ]]
    fi
}

run case_merge || fail merge
run case_fstab || fail fstab
run case_lvm physical || fail physical-root-lv-home
run case_lvm lv || fail lv-root
run case_lvm multi || fail multi-root
run case_windows success || fail windows-mbr-gpt
run case_windows no-hive || fail windows-no-hive
run case_windows double-hive || fail windows-double-hive
run case_windows ambiguous-map || fail windows-ambiguous-map
run case_windows reged-fail || fail windows-reged-fail
run case_windows cleanup-fail || fail windows-cleanup-fail
echo 'PASS: display metadata regression'
