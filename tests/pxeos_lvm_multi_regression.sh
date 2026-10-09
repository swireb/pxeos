#!/usr/bin/env bash
# Mock-only contract for multiple independent PV/VG groups.  It deliberately
# shadows every LVM/disk writer, so it is safe on a developer workstation.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
download="$overlay/bin/pxeos.download"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
real_jq=$(command -v jq) || fail 'jq is required'
# Production entrypoint contract: the early barrier follows artifact checking
# but precedes permit planning, hooks, partition layout, and Partclone work.
artifact_line=$(grep -n '^rootpxe_validate_restore_artifacts ' "$download" | head -n1 | cut -d: -f1)
early_line=$(grep -n '^    rootpxe_lvm_preflight_restore_groups ' "$download" | head -n1 | cut -d: -f1)
permit_line=$(grep -n '^if \[\[ \${imgType:-} == mpa \]\]; then' "$download" | tail -n1 | cut -d: -f1)
predeploy_line=$(grep -n '^rootpxe_run_pre_deploy_script ' "$download" | tail -n1 | cut -d: -f1)
prepare_line=$(grep -n '^\[\[ \$nombr -eq 1 \]\].*preparePartitions' "$download" | head -n1 | cut -d: -f1)
[[ $artifact_line =~ ^[1-9][0-9]*$ && $early_line =~ ^[1-9][0-9]*$ && $permit_line =~ ^[1-9][0-9]*$ && $predeploy_line =~ ^[1-9][0-9]*$ && $prepare_line =~ ^[1-9][0-9]*$ && $artifact_line -lt $early_line && $early_line -lt $permit_line && $early_line -lt $predeploy_line && $early_line -lt $prepare_line ]] || fail early-preflight-entrypoint-must-precede-writers
grep -Fq 'LC_ALL=C pvdisplay -m --units b' "$overlay/usr/share/pxeos/lib/funcs.sh" || fail capture-pv-sidecar-must-use-c-locale
: >"$tmp/proc-cmdline"
sed -e "s|/usr/share/pxeos|$overlay/usr/share/pxeos|g" -e "s|</proc/cmdline|<\"$tmp/proc-cmdline\"|" "$overlay/usr/share/pxeos/lib/funcs.sh" >"$tmp/funcs.sh"
# shellcheck disable=SC1090
ismajordebug=0
. "$tmp/funcs.sh"

# Keep the real leaf executors so the latter half of this script can exercise
# them through the multi-group dispatchers.  The short dispatcher-only cases
# below intentionally replace these names to make publication ordering easy
# to observe; they are not the production-executor integration coverage.
declare -f rootpxe_capture_lvm_volumes_single >"$tmp/real-capture-single.sh"
declare -f rootpxe_restore_lvm_volumes_single >"$tmp/real-restore-single.sh"

rootpxe_lvm_json_jq() { command "$real_jq" "$@"; }
rootpxe_lvm_trim() { local value="$1"; value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"; printf '%s' "$value"; }
getPartitions() {
    local n sequence
    if [[ ${MATRIX_GROUP_COUNT:-0} =~ ^[1-9][0-9]*$ ]]; then
      sequence=$(seq 1 "$MATRIX_GROUP_COUNT")
      [[ ${MATRIX_REVERSE:-no} == yes ]] && sequence=$(printf '%s\n' "$sequence" | tac)
      parts=$(printf '/dev/mock%s ' $sequence); parts=${parts% }
    else parts='/dev/mock1 /dev/mock2'; fi
}
getPartitionNumber() { part_number=${1##*mock}; }
blockdev() { case "$1:$2" in --getsize64:/dev/mock) [[ ${MATRIX_GROUP_COUNT:-0} =~ ^[1-9][0-9]*$ ]] && printf '%s\n' "$((MATRIX_GROUP_COUNT * 268435456 + 268435456))" || { [[ ${TARGET_GROW:-no} == yes ]] && printf '2147483648\n' || printf '1073741824\n'; };; --getsize64:/dev/vg[0-9]/root) printf '67108864\n';; --getsize64:/dev/vg[0-9]/data) printf '33554432\n';; --getsize64:/dev/mock[1-9]) printf '268435456\n';; --getsize64:/dev/vg0/swap) printf '33554432\n';; --getss:/dev/mock|--getpbsz:/dev/mock) printf '512\n';; *) return 1;; esac; }
blkid() { for last; do :; done; case " $* " in *' TYPE '*) [[ ${MULTI_MODE:-ok} == no_pv_luks && $last == /dev/mock1 ]] && { printf 'crypto_LUKS\n'; return; }; [[ ${MATRIX_GROUP_COUNT:-0} =~ ^[1-9][0-9]*$ && $last =~ ^/dev/mock[1-9][0-9]*$ ]] && { printf 'LVM2_member\n'; return; }; [[ $last == /dev/mock1 || $last == /dev/mock2 ]] && { printf 'LVM2_member\n'; return; }; [[ $last == /dev/vg0/swap ]] && printf 'swap\n' || printf 'ext4\n';; *' UUID '*) [[ $last == /dev/vg0/swap ]] && printf 'swap-uuid\n' || printf 'root-uuid\n';; esac; }

