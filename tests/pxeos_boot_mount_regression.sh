#!/usr/bin/env bash
# Exercise the production boot-mount helper with mocked system interfaces.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
lib="${ROOTPXE_IDENTITY_LIB:-$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/deployment-identity.sh}"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
. "$lib"
declare -A mounted=()
log="$tmp/log"; : >"$log"
rootpxe_deployment_identity_boot_device_is_block(){ [[ $1 == /dev/mock-* ]]; }
rootpxe_deployment_identity_plan_target_device(){ [[ $1 == /dev/mock-boot || $1 == /dev/mock-efi ]]; }
rootpxe_linux_mount_options(){ printf rw; }
blkid(){ case "$*" in *'TYPE'*mock-boot*) printf ext4;; *'TYPE'*mock-efi*) printf vfat;; '-U boot') printf /dev/mock-boot;; *'PARTUUID=efi'*) printf /dev/mock-efi;; *) return 1;; esac; }
mountpoint(){ [[ $1 == -q ]] && [[ -n ${mounted[$2]:-} ]]; }
mount(){ local source="${@: -2:1}" target="${@: -1}"; printf 'mount %s %s\n' "$source" "$target" >>"$log"; [[ ${FAIL_SECOND:-0} != 1 || $target != */boot/efi ]] || return 1; mounted[$target]=$source; }
umount(){ printf 'umount %s\n' "$1" >>"$log"; unset 'mounted[$1]'; }
rootpxe_deployment_identity_boot_mount_device_numbers(){
  local mount_target="$1" device="$2" mounted_device
  mounted_device="${mounted[$mount_target]:-}"
  [[ -n $mounted_device && $mounted_device == "$device" ]]
}
run_case(){ local name="$1" fstab="$2"; shift 2; local target="$tmp/$name"; mkdir -p "$target/etc" "$target/boot/efi"; printf '%s' "$fstab" >"$target/etc/fstab"; rootpxe_deployment_identity_plan_file="$tmp/plan"; : >"$tmp/plan"; mounted=(); : >"$log"; "$@" "$target"; }
normal(){ rootpxe_deployment_identity_mount_linux_boot_filesystems "$1"; }
# ESP first in fstab must still mount /boot before /boot/efi.
run_case normal $'PARTUUID=efi /boot/efi vfat defaults 0 2\nUUID=boot /boot ext4 defaults 0 1\n' normal || fail normal
[[ $(sed -n '1p' "$log") == "mount /dev/mock-boot $tmp/normal/boot" ]] || fail 'fstab reverse order mounted ESP first'
[[ $(sed -n '2p' "$log") == "mount /dev/mock-efi $tmp/normal/boot/efi" ]] || fail normal-order
rootpxe_deployment_identity_unmount_linux_boot_filesystems || fail normal-cleanup
# After the storage-identifier phase, fstab carries the frozen *new* UUID.
# PXEOS blkid may not resolve that UUID's presentation, so /boot must use the
# same plan-bound fallback as any other target filesystem instead of failing
# before initramfs repair.
target="$tmp/post-uuid"; mkdir -p "$target/etc" "$target/boot/efi"
printf 'UUID=NEW-BOOT /boot ext4 defaults 0 1\nPARTUUID=efi /boot/efi vfat defaults 0 2\n' >"$target/etc/fstab"
rootpxe_deployment_identity_plan_file="$tmp/post-uuid-plan"
printf '%s\n' '{"plan":{"topology":{"disks":[{"partitions":[{"targetDevice":"/dev/mock-boot","originalFilesystemUuid":"old-boot"}]}]},"disks":[{"partitions":[{"targetDevice":"/dev/mock-boot","filesystemUuid":"NEW-BOOT"}]}]}}' >"$rootpxe_deployment_identity_plan_file"
mounted=(); : >"$log"
rootpxe_deployment_identity_mount_linux_boot_filesystems "$target" || fail 'post-change boot UUID was rejected'
[[ $(sed -n '1p' "$log") == "mount /dev/mock-boot $target/boot" ]] || fail 'post-change boot UUID did not use planned device'
rootpxe_deployment_identity_unmount_linux_boot_filesystems || fail post-change-cleanup
# A borrowed wrong mount must fail but never be unmounted.
target="$tmp/borrow"; mkdir -p "$target/etc" "$target/boot/efi"; printf 'UUID=boot /boot ext4 defaults 0 1\n' >"$target/etc/fstab"; mounted=(["$target/boot"]=/dev/mock-other); : >"$log"
if rootpxe_deployment_identity_mount_linux_boot_filesystems "$target"; then fail borrowed-accepted; fi
[[ -z $(cat "$log") ]] || fail borrowed-unmounted
# Failure mounting the second filesystem must unmount only the first one.
target="$tmp/second"; mkdir -p "$target/etc" "$target/boot/efi"; printf 'UUID=boot /boot ext4 defaults 0 1\nPARTUUID=efi /boot/efi vfat defaults 0 2\n' >"$target/etc/fstab"; mounted=(); : >"$log"
if FAIL_SECOND=1 rootpxe_deployment_identity_mount_linux_boot_filesystems "$target"; then fail second-accepted; fi
grep -Fqx "umount $target/boot" "$log" || fail second-did-not-clean-first
grep -Fq "umount $target/boot/efi" "$log" && fail second-cleaned-unmounted-esp
printf 'PASS: PXEOS boot mount regression\n'
