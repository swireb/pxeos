#!/usr/bin/env bash
# Mock-only LVM name contract.  It never opens a block device or invokes an
# LVM writer: invalid plans must stop in the private dispatcher validation.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

: >"$tmp/proc-cmdline"
sed -e "s|/usr/share/pxeos|$overlay/usr/share/pxeos|g" -e "s|</proc/cmdline|<\"$tmp/proc-cmdline\"|" "$overlay/usr/share/pxeos/lib/funcs.sh" >"$tmp/funcs.sh"
# shellcheck disable=SC1090
ismajordebug=0
. "$tmp/funcs.sh"

trace="$tmp/writers.trace"
: >"$tmp/pv.meta"; : >"$tmp/vg.conf"; : >"$tmp/payload.img"
: >"$tmp/pv-contract-2.img"; : >"$tmp/vg-contract-2.conf"; : >"$tmp/payload-2.img"
pvs() { printf 'pvs\n' >>"$trace"; printf '%s\n' '{"report":[{"pv":[]}]}'; }
vgs() { printf 'vgs\n' >>"$trace"; printf '%s\n' '{"report":[{"vg":[]}]}'; }
rootpxe_lvm_restore_metadata_binds_group() { return 0; }
rootpxe_lvm_pv_sidecar_binds_uuid() { return 0; }
rootpxe_restore_lvm_volumes_single() { printf 'restore-single\n' >>"$trace"; return 0; }

make_plan() {
    local vg="$1" lv="$2" plan="$3"
    jq -n --arg vg "$vg" --arg lv "$lv" '{groups:[{pv:{uuid:"pv-contract",partitionNumber:1,originalBytes:1048576,artifact:"pv.meta",vgConfigArtifact:"vg.conf"},vg:{uuid:"vg-contract",name:$vg,extentBytes:4096},pvBytes:1048576,volumes:[{name:$lv,uuid:"lv-contract",fs:"ext4",resolvedBytes:1048576,artifact:"payload.img",swapUuid:""}]}]}' >"$plan"
}

expect_dispatch_rejects() {
    local label="$1" vg="$2" lv="$3" plan before
    plan="$tmp/$label.json"; before="$tmp/$label.before.json"
    make_plan "$vg" "$lv" "$plan"
    cp "$plan" "$before"
    rootpxe_resolved_lvm_layout_file="$plan"; : >"$trace"
    if rootpxe_lvm_preflight_restore_groups "$tmp" /dev/mock; then fail "$label early accepted"; fi
    [[ ! -s $trace ]] || fail "$label early reached writer"
    cmp -s "$plan" "$before" || fail "$label early changed public plan"
    if rootpxe_restore_lvm_volumes "$tmp" /dev/mock; then fail "$label restore accepted"; fi
    [[ ! -s $trace ]] || fail "$label restore reached writer"
    cmp -s "$plan" "$before" || fail "$label restore changed public plan"
}

make_two_group_plan() {
    local vg2="$1" plan="$2"
    make_plan vg root "$plan"
    jq --arg vg "$vg2" '.groups += [(.groups[0] | .pv.uuid="pv-contract-2" | .pv.partitionNumber=2 | .pv.artifact="pv-contract-2.img" | .pv.vgConfigArtifact="vg-contract-2.conf" | .vg.uuid="vg-contract-2" | .vg.name=$vg | .volumes[0].uuid="lv-contract-2" | .volumes[0].artifact="payload-2.img")]' "$plan" >"$plan.next"
    mv "$plan.next" "$plan"
}

expect_late_group_rejects() {
    local plan="$tmp/late-group.json" before="$tmp/late-group.before.json"
    make_two_group_plan "$(printf 'v%.0s' {1..128})" "$plan"
    cp "$plan" "$before"
    rootpxe_resolved_lvm_layout_file="$plan"; : >"$trace"
    if rootpxe_lvm_preflight_restore_groups "$tmp" /dev/mock; then fail late-group-early-accepted; fi
    [[ ! -s $trace ]] || fail late-group-early-reached-writer
    if rootpxe_restore_lvm_volumes "$tmp" /dev/mock; then fail late-group-restore-accepted; fi
    [[ ! -s $trace ]] || fail late-group-restore-reached-writer
    cmp -s "$plan" "$before" || fail late-group-changed-public-plan
}