pvs() {
    local selected= pv1=/dev/mock1 pv2=/dev/mock2 all
    [[ ${CAPTURE_REPORT_DIAGNOSTIC:-} == pvs ]] && printf '%s\n' 'pvs capture diagnostic' >&2
    case ${EARLY_PVS_MODE:-ok} in
      fail) return 7 ;;
      stderr) printf '%s\n' 'pvs diagnostic' >&2 ;;
      malformed) printf '%s\n' '{not-json'; return 0 ;;
      emptyreport) printf '%s\n' '{"report":[]}'; return 0 ;;
      badrow) printf '%s\n' '{"report":[{"pv":[{"pv_name":7,"pv_uuid":null,"vg_name":null,"vg_uuid":false}]}]}'; return 0 ;;
      duplicate) printf '%s\n' '{"report":[{"pv":[{"pv_name":"/dev/mock1","pv_uuid":"pv-1","vg_name":"vg0","vg_uuid":"vg-1"},{"pv_name":"/dev/mock1","pv_uuid":"pv-1","vg_name":"vg0","vg_uuid":"vg-1"}]}]}'; return 0 ;;
    esac
    if [[ ${MATRIX_GROUP_COUNT:-0} =~ ^[1-9][0-9]*$ ]]; then
      local n selected
      for selected; do :; done
      if [[ ${EMPTY_TARGET:-no} == yes && $* == *'pv_name,pv_uuid,vg_name,vg_uuid'* && $* != *'/dev/mock'* ]]; then printf '%s\n' '{"report":[{"pv":[]}]}'; return 0; fi
      if [[ $selected =~ ^/dev/mock([1-9][0-9]*)$ ]]; then n=${BASH_REMATCH[1]}; pv_path="/dev/mock${n}"; [[ ${RESTORE_MSYS_PATHS:-no} == yes ]] && pv_path="C:/Program Files/Git/dev/mock${n}"; printf '{"report":[{"pv":[{"pv_name":"%s","pv_uuid":"pv-%s","vg_name":"vg%s","vg_uuid":"vg-%s"}]}]}\n' "$pv_path" "$n" "$n" "$n"; return 0; fi
      if [[ ${MATRIX_REVERSE:-no} == yes ]]; then
        "$real_jq" -n --argjson count "$MATRIX_GROUP_COUNT" '[range(1;$count+1)|{pv_name:("/dev/mock"+tostring),pv_uuid:("pv-"+tostring),vg_name:("vg"+tostring),vg_uuid:("vg-"+tostring),pv_size:"268435456",pe_start:"1048576"}] | reverse | {report:[{pv:.}]}'
      else
        "$real_jq" -n --argjson count "$MATRIX_GROUP_COUNT" '[range(1;$count+1)|{pv_name:("/dev/mock"+tostring),pv_uuid:("pv-"+tostring),vg_name:("vg"+tostring),vg_uuid:("vg-"+tostring),pv_size:"268435456",pe_start:"1048576"}] | {report:[{pv:.}]}'
      fi
      return 0
    fi
    [[ ${RESTORE_MSYS_PATHS:-no} == yes ]] && { pv1='C:/Program Files/Git/dev/mock1'; pv2='C:/Program Files/Git/dev/mock2'; }
    all="[{\"pv_name\":\"$pv1\",\"pv_uuid\":\"pv-1\",\"vg_name\":\"vg0\",\"vg_uuid\":\"vg-1\",\"pv_size\":\"268435456\",\"pe_start\":\"1048576\"},{\"pv_name\":\"$pv2\",\"pv_uuid\":\"pv-2\",\"vg_name\":\"vg1\",\"vg_uuid\":\"vg-2\",\"pv_size\":\"268435456\",\"pe_start\":\"1048576\"}]"
    if [[ ${LIVE_DUPLICATE_SOURCE:-no} == yes && $* == *'pv_name,pv_uuid,vg_name,vg_uuid'* ]]; then
      printf '%s\n' '{"report":[{"pv":[{"pv_name":"/dev/source1","pv_uuid":"pv-1","vg_name":"vg0","vg_uuid":"vg-1"}]}]}'
      return 0
    fi
    case ${MULTI_MODE:-ok} in
      multipv) all='[{"pv_name":"/dev/mock1","pv_uuid":"pv-1","vg_name":"vg0","vg_uuid":"vg-1","pv_size":"268435456","pe_start":"1048576"},{"pv_name":"/dev/mock2","pv_uuid":"pv-2","vg_name":"vg0","vg_uuid":"vg-1","pv_size":"268435456","pe_start":"1048576"}]' ;;
      cross) all='[{"pv_name":"/dev/mock1","pv_uuid":"pv-1","vg_name":"vg0","vg_uuid":"vg-1","pv_size":"268435456","pe_start":"1048576"},{"pv_name":"/dev/foreign","pv_uuid":"pv-x","vg_name":"vg0","vg_uuid":"vg-1","pv_size":"268435456","pe_start":"1048576"}]' ;;
      duplicate_lv) all='[{"pv_name":"/dev/mock1","pv_uuid":"pv-1","vg_name":"vg0","vg_uuid":"vg-1","pv_size":"268435456","pe_start":"1048576"},{"pv_name":"/dev/mock2","pv_uuid":"pv-2","vg_name":"vg1","vg_uuid":"vg-2","pv_size":"268435456","pe_start":"1048576"}]' ;;
      no_pv_luks) all='[]' ;;
    esac
    for selected; do :; done
    if [[ $selected == /dev/mock1 || $selected == /dev/mock2 ]]; then
      if [[ $selected == /dev/mock1 ]]; then printf '{"report":[{"pv":[{"pv_name":"%s","pv_uuid":"pv-1","vg_name":"vg0","vg_uuid":"vg-1"}]}]}\n' "$pv1"
      else printf '{"report":[{"pv":[{"pv_name":"%s","pv_uuid":"pv-2","vg_name":"vg1","vg_uuid":"vg-2"}]}]}\n' "$pv2"; fi
      return
    fi
    if [[ ${EMPTY_TARGET:-no} == yes && $* == *'pv_name,pv_uuid,vg_name,vg_uuid'* ]]; then printf '%s\n' '{"report":[{"pv":[]}]}'; return 0; fi
    printf '{"report":[{"pv":%s}]}\n' "$all"
}
vgs() {
    [[ ${CAPTURE_REPORT_DIAGNOSTIC:-} == vgs ]] && printf '%s\n' 'vgs capture diagnostic' >&2
    case ${EARLY_VGS_MODE:-ok} in
      fail) return 8 ;;
      stderr) printf '%s\n' 'vgs diagnostic' >&2 ;;
      malformed) printf '%s\n' '{not-json'; return 0 ;;
      emptyreport) printf '%s\n' '{"report":[]}'; return 0 ;;
      badrow) printf '%s\n' '{"report":[{"vg":[{"vg_name":7,"vg_uuid":null}]}]}'; return 0 ;;
      duplicate) printf '%s\n' '{"report":[{"vg":[{"vg_name":"vg0","vg_uuid":"vg-1"},{"vg_name":"vg0","vg_uuid":"vg-1"}]}]}'; return 0 ;;
    esac
    if [[ ${MATRIX_GROUP_COUNT:-0} =~ ^[1-9][0-9]*$ ]]; then
      local n
      if [[ ${EMPTY_TARGET:-no} == yes && $* != *vg[1-9]* ]]; then printf '%s\n' '{"report":[{"vg":[]}]}'; return 0; fi
      if [[ $* =~ vg([1-9][0-9]*) ]]; then n=${BASH_REMATCH[1]}; printf '{"report":[{"vg":[{"vg_name":"vg%s","vg_uuid":"vg-%s","vg_extent_size":"4194304","vg_free":"0"}]}]}\n' "$n" "$n"; return 0; fi
      if [[ ${MATRIX_REVERSE:-no} == yes ]]; then
        "$real_jq" -n --argjson count "$MATRIX_GROUP_COUNT" '[range(1;$count+1)|{vg_name:("vg"+tostring),vg_uuid:("vg-"+tostring),vg_extent_size:"4194304",vg_free:"0"}] | reverse | {report:[{vg:.}]}'
      else
        "$real_jq" -n --argjson count "$MATRIX_GROUP_COUNT" '[range(1;$count+1)|{vg_name:("vg"+tostring),vg_uuid:("vg-"+tostring),vg_extent_size:"4194304",vg_free:"0"}] | {report:[{vg:.}]}'
      fi
      return 0
    fi
    if [[ ${VGS_QUERY_FAIL:-no} == yes ]]; then return 5; fi
    [[ ${DUPLICATE_SOURCE_DIAGNOSTIC:-no} == yes ]] && printf '%s\n' 'duplicate PV UUID detected' >&2
    if [[ ${EMPTY_TARGET:-no} == yes && $* != *vg0* && $* != *vg1* ]]; then printf '%s\n' '{"report":[{"vg":[]}]}'; return 0; fi
    if [[ $* == *vg0* ]]; then printf '%s\n' '{"report":[{"vg":[{"vg_name":"vg0","vg_uuid":"vg-1","vg_extent_size":"4194304","vg_free":"0"}]}]}'; return 0; fi
    if [[ $* == *vg1* ]]; then printf '%s\n' '{"report":[{"vg":[{"vg_name":"vg1","vg_uuid":"vg-2","vg_extent_size":"4194304","vg_free":"0"}]}]}'; return 0; fi
    printf '%s\n' '{"report":[{"vg":[{"vg_name":"vg0","vg_uuid":"vg-1","vg_extent_size":"4194304","vg_free":"0"},{"vg_name":"vg1","vg_uuid":"vg-2","vg_extent_size":"4194304","vg_free":"0"}]}]}'
}
lvs() {
    local vg=vg0 root='{"vg_name":"vg0","vg_uuid":"vg-1","lv_name":"root","lv_uuid":"lv-root","lv_path":"/dev/vg0/root","lv_size":"67108864","lv_attr":"-wi-a-----","segtype":"linear","origin":null,"pool_lv":null,"data_lv":null,"metadata_lv":null,"lv_active":"active"}' swap='{"vg_name":"vg0","vg_uuid":"vg-1","lv_name":"swap","lv_uuid":"lv-swap","lv_path":"/dev/vg0/swap","lv_size":"33554432","lv_attr":"-wi-a-----","segtype":"linear","origin":null,"pool_lv":null,"data_lv":null,"metadata_lv":null,"lv_active":"active"}' root2='{"vg_name":"vg1","vg_uuid":"vg-2","lv_name":"root","lv_uuid":"lv-root-2","lv_path":"/dev/vg1/root","lv_size":"67108864","lv_attr":"-wi-a-----","segtype":"linear","origin":null,"pool_lv":null,"data_lv":null,"metadata_lv":null,"lv_active":"active"}'
    [[ ${CAPTURE_REPORT_DIAGNOSTIC:-} == lvs ]] && printf '%s\n' 'lvs capture diagnostic' >&2
    if [[ ${MATRIX_GROUP_COUNT:-0} =~ ^[1-9][0-9]*$ ]]; then
      local n=1; [[ $* =~ vg([1-9][0-9]*) ]] && n=${BASH_REMATCH[1]}
      local root_row data_row
      root_row=$(printf '{"vg_name":"vg%s","vg_uuid":"vg-%s","lv_name":"root","lv_uuid":"lv-%s","lv_path":"/dev/vg%s/root","lv_size":"67108864","lv_attr":"-wi-a-----","segtype":"linear","origin":null,"pool_lv":null,"data_lv":null,"metadata_lv":null,"lv_active":"active"}' "$n" "$n" "$n" "$n")
      data_row=$(printf '{"vg_name":"vg%s","vg_uuid":"vg-%s","lv_name":"data","lv_uuid":"lv-data-1","lv_path":"/dev/vg%s/data","lv_size":"33554432","lv_attr":"-wi-a-----","segtype":"linear","origin":null,"pool_lv":null,"data_lv":null,"metadata_lv":null,"lv_active":"active"}' "$n" "$n" "$n")
      if [[ $* == */data* ]]; then
        printf '{"report":[{"lv":[%s]}]}\n' "$data_row"
      elif [[ $n == 1 && $* != */root* ]]; then
        if [[ ${MATRIX_REVERSE:-no} == yes ]]; then printf '{"report":[{"lv":[%s,%s]}]}\n' "$data_row" "$root_row"; else printf '{"report":[{"lv":[%s,%s]}]}\n' "$root_row" "$data_row"; fi
      else
        printf '{"report":[{"lv":[%s]}]}\n' "$root_row"
      fi
      return 0
    fi
    [[ $* == *vg1* || $* == *vg-2* ]] && vg=vg1
    if [[ ${MULTI_MODE:-ok} == linear_segments && $vg == vg0 ]]; then
      printf '{"report":[{"lv":[%s,%s,%s]}]}\n' "$root" "$root" "$swap"; return 0
    fi
    if [[ ${MULTI_MODE:-ok} == nonlinear_segment && $vg == vg0 ]]; then
      printf '{"report":[{"lv":[%s,%s]}]}\n' "$root" "${root/\"segtype\":\"linear\"/\"segtype\":\"raid\"}"; return 0
    fi
    if [[ ${MULTI_MODE:-ok} == conflicting_segment && $vg == vg0 ]]; then
      printf '{"report":[{"lv":[%s,%s]}]}\n' "$root" "${root/\"lv_path\":\"\/dev\/vg0\/root\"/\"lv_path\":\"\/dev\/vg0\/other\"}"; return 0
    fi
    [[ ${MULTI_MODE:-ok} == duplicate_lv && $vg == vg1 ]] && root2=${root2/lv-root-2/lv-root}
    if [[ $* == */swap* ]]; then printf '{"report":[{"lv":[%s]}]}\n' "$swap"; return 0; fi
    if [[ $* == */root* && $vg == vg0 ]]; then printf '{"report":[{"lv":[%s]}]}\n' "$root"; return 0; fi
    if [[ $* == */root* && $vg == vg1 ]]; then printf '{"report":[{"lv":[%s]}]}\n' "$root2"; return 0; fi
    [[ $vg == vg1 ]] && printf '{"report":[{"lv":[%s]}]}\n' "$root2" || printf '{"report":[{"lv":[%s,%s]}]}\n' "$root" "$swap"
}
rootpxe_partition_progress_item() { :; }

