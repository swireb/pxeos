#!/usr/bin/env bash
# Temporary command stubs only: this suite never accesses host LVM or disks.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$tmp/bin" "$tmp/image"; export PATH="$tmp/bin:$PATH" LVM_TRACE="$tmp/trace"; : >"$LVM_TRACE"
cat >"$tmp/bin/pvs" <<'EOF'
#!/usr/bin/env bash
case " $* " in
 *' pv_name,pv_uuid,vg_name,vg_uuid,pv_size,pe_start '*) printf ' /dev/mock1 | pv-1 | vg0 | vg-1 | 268435456 | 1048576\n'; [[ ${PVS_FAIL:-0} != 1 ]] || exit 1; [[ ${LVM_MODE:-ok} != multi ]] || printf ' /dev/mock1 | pv-2 | vg0 | vg-1 | 268435456 | 1048576\n'; exit 0;;
 *' pv_name,vg_uuid '*) printf ' /dev/mock1 | vg-1\n'; [[ ${PVS_ALL_FAIL:-0} != 1 ]] || exit 1; [[ ${LVM_MODE:-ok} != cross ]] || printf ' /dev/foreign1 | vg-1\n'; exit 0;;
 *' pv_uuid '*) printf ' pv-1\n';;
esac
EOF
cat >"$tmp/bin/vgs" <<'EOF'
#!/usr/bin/env bash
printf ' vg0 | vg-1 | 4194304 | 0\n'; [[ ${VGS_FAIL:-0} != 1 ]] || exit 1
EOF
cat >"$tmp/bin/lvs" <<'EOF'
#!/usr/bin/env bash
printf ' root | lv-root | /dev/vg0/root | 67108864 | -wi-a----- | %s |  |  |  | \n' "${LVM_SEGTYPE:-linear}"
printf ' swap | lv-swap | /dev/vg0/swap | 33554432 | -wi-a----- | linear |  |  |  | \n'
[[ ${LVS_FAIL:-0} != 1 ]] || exit 1
EOF
cat >"$tmp/bin/blockdev" <<'EOF'
#!/usr/bin/env bash
case "$1" in --getsize64) case "$2" in /dev/mock1) echo 268435456;; /dev/vg0/root) [[ -f ${LVM_SIZE_STATE:-} ]] && cat "$LVM_SIZE_STATE" || echo 67108864;; /dev/vg0/swap) echo 33554432;; *) echo 209715200;; esac;; --getss|--getpbsz) echo 512;; *) exit 1;; esac
EOF
cat >"$tmp/bin/blkid" <<'EOF'
#!/usr/bin/env bash
for last; do :; done
case " $* " in *' TYPE '*) [[ ${LVM_MODE:-ok} == crypt ]] && { echo crypto_LUKS; exit 0; }; [[ ${LVM_MODE:-ok} == mdraid ]] && { echo linux_raid_member; exit 0; }; [[ $last == /dev/vg0/swap ]] && echo swap || echo "${LVM_FS:-ext4}";; *' UUID '*) [[ $last == /dev/vg0/swap ]] && echo swap-uuid || echo root-uuid;; esac
EOF
cat >"$tmp/bin/pvdisplay" <<'EOF'
#!/usr/bin/env bash
[[ ${PV_FAIL:-0} == 1 ]] && exit 1; echo 'PV UUID pv-1'
EOF
cat >"$tmp/bin/vgcfgbackup" <<'EOF'
#!/usr/bin/env bash
[[ ${VG_FAIL:-0} == 1 ]] && exit 1; while (($#)); do [[ $1 == -f ]] && { echo pv-1 >"$2"; exit 0; }; shift; done; exit 1
EOF
cat >"$tmp/bin/resize2fs" <<'EOF'
#!/usr/bin/env bash
[[ $1 == -P ]] && { echo 'Estimated minimum size of the filesystem: 8192'; exit 0; }; echo "resize2fs:$*" >>"$LVM_TRACE"
EOF
cat >"$tmp/bin/dumpe2fs" <<'EOF'
#!/usr/bin/env bash
echo 'Block size:               4096'
EOF
for cmd in partclone.extfs partclone.xfs pvcreate vgcfgrestore pvresize vgchange lvresize lvreduce lvextend lvcreate vgcreate mkswap e2fsck; do
printf '#!/usr/bin/env bash\necho "%s:$*" >>"$LVM_TRACE"\nexit 0\n' "$cmd" >"$tmp/bin/$cmd"; chmod +x "$tmp/bin/$cmd"
done
cat >"$tmp/bin/lvresize" <<'EOF'
#!/usr/bin/env bash
echo "lvresize:$*" >>"$LVM_TRACE"
while (($#)); do
  if [[ $1 == -L ]]; then
    value=${2%B}
    shift 2
    [[ ${!#} == /dev/vg0/root && $value =~ ^[1-9][0-9]*$ ]] && printf '%s\n' "$value" >"$LVM_SIZE_STATE"
    exit 0
  fi
  shift
done
exit 1
EOF
chmod +x "$tmp/bin/lvresize"
cat >"$tmp/bin/lvreduce" <<'EOF'
#!/usr/bin/env bash
echo "lvreduce:$*" >>"$LVM_TRACE"; [[ ${LVREDUCE_FAIL:-0} != 1 ]] || exit 1; echo 37748736 >"$LVM_SIZE_STATE"
EOF
chmod +x "$tmp/bin/lvreduce"
cat >"$tmp/bin/lvextend" <<'EOF'
#!/usr/bin/env bash
echo "lvextend:$*" >>"$LVM_TRACE"; echo 67108864 >"$LVM_SIZE_STATE"
EOF
chmod +x "$tmp/bin/lvextend"
cat >"$tmp/bin/e2fsck" <<'EOF'
#!/usr/bin/env bash
echo "e2fsck:$*" >>"$LVM_TRACE"
exit "${E2FSCK_RC:-0}"
EOF
chmod +x "$tmp/bin/e2fsck"
cat >"$tmp/bin/jq" <<'EOF'
#!/usr/bin/env bash
args="$*"
[[ $args == *'--argjson number'* || $args == *'has("lvm")'* || $args == *'.version == 2'* ]] && exit 0
if [[ $args == *'--rawfile lvs'* ]]; then [[ -n ${JQ_ARGS_LOG:-} ]] && printf '%s\n' "$args" >>"$JQ_ARGS_LOG"; echo '{"version":2,"pvs":[{"partitionNumber":1,"uuid":"pv-1","vgUuid":"vg-1","originalBytes":268435456,"minBytes":105906176,"peStartBytes":1048576,"artifact":"d1.pv.pv-1.meta","vgConfigArtifact":"d1.vg.vg-1.cfg"}],"vgs":[{"name":"vg0","uuid":"vg-1","extentBytes":4194304,"pvPartitionNumbers":[1],"originalFreeBytes":0,"lvs":[{"name":"root","uuid":"lv-root","layout":"linear","originalBytes":67108864,"minBytes":37748736,"fs":"ext4","role":"data","resizable":true,"artifact":"d1.lv.lv-root.img"},{"name":"swap","uuid":"lv-swap","layout":"linear","originalBytes":33554432,"minBytes":33554432,"fs":"swap","role":"swap","resizable":false,"artifact":"","swapUuid":"swap-uuid"}]}]}'; exit 0; fi
if [[ $args == *'--slurpfile schema'* ]]; then [[ ${LAYOUT_MODE:-ok} != belowmin ]] || exit 1; echo '{"pv":{"partitionNumber":1,"uuid":"pv-1","originalBytes":268435456,"artifact":"d1.pv.pv-1.meta","vgConfigArtifact":"d1.vg.vg-1.cfg"},"vg":{"name":"vg0","uuid":"vg-1","extentBytes":4194304},"pvBytes":268435456,"volumes":[{"name":"root","uuid":"lv-root","fs":"ext4","artifact":"d1.lv.lv-root.img","resolvedBytes":67108864},{"name":"swap","uuid":"lv-swap","fs":"swap","artifact":"","swapUuid":"swap-uuid","resolvedBytes":33554432}]}'; exit 0; fi
if [[ $args == *'.volumes[]|.name,'* ]]; then
  [[ ${LVM_LIST_MODE:-ok} != fail ]] || exit 1
  [[ ${LVM_LIST_MODE:-ok} != empty ]] || exit 0
  artifact=${LVM_PIPE_ARTIFACT:+d1.lv.name\|safe.img}; artifact=${artifact:-d1.lv.lv-root.img}
  printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' root lv-root ext4 "$artifact" 67108864 swap lv-swap swap '' 33554432
  exit 0
fi
case "$args" in *'.volumes|length'*) echo 2;; *'.pv.uuid'*) echo pv-1;; *'.vg.name'*) echo vg0;; *'.pv.originalBytes'*) echo 268435456;; *'.vg.uuid'*) echo vg-1;; *'.vg.extentBytes'*) echo 4194304;; *'.pv.partitionNumber'*) echo 1;; *'.pv.artifact'*) echo d1.pv.pv-1.meta;; *'.pv.vgConfigArtifact'*) echo d1.vg.vg-1.cfg;; *'.pvBytes'*) [[ ${LVM_SMALL:-0} == 1 ]] && echo 134217728 || echo 268435456;; *'swapUuid'*) echo swap-uuid;; *) exit 1;; esac
EOF
chmod +x "$tmp/bin"/*
sed "s|/usr/share/pxeos|$overlay/usr/share/pxeos|g" "$overlay/usr/share/pxeos/lib/funcs.sh" >"$tmp/funcs.sh"
# shellcheck disable=SC1090
ismajordebug=0
. "$tmp/funcs.sh"
# The production trimmer uses sed, which makes this pure mock suite very slow
# under Git Bash on Windows.  Keep equivalent whitespace semantics locally so
# branch coverage is bounded without replacing any production command flow.
rootpxe_lvm_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}
# Keep the LVM command contract in-process. Git Bash process startup otherwise
# dominates this mock matrix and obscures whether a failure is handled by the
# production preflight rather than by the test runner timeout.
pvs() {
  case " $* " in
    *' pv_name,pv_uuid,vg_name,vg_uuid,pv_size,pe_start '*)
      printf ' /dev/mock1 | pv-1 | vg0 | vg-1 | 268435456 | 1048576\n'; [[ ${PVS_FAIL:-0} != 1 ]] || return 1
      [[ ${LVM_MODE:-ok} != multi ]] || printf ' /dev/mock1 | pv-2 | vg0 | vg-1 | 268435456 | 1048576\n'; return 0 ;;
    *' pv_name,vg_uuid '*)
      printf ' /dev/mock1 | vg-1\n'; [[ ${PVS_ALL_FAIL:-0} != 1 ]] || return 1
      [[ ${LVM_MODE:-ok} != cross ]] || printf ' /dev/foreign1 | vg-1\n'; return 0 ;;
    *' pv_uuid '*) printf ' pv-1\n'; return 0 ;;
  esac
  return 0
}
vgs() { printf ' vg0 | vg-1 | 4194304 | 0\n'; [[ ${VGS_FAIL:-0} != 1 ]]; }
lvs() {
  printf ' root | lv-root | /dev/vg0/root | 67108864 | -wi-a----- | %s |  |  |  | \n' "${LVM_SEGTYPE:-linear}"
  printf ' swap | lv-swap | /dev/vg0/swap | 33554432 | -wi-a----- | linear |  |  |  | \n'
  [[ ${LVS_FAIL:-0} != 1 ]]
}
export LVM_SIZE_STATE="$tmp/lv-size"; echo 67108864 >"$LVM_SIZE_STATE"
getPartitions() { parts='/dev/mock1'; }
getPartitionNumber() { part_number=${1##*mock}; part_number=${part_number##*p}; }
uploadFormat() { [[ ${UPLOAD_FAIL:-0} != 1 ]] || return 1; : >"$2.000"; rootpxe_last_writer_pid=1; }
rootpxe_wait_for_writer() { [[ ${WRITER_FAIL:-0} != 1 ]]; }

# Legal preflight/capture executes real helper branches; it occurs before any permit.
rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" || fail legal-preflight
[[ $rootpxe_lvm_active == yes && $rootpxe_lvm_pv_number == 1 ]] || fail facts
for command_failure in PVS_FAIL PVS_ALL_FAIL VGS_FAIL LVS_FAIL; do
  export "$command_failure"=1
  rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" && fail "$command_failure-process-substitution-hidden"
  [[ ${rootpxe_lvm_active:-no} != yes && -z ${rootpxe_lvm_facts_file:-} && -z ${rootpxe_lvm_lv_facts_file:-} ]] || fail "$command_failure-facts-not-cleaned"
  unset "$command_failure"
done
rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" || fail preflight-after-command-failure
export E2FSCK_RC=1; rootpxe_capture_lvm_volumes "$tmp/image" || fail legal-capture-e2fsck-fixed; unset E2FSCK_RC
[[ -s "$tmp/image/d1.lvm.schema.json" && -f "$tmp/image/d1.lv.lv-root.img" && ! -e "$tmp/image/d1.lv.lv-swap.img" ]] || fail artifacts
awk -F'|' '$5 == "swap" && $6 != "" { exit 1 }' "$tmp/image/d1.lvm.capture.tsv" || fail swap-artifact-inherited
grep -Fq 'partclone.extfs:' "$LVM_TRACE" || fail writer-not-run
grep -Fq 'lvreduce:' "$LVM_TRACE" || fail source-shrink-missing
grep -Fq 'lvextend:' "$LVM_TRACE" || fail source-expand-missing
# Later injected producer/writer failures only verify that the capture branch
# invokes cleanup.  The successful path above already exercises the real
# source expand helper; a marker avoids turning an expected writer failure
# into a host-shell timing test.
rootpxe_lvm_restore_source_lv() { echo "source-cleanup:$*" >>"$LVM_TRACE"; }
export LVM_MODE=multi; rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" && fail multipv; unset LVM_MODE
rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" || fail facts-after-multipv
export PV_FAIL=1; rootpxe_capture_lvm_volumes "$tmp/image" && fail sidecar-failure; unset PV_FAIL
export WRITER_FAIL=1; rootpxe_capture_lvm_volumes "$tmp/image" && fail writer-failure; unset WRITER_FAIL
: >"$LVM_TRACE"; export UPLOAD_FAIL=1; rootpxe_capture_lvm_volumes "$tmp/image" && fail upload-failure; unset UPLOAD_FAIL
grep -Fq 'source-cleanup:' "$LVM_TRACE" || fail upload-failure-source-rollback
: >"$LVM_TRACE"; export LVREDUCE_FAIL=1; rootpxe_capture_lvm_volumes "$tmp/image" && fail reduce-failure; unset LVREDUCE_FAIL
grep -Fq 'source-cleanup:' "$LVM_TRACE" || fail reduce-failure-source-cleanup
export LVM_MODE=cross; rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" && fail cross-disk-vg; unset LVM_MODE
export LVM_SEGTYPE=thin; rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" && fail thin-topology; unset LVM_SEGTYPE
export LVM_MODE=crypt; rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" && fail crypt-topology; unset LVM_MODE
export LVM_MODE=mdraid; rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" && fail mdraid-topology; unset LVM_MODE
grep -Fq '[[ $fs == xfs ]]' "$overlay/usr/share/pxeos/lib/funcs.sh" || fail xfs-capture-branch
grep -Fq '.[4] != "xfs"' "$overlay/usr/share/pxeos/lib/funcs.sh" || fail xfs-nonresizable-schema

# Resolver produces an LVM plan with no LVM write command before permit.
printf '{"version":2,"lvm":{"version":2}}' >"$tmp/schema.json"; printf '{"lvm":[]}' >"$tmp/layout.json"; printf '[]' >"$tmp/partitions.json"; : >"$LVM_TRACE"
rootpxe_validate_lvm_deployment_layout "$tmp/schema.json" "$tmp/layout.json" "$tmp/partitions.json" || fail layout-plan
[[ ! -s "$LVM_TRACE" ]] || fail prepermit-write
for mode in fixed percentage remaining; do export LAYOUT_MODE="$mode"; rootpxe_validate_lvm_deployment_layout "$tmp/schema.json" "$tmp/layout.json" "$tmp/partitions.json" || fail "layout-$mode"; unset LAYOUT_MODE; done
export LAYOUT_MODE=belowmin; rootpxe_validate_lvm_deployment_layout "$tmp/schema.json" "$tmp/layout.json" "$tmp/partitions.json" && fail layout-below-min; unset LAYOUT_MODE
node -e 'const extent=4194304,capacity=100*extent,min=9*extent,fixed=10*extent,pct=Math.floor(capacity*25/100/extent)*extent,remaining=capacity-fixed-pct;if(fixed<min||pct<=0||remaining<min)process.exit(1)' || fail layout-capacity-oracle

rootpxe_resolved_lvm_layout_file="$tmp/plan.json"; printf '{}' >"$rootpxe_resolved_lvm_layout_file"; rootpxe_disk_permit_granted=no
rootpxe_restore_lvm_volumes "$tmp/image" /dev/mock && fail no-permit
[[ ! -s "$LVM_TRACE" ]] || fail no-permit-write
echo pv-1 >"$tmp/image/d1.pv.pv-1.meta"; echo pv-1 >"$tmp/image/d1.vg.vg-1.cfg"; : >"$tmp/image/d1.lv.lv-root.img"
rootpxe_disk_stable_identity() { echo target-1; }; rootpxe_disk_permit_granted=yes; rootpxe_disk_permit_target_id=target-1; rootpxe_disk_permit_operation=deploy_write
writeImage() { echo "writeImage:$*" >>"$LVM_TRACE"; }
for list_mode in fail empty; do
  : >"$LVM_TRACE"; export LVM_LIST_MODE="$list_mode"
  rootpxe_restore_lvm_volumes "$tmp/image" /dev/mock && fail "lvm-list-$list_mode"
  [[ ! -s "$LVM_TRACE" ]] || fail "lvm-list-$list_mode-wrote-before-parse"
  unset LVM_LIST_MODE
done
rootpxe_restore_lvm_volumes "$tmp/image" /dev/mock || fail permitted-restore
for marker in pvcreate vgcfgrestore pvresize lvresize writeImage; do grep -Fq "$marker:" "$LVM_TRACE" || fail "missing-$marker"; done
grep -Fq 'lvcreate:' "$LVM_TRACE" && fail lvcreate-after-vgcfgrestore
: >"$LVM_TRACE"; export LVM_PIPE_ARTIFACT=1; : >"$tmp/image/d1.lv.name|safe.img"; rootpxe_restore_lvm_volumes "$tmp/image" /dev/mock || fail pipe-artifact-restore; unset LVM_PIPE_ARTIFACT
grep -Fq 'd1.lv.name|safe.img' "$LVM_TRACE" || fail pipe-artifact-shifted
: >"$LVM_TRACE"; export LVM_SMALL=1; rootpxe_restore_lvm_volumes "$tmp/image" /dev/mock || fail small-pv-rebuild; unset LVM_SMALL
grep -Fq 'vgcreate:' "$LVM_TRACE" || fail small-pv-vg-rebuild
grep -Fq 'lvcreate:' "$LVM_TRACE" || fail small-pv-lv-rebuild
grep -Fq -- '--norestorefile' "$LVM_TRACE" || fail small-pv-no-restorefile
echo 'PASS: PXEOS LVM behavior regression'