expect_late_group_accepts() {
    local plan="$tmp/late-group-valid.json"
    make_two_group_plan vg-second "$plan"
    rootpxe_resolved_lvm_layout_file="$plan"; : >"$trace"
    rootpxe_lvm_preflight_restore_groups "$tmp" /dev/mock || fail late-group-valid-early-rejected
    grep -Fx pvs "$trace" >/dev/null || fail late-group-valid-early-did-not-reach-post-name-barrier
    rootpxe_restore_lvm_volumes "$tmp" /dev/mock || fail late-group-valid-restore-rejected
    [[ $(grep -Fc restore-single "$trace") -eq 4 ]] || fail late-group-valid-restore-did-not-reach-each-leaf
}

expect_dispatch_accepts() {
    local label="$1" vg="$2" lv="$3" plan
    plan="$tmp/$label.json"
    make_plan "$vg" "$lv" "$plan"
    rootpxe_resolved_lvm_layout_file="$plan"; : >"$trace"
    rootpxe_lvm_preflight_restore_groups "$tmp" /dev/mock || fail "$label early rejected"
    grep -Fx pvs "$trace" >/dev/null || fail "$label early did not reach post-name barrier"
    grep -Fx vgs "$trace" >/dev/null || fail "$label early did not reach post-name barrier"
    rootpxe_restore_lvm_volumes "$tmp" /dev/mock || fail "$label restore rejected"
    [[ $(grep -Fc restore-single "$trace") -eq 2 ]] || fail "$label restore did not reach single leaf twice"
}

rootpxe_lvm_validate_vg_name "$(printf 'v%.0s' {1..127})" || fail vg-127-rejected
if rootpxe_lvm_validate_vg_name "$(printf 'v%.0s' {1..128})"; then fail vg-128-accepted; fi
rootpxe_lvm_validate_lv_name .hidden || fail lv-leading-dot-rejected
rootpxe_lvm_validate_lv_name +name || fail lv-leading-plus-rejected
rootpxe_lvm_validate_lv_name Root || fail lv-uppercase-rejected
rootpxe_lvm_validate_lv_name root || fail lv-lowercase-rejected
for name in snapshot-data pvmove-data data_cdata data_cmeta data_corig data_cpool data_cvol data_wcorig data_mimage data_mlog data_rimage data_rmeta data_tdata data_tmeta data_vdata data_imeta data_iorig data_pmspare data_vorigin; do
    if rootpxe_lvm_validate_lv_name "$name"; then fail "$name accepted"; fi
    expect_dispatch_rejects "reserved-$name" vg "$name"
done
rootpxe_lvm_validate_lv_name Snapshot-data || fail snapshot-case-sensitive-rejected

expect_dispatch_rejects vg128 "$(printf 'v%.0s' {1..128})" root
expect_dispatch_rejects lv128 vg "$(printf 'l%.0s' {1..128})"
expect_dispatch_rejects mapped128 "$(printf 'a%.0s' {1..64})" "$(printf 'b%.0s' {1..63})"
expect_dispatch_rejects escaped128 "$(printf 'a-%.0s' {1..31})" "$(printf 'b%.0s' {1..34})"
expect_late_group_rejects
expect_late_group_accepts

rootpxe_lvm_validate_vg_name "$(printf 'a%.0s' {1..63})" || fail mapper-127-vg-invalid
rootpxe_lvm_validate_lv_name "$(printf 'b%.0s' {1..63})" || fail mapper-127-lv-invalid
rootpxe_lvm_validate_mapper_name "$(printf 'a%.0s' {1..63})" "$(printf 'b%.0s' {1..63})" || fail mapper-127-rejected
if rootpxe_lvm_validate_mapper_name "$(printf 'a%.0s' {1..64})" "$(printf 'b%.0s' {1..63})"; then fail mapper-128-accepted; fi
rootpxe_lvm_validate_mapper_name "$(printf 'a-%.0s' {1..31})" "$(printf 'b%.0s' {1..33})" || fail escaped-mapper-127-rejected
if rootpxe_lvm_validate_mapper_name "$(printf 'a-%.0s' {1..31})" "$(printf 'b%.0s' {1..34})"; then fail escaped-mapper-128-accepted; fi
expect_dispatch_accepts mapper127 "$(printf 'a%.0s' {1..63})" "$(printf 'b%.0s' {1..63})"
expect_dispatch_accepts escaped127 "$(printf 'a-%.0s' {1..31})" "$(printf 'b%.0s' {1..33})"
expect_dispatch_accepts case-upper Root Root
expect_dispatch_accepts case-lower root root
printf 'PASS: PXEOS LVM naming contract\n'