# Names are command operands, not artifact fields.  Keep case-distinct legal
# while rejecting option-like and LVM-internal values before any writer.
for bad_vg in -vg . ..; do rootpxe_lvm_validate_vg_name "$bad_vg" && fail "bad-vg-name-$bad_vg-must-reject"; done
for bad_lv in -lv . .. snapshot pvmove root_cdata root_tmeta root_vorigin; do rootpxe_lvm_validate_lv_name "$bad_lv" && fail "bad-lv-name-$bad_lv-must-reject"; done
rootpxe_lvm_validate_vg_name VGCase && rootpxe_lvm_validate_lv_name RootCase && rootpxe_lvm_validate_vg_name .foo && rootpxe_lvm_validate_lv_name .foo || fail case-distinct-and-dot-prefixed-lvm-names-must-accept

# An unreadable resolved plan is not evidence that the image has no LVM work.
# Keep this red test ahead of the longer capture/restore integration coverage.
rootpxe_resolved_lvm_layout_file="$tmp/missing-early-plan.json"
rootpxe_lvm_preflight_restore_groups "$tmp/missing-image" /dev/mock && fail early-preflight-unreadable-plan-must-reject
unset rootpxe_resolved_lvm_layout_file

if [[ ${PXEOS_MULTI_LEAF_ONLY:-no} != yes && ${PXEOS_MULTI_MATRIX_ONLY:-no} != yes ]]; then
mkdir -p "$tmp/image"
rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" || fail preflight-two-independent-groups
[[ ${rootpxe_lvm_group_count:-} == 2 ]] || fail frozen-two-group-manifest

# The real single-group executor is covered elsewhere.  This controlled writer
# makes the multi dispatcher observable: its only output directory is the
# supplied staging path and it can fail after group one without touching image.
rootpxe_capture_lvm_volumes_single() {
    local out="$1" fragment="${rootpxe_lvm_capture_fragment_path:?}" n="$rootpxe_lvm_pv_number" vg="$rootpxe_lvm_vg_name" pv="$rootpxe_lvm_pv_uuid" vguuid="$rootpxe_lvm_vg_uuid" lv_uuid
    [[ ${FAIL_SECOND_CAPTURE:-no} == yes && $n == 2 ]] && { : >"$out/left-behind"; return 1; }
    : >"$out/d1p${n}.lvm.pv.meta"; : >"$out/d1p${n}.lvm.vg.cfg"; : >"$out/d1p${n}.lvm.lv.root.img"
    if [[ $n == 1 ]]; then : >"$out/d1p${n}.lvm.lv.swap.img"; fi
    [[ $n == 1 ]] && lv_uuid=lv-root || lv_uuid=lv-root-2
    "$real_jq" -n --arg pv "$pv" --arg vg "$vguuid" --arg name "$vg" --arg lv "$lv_uuid" --argjson n "$n" '{version:1,captureMode:"per_lv",resizePolicy:"grow_only",pvs:[{partitionNumber:$n,uuid:$pv,vgUuid:$vg,artifact:("d1p"+($n|tostring)+".lvm.pv.meta"),vgConfigArtifact:("d1p"+($n|tostring)+".lvm.vg.cfg")}],vgs:[{name:$name,uuid:$vg,pvPartitionNumbers:[$n],lvs:[{name:"root",uuid:$lv,layout:"linear",artifact:("d1p"+($n|tostring)+".lvm.lv.root.img")}]}]}' >"$fragment"
    rootpxe_lvm_captured=yes
}
rootpxe_capture_lvm_volumes "$tmp/image" || fail capture-two-independent-groups
"$real_jq" -e '(.pvs|length)==2 and (.vgs|length)==2 and ([.vgs[].lvs[].name]|map(select(. == "root"))|length)==2' "$tmp/image/d1.lvm.schema.json" >/dev/null || fail combined-schema
[[ -f "$tmp/image/d1p1.lvm.lv.root.img" && -f "$tmp/image/d1p2.lvm.lv.root.img" ]] || fail group-artifacts-published

rootpxe_lvm_reset_capture_facts
mkdir -p "$tmp/failing-image"
rootpxe_lvm_capture_preflight /dev/mock "$tmp/failing-image" || fail second-preflight
export FAIL_SECOND_CAPTURE=yes
rootpxe_capture_lvm_volumes "$tmp/failing-image" && fail second-group-capture-must-fail
unset FAIL_SECOND_CAPTURE
[[ ! -e "$tmp/failing-image/d1.lvm.schema.json" && ! -e "$tmp/failing-image/d1p1.lvm.lv.root.img" && ${rootpxe_lvm_group_dispatch:-no} != yes ]] || fail failed-capture-must-not-publish-or-leak

for mode in multipv cross duplicate_lv; do
  rootpxe_lvm_reset_capture_facts
  export MULTI_MODE="$mode"
  rootpxe_lvm_capture_preflight /dev/mock "$tmp/failing-image" && fail "$mode-must-reject-before-writer"
  unset MULTI_MODE
done
for mode in linear_segments nonlinear_segment conflicting_segment; do
  rootpxe_lvm_reset_capture_facts
  export MULTI_MODE="$mode"
  if [[ $mode == linear_segments ]]; then
    rootpxe_lvm_capture_preflight /dev/mock "$tmp/failing-image" || fail linear-segments-must-merge-as-one-lv
    [[ $(grep -c '^root|' "$rootpxe_lvm_lv_facts_file") == 1 ]] || fail linear-segments-must-produce-one-lv-fact
  else
    rootpxe_lvm_capture_preflight /dev/mock "$tmp/failing-image" && fail "$mode-must-reject"
  fi
  unset MULTI_MODE
