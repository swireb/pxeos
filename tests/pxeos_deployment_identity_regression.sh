#!/usr/bin/env bash
# Deployment identity v1 protocol and storage operations use mocks only.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/deployment-identity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
real_ssh_keygen="$(command -v ssh-keygen)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$tmp/bin"
cat >"$tmp/bin/sfdisk" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == --json ]]; then cat <<'JSON'
{"partitiontable":{"label":"gpt","id":"11111111-1111-1111-1111-111111111111","sectorsize":4096,"partitions":[{"node":"/dev/mock0p1","start":2048,"size":4096},{"node":"/dev/mock0p2","start":8192,"size":16384},{"node":"/dev/mock1p1","start":2048,"size":4096},{"node":"/dev/sda1","start":2048,"size":4096},{"node":"/dev/sda2","start":8192,"size":16384}]}}
JSON
else printf '%s\n' "$*" >>"$ROOTPXE_TEST_LOG"; fi
EOF
cat >"$tmp/bin/lsblk" <<'EOF'
#!/usr/bin/env bash
if [[ $* == *'-nrpo NAME,PARTN,TYPE'* ]]; then printf '/dev/mockp1\t1\tpart\n'; elif [[ $* == *'-no PARTN'* ]]; then printf '1\n'; elif [[ $* == *'-no PKNAME'* ]]; then printf 'mock0\n'; fi
EOF
cat >"$tmp/bin/blkid" <<'EOF'
#!/usr/bin/env bash
[[ $* == *\"* ]] && exit 1
case "$*" in
  *LABEL*) printf preserved-swap-label ;;
  *TYPE*)
    if [[ ${ROOTPXE_TEST_WINDOWS:-0} == 1 ]]; then [[ $* == *sda1* ]] && printf vfat || printf ntfs
    else [[ $* == *sda1* ]] && printf vfat || printf ext4; fi
    ;;
  *PARTUUID*) printf /dev/sda1 ;;
  *UUID*|-U*) printf /dev/sda2 ;;