done
rootpxe_lvm_reset_capture_facts
export MULTI_MODE=no_pv_luks
rootpxe_lvm_capture_preflight /dev/mock "$tmp/failing-image" && fail no-pv-luks-must-reject-before-writer
unset MULTI_MODE
for report in pvs vgs lvs; do
  rootpxe_lvm_reset_capture_facts
  export CAPTURE_REPORT_DIAGNOSTIC="$report"
  rootpxe_lvm_capture_preflight /dev/mock "$tmp/failing-image" && fail "capture-$report-stderr-must-reject"
  unset CAPTURE_REPORT_DIAGNOSTIC
done

# The public schema stays v2/v1 arrays.  The resolver is responsible for
# deriving the private groups[] deployment plan and enforcing the one global
# remaining LV budget across those independent VGs.
cat >"$tmp/layout-schema.json" <<'EOF'
{"version":2,"logicalSectorBytes":512,"partitions":[{"number":1,"originalSectors":524288},{"number":2,"originalSectors":524288}],"lvm":{"version":1,"captureMode":"per_lv","resizePolicy":"grow_only","pvs":[{"partitionNumber":1,"uuid":"pv-1","vgUuid":"vg-1","originalBytes":268435456,"minBytes":268435456,"peStartBytes":1048576,"artifact":"d1p1.lvm.pv.meta","vgConfigArtifact":"d1p1.lvm.vg.cfg"},{"partitionNumber":2,"uuid":"pv-2","vgUuid":"vg-2","originalBytes":268435456,"minBytes":268435456,"peStartBytes":1048576,"artifact":"d1p2.lvm.pv.meta","vgConfigArtifact":"d1p2.lvm.vg.cfg"}],"vgs":[{"name":"vg0","uuid":"vg-1","extentBytes":4194304,"pvPartitionNumbers":[1],"originalFreeBytes":0,"lvs":[{"name":"root","uuid":"lv-root","layout":"linear","originalBytes":67108864,"minBytes":67108864,"fs":"ext4","role":"data","resizable":true,"artifact":"d1p1.lvm.lv.root.img"}]},{"name":"vg1","uuid":"vg-2","extentBytes":4194304,"pvPartitionNumbers":[2],"originalFreeBytes":0,"lvs":[{"name":"root","uuid":"lv-root-2","layout":"linear","originalBytes":67108864,"minBytes":67108864,"fs":"ext4","role":"data","resizable":true,"artifact":"d1p2.lvm.lv.root.img"}]}]}}
EOF
cat >"$tmp/layout.json" <<'EOF'
{"version":2,"partitions":[{"number":1,"mode":"original"},{"number":2,"mode":"original"}],"lvm":[{"pvPartitionNumber":1,"freeSpacePolicy":"preserveOriginal","volumes":[{"uuid":"lv-root","mode":"original"}]},{"pvPartitionNumber":2,"freeSpacePolicy":"preserveOriginal","volumes":[{"uuid":"lv-root-2","mode":"original"}]}]}
EOF
printf '%s\n' '[{"number":1,"resolvedSectors":524288},{"number":2,"resolvedSectors":524288}]' >"$tmp/partitions.json"
rootpxe_validate_lvm_deployment_layout "$tmp/layout-schema.json" "$tmp/layout.json" "$tmp/partitions.json" || fail resolve-two-groups
"$real_jq" -e '(.groups|length)==2 and [.groups[].pv.partitionNumber] == [1,2]' "$rootpxe_resolved_lvm_layout_file" >/dev/null || fail resolved-groups-content
rm -f "$rootpxe_resolved_lvm_layout_file"; unset rootpxe_resolved_lvm_layout_file
# Layout volumes are a UUID-keyed set, not an ordering contract.  A reversed
# first VG layout must resolve exactly like its source order.
"$real_jq" '.lvm.vgs[0].lvs += [{name:"swap",uuid:"lv-swap",layout:"linear",originalBytes:33554432,minBytes:33554432,fs:"swap",role:"swap",resizable:false,artifact:"",swapUuid:"swap-uuid"}]' "$tmp/layout-schema.json" >"$tmp/layout-schema-reversed-lv.json"
"$real_jq" '.lvm[0].volumes = [{uuid:"lv-swap",mode:"original"}, .lvm[0].volumes[0]]' "$tmp/layout.json" >"$tmp/layout-reversed-lv.json"
rootpxe_validate_lvm_deployment_layout "$tmp/layout-schema-reversed-lv.json" "$tmp/layout-reversed-lv.json" "$tmp/partitions.json" || fail resolve-reversed-lv-order
"$real_jq" -e '(.groups|length)==2 and ([.groups[] | select(.pv.partitionNumber==1).volumes[].uuid] | sort) == ["lv-root","lv-swap"]' "$rootpxe_resolved_lvm_layout_file" >/dev/null || fail resolve-reversed-lv-content
rm -f "$rootpxe_resolved_lvm_layout_file"; unset rootpxe_resolved_lvm_layout_file
sed 's/"lv-root-2","mode":"original"/"lv-root-2","mode":"remaining"/' "$tmp/layout.json" >"$tmp/two-remaining-layout.json"
sed 's/"lv-root","mode":"original"/"lv-root","mode":"remaining"/' "$tmp/two-remaining-layout.json" >"$tmp/two-remaining-layout-bad.json"
rootpxe_validate_lvm_deployment_layout "$tmp/layout-schema.json" "$tmp/two-remaining-layout-bad.json" "$tmp/partitions.json" && fail cross-group-second-remaining-must-reject

# Restore dispatcher tests the critical ordering invariant with an execution
# mock: all group validation calls happen before the first write call.
restore_trace="$tmp/restore.trace"; : >"$restore_trace"
rootpxe_restore_lvm_volumes_single() {
    local plan="${rootpxe_resolved_lvm_layout_file:?}" pv
    pv=$("$real_jq" -r '.pv.uuid' "$plan")
    if [[ ${rootpxe_lvm_restore_preflight_only:-no} == yes ]]; then
      [[ -r "$1/$("$real_jq" -r '.volumes[]|select(.fs!="swap")|.artifact' "$plan")" ]] || return 1
      printf 'preflight:%s\n' "$pv" >>"$restore_trace"; return 0
    fi
    printf 'write:%s\n' "$pv" >>"$restore_trace"
}
cat >"$tmp/restore-plan.json" <<'EOF'
{"groups":[{"pv":{"uuid":"pv-1","partitionNumber":1,"artifact":"d1p1.lvm.pv.meta","vgConfigArtifact":"d1p1.lvm.vg.cfg"},"vg":{"uuid":"vg-1","name":"vg0"},"volumes":[{"uuid":"lv-root","name":"root","fs":"ext4","artifact":"d1p1.lvm.lv.root.img"}]},{"pv":{"uuid":"pv-2","partitionNumber":2,"artifact":"d1p2.lvm.pv.meta","vgConfigArtifact":"d1p2.lvm.vg.cfg"},"vg":{"uuid":"vg-2","name":"vg1"},"volumes":[{"uuid":"lv-root-2","name":"root","fs":"ext4","artifact":"d1p2.lvm.lv.root.img"}]}]}
EOF
for n in 1 2; do printf 'PV UUID pv-%s\n' "$n" >"$tmp/image/d1p${n}.lvm.pv.meta"; vg=vg0; vgid=vg-1; lvid=lv-root; [[ $n == 2 ]] && { vg=vg1; vgid=vg-2; lvid=lv-root-2; }; cat >"$tmp/image/d1p${n}.lvm.vg.cfg" <<EOF
${vg} {
 id = "${vgid}"
 physical_volumes {
  pv0 {
   id = "pv-${n}"
  }
 }
 logical_volumes {
  root {
   id = "${lvid}"
  }
 }
}
EOF
done
rootpxe_resolved_lvm_layout_file="$tmp/restore-plan.json"
rootpxe_restore_lvm_volumes "$tmp/image" /dev/mock || fail restore-two-groups
[[ $(cat "$restore_trace") == $'preflight:pv-1\npreflight:pv-2\nwrite:pv-1\nwrite:pv-2' ]] || fail restore-must-preflight-all-before-write
rm -f "$tmp/image/d1p2.lvm.lv.root.img"; : >"$restore_trace"
rootpxe_restore_lvm_volumes "$tmp/image" /dev/mock && fail missing-second-payload-must-fail
! grep -Fq 'write:' "$restore_trace" || fail missing-second-payload-must-have-zero-writes
printf '%s\n' '# pv-2 vg-2 lv-root-2' >"$tmp/image/d1p2.lvm.vg.cfg"; : >"$restore_trace"
rootpxe_restore_lvm_volumes "$tmp/image" /dev/mock && fail commented-foreign-metadata-must-fail
[[ ! -s "$restore_trace" ]] || fail commented-foreign-metadata-must-have-zero-writes
fi

# Exercise the actual single-group capture and restore executors through the
# multi-group dispatchers.  Only commands that would inspect or write a real
# device are mocked; neither production leaf executor is replaced here.
if [[ ${PXEOS_MULTI_BASELINE_ONLY:-no} != yes || ${PXEOS_MULTI_MATRIX_ONLY:-no} == yes ]]; then
. "$tmp/real-capture-single.sh"
. "$tmp/real-restore-single.sh"
capture_trace="$tmp/production-capture.trace"; capture_stage_trace="$tmp/production-capture-stage.trace"; restore_trace="$tmp/production-restore.trace"
: >"$capture_trace"; : >"$capture_stage_trace"; : >"$restore_trace"
rootpxe_display_metadata_collect_lvm() { return 0; }
rootpxe_partclone_progress_prepare() { rootpxe_partclone_progress_args=(); rootpxe_partclone_progress_term=dumb; rootpxe_partclone_progress_stderr_target="$tmp/partclone.stderr"; return 0; }
rootpxe_partclone_progress_start_collector() { return 0; }
rootpxe_partclone_progress_wait() { return 0; }
rootpxe_partclone_progress_abort() { return 0; }
rootpxe_wait_for_writer() { return 0; }
uploadFormat() { [[ $2 == "$tmp"/*/.rootpxe-lvm-groups.*/* ]] || return 1; printf '%s\n' "$2" >>"$capture_stage_trace"; : >"$2.000"; rootpxe_last_writer_pid=mock; return 0; }
partclone.extfs() { printf 'capture:%s\n' "$5" >>"$capture_trace"; return 0; }
partclone.xfs() { printf 'capture:%s\n' "$5" >>"$capture_trace"; return 0; }
pvdisplay() { printf 'PV UUID %s\n' "${rootpxe_lvm_pv_uuid:-unknown}"; }
vgcfgbackup() {
    local file="" vg=""; while [[ $# -gt 0 ]]; do [[ $1 == -f ]] && { file=$2; shift 2; continue; }; vg=$1; shift; done
    if [[ ${MATRIX_GROUP_COUNT:-0} =~ ^[1-9][0-9]*$ && $vg =~ ^vg([1-9][0-9]*)$ ]]; then
    local n=${BASH_REMATCH[1]}
      if [[ $n == 1 ]]; then
        printf '%s\n' "vg${n} {" " id = \"vg-${n}\"" ' physical_volumes {' '  pv0 {' "   id = \"pv-${n}\"" '  }' ' }' ' logical_volumes {' '  root {' "   id = \"lv-${n}\"" '  }' '  data {' '   id = "lv-data-1"' '  }' ' }' '}' >"$file"
      else
        printf '%s\n' "vg${n} {" " id = \"vg-${n}\"" ' physical_volumes {' '  pv0 {' "   id = \"pv-${n}\"" '  }' ' }' ' logical_volumes {' '  root {' "   id = \"lv-${n}\"" '  }' ' }' '}' >"$file"
      fi
      return 0
    fi
    case $vg in
      vg0) printf '%s\n' 'vg0 {' ' id = "vg-1"' ' physical_volumes {' '  pv0 {' '   id = "pv-1"' '  }' ' }' ' logical_volumes {' '  root {' '   id = "lv-root"' '  }' '  swap {' '   id = "lv-swap"' '  }' ' }' '}' >"$file" ;;
      vg1) printf '%s\n' 'vg1 {' ' id = "vg-2"' ' physical_volumes {' '  pv0 {' '   id = "pv-2"' '  }' ' }' ' logical_volumes {' '  root {' '   id = "lv-root-2"' '  }' ' }' '}' >"$file" ;;
      *) return 1 ;;
    esac
}
rootpxe_disk_stable_identity() { printf 'mock-target\n'; }
rootpxe_lvm_partition_path() { printf '%s%s\n' "$1" "$2"; }
pvcreate() { printf 'pvcreate:%s\n' "$*" >>"$restore_trace"; }
vgcfgrestore() { printf 'vgcfgrestore:%s\n' "$*" >>"$restore_trace"; }
pvresize() { printf 'pvresize:%s\n' "$*" >>"$restore_trace"; }
vgchange() { printf 'vgchange:%s\n' "$*" >>"$restore_trace"; }
lvextend() { printf 'lvextend:%s\n' "$*" >>"$restore_trace"; }
writeImage() { printf 'writeImage:%s:%s\n' "$1" "$2" >>"$restore_trace"; }
mkswap() { printf 'mkswap:%s\n' "$*" >>"$restore_trace"; }
e2fsck() { return 0; }
resize2fs() { return 0; }

if [[ ${PXEOS_MULTI_MATRIX_ONLY:-no} != yes ]]; then
rootpxe_lvm_reset_capture_facts
mkdir -p "$tmp/real-image"
rootpxe_lvm_capture_preflight /dev/mock "$tmp/real-image" || fail production-capture-preflight
rootpxe_capture_lvm_volumes "$tmp/real-image" || fail production-capture-two-groups
"$real_jq" -e '(.pvs|length)==2 and (.vgs|length)==2 and ([.vgs[].lvs[].uuid]|sort)==["lv-root","lv-root-2","lv-swap"]' "$tmp/real-image/d1.lvm.schema.json" >/dev/null || fail production-capture-combined-schema
[[ $(wc -l <"$capture_trace") == 2 && $(wc -l <"$capture_stage_trace") == 2 && -r "$tmp/real-image/d1p1.lvm.lv.root.img" && -r "$tmp/real-image/d1p2.lvm.lv.root.img" ]] || fail production-capture-leaf-not-run
[[ -z $(find "$tmp/real-image" -maxdepth 1 -type d -name '.rootpxe-lvm-groups.*' -print -quit) ]] || fail production-capture-staging-must-cleanup
rootpxe_lvm_is_pv_partition /dev/mock2 || fail production-capture-manifest-must-keep-second-pv
rootpxe_lvm_is_pv_partition /dev/mock1 || fail production-capture-manifest-must-keep-first-pv
rootpxe_capture_lvm_volumes "$tmp/real-image" || fail production-capture-repeat-must-be-idempotent
[[ $(wc -l <"$capture_trace") == 2 ]] || fail production-capture-repeat-must-not-rewrite
cat >"$tmp/real-image/d1.partitions" <<'EOF'
label: gpt
label-id: 00000000-0000-0000-0000-000000000001
device: /dev/mock
unit: sectors
first-lba: 34
last-lba: 1048542
/dev/mock1 : start=2048, size=524288, type=8300
/dev/mock2 : start=526336, size=524288, type=8300
EOF
rootpxe_build_original_schema /dev/mock "$tmp/real-image" || fail production-build-original-schema-multi
"$real_jq" -e '.version == 2 and (.lvm.pvs|length) == 2 and (.lvm.vgs|length) == 2' "$rootpxe_original_schema_file" >/dev/null || fail production-build-original-schema-multi-content
full_schema_hash=$(rootpxe_canonical_json_hash "$rootpxe_original_schema_file") || fail production-full-layout-schema-hash
"$real_jq" -n --arg hash "$full_schema_hash" --slurpfile schema "$rootpxe_original_schema_file" '
  $schema[0] as $s | {schemaHash:$hash,partitions:[$s.partitions[]|{number:.number,mode:"original"}],lvm:[$s.lvm.pvs[] as $pv | $s.lvm.vgs[] | select(.uuid == $pv.vgUuid) | {pvPartitionNumber:$pv.partitionNumber,freeSpacePolicy:"preserveOriginal",volumes:[.lvs[]|{uuid:.uuid,mode:"original"}]}]}