esac
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$ROOTPXE_CURL_ARGS"
while (($#)); do [[ $1 == --data-binary ]] && { printf '%s' "$2" >"$ROOTPXE_CURL_BODY"; break; }; shift; done
topology=$(jq -c '.topology' "$ROOTPXE_CURL_BODY")
jq -cn --argjson topology "$topology" '{plan:{version:1,planId:"plan-1",topology:$topology,disks:[{targetDevice:"/dev/mock0",partitionTable:"gpt",diskGuid:"cccccccc-cccc-cccc-cccc-cccccccccccc",partitions:[{targetDevice:"/dev/mock0p1",filesystem:"ext4",partitionGuid:"dddddddd-dddd-dddd-dddd-dddddddddddd",filesystemUuid:"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"}]}]},planHash:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",attempt:3}'
printf '\n200'
EOF
cat >"$tmp/bin/sgdisk" <<'EOF'
#!/usr/bin/env bash
printf 'sgdisk %s\n' "$*" >>"$ROOTPXE_TEST_LOG"
EOF
cat >"$tmp/bin/tune2fs" <<'EOF'
#!/usr/bin/env bash
printf 'tune2fs %s\n' "$*" >>"$ROOTPXE_TEST_LOG"
EOF
cat >"$tmp/bin/mkswap" <<'EOF'
#!/usr/bin/env bash
printf 'mkswap %s\n' "$*" >>"$ROOTPXE_TEST_LOG"
EOF
cat >"$tmp/bin/lvchange" <<'EOF'
#!/usr/bin/env bash
printf 'lvchange %s\n' "$*" >>"$ROOTPXE_TEST_LOG"
EOF
cat >"$tmp/bin/partprobe" <<'EOF'
#!/usr/bin/env bash
printf 'partprobe %s\n' "$*" >>"$ROOTPXE_TEST_LOG"
EOF
cat >"$tmp/bin/ntfs-3g" <<'EOF'
#!/usr/bin/env bash
printf 'ntfs-3g %s\n' "$*" >>"$ROOTPXE_TEST_LOG"
target="${@: -1}"
if [[ ${ROOTPXE_TEST_WINDOWS:-0} == 1 && ! -e $target/Windows/System32/config/SYSTEM ]]; then cp -a "$ROOTPXE_WINDOWS_TEMPLATE/." "$target/"; fi
EOF
cat >"$tmp/bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == -y ]]; then
  type=""; path=""
  while (($#)); do [[ $1 == -f ]] && { path="$2"; shift 2; continue; }; shift; done
  type=$(cat "$path")
  [[ $type == ecdsa ]] && type=ecdsa-sha2-nistp256 || type="ssh-$type"
  printf '%s mockmaterial\n' "$type"
  exit 0
fi
type=""; path=""
while (($#)); do
  [[ $1 == -t ]] && { type="$2"; shift 2; continue; }
  [[ $1 == -f ]] && { path="$2"; shift 2; continue; }
  shift
done
[[ -n $type && -n $path ]] || exit 1
printf '%s\n' "$type" >"$path"
[[ $type == ecdsa ]] && type=ecdsa-sha2-nistp256 || type="ssh-$type"
printf '%s mockmaterial generated-comment\n' "$type" >"$path.pub"
printf 'ssh-keygen %s\n' "$type" >>"$ROOTPXE_TEST_LOG"
EOF
cat >"$tmp/bin/chroot" <<'EOF'
#!/usr/bin/env bash
printf 'chroot %s\n' "$*" >>"$ROOTPXE_TEST_LOG"
if [[ $2 == */grub2-editenv ]]; then
  root="$1"; env="$3"; operation="$4"
  case "$operation" in
    list) cat "$root$env" ;;
    set) printf '%s\n' "$5" >"$root$env" ;;
    *) exit 1 ;;
  esac
fi
EOF
cat >"$tmp/bin/mount" <<'EOF'
#!/usr/bin/env bash
printf 'mount %s\n' "$*" >>"$ROOTPXE_TEST_LOG"
source="${@: -2:1}"; target="${@: -1}"
if [[ ${ROOTPXE_TEST_WINDOWS:-0} == 1 && $source == /dev/sda1 && ! -e $target/EFI/Microsoft/Boot/BCD ]]; then cp -a "$ROOTPXE_WINDOWS_ESP_TEMPLATE/." "$target/"; fi
if [[ ${ROOTPXE_TEST_WINDOWS:-0} == 1 && $source == /dev/sda1 && -f $ROOTPXE_WINDOWS_ESP_TEMPLATE/EFI/Boot/BOOTX64.EFI && ! -e $target/EFI/Boot/BOOTX64.EFI ]]; then mkdir -p "$target/EFI/Boot"; cp "$ROOTPXE_WINDOWS_ESP_TEMPLATE/EFI/Boot/BOOTX64.EFI" "$target/EFI/Boot/BOOTX64.EFI"; fi
if [[ ${ROOTPXE_TEST_WINDOWS:-0} != 1 && $source == /dev/vg0/root && ! -e $target/etc/fstab && -d $ROOTPXE_LINUX_TEMPLATE/root ]]; then cp -a "$ROOTPXE_LINUX_TEMPLATE/root/." "$target/"; fi
if [[ ${ROOTPXE_TEST_WINDOWS:-0} != 1 && $source == /dev/sda1 && -d $ROOTPXE_LINUX_TEMPLATE/esp ]]; then cp -a "$ROOTPXE_LINUX_TEMPLATE/esp/." "$target/"; fi
EOF
cat >"$tmp/bin/umount" <<'EOF'
#!/usr/bin/env bash
printf 'umount %s\n' "$*" >>"$ROOTPXE_TEST_LOG"
EOF
cat >"$tmp/bin/mountpoint" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat >"$tmp/bin/rootpxe-offline-identities" <<'EOF'
#!/usr/bin/env bash
mode="$1"
phase=""; result=""
while (($#)); do
  [[ $1 == --phase ]] && { phase="$2"; shift 2; continue; }
  [[ $1 == --result ]] && { result="$2"; shift 2; continue; }
  shift
done
[[ -n $result ]] || exit 1
if [[ $mode == windows-repair ]]; then
  printf 'windows %s\n' "$phase" >>"$ROOTPXE_TEST_LOG"
  if [[ $phase == preflight ]]; then
    printf '{"version":1,"phase":"preflight","storage":false,"bcd":false,"mountedDevices":false}\n' >"$result"
  else
    printf '{"version":1,"phase":"%s","storage":false,"bcd":true,"mountedDevices":true}\n' "$phase" >"$result"
  fi
  exit 0
fi
printf 'efi %s\n' "$phase" >>"$ROOTPXE_TEST_LOG"
if [[ ${ROOTPXE_EFI_BAD_UPDATED:-0} == 1 ]]; then updated='"invalid"'; else updated=2; fi
if [[ ${ROOTPXE_EFI_READBACK_FAIL:-0} == 1 ]]; then verified=false; else verified=true; fi
printf '{"version":1,"efi":{"available":true,"matched":%s,"updated":%s,"verified":%s}}\n' "${ROOTPXE_EFI_MATCHED:-1}" "$updated" "$verified" >"$result"
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" ROOTPXE_TEST_LOG="$tmp/commands" ROOTPXE_CURL_ARGS="$tmp/curl-args" ROOTPXE_CURL_BODY="$tmp/curl-body" ROOTPXE_LINUX_TEMPLATE="$tmp/linux-template"

rootpxe_disk_stable_identity() { printf 'wwn:stable-target\n'; }
taskid=17; task_token=token; mac=001122334455; pxeapi=https://service/; progress_attempt=3
schemaHash=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
imgType=n
deploymentIdentityPolicyFile="$tmp/policy"; printf '%s\n' '{"version":1,"randomizeStorageIdentifiers":true,"systemIdentity":{"hostname":false,"machineId":false,"sshHostKeys":false}}' >"$deploymentIdentityPolicyFile"
rootpxe_disk_permit_granted=yes; rootpxe_disk_permit_target_id=wwn:stable-target

. "$lib"
real_key_dir="$tmp/real-key"; mkdir -p "$real_key_dir"
"$real_ssh_keygen" -q -t ed25519 -C rootpxe-regression-comment -N '' -f "$real_key_dir/key" || fail 'real ssh-keygen fixture failed'
read -r real_key_type real_key_material _ <"$real_key_dir/key.pub"
printf '%s %s external-comment\n' "$real_key_type" "$real_key_material" >"$real_key_dir/key.pub"
ssh-keygen() { command "$real_ssh_keygen" "$@"; }
rootpxe_deployment_identity_key_pair_valid "$real_key_dir/key" "$real_key_dir/key.pub" || fail 'real ssh public comment was not ignored'
unset -f ssh-keygen
rootpxe_deployment_identity_policy_enabled || fail 'enabled policy rejected'
printf '%s\n' '{"version":1,"randomizeStorageIdentifiers":false,"systemIdentity":{"hostname":true,"machineId":false,"sshHostKeys":false}}' >"$deploymentIdentityPolicyFile"
if rootpxe_deployment_identity_policy_enabled; then
    fail 'hostname-only policy incorrectly requested a modern plan'
fi
printf '%s\n' '{"version":1,"randomizeStorageIdentifiers":true,"systemIdentity":{"hostname":false,"machineId":false,"sshHostKeys":false}}' >"$deploymentIdentityPolicyFile"
imagePath="$tmp/image"; mkdir -p "$imagePath"
cat >"$imagePath/d1.partitions" <<'EOF'
label: gpt
label-id: 11111111-1111-1111-1111-111111111111
/dev/sourcep1 : start=2048, size=4096, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
EOF
originalSchemaFile="$tmp/schema.json"
cat >"$originalSchemaFile" <<'JSON'
{"partitionTable":"gpt","partitions":[{"number":1,"role":"data","fs":"ext4","uuid":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","partuuid":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}]}
JSON
topology="$(rootpxe_deployment_identity_source_disk_topology /dev/mock0 1 "$imagePath/d1.partitions" "$originalSchemaFile")" || fail 'source topology failed'
jq -e '.targetBinding == "wwn:stable-target" and .partitionTable == "gpt" and .partitions[0].number == 1 and .partitions[0].oldPartitionId == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"' <<<"$topology" >/dev/null || fail 'topology omitted stable identifiers'
# LVM filesystem UUIDs are part of the n source topology, but the LVM UUID
# itself is only an immutable matcher.  An older capture without that UUID is
# rejected before clone writes when storage randomization is requested.
lvm_schema="$tmp/lvm-schema.json"
cat >"$lvm_schema" <<'JSON'
{"partitionTable":"gpt","partitions":[{"number":3,"role":"data","fs":"LVM2_member","uuid":"","partuuid":"33333333-3333-3333-3333-333333333333"}],"lvm":{"version":1,"pvs":[{"partitionNumber":3,"vgUuid":"vg-id"}],"vgs":[{"name":"vg0","uuid":"vg-id","pvPartitionNumbers":[3],"lvs":[{"name":"root","uuid":"lv-id","fs":"ext4","filesystemUuid":"11111111-2222-3333-4444-555555555555"}]}]}}
JSON
lvm_topology="$(rootpxe_deployment_identity_source_disk_topology /dev/mock0 1 "$imagePath/d1.partitions" "$lvm_schema")" || fail 'LVM source topology failed'
jq -e '.partitions[0].logicalVolumes[0] | (.targetDevice | endswith("/dev/vg0/root")) and .oldPartitionId == "lv-id" and .filesystem == "ext4" and .originalFilesystemUuid == "11111111-2222-3333-4444-555555555555"' <<<"$lvm_topology" >/dev/null || fail 'LVM topology omitted filesystem UUID'
jq 'del(.lvm.vgs[0].lvs[0].filesystemUuid)' "$lvm_schema" >"$tmp/lvm-schema-old.json"
if rootpxe_deployment_identity_source_disk_topology /dev/mock0 1 "$imagePath/d1.partitions" "$tmp/lvm-schema-old.json" >/dev/null; then
    fail 'legacy LVM schema without filesystem UUID was accepted'
fi
cat >"$tmp/inventory.json" <<'JSON'
{"version":1,"disks":[{"number":1,"partitionTable":"mbr","partitions":[{"number":1,"fs":"xfs","uuid":"old-xfs-uuid","partuuid":""}]}]}
JSON
cat >"$tmp/mbr.partitions" <<'EOF'
label: dos
label-id: 0xa1b2c3d4
/dev/source1 : start=2048, size=4096, type=83
EOF
inventory_topology="$(rootpxe_deployment_identity_inventory_disk_topology /dev/mock0 1 "$tmp/mbr.partitions" "$tmp/inventory.json")" || fail 'inventory topology failed'
jq -e '.sourceDiskNumber == 1 and .oldDiskId == "A1B2C3D4" and .partitions[0].oldPartitionId == "A1B2C3D4:1"' <<<"$inventory_topology" >/dev/null || fail 'inventory MBR topology omitted stable identifiers'
rootpxe_deployment_identity_request_plan /dev/mock0 || fail 'plan request failed'
jq -e '.attempt == 3 and .topology.sourceLayoutHash == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" and (.topology | has("targetBinding") | not) and .topology.disks[0].targetBinding == "wwn:stable-target"' "$tmp/curl-body" >/dev/null || fail 'plan request binding or attempt invalid'
# Git Bash rewrites /dev arguments passed through jq into a Windows path.  The
# wrapper contract itself stays unchanged; normalize only this host artifact
# before exercising the Linux apply function against its real no-number plan.
jq '(.plan.topology.disks[] |= (.targetDevice |= gsub("^C:/Program Files/Git"; "") | (.partitions[]?.targetDevice |= gsub("^C:/Program Files/Git"; ""))))' "$rootpxe_deployment_identity_plan_file" >"$tmp/plan-normalized.json" && mv "$tmp/plan-normalized.json" "$rootpxe_deployment_identity_plan_file"
rootpxe_deployment_identity_apply_linux_storage /dev/mock0 || fail 'linux storage application failed'
grep -Fq 'sgdisk -U cccccccc-cccc-cccc-cccc-cccccccccccc /dev/mock0' "$tmp/commands" || fail 'GPT disk GUID was not applied'
grep -Fq 'sgdisk -u 1:dddddddd-dddd-dddd-dddd-dddddddddddd /dev/mock0' "$tmp/commands" || fail 'GPT partition GUID was not applied'
grep -Fq 'tune2fs -U eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee /dev/mock0p1' "$tmp/commands" || fail 'ext filesystem UUID was not applied'
cat >"$tmp/windows-plan.json" <<'JSON'
{"plan":{"version":1,"planId":"plan-win","topology":{"disks":[{"targetDevice":"/dev/mock0","partitions":[{"targetDevice":"/dev/mock0p1","number":1}]}]},"disks":[{"targetDevice":"/dev/mock0","partitionTable":"gpt","diskGuid":"99999999-9999-9999-9999-999999999999","partitions":[{"targetDevice":"/dev/mock0p1","partitionGuid":"88888888-8888-8888-8888-888888888888"}]}]},"planHash":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","attempt":3}
JSON
rootpxe_deployment_identity_plan_file="$tmp/windows-plan.json"
rootpxe_deployment_identity_apply_windows_storage_targets /dev/mock0 || fail 'windows storage identifiers failed'
grep -Fq 'sgdisk -U 99999999-9999-9999-9999-999999999999 /dev/mock0' "$tmp/commands" || fail 'Windows GPT disk GUID was not applied'
grep -Fq 'sgdisk -u 1:88888888-8888-8888-8888-888888888888 /dev/mock0' "$tmp/commands" || fail 'Windows GPT partition GUID was not applied'
grep -Fq 'partprobe /dev/mock0' "$tmp/commands" || fail 'Windows partition table was not reprobed'
# New plan partitions deliberately do not carry source numbers.  Every target
# mapping must be validated from frozen topology before any GPT write occurs.
cat >"$tmp/invalid-gpt-map-plan.json" <<'JSON'
{"plan":{"topology":{"disks":[{"targetDevice":"/dev/mock0","partitions":[{"targetDevice":"/dev/mock0p1","number":1}]}]},"disks":[{"targetDevice":"/dev/mock0","partitionTable":"gpt","diskGuid":"99999999-9999-9999-9999-999999999999","partitions":[{"targetDevice":"/dev/mock0p2","partitionGuid":"88888888-8888-8888-8888-888888888888"}]}]}}
JSON
rootpxe_deployment_identity_plan_file="$tmp/invalid-gpt-map-plan.json"; : >"$tmp/commands"
if rootpxe_deployment_identity_apply_windows_storage /dev/mock0; then fail 'Windows accepted an unmapped GPT partition'; fi
[[ ! -s $tmp/commands ]] || fail 'Windows wrote GPT metadata before validating every partition mapping'
if rootpxe_deployment_identity_apply_linux_storage /dev/mock0; then fail 'Linux accepted an unmapped GPT partition'; fi
[[ ! -s $tmp/commands ]] || fail 'Linux wrote GPT metadata before validating every partition mapping'
cat >"$tmp/lvm-plan.json" <<'JSON'
{"plan":{"version":1,"planId":"plan-lvm","topology":{"disks":[{"targetDevice":"/dev/mock0","partitions":[{"targetDevice":"/dev/mock0p3","number":3,"oldPartitionId":"33333333-3333-3333-3333-333333333333","filesystem":"LVM2_member","logicalVolumes":[{"targetDevice":"/dev/vg0/root","oldPartitionId":"lv-id","filesystem":"ext4","originalFilesystemUuid":"11111111-2222-3333-4444-555555555555"}]}]}]},"disks":[{"targetDevice":"/dev/mock0","partitionTable":"gpt","diskGuid":"cccccccc-cccc-cccc-cccc-cccccccccccc","partitions":[{"targetDevice":"/dev/mock0p3","partitionGuid":"dddddddd-dddd-dddd-dddd-dddddddddddd","filesystem":"LVM2_member","logicalVolumes":[{"targetDevice":"/dev/vg0/root","filesystem":"ext4","filesystemUuid":"66666666-7777-8888-9999-aaaaaaaaaaaa"}]}]}]},"planHash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","attempt":3}
JSON
rootpxe_deployment_identity_plan_file="$tmp/lvm-plan.json"
rootpxe_deployment_identity_apply_linux_storage_targets /dev/mock0 || fail 'LVM filesystem UUID application failed'
grep -Fq 'lvchange -ay /dev/vg0/root' "$tmp/commands" || fail 'logical volume was not activated'
grep -Fq 'tune2fs -U 66666666-7777-8888-9999-aaaaaaaaaaaa /dev/vg0/root' "$tmp/commands" || fail 'logical volume filesystem UUID was not applied'
# mkswap recreates the filesystem header; carry the old LABEL explicitly while
# assigning the planned UUID so fstab labels do not silently disappear.
cat >"$tmp/swap-plan.json" <<'JSON'
{"plan":{"topology":{"disks":[{"targetDevice":"/dev/mock0","partitions":[{"targetDevice":"/dev/mock0p2","number":2}]}]},"disks":[{"targetDevice":"/dev/mock0","partitionTable":"gpt","diskGuid":"cccccccc-cccc-cccc-cccc-cccccccccccc","partitions":[{"targetDevice":"/dev/mock0p2","partitionGuid":"dddddddd-dddd-dddd-dddd-dddddddddddd","filesystem":"swap","filesystemUuid":"77777777-7777-7777-7777-777777777777"}]}]}}
JSON
rootpxe_deployment_identity_plan_file="$tmp/swap-plan.json"; : >"$tmp/commands"
rootpxe_deployment_identity_apply_linux_storage /dev/mock0 || fail 'swap UUID application failed'
grep -Fqx 'mkswap -L preserved-swap-label -U 77777777-7777-7777-7777-777777777777 /dev/mock0p2' "$tmp/commands" || fail 'swap UUID application did not preserve LABEL'
lvm_map="$(rootpxe_deployment_identity_linux_reference_map "$tmp/lvm-plan.json")" || fail 'LVM reference map failed'
printf '%s\n' "$lvm_map" | grep -Fq $'UUID\t11111111-2222-3333-4444-555555555555\t66666666-7777-8888-9999-aaaaaaaaaaaa' || fail 'LVM reference UUID map missing'
# Field separators in plan rows must preserve an empty filesystem UUID and an
# MBR partition GUID while still mapping later rows.  MBR fstab PARTUUID uses
# disk-signature-hex-partition rather than the frozen signature:number token.
cat >"$tmp/reference-map-plan.json" <<'JSON'
{"plan":{"topology":{"disks":[{"targetDevice":"/dev/mock0","sourceDiskNumber":1,"partitions":[{"targetDevice":"/dev/mock0p1","number":1,"oldPartitionId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","originalFilesystemUuid":"old-empty-next"},{"targetDevice":"/dev/mock0p2","number":2,"oldPartitionId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","originalFilesystemUuid":"old-after-empty"}]},{"targetDevice":"/dev/mock1","sourceDiskNumber":2,"partitions":[{"targetDevice":"/dev/mock1p2","number":2,"oldPartitionId":"A1B2C3D4:2"}]}]},"disks":[{"targetDevice":"/dev/mock0","partitionTable":"gpt","partitions":[{"targetDevice":"/dev/mock0p1","number":1,"partitionGuid":"cccccccc-cccc-cccc-cccc-cccccccccccc"},{"targetDevice":"/dev/mock0p2","number":2,"partitionGuid":"dddddddd-dddd-dddd-dddd-dddddddddddd","filesystemUuid":"new-after-empty"}]},{"targetDevice":"/dev/mock1","partitionTable":"mbr","diskSignature":"11223344","partitions":[{"targetDevice":"/dev/mock1p2","number":2}]}]}}
JSON
reference_map="$(rootpxe_deployment_identity_linux_reference_map "$tmp/reference-map-plan.json")" || fail 'reference map with empty fields failed'
printf '%s\n' "$reference_map" | grep -Fqx $'UUID\told-after-empty\tnew-after-empty' || fail 'empty fields shifted a later UUID mapping'
printf '%s\n' "$reference_map" | grep -Fqx $'PARTUUID\ta1b2c3d4-02\t11223344-02' || fail 'MBR PARTUUID mapping was not normalized'
# Reference syntax may quote an identifier.  GRUB also commonly puts options
# and hints between --fs-uuid and its value.  Both must preserve surrounding
# syntax while replacing only frozen values.
reference_text_map="$tmp/reference-text-map"
printf 'UUID\told-uuid\tnew-uuid\nPARTUUID\told-part\tnew-part\n' >"$reference_text_map"
reference_text=$(printf 'UUID="old-uuid" / ext4 defaults 0 1\nPARTUUID="old-part" /boot vfat defaults 0 2\nsearch --no-floppy --fs-uuid --set=root [hd0,gpt2] "old-uuid"\n' | rootpxe_deployment_identity_rewrite_linux_reference_text "$reference_text_map")
[[ $reference_text == *'UUID="new-uuid"'* && $reference_text == *'PARTUUID="new-part"'* && $reference_text == *'--set=root [hd0,gpt2] "new-uuid"'* ]] || fail 'quoted fstab or standard GRUB search references were not repaired'
# Do not follow a symlink in an ancestor directory while rewriting a target
# root.  A regular file below the escaped directory must remain untouched.
outside_defaults="$tmp/outside-defaults"; mkdir -p "$outside_defaults"
printf 'UUID=old-uuid\n' >"$outside_defaults/grub"
unsafe_reference_root="$tmp/unsafe-reference-root"; mkdir -p "$unsafe_reference_root/etc" "$unsafe_reference_root/boot"
MSYS=winsymlinks:nativestrict ln -s "$outside_defaults" "$unsafe_reference_root/etc/default"
[[ -L $unsafe_reference_root/etc/default ]] || fail 'native symlink fixture was not created'
if rootpxe_deployment_identity_rewrite_linux_references "$unsafe_reference_root" "$reference_text_map"; then
    fail 'reference rewrite followed a symlinked ancestor directory'
fi
grep -Fqx 'UUID=old-uuid' "$outside_defaults/grub" || fail 'reference rewrite changed data outside target root'
# fstab accepts quoted identifiers.  Quotes are syntax, never part of the
# blkid lookup value, and both /boot and an independent ESP must be mounted.
quoted_mount_plan="$tmp/quoted-mount-plan.json"
cat >"$quoted_mount_plan" <<'JSON'
{"plan":{"disks":[{"targetDevice":"/dev/sda","partitions":[{"targetDevice":"/dev/sda1"},{"targetDevice":"/dev/sda2"}]}]}}
JSON
quoted_mount_root="$tmp/quoted-mount-root"; mkdir -p "$quoted_mount_root/etc" "$quoted_mount_root/boot/efi"
printf 'UUID="mount-root" /boot ext4 defaults 0 1\nPARTUUID="mount-esp" /boot/efi vfat defaults 0 2\n' >"$quoted_mount_root/etc/fstab"
rootpxe_linux_mount_options() { printf '%s' "$1"; }
rootpxe_deployment_identity_plan_file="$quoted_mount_plan"; : >"$tmp/commands"
rootpxe_deployment_identity_mount_linux_boot_filesystems "$quoted_mount_root" || fail 'quoted fstab identifiers were not mounted'
grep -Fqx "mount -t ext4 -o rw /dev/sda2 $quoted_mount_root/boot" "$tmp/commands" || fail 'quoted UUID leaked into blkid or boot mount'
grep -Fqx "mount -t vfat -o rw /dev/sda1 $quoted_mount_root/boot/efi" "$tmp/commands" || fail 'quoted PARTUUID leaked into blkid or ESP mount'
rootpxe_deployment_identity_unmount_linux_boot_filesystems || fail 'quoted fstab mount cleanup failed'
# Target initramfs tools need controlled target-local /dev, /proc and /sys
# mounts.  The cleanup must run after the chroot command.
initramfs_root="$tmp/initramfs-root"; mkdir -p "$initramfs_root/etc" "$initramfs_root/lib/modules/test-kernel" "$initramfs_root/usr/bin"
printf '#!/bin/sh\n' >"$initramfs_root/usr/bin/dracut"; chmod +x "$initramfs_root/usr/bin/dracut"
: >"$tmp/commands"
rootpxe_deployment_identity_rebuild_linux_initramfs "$initramfs_root" || fail 'initramfs rebuild fixture failed'
grep -Fqx "mount --rbind /dev $initramfs_root/dev" "$tmp/commands" || fail 'initramfs rebuild did not bind target /dev'
grep -Fqx "mount -t proc proc $initramfs_root/proc" "$tmp/commands" || fail 'initramfs rebuild did not mount target /proc'
grep -Fqx "mount -t sysfs sysfs $initramfs_root/sys" "$tmp/commands" || fail 'initramfs rebuild did not mount target /sys'
grep -Fqx "umount $initramfs_root/sys" "$tmp/commands" || fail 'initramfs rebuild did not clean target /sys'
cat >"$tmp/multi-disk-plan.json" <<'JSON'
{"plan":{"version":1,"planId":"plan-multi","disks":[{"targetDevice":"/dev/mock0","partitionTable":"gpt","diskGuid":"11111111-1111-1111-1111-111111111111","partitions":[]},{"targetDevice":"/dev/mock1","partitionTable":"mbr","diskSignature":"11223344","partitions":[{"targetDevice":"/dev/mock1p1","number":1,"filesystem":"ext4","filesystemUuid":"77777777-7777-7777-7777-777777777777"}]}]},"planHash":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","attempt":3}
JSON
rootpxe_deployment_identity_plan_file="$tmp/multi-disk-plan.json"
rootpxe_deployment_identity_apply_linux_storage_targets /dev/mock1 || fail 'second plan disk selection failed'
grep -Fq '0x11223344' "$tmp/commands" || fail 'second permitted disk was not updated'
grep -Fq 'tune2fs -U 77777777-7777-7777-7777-777777777777 /dev/mock1p1' "$tmp/commands" || fail 'second disk filesystem UUID was not applied'

# A completed same-plan Linux identity setup reuses its marker and validates
# public/private pairs instead of generating a second set.  Reference files
# only replace exact UUID/PARTUUID values from the frozen plan.
linux_root="$tmp/linux-root"; mkdir -p "$linux_root/etc/ssh" "$linux_root/etc/default" "$linux_root/etc/kernel" "$linux_root/boot/loader/entries" "$linux_root/boot/grub2" "$linux_root/usr/bin" "$linux_root/lib/modules/target-kernel" "$linux_root/var/lib/dbus"
printf '#!/bin/sh\n' >"$linux_root/usr/bin/dracut"; chmod +x "$linux_root/usr/bin/dracut"
printf 'UUID=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa / ext4 defaults 0 1\nPARTUUID=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb /data ext4 defaults 0 2\n' >"$linux_root/etc/fstab"
printf 'crypt PARTUUID=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb none luks\n' >"$linux_root/etc/crypttab"
printf 'root=UUID=unmatched UUID=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" search --fs-uuid aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\n' >"$linux_root/etc/default/grub"
printf '#!/bin/sh\n' >"$linux_root/usr/bin/grub2-editenv"; chmod +x "$linux_root/usr/bin/grub2-editenv"
printf 'kernelopts=root=UUID=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" search --fs-uuid aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\n' >"$linux_root/boot/grub2/grubenv"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >"$linux_root/etc/machine-id"
printf 'outside-machine-id\n' >"$tmp/machine-id-outside"
ln -s "$tmp/machine-id-outside" "$linux_root/etc/.machine-id.rootpxe-new"
mkdir -p "$linux_root/var/lib/dbus"
printf 'old-dbus-machine-id\n' >"$linux_root/var/lib/dbus/machine-id"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >"$linux_root/etc/kernel/entry-token"
printf 'options root=PARTUUID=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb\n' >"$linux_root/boot/loader/entries/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-test.conf"
cat >"$tmp/identity-plan.json" <<'JSON'
{"plan":{"version":1,"planId":"plan-identity","topology":{"disks":[{"partitions":[{"number":1,"oldPartitionId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","originalFilesystemUuid":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}]}]},"disks":[{"diskGuid":"cccccccc-cccc-cccc-cccc-cccccccccccc","partitions":[{"partitionGuid":"dddddddd-dddd-dddd-dddd-dddddddddddd","filesystemUuid":"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"}]}],"systemIdentity":{"machineId":"0123456789abcdef0123456789abcdef"}},"planHash":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","attempt":3}
JSON
rootpxe_deployment_identity_plan_file="$tmp/identity-plan.json"
osid=50
printf '%s\n' '{"version":1,"randomizeStorageIdentifiers":true,"systemIdentity":{"hostname":false,"machineId":true,"sshHostKeys":true}}' >"$deploymentIdentityPolicyFile"
rootpxe_deployment_identity_linux_system_in_root "$linux_root" || fail 'linux system identity failed'
rootpxe_deployment_identity_linux_repair_references_in_root "$linux_root" || fail 'linux reference repair failed'
grep -Fq 'UUID=eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' "$linux_root/etc/fstab" || fail 'fstab UUID not repaired'
grep -Fq 'PARTUUID=dddddddd-dddd-dddd-dddd-dddddddddddd' "$linux_root/etc/crypttab" || fail 'crypttab PARTUUID not repaired'
grep -Fq 'UUID=unmatched UUID=eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee" search --fs-uuid eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' "$linux_root/etc/default/grub" || fail 'quoted or later GRUB references were not repaired'
grep -Fq 'kernelopts=root=UUID=eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee" search --fs-uuid eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' "$linux_root/boot/grub2/grubenv" || fail 'grubenv kernelopts was not repaired through grub2-editenv'
grep -Fq 'PARTUUID=dddddddd-dddd-dddd-dddd-dddddddddddd' "$linux_root/boot/loader/entries/0123456789abcdef0123456789abcdef-test.conf" || fail 'BLS PARTUUID not repaired'
grep -Fq "chroot $linux_root /usr/bin/dracut -f --kver target-kernel" "$tmp/commands" || fail 'initramfs was not rebuilt'
[[ $(cat "$linux_root/etc/machine-id") == 0123456789abcdef0123456789abcdef ]] || fail 'machine-id not applied'
[[ ! -L $linux_root/etc/machine-id && $(cat "$tmp/machine-id-outside") == outside-machine-id ]] || fail 'machine-id staging followed a symlink'
[[ $(cat "$linux_root/var/lib/dbus/machine-id") == 0123456789abcdef0123456789abcdef ]] || fail 'regular dbus machine-id was not updated'
[[ $(cat "$linux_root/etc/kernel/entry-token") == 0123456789abcdef0123456789abcdef ]] || fail 'BLS entry token not updated'
[[ $(grep -c '^ssh-keygen ' "$tmp/commands") == 3 ]] || fail 'expected first SSH key generation'
rootpxe_deployment_identity_linux_system_in_root "$linux_root" || fail 'same plan identity reuse failed'
[[ $(grep -c '^ssh-keygen ' "$tmp/commands") == 3 ]] || fail 'same plan generated new SSH keys'
# Standard non-recursive Include snippets select only the configured host key;
# recursive Include and unknown paths fail before any key replacement.
ssh_root="$tmp/ssh-config-root"; mkdir -p "$ssh_root/etc/ssh/sshd_config.d"
printf 'Include /etc/ssh/sshd_config.d/*.conf\n' >"$ssh_root/etc/ssh/sshd_config"
printf 'HostKey /etc/ssh/ssh_host_ed25519_key\n' >"$ssh_root/etc/ssh/sshd_config.d/10-hostkeys.conf"
rootpxe_deployment_identity_collect_ssh_host_keys "$ssh_root" || fail 'standard ssh Include was rejected'
[[ ${rootpxe_deployment_identity_ssh_keys[*]} == ed25519 ]] || fail 'included ssh HostKey was not selected'
printf 'Include /etc/ssh/sshd_config.d/*.conf\n' >>"$ssh_root/etc/ssh/sshd_config.d/10-hostkeys.conf"
if rootpxe_deployment_identity_collect_ssh_host_keys "$ssh_root"; then
    fail 'recursive ssh Include was accepted'
fi
empty_include_root="$tmp/empty-include-root"; mkdir -p "$empty_include_root/etc/ssh/sshd_config.d"
printf 'Include /etc/ssh/sshd_config.d/*.conf\n' >"$empty_include_root/etc/ssh/sshd_config"
rootpxe_deployment_identity_collect_ssh_host_keys "$empty_include_root" || fail 'empty ssh Include glob was rejected'
[[ ${rootpxe_deployment_identity_ssh_keys[*]} == 'ecdsa ed25519 rsa' ]] || fail 'empty ssh Include did not retain default keys'
rootpxe_deployment_identity_machine_id_dbus_link_target_safe ../../../etc/machine-id || fail 'relative in-root dbus machine-id symlink was rejected'
rootpxe_deployment_identity_machine_id_dbus_link_target_safe /etc/machine-id || fail 'absolute in-root dbus machine-id symlink was rejected'
if rootpxe_deployment_identity_machine_id_dbus_link_target_safe ../../../../etc/machine-id; then fail 'escaping dbus machine-id symlink was accepted'; fi
# Machine-ID boot-path updates must not follow a symlinked etc/kernel or BLS
# ancestor, and a failed entry-token write is a real failure rather than a
# best-effort success.
machine_old=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; machine_new=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
machine_outside="$tmp/machine-id-outside-tree"; mkdir -p "$machine_outside" "$tmp/machine-id-safe-root/etc" "$tmp/machine-id-safe-root/boot"
printf '%s\n' "$machine_old" >"$machine_outside/entry-token"
MSYS=winsymlinks:nativestrict ln -s "$machine_outside" "$tmp/machine-id-safe-root/etc/kernel"
[[ -L $tmp/machine-id-safe-root/etc/kernel ]] || fail 'native machine-id kernel symlink fixture was not created'
if rootpxe_deployment_identity_update_machine_id_boot_paths "$tmp/machine-id-safe-root" "$machine_old" "$machine_new"; then fail 'machine-id update followed a symlinked etc/kernel ancestor'; fi
[[ $(cat "$machine_outside/entry-token") == "$machine_old" ]] || fail 'machine-id update changed entry token outside target root'
machine_write_root="$tmp/machine-id-write-root"; mkdir -p "$machine_write_root/etc/kernel"
printf '%s\n' "$machine_old" >"$machine_write_root/etc/kernel/entry-token"
if (printf() { return 1; }; rootpxe_deployment_identity_update_machine_id_boot_paths "$machine_write_root" "$machine_old" "$machine_new"); then fail 'machine-id entry-token write failure was ignored'; fi
machine_bls_outside="$tmp/machine-id-bls-outside"; mkdir -p "$machine_bls_outside/entries" "$tmp/machine-id-bls-root/etc" "$tmp/machine-id-bls-root/boot"
printf 'options test\n' >"$machine_bls_outside/entries/${machine_old}-test.conf"
MSYS=winsymlinks:nativestrict ln -s "$machine_bls_outside" "$tmp/machine-id-bls-root/boot/loader"
[[ -L $tmp/machine-id-bls-root/boot/loader ]] || fail 'native machine-id BLS symlink fixture was not created'
if rootpxe_deployment_identity_update_machine_id_boot_paths "$tmp/machine-id-bls-root" "$machine_old" "$machine_new"; then fail 'machine-id update followed a symlinked BLS ancestor'; fi
[[ -f $machine_bls_outside/entries/${machine_old}-test.conf && ! -e $machine_bls_outside/entries/${machine_new}-test.conf ]] || fail 'machine-id BLS rename escaped target root'

# Windows storage-reference repair and EFI repair share one mount context.  A
# normal installation may omit ReAgent.xml, which must not turn the successful
# BCD repair flow into a false failure or unmount the context before EFI runs.
windows_template="$tmp/windows-template"; windows_esp_template="$tmp/windows-esp-template"
mkdir -p "$windows_template/Windows/System32/config" "$windows_template/Boot" "$windows_esp_template/EFI/Microsoft/Boot" "$windows_esp_template/EFI/Boot"
: >"$windows_template/Windows/System32/config/SYSTEM"; : >"$windows_template/Boot/BCD"; : >"$windows_esp_template/EFI/Microsoft/Boot/BCD"; : >"$windows_esp_template/EFI/Boot/BOOTX64.EFI"
windows_schema="$tmp/windows-schema.json"
cat >"$windows_schema" <<'JSON'
{"logicalSectorBytes":4096,"partitions":[{"number":1,"startSectors":2048,"originalSectors":4096,"role":"efi","typeGuid":"C12A7328-F81F-11D2-BA4B-00A0C93EC93B"},{"number":2,"startSectors":8192,"originalSectors":16384}]}
JSON
windows_repair_plan="$tmp/windows-repair-plan.json"
cat >"$windows_repair_plan" <<'JSON'
{"plan":{"version":1,"planId":"windows-repair","topology":{"disks":[{"targetDevice":"/dev/sda","sourceDiskNumber":1,"partitionTable":"gpt","targetBinding":"wwn:stable-target","oldDiskId":"11111111-1111-1111-1111-111111111111","partitions":[{"targetDevice":"/dev/sda1","number":1,"oldPartitionId":"old-esp"},{"targetDevice":"/dev/sda2","number":2,"oldPartitionId":"old-windows"}]}]},"disks":[{"targetDevice":"/dev/sda","partitionTable":"gpt","diskGuid":"22222222-2222-2222-2222-222222222222","partitions":[{"targetDevice":"/dev/sda1","partitionGuid":"33333333-3333-3333-3333-333333333333"},{"targetDevice":"/dev/sda2","partitionGuid":"44444444-4444-4444-4444-444444444444"}]}]},"planHash":"abababababababababababababababababababababababababababababababab","attempt":3}
JSON
export ROOTPXE_TEST_WINDOWS=1 ROOTPXE_WINDOWS_TEMPLATE="$windows_template" ROOTPXE_WINDOWS_ESP_TEMPLATE="$windows_esp_template"
rootpxe_deployment_identity_windows_dir="$tmp/windows-repair-context"; mkdir -p "$rootpxe_deployment_identity_windows_dir"; rootpxe_deployment_identity_plan_file="$windows_repair_plan"; originalSchemaFile="$windows_schema"; imgType=n
rootpxe_deployment_identity_efi_var_fs="$tmp/windows-efivars"; mkdir -p "$rootpxe_deployment_identity_efi_var_fs"
# A loader on the NTFS Windows volume is not proof of an ESP fallback.  The
# frozen ESP itself must be the controlled vfat mount containing the loader.
boottype=pxe
rm -f "$windows_esp_template/EFI/Boot/BOOTX64.EFI"
mkdir -p "$windows_template/EFI/Boot"; : >"$windows_template/EFI/Boot/BOOTX64.EFI"
: >"$tmp/commands"
if rootpxe_deployment_identity_windows_preflight; then fail 'Windows fallback accepted a loader found only on NTFS'; fi
# A standard Windows ESP normally boots through this three-level Microsoft
# loader path.  It is sufficient evidence of UEFI when native NVRAM matching
# succeeds, even without the removable-media fallback or a Linux loader.
rm -f "$windows_template/EFI/Boot/BOOTX64.EFI" "$windows_esp_template/EFI/Boot/BOOTX64.EFI" "$rootpxe_deployment_identity_windows_dir/v0/EFI/Boot/BOOTX64.EFI"
rm -rf "$windows_esp_template/EFI/Linux" "$rootpxe_deployment_identity_windows_dir/v0/EFI/Linux"
mkdir -p "$windows_esp_template/EFI/Microsoft/Boot" "$rootpxe_deployment_identity_windows_dir/v0/EFI/Microsoft/Boot"
: >"$windows_esp_template/EFI/Microsoft/Boot/bootmgfw.efi"; : >"$rootpxe_deployment_identity_windows_dir/v0/EFI/Microsoft/Boot/bootmgfw.efi"
export ROOTPXE_EFI_MATCHED=1
: >"$tmp/commands"
rootpxe_deployment_identity_windows_preflight || fail 'Windows standard Microsoft ESP loader was not treated as UEFI'
grep -Fqx 'efi preflight' "$tmp/commands" || fail 'Windows standard Microsoft loader skipped EFI repair'
[[ ! -e $rootpxe_deployment_identity_windows_dir/v0/EFI/Boot/BOOTX64.EFI && ! -e $rootpxe_deployment_identity_windows_dir/v0/EFI/Linux/grubx64.efi ]] || fail 'Windows standard loader fixture retained fallback or Linux loader'
: >"$windows_esp_template/EFI/Boot/BOOTX64.EFI"
# A dual-boot ESP may contain Microsoft and Linux components; it remains UEFI
# even when PXEOS itself was reached through the ordinary PXE transport.
mkdir -p "$windows_esp_template/EFI/Linux"; : >"$windows_esp_template/EFI/Linux/grubx64.efi"
: >"$tmp/commands"
rootpxe_deployment_identity_windows_preflight || fail 'Windows dual-boot ESP was not treated as UEFI'
grep -Fqx 'efi preflight' "$tmp/commands" || fail 'Windows dual-boot ESP skipped EFI repair'
export ROOTPXE_EFI_MATCHED=0
rm -f "$windows_esp_template/EFI/Boot/BOOTX64.EFI"
rm -f "$rootpxe_deployment_identity_windows_dir/v0/EFI/Boot/BOOTX64.EFI"
: >"$tmp/commands"
if rootpxe_deployment_identity_windows_preflight; then fail 'Windows matched-zero EFI result accepted a missing standard fallback'; fi
: >"$windows_esp_template/EFI/Boot/BOOTX64.EFI"
rootpxe_deployment_identity_windows_preflight || fail 'Windows matched-zero EFI result rejected a mounted standard fallback'
unset ROOTPXE_EFI_MATCHED
: >"$tmp/commands"
rootpxe_deployment_identity_windows_preflight || fail 'Windows preflight with omitted ReAgent.xml failed'
jq -e --arg root "$rootpxe_deployment_identity_windows_root" --arg efiVarFs "$rootpxe_deployment_identity_efi_var_fs" '.stateRoot == $root and .efiVarFs == $efiVarFs and (.volumes | length) == 2 and (.reAgentXml | length) == 0' "$rootpxe_deployment_identity_windows_manifest_file" >/dev/null || fail 'Windows manifest omitted the EFI state root, full mounted geometry or empty ReAgent list'
: >"$tmp/commands"
rootpxe_deployment_identity_windows_apply_repair || fail 'Windows repair with omitted ReAgent.xml failed'
windows_apply_line=$(grep -n '^windows apply$' "$tmp/commands" | cut -d: -f1)
windows_verify_line=$(grep -n '^windows verify$' "$tmp/commands" | cut -d: -f1)
efi_apply_line=$(grep -n '^efi apply$' "$tmp/commands" | cut -d: -f1)
efi_verify_line=$(grep -n '^efi verify$' "$tmp/commands" | cut -d: -f1)
first_umount_line=$(grep -n '^umount ' "$tmp/commands" | head -n1 | cut -d: -f1)
[[ -n $windows_apply_line && -n $windows_verify_line && -n $efi_apply_line && -n $efi_verify_line && -n $first_umount_line && $windows_apply_line -lt $windows_verify_line && $windows_verify_line -lt $efi_apply_line && $efi_apply_line -lt $efi_verify_line && $efi_verify_line -lt $first_umount_line ]] || fail 'Windows EFI repair was not completed before context cleanup'
windows_bios_schema="$tmp/windows-bios-schema.json"
jq '(.partitions[0].role) = "data" | (.partitions[0].typeGuid) = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"' "$windows_schema" >"$windows_bios_schema"
originalSchemaFile="$windows_bios_schema"; boottype=pxe; : >"$tmp/commands"
rootpxe_deployment_identity_windows_preflight || fail 'BIOS-only Windows target was rejected without boottype=bios'
[[ $(grep -c '^efi ' "$tmp/commands" || true) == 0 ]] || fail 'BIOS-only Windows target invoked EFI repair'
originalSchemaFile="$windows_schema"; unset boottype
unset ROOTPXE_TEST_WINDOWS

# Linux EFI repair keeps its manifest below the authorised target root.  The
# fixture has an independent ESP and an LVM root, so preflight must happen
# while both mounts still resolve their old identifiers, before sgdisk changes
# the GPT PARTUUID values.
linux_efi_state="$tmp/linux-efi-state"; linux_efi_template="$tmp/linux-template"
mkdir -p "$linux_efi_template/root/etc" "$linux_efi_template/root/boot/efi" "$linux_efi_template/root/usr/bin" "$linux_efi_template/root/lib/modules/target-kernel" "$linux_efi_template/esp/EFI/BOOT"
printf 'UUID=old-root / ext4 defaults 0 1\nPARTUUID=old-esp /boot/efi vfat defaults 0 2\n' >"$linux_efi_template/root/etc/fstab"
printf 'host\n' >"$linux_efi_template/root/etc/hostname"; : >"$linux_efi_template/root/etc/hosts"
printf '#!/bin/sh\n' >"$linux_efi_template/root/usr/bin/dracut"; chmod +x "$linux_efi_template/root/usr/bin/dracut"
printf 'fallback\n' >"$linux_efi_template/esp/EFI/BOOT/BOOTX64.EFI"
linux_efi_schema="$tmp/linux-efi-schema.json"
cat >"$linux_efi_schema" <<'JSON'
{"logicalSectorBytes":512,"partitions":[{"number":1,"startSectors":2048,"originalSectors":4096,"role":"efi","typeGuid":"C12A7328-F81F-11D2-BA4B-00A0C93EC93B"},{"number":2,"startSectors":8192,"originalSectors":16384,"role":"lvm_pv","typeGuid":"0FC63DAF-8483-4772-8E79-3D69D8477DE4"}]}
JSON
linux_efi_plan="$tmp/linux-efi-plan.json"
cat >"$linux_efi_plan" <<'JSON'
{"plan":{"version":1,"planId":"linux-efi","topology":{"disks":[{"targetDevice":"/dev/sda","targetBinding":"wwn:stable-target","sourceDiskNumber":1,"partitionTable":"gpt","oldDiskId":"11111111-1111-1111-1111-111111111111","partitions":[{"targetDevice":"/dev/sda1","number":1,"oldPartitionId":"old-esp","originalFilesystemUuid":"old-esp-fs"},{"targetDevice":"/dev/sda2","number":2,"oldPartitionId":"old-root-part","logicalVolumes":[{"targetDevice":"/dev/vg0/root","oldPartitionId":"lv-old","filesystem":"ext4","originalFilesystemUuid":"old-root"}]}]}]},"disks":[{"targetDevice":"/dev/sda","partitionTable":"gpt","diskGuid":"22222222-2222-2222-2222-222222222222","partitions":[{"targetDevice":"/dev/sda1","partitionGuid":"33333333-3333-3333-3333-333333333333","filesystem":"vfat","filesystemUuid":"new-esp-fs"},{"targetDevice":"/dev/sda2","partitionGuid":"55555555-5555-5555-5555-555555555555","filesystem":"LVM2_member","logicalVolumes":[{"targetDevice":"/dev/vg0/root","filesystem":"ext4","filesystemUuid":"new-root"}]}]}]},"planHash":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","attempt":3}
JSON
rootpxe_find_linux_root_filesystem() { printf '/dev/vg0/root|ext4|vg0|vg-id|\n'; }
rootpxe_linux_activate_vg_if_needed() { printf 'no\n'; }
rootpxe_linux_cleanup_selected_vg() { return 0; }
rootpxe_linux_mount_options() { printf '%s' "$1"; }
rootpxe_linux_paths_safe_for_write() { [[ -d $1/etc && ! -L $1/etc ]]; }
rootpxe_deployment_identity_linux_state_root="$linux_efi_state"
rootpxe_deployment_identity_plan_file="$linux_efi_plan"; originalSchemaFile="$linux_efi_schema"; imgType=n
rootpxe_deployment_identity_efi_var_fs="$tmp/efivars"; mkdir -p "$rootpxe_deployment_identity_efi_var_fs"
: >"$tmp/commands"
rootpxe_deployment_identity_linux_storage_preflight /dev/sda || fail 'Linux EFI preflight failed'
manifest="$linux_efi_state/.rootpxe-offline-identities/linux-efi/efi/manifest.json"
jq -e --arg root "$linux_efi_state" '.version == 1 and .stateRoot == $root and (.volumes | length) == 2 and .volumes[0].newLogicalSectorBytes == 4096 and .volumes[0].newOffsetBytes == 8388608' "$manifest" >/dev/null || fail 'Linux EFI manifest did not use sfdisk logical-sector geometry'
rootpxe_deployment_identity_apply_linux_storage /dev/sda || fail 'Linux storage apply after EFI preflight failed'
rootpxe_deployment_identity_linux_repair_references_in_root "$linux_efi_state" || fail 'Linux EFI apply and verify failed'
preflight_line=$(grep -n '^efi preflight$' "$tmp/commands" | head -n1 | cut -d: -f1)
sgdisk_line=$(grep -n '^sgdisk -U 22222222-2222-2222-2222-222222222222 /dev/sda$' "$tmp/commands" | head -n1 | cut -d: -f1)
[[ -n $preflight_line && -n $sgdisk_line && $preflight_line -lt $sgdisk_line ]] || fail 'EFI preflight did not run before sgdisk'
grep -Fqx 'efi apply' "$tmp/commands" || fail 'Linux EFI apply was not called'
grep -Fqx 'efi verify' "$tmp/commands" || fail 'Linux EFI verify was not called'
rootpxe_deployment_identity_boot_mount_records=("$linux_efi_state/boot/efi"$'\x1f'"/dev/sda1")
rootpxe_deployment_identity_efi_var_fs="$tmp/no-efivars"
rootpxe_deployment_identity_linux_efi_phase "$linux_efi_state" preflight || fail 'EFI fallback was rejected when efivarfs was unavailable'
rm -f "$linux_efi_state/boot/efi/EFI/BOOT/BOOTX64.EFI"
if rootpxe_deployment_identity_linux_efi_phase "$linux_efi_state" preflight; then fail 'EFI fallback accepted a missing standard loader'; fi
printf 'fallback\n' >"$linux_efi_state/boot/efi/EFI/BOOT/BOOTX64.EFI"
rootpxe_deployment_identity_efi_var_fs="$tmp/efivars"; export ROOTPXE_EFI_MATCHED=0
rootpxe_deployment_identity_linux_efi_phase "$linux_efi_state" preflight || fail 'matched-zero EFI result did not accept a real fallback'
rm -f "$linux_efi_state/boot/efi/EFI/BOOT/BOOTX64.EFI"
if rootpxe_deployment_identity_linux_efi_phase "$linux_efi_state" preflight; then fail 'matched-zero EFI result accepted a missing fallback'; fi
printf 'fallback\n' >"$linux_efi_state/boot/efi/EFI/BOOT/BOOTX64.EFI"; export ROOTPXE_EFI_MATCHED=1
export ROOTPXE_EFI_BAD_UPDATED=1
if rootpxe_deployment_identity_linux_efi_phase "$linux_efi_state" apply; then fail 'non-numeric EFI updated count was accepted'; fi
unset ROOTPXE_EFI_BAD_UPDATED
export ROOTPXE_EFI_READBACK_FAIL=1
if rootpxe_deployment_identity_linux_efi_phase "$linux_efi_state" verify; then fail 'failed EFI readback was accepted'; fi
unset ROOTPXE_EFI_READBACK_FAIL
cp "$linux_efi_schema" "$tmp/linux-bios-schema.json"
jq '(.partitions[0].role) = "data" | (.partitions[0].typeGuid) = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"' "$tmp/linux-bios-schema.json" >"$tmp/linux-bios-schema.next" && mv "$tmp/linux-bios-schema.next" "$tmp/linux-bios-schema.json"
efi_calls_before=$(grep -c '^efi ' "$tmp/commands" || true)
originalSchemaFile="$tmp/linux-bios-schema.json"
rootpxe_deployment_identity_linux_efi_preflight "$linux_efi_state" || fail 'BIOS-only storage was rejected'
[[ $(grep -c '^efi ' "$tmp/commands" || true) == "$efi_calls_before" ]] || fail 'BIOS-only storage invoked EFI repair'
originalSchemaFile="$linux_efi_schema"
printf 'PASS: PXEOS deployment identity regression\n'