' >"$tmp/full-layout.json" || fail production-full-layout-build
schemaHash="$full_schema_hash"; schemaRevision=1
rootpxe_validate_deployment_layout /dev/mock "$rootpxe_original_schema_file" "$tmp/full-layout.json" || fail production-full-layout-two-groups-original
"$real_jq" -e '(.groups|length) == 2 and ([.groups[].pv.partitionNumber]|sort) == [1,2]' "$rootpxe_resolved_lvm_layout_file" >/dev/null || fail production-full-layout-two-groups-content
rm -f -- "$rootpxe_resolved_lvm_layout_file"; unset rootpxe_resolved_lvm_layout_file
"$real_jq" '.partitions |= map(if .number == 1 then .mode="fixed" | .fixedBytes=370147328 else . end) | .lvm |= map(if .pvPartitionNumber == 1 then .volumes |= map(if .uuid == "lv-root" then .mode="fixed" | .fixedBytes=335544320 else . end) else . end)' "$tmp/full-layout.json" >"$tmp/full-layout-fixed.json" || fail production-full-layout-fixed-build
TARGET_GROW=yes rootpxe_validate_deployment_layout /dev/mock "$rootpxe_original_schema_file" "$tmp/full-layout-fixed.json" || fail production-full-layout-two-groups-fixed
"$real_jq" -e '(.groups|length)==2 and ([.groups[]|select(.pv.partitionNumber==1).pvBytes]|first) > 268435456 and ([.groups[]|select(.pv.partitionNumber==1).volumes[]|select(.uuid=="lv-root").resolvedBytes]|first)==335544320' "$rootpxe_resolved_lvm_layout_file" >/dev/null || fail production-full-layout-fixed-content
rm -f -- "$rootpxe_resolved_lvm_layout_file"; unset rootpxe_resolved_lvm_layout_file
"$real_jq" '.partitions |= map(if .number == 1 then .mode="remaining" else . end) | .lvm |= map(if .pvPartitionNumber == 1 then .freeSpacePolicy="allocateToRemaining" | .volumes |= map(if .uuid == "lv-root" then .mode="remaining" else . end) else . end)' "$tmp/full-layout.json" >"$tmp/full-layout-remaining.json" || fail production-full-layout-remaining-build
TARGET_GROW=yes rootpxe_validate_deployment_layout /dev/mock "$rootpxe_original_schema_file" "$tmp/full-layout-remaining.json" || fail production-full-layout-two-groups-remaining
"$real_jq" -e '(.groups|length)==2 and ([.groups[]|select(.pv.partitionNumber==1).volumes[]|select(.uuid=="lv-root").resolvedBytes]|first) > 67108864' "$rootpxe_resolved_lvm_layout_file" >/dev/null || fail production-full-layout-remaining-content
"$real_jq" '.lvm |= map(if .pvPartitionNumber == 2 then .volumes |= map(if .uuid == "lv-root-2" then .mode="remaining" else . end) else . end)' "$tmp/full-layout-remaining.json" >"$tmp/full-layout-two-remaining.json" || fail production-full-layout-two-remaining-build
if TARGET_GROW=yes rootpxe_validate_deployment_layout /dev/mock "$rootpxe_original_schema_file" "$tmp/full-layout-two-remaining.json"; then fail production-full-layout-second-remaining-must-reject; fi
rm -f -- "$rootpxe_resolved_lvm_layout_file"; unset rootpxe_resolved_lvm_layout_file TARGET_GROW

cat >"$tmp/production-restore-plan.json" <<'EOF'
{"groups":[{"pv":{"uuid":"pv-1","partitionNumber":1,"originalBytes":268435456,"artifact":"d1p1.lvm.pv.meta","vgConfigArtifact":"d1p1.lvm.vg.cfg"},"vg":{"uuid":"vg-1","name":"vg0","extentBytes":4194304},"pvBytes":268435456,"volumes":[{"name":"root","uuid":"lv-root","fs":"ext4","artifact":"d1p1.lvm.lv.root.img","resolvedBytes":67108864},{"name":"swap","uuid":"lv-swap","fs":"swap","artifact":"","swapUuid":"swap-uuid","resolvedBytes":33554432}]},{"pv":{"uuid":"pv-2","partitionNumber":2,"originalBytes":268435456,"artifact":"d1p2.lvm.pv.meta","vgConfigArtifact":"d1p2.lvm.vg.cfg"},"vg":{"uuid":"vg-2","name":"vg1","extentBytes":4194304},"pvBytes":268435456,"volumes":[{"name":"root","uuid":"lv-root-2","fs":"ext4","artifact":"d1p2.lvm.lv.root.img","resolvedBytes":67108864}]}]}
EOF
export rootpxe_disk_permit_granted=yes rootpxe_disk_permit_target_id=mock-target rootpxe_disk_permit_operation=deploy_write EMPTY_TARGET=yes
export RESTORE_MSYS_PATHS=yes
rootpxe_resolved_lvm_layout_file="$tmp/production-restore-plan.json"
# The early barrier is a real production helper, not a mocked callback.  It
# must accept an empty target report but reject unreadable/foreign/corrupt
# host reports and every artifact/identity defect before a writer is reached.
rootpxe_lvm_preflight_restore_groups "$tmp/real-image" /dev/mock || fail early-preflight-empty-target-must-accept
for mode in fail stderr malformed emptyreport badrow; do
  export EARLY_PVS_MODE="$mode"
  rootpxe_lvm_preflight_restore_groups "$tmp/real-image" /dev/mock >/dev/null 2>&1 && fail "early-pvs-$mode-must-reject"
  unset EARLY_PVS_MODE
  export EARLY_VGS_MODE="$mode"
  rootpxe_lvm_preflight_restore_groups "$tmp/real-image" /dev/mock >/dev/null 2>&1 && fail "early-vgs-$mode-must-reject"
  unset EARLY_VGS_MODE
done
# A safe flat artifact may start with . or + (except . and ..).  The plan
# remains readable only after the matching sidecar is supplied.
cp "$tmp/real-image/d1p1.lvm.pv.meta" "$tmp/real-image/.pv-sidecar"
"$real_jq" '(.groups[0].pv.artifact) = ".pv-sidecar"' "$tmp/production-restore-plan.json" >"$tmp/early-dot-prefix-artifact.json"
rootpxe_resolved_lvm_layout_file="$tmp/early-dot-prefix-artifact.json"
rootpxe_lvm_preflight_restore_groups "$tmp/real-image" /dev/mock || fail early-dot-prefix-artifact-must-accept
cp "$tmp/real-image/d1p1.lvm.pv.meta" "$tmp/real-image/+pv-sidecar"
"$real_jq" '(.groups[0].pv.artifact) = "+pv-sidecar"' "$tmp/production-restore-plan.json" >"$tmp/early-plus-prefix-artifact.json"
rootpxe_resolved_lvm_layout_file="$tmp/early-plus-prefix-artifact.json"
rootpxe_lvm_preflight_restore_groups "$tmp/real-image" /dev/mock || fail early-plus-prefix-artifact-must-accept
rootpxe_resolved_lvm_layout_file="$tmp/production-restore-plan.json"
: >"$restore_trace"
rm -f "$tmp/real-image/d1p2.lvm.lv.root.img"
rootpxe_lvm_preflight_restore_groups "$tmp/real-image" /dev/mock && fail early-missing-later-payload-must-reject
[[ ! -s $restore_trace ]] || fail early-missing-later-payload-must-have-zero-writers
: >"$tmp/real-image/d1p2.lvm.lv.root.img"
"$real_jq" '(.groups[1].volumes[0].uuid) = "lv-root"' "$tmp/production-restore-plan.json" >"$tmp/early-duplicate-lv.json"
rootpxe_resolved_lvm_layout_file="$tmp/early-duplicate-lv.json"
rootpxe_lvm_preflight_restore_groups "$tmp/real-image" /dev/mock && fail early-duplicate-lv-uuid-must-reject
"$real_jq" '(.groups[1].volumes[0].uuid) = "pv-1"' "$tmp/production-restore-plan.json" >"$tmp/early-cross-uuid.json"
rootpxe_resolved_lvm_layout_file="$tmp/early-cross-uuid.json"
rootpxe_lvm_preflight_restore_groups "$tmp/real-image" /dev/mock && fail early-cross-object-uuid-must-reject
"$real_jq" '(.groups[0].pv.artifact) = "."' "$tmp/production-restore-plan.json" >"$tmp/early-dot-artifact.json"
rootpxe_resolved_lvm_layout_file="$tmp/early-dot-artifact.json"
rootpxe_lvm_preflight_restore_groups "$tmp/real-image" /dev/mock && fail early-dot-artifact-must-reject
rootpxe_resolved_lvm_layout_file="$tmp/production-restore-plan.json"
export LIVE_DUPLICATE_SOURCE=yes
rootpxe_lvm_preflight_restore_groups "$tmp/real-image" /dev/mock && fail early-foreign-pv-uuid-must-reject
unset LIVE_DUPLICATE_SOURCE
unset EMPTY_TARGET RESTORE_MSYS_PATHS
export EARLY_PVS_MODE=duplicate
rootpxe_lvm_preflight_restore_groups "$tmp/real-image" /dev/mock && fail early-duplicate-target-pv-row-must-reject
unset EARLY_PVS_MODE
export EARLY_VGS_MODE=duplicate
rootpxe_lvm_preflight_restore_groups "$tmp/real-image" /dev/mock && fail early-duplicate-target-vg-row-must-reject
unset EARLY_VGS_MODE
[[ ! -s "$restore_trace" ]] || fail early-duplicate-target-row-must-have-zero-writers
export EMPTY_TARGET=yes RESTORE_MSYS_PATHS=yes
cp "$tmp/real-image/d1p2.lvm.pv.meta" "$tmp/real-image/d1p2.lvm.pv.meta.good"
printf '%s\n' 'PV UUID foreign-pv' >"$tmp/real-image/d1p2.lvm.pv.meta"
rootpxe_lvm_preflight_restore_groups "$tmp/real-image" /dev/mock && fail early-pv-sidecar-binding-must-reject
printf '%s\n' '# PV UUID pv-2' 'PV UUID foreign-pv' >"$tmp/real-image/d1p2.lvm.pv.meta"
rootpxe_lvm_preflight_restore_groups "$tmp/real-image" /dev/mock && fail early-pv-sidecar-comment-must-reject
mv "$tmp/real-image/d1p2.lvm.pv.meta.good" "$tmp/real-image/d1p2.lvm.pv.meta"
# Execute the production downloader's pre-permit fragment, not just its
# helper.  The actual helper above is retained; every subsequent writer and
# permit/hook stub records an event, so a late-group fault proves the real
# control-flow barrier stops before those calls.
download_barrier="$tmp/download-prepermit-barrier.sh"
sed -n '201,277p' "$download" >"$download_barrier"
bash -n "$download_barrier" || fail downloader-prepermit-fragment-syntax
assert_download_barrier() {
  local fault events
  fault="$1"
  events="$tmp/downloader-$fault.trace"
  : >"$events"
  case $fault in
    payload) rm -f "$tmp/real-image/d1p2.lvm.lv.root.img" ;;
    metadata) cp "$tmp/real-image/d1p2.lvm.vg.cfg" "$tmp/real-image/d1p2.lvm.vg.cfg.gate-good"; printf '%s\n' 'corrupt' >"$tmp/real-image/d1p2.lvm.vg.cfg" ;;
    host) export LIVE_DUPLICATE_SOURCE=yes ;;
    *) fail "unknown downloader barrier fault: $fault" ;;
  esac
  (
    set -u
    imgType=n imgPartitionType=all imagePath="$tmp/real-image" hd=/dev/mock mc=no nombr=0 sector_metadata= originalSchemaFile= deploymentLayoutFile=
    rootpxe_validate_restore_artifacts() { printf 'artifact\n' >>"$events"; }
    rootpxe_plan_deploy_disk_operation() { printf 'UNEXPECTED:permit\n' >>"$events"; }
    rootpxe_wait_for_disk_permit() { printf 'UNEXPECTED:permit-wait\n' >>"$events"; }
    rootpxe_run_pre_deploy_script() { printf 'UNEXPECTED:pre-deploy\n' >>"$events"; }
    preparePartitions() { printf 'UNEXPECTED:preparePartitions\n' >>"$events"; }
    rootpxe_apply_deployment_layout() { printf 'UNEXPECTED:sfdisk\n' >>"$events"; }
    writeImage() { printf 'UNEXPECTED:ordinary-writeImage\n' >>"$events"; }
    pvcreate() { printf 'UNEXPECTED:pvcreate\n' >>"$events"; }
    vgcfgrestore() { printf 'UNEXPECTED:vgcfgrestore\n' >>"$events"; }
    handleError() { printf 'error\n' >>"$events"; exit 0; }
    rootpxe_console_message() { :; }
    rootpxe_stage() { :; }
    rootpxe_deployment_identity_policy_enabled() { return 1; }
    . "$download_barrier"
  ) || fail "downloader barrier execution failed: $fault"
  [[ $(<"$events") == $'artifact\nerror' ]] || { cat "$events" >&2; fail "downloader barrier must stop all writers: $fault"; }
  case $fault in
    payload) : >"$tmp/real-image/d1p2.lvm.lv.root.img" ;;
    metadata) mv "$tmp/real-image/d1p2.lvm.vg.cfg.gate-good" "$tmp/real-image/d1p2.lvm.vg.cfg" ;;
    host) unset LIVE_DUPLICATE_SOURCE ;;
  esac
}
for barrier_fault in payload metadata host; do assert_download_barrier "$barrier_fault"; done
pvs --reportformat json -o pv_name,pv_uuid,vg_name,vg_uuid /dev/mock1 >"$tmp/production-restore-pv-query.json"
"$real_jq" -e --arg path /dev/mock1 '.report[0].pv[0].pv_name == $path' "$tmp/production-restore-pv-query.json" >/dev/null || fail production-restore-pv-query-fixture
rootpxe_restore_lvm_volumes "$tmp/real-image" /dev/mock || fail production-restore-two-groups
[[ $(grep -c '^pvcreate:' "$restore_trace") == 2 && $(grep -c '^vgcfgrestore:' "$restore_trace") == 2 && $(grep -c '^writeImage:' "$restore_trace") == 2 && $(grep -c '^mkswap:' "$restore_trace") == 1 ]] || fail production-restore-leaf-not-run

# A late public-group artifact collision must stop the all-group dispatcher
# before group 1 enters pvcreate/writeImage; validating only each leaf in turn
# would incorrectly leave a partial restore behind.
"$real_jq" '(.groups[1].volumes[0].artifact) = .groups[0].volumes[0].artifact' "$tmp/production-restore-plan.json" >"$tmp/public-group-artifact-conflict.json"
rootpxe_resolved_lvm_layout_file="$tmp/public-group-artifact-conflict.json"; : >"$restore_trace"
rootpxe_restore_lvm_volumes "$tmp/real-image" /dev/mock && fail public-group-artifact-conflict-must-reject
[[ ! -s "$restore_trace" ]] || fail public-group-artifact-conflict-must-have-zero-writers
rootpxe_resolved_lvm_layout_file="$tmp/production-restore-plan.json"

# A missing later payload, a failed full-VG query, and a same-UUID source PV
# all fail in the all-group prewrite phase.  No writer trace may be present.
cp "$tmp/real-image/d1p1.lvm.vg.cfg" "$tmp/real-image/d1p1.lvm.vg.cfg.good"
sed -e 's/"lv-root"/"lv-temp"/' -e 's/"lv-swap"/"lv-root"/' -e 's/"lv-temp"/"lv-swap"/' "$tmp/real-image/d1p1.lvm.vg.cfg.good" >"$tmp/real-image/d1p1.lvm.vg.cfg"; : >"$restore_trace"
rootpxe_restore_lvm_volumes "$tmp/real-image" /dev/mock && fail production-swapped-lv-uuid-must-fail
mv "$tmp/real-image/d1p1.lvm.vg.cfg.good" "$tmp/real-image/d1p1.lvm.vg.cfg"
[[ ! -s "$restore_trace" ]] || fail production-swapped-lv-uuid-must-not-write
rm -f "$tmp/real-image/d1p2.lvm.lv.root.img"; : >"$restore_trace"
rootpxe_restore_lvm_volumes "$tmp/real-image" /dev/mock && fail production-missing-later-payload-must-fail
[[ ! -s "$restore_trace" ]] || fail production-missing-later-payload-must-not-write
: >"$tmp/real-image/d1p2.lvm.lv.root.img"; : >"$restore_trace"; export VGS_QUERY_FAIL=yes
rootpxe_restore_lvm_volumes "$tmp/real-image" /dev/mock && fail production-vgs-query-must-fail
unset VGS_QUERY_FAIL
[[ ! -s "$restore_trace" ]] || fail production-vgs-query-must-not-write
: >"$restore_trace"; export LIVE_DUPLICATE_SOURCE=yes
rootpxe_restore_lvm_volumes "$tmp/real-image" /dev/mock && fail production-foreign-duplicate-must-fail
unset LIVE_DUPLICATE_SOURCE EMPTY_TARGET RESTORE_MSYS_PATHS
[[ ! -s "$restore_trace" ]] || fail production-foreign-duplicate-must-not-write
: >"$restore_trace"; export EMPTY_TARGET=yes DUPLICATE_SOURCE_DIAGNOSTIC=yes RESTORE_MSYS_PATHS=yes
rootpxe_restore_lvm_volumes "$tmp/real-image" /dev/mock && fail production-duplicate-diagnostic-must-fail
unset DUPLICATE_SOURCE_DIAGNOSTIC EMPTY_TARGET RESTORE_MSYS_PATHS
[[ ! -s "$restore_trace" ]] || fail production-duplicate-diagnostic-must-not-write
fi

# Parameterized source-helper matrix: retain the real capture/build-schema/
# resolver/early-preflight/restore leaf functions and vary only command mocks.
# The input discovery and layout arrays are deliberately reversed on alternate
# runs, proving identity binding is not an incidental array-order contract.
for matrix_count in 1 2 3 5; do
  for matrix_order in forward reverse; do
    matrix_image="$tmp/matrix-image-${matrix_count}-${matrix_order}"
    mkdir -p "$matrix_image"; : >"$capture_trace"; : >"$capture_stage_trace"; : >"$restore_trace"
    export MATRIX_GROUP_COUNT="$matrix_count"; unset RESTORE_MSYS_PATHS; [[ $matrix_order == reverse ]] && export MATRIX_REVERSE=yes || unset MATRIX_REVERSE
    rootpxe_lvm_reset_capture_facts
    rootpxe_lvm_capture_preflight /dev/mock "$matrix_image" || fail "matrix-${matrix_count}-${matrix_order}-capture-preflight"
    rootpxe_capture_lvm_volumes "$matrix_image" || fail "matrix-${matrix_count}-${matrix_order}-capture"
    "$real_jq" -e --argjson n "$matrix_count" '(.pvs|length)==$n and (.vgs|length)==$n' "$matrix_image/d1.lvm.schema.json" >/dev/null || fail "matrix-${matrix_count}-${matrix_order}-capture-schema"
    if [[ $matrix_order == reverse ]]; then
      "$real_jq" -e --arg first "$matrix_count" '(.pvs[0].partitionNumber|tostring)==$first and (.vgs[0].uuid == ("vg-"+$first)) and ([.vgs[]|select(.uuid=="vg-1")|.lvs[0].name] == ["data"])' "$matrix_image/d1.lvm.schema.json" >/dev/null || fail "matrix-${matrix_count}-${matrix_order}-schema-wire-order"
    else
      "$real_jq" -e '(.pvs[0].partitionNumber)==1 and (.vgs[0].uuid == "vg-1") and ([.vgs[]|select(.uuid=="vg-1")|.lvs[0].name] == ["root"])' "$matrix_image/d1.lvm.schema.json" >/dev/null || fail "matrix-${matrix_count}-${matrix_order}-schema-wire-order"
    fi
    matrix_last_lba=$(( ((matrix_count + 1) * 268435456 / 512) - 34 ))
    {
      printf '%s\n' 'label: gpt' 'label-id: 00000000-0000-0000-0000-000000000001' 'device: /dev/mock' 'unit: sectors' 'first-lba: 34' "last-lba: $matrix_last_lba"
      for ((matrix_n=1; matrix_n<=matrix_count; matrix_n++)); do printf '/dev/mock%s : start=%s, size=524288, type=8300\n' "$matrix_n" "$((2048 + (matrix_n-1)*524288))"; done
    } >"$matrix_image/d1.partitions"
    rootpxe_build_original_schema /dev/mock "$matrix_image" || fail "matrix-${matrix_count}-${matrix_order}-build-schema"
    if [[ $matrix_order == reverse ]]; then
      "$real_jq" '.lvm.vgs |= reverse' "$rootpxe_original_schema_file" >"$matrix_image/schema-vgs-forward.json" || fail matrix-schema-vgs-reverse
      mv "$matrix_image/schema-vgs-forward.json" "$rootpxe_original_schema_file"
      "$real_jq" -e --arg first "$matrix_count" '(.lvm.pvs[0].partitionNumber|tostring)==$first and (.lvm.vgs[0].uuid=="vg-1") and ([.lvm.vgs[]|select(.uuid=="vg-1")|.lvs[0].name] == ["data"])' "$rootpxe_original_schema_file" >/dev/null || fail "matrix-${matrix_count}-${matrix_order}-schema-independent-wire-order"
    fi
    matrix_hash=$(rootpxe_canonical_json_hash "$rootpxe_original_schema_file") || fail matrix-schema-hash
    "$real_jq" -n --arg hash "$matrix_hash" --slurpfile schema "$rootpxe_original_schema_file" '
      $schema[0] as $s | {schemaHash:$hash,partitions:[$s.partitions[]|{number:.number,mode:"original"}],lvm:[$s.lvm.pvs[] as $pv | $s.lvm.vgs[]|select(.uuid==$pv.vgUuid)|{pvPartitionNumber:$pv.partitionNumber,freeSpacePolicy:"preserveOriginal",volumes:[.lvs[]|{uuid:.uuid,mode:"original"}]}]}' >"$matrix_image/layout.json" || fail matrix-layout-build
    if [[ $matrix_order == reverse ]]; then
      "$real_jq" '.lvm = (.lvm | reverse | map(.volumes = (.volumes | reverse)))' "$matrix_image/layout.json" >"$matrix_image/layout-reversed.json" || fail matrix-layout-reverse
      mv "$matrix_image/layout-reversed.json" "$matrix_image/layout.json"
    fi
    if [[ $matrix_order == reverse ]]; then
      "$real_jq" -e '(.lvm[0].pvPartitionNumber)==1 and ((.lvm | map(select(.pvPartitionNumber == 1))[0].volumes[0].uuid) == "lv-1")' "$matrix_image/layout.json" >/dev/null || fail "matrix-${matrix_count}-${matrix_order}-layout-wire-order"
    else
      "$real_jq" -e '(.lvm[0].pvPartitionNumber)==1 and ((.lvm | map(select(.pvPartitionNumber == 1))[0].volumes[0].uuid) == "lv-1")' "$matrix_image/layout.json" >/dev/null || fail "matrix-${matrix_count}-${matrix_order}-layout-wire-order"
    fi
    schemaHash="$matrix_hash"; schemaRevision=1
    rootpxe_validate_deployment_layout /dev/mock "$rootpxe_original_schema_file" "$matrix_image/layout.json" || fail "matrix-${matrix_count}-${matrix_order}-resolve"
    export rootpxe_disk_permit_granted=yes rootpxe_disk_permit_target_id=mock-target rootpxe_disk_permit_operation=deploy_write EMPTY_TARGET=yes RESTORE_MSYS_PATHS=yes
    rootpxe_lvm_preflight_restore_groups "$matrix_image" /dev/mock || fail "matrix-${matrix_count}-${matrix_order}-early"
    rootpxe_restore_lvm_volumes "$matrix_image" /dev/mock || { printf 'MATRIX-RESTORE-ERROR count=%s order=%s code=%s reason=%s\n' "$matrix_count" "$matrix_order" "${rootpxe_restore_lvm_error_code:-unknown}" "${rootpxe_restore_lvm_error_reason:-unknown}" >&2; fail "matrix-${matrix_count}-${matrix_order}-restore"; }
    expected_writers=$((matrix_count + 1))
    [[ $(grep -c '^pvcreate:' "$restore_trace") == "$matrix_count" && $(grep -c '^writeImage:' "$restore_trace") == "$expected_writers" ]] || fail "matrix-${matrix_count}-${matrix_order}-writers"
    for ((matrix_n=1; matrix_n<=matrix_count; matrix_n++)); do
      grep -Fqx "writeImage:$matrix_image/d1p${matrix_n}.lvm.lv.root.img:/dev/vg${matrix_n}/root" "$restore_trace" || fail "matrix-${matrix_count}-${matrix_order}-root-mapping-${matrix_n}"
      if [[ $matrix_n == 1 ]]; then
        grep -Fqx "writeImage:$matrix_image/d1p1.lvm.lv.data.img:/dev/vg1/data" "$restore_trace" || fail "matrix-${matrix_count}-${matrix_order}-data-mapping"
      fi
    done
    printf 'PASS: matrix groups=%s order=%s\n' "$matrix_count" "$matrix_order"
    rm -f -- "$rootpxe_resolved_lvm_layout_file"; unset rootpxe_resolved_lvm_layout_file EMPTY_TARGET MATRIX_REVERSE
  done
done
unset MATRIX_GROUP_COUNT
fi

echo 'PASS: PXEOS multi-LVM regression'
