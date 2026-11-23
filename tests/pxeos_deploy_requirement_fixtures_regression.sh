#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
repo_root=$(cd "$root/../.." && pwd)
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
checkin="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.checkin"
fixtures_dir="$repo_root/test/fixtures/deploy-requirement"

[[ -d $fixtures_dir ]] || { printf 'FAIL: missing fixtures dir %s\n' "$fixtures_dir" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"; rm -f -- "${rootpxe_resolved_layout_file:-}" "${rootpxe_resolved_lvm_layout_file:-}"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

extract_func(){
    local src="$1" name="$2"
    eval "$(awk -v name="$name" '$0 ~ "^" name "\\(\\)" { found=1 } found {print} found && /^}/ {exit}' "$src")"
}

for fn in \
    rootpxe_canonical_json_hash \
    rootpxe_validate_partition_lba_contract \
    rootpxe_gpt_backup_sectors \
    rootpxe_register_derived_layout_file \
    rootpxe_validate_lvm_deployment_layout_single \
    rootpxe_validate_lvm_deployment_layout \
    rootpxe_validate_deployment_layout; do
    extract_func "$funcs" "$fn"
done

rootpxe_lvm_json_jq(){ command jq "$@"; }
rootpxe_lvm_trim(){ local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; printf '%s' "$v"; }
blockdev(){
    case "$1" in
        --getsize64) printf '%s\n' "$fixture_target_bytes" ;;
        *) return 1 ;;
    esac
}

console_log="$tmp/console.log"
task_log="$tmp/task.log"
stage_log="$tmp/stage.log"
rootpxe_console_message(){ printf '%s|%s\n' "$1" "$2" >>"$console_log"; }
rootpxe_task_log_append(){ printf '%s\n' "$1" >>"$task_log"; }
rootpxe_stage(){ printf '%s|%s\n' "$1" "$2" >>"$stage_log"; }

count=0
shopt -s nullglob
for fixture in "$fixtures_dir"/*.json; do
    count=$((count + 1))
    name=$(basename "$fixture")
    jq '.schema' "$fixture" >"$tmp/schema.json"
    jq '.layout' "$fixture" >"$tmp/layout.json"
    schemaHash=$(jq -er '.schemaHash' "$fixture")
    schemaRevision=1
    fixture_target_bytes=$(jq -er '.targetBytes' "$fixture")
    expected_min=$(jq -er '.expected.minTargetBytes' "$fixture")
    expected_pass=$(jq -r '.expected.pass' "$fixture")
    expected_basis=$(jq -er '.expected.resolvedBasis' "$fixture")
    expected_failure=$(jq -r '.expected.failureKind // ""' "$fixture")
    expected_required=$(jq -r '.expected.requiredBytes // ""' "$fixture")

    : >"$console_log"; : >"$task_log"; : >"$stage_log"
    rm -f -- "${rootpxe_resolved_layout_file:-}" "${rootpxe_resolved_lvm_layout_file:-}"
    unset rootpxe_resolved_layout_file rootpxe_resolved_lvm_layout_file

    taskid=9 task_token=fixture-token pxeapi=https://example.invalid/pxe/v1/
    if rootpxe_validate_deployment_layout /dev/mock "$tmp/schema.json" "$tmp/layout.json"; then
        actual_pass=true
    else
        actual_pass=false
    fi

    [[ $actual_pass == "$expected_pass" ]] || fail "$name: pass=$actual_pass want=$expected_pass"

    if [[ $expected_pass == true ]]; then
        [[ ${rootpxe_resolved_layout_basis:-} == "$expected_basis" ]] || fail "$name: basis=${rootpxe_resolved_layout_basis:-} want=$expected_basis"
        [[ ${rootpxe_resolved_layout_min_target_bytes:-} == "$expected_min" ]] || fail "$name: minTargetBytes=${rootpxe_resolved_layout_min_target_bytes:-} want=$expected_min"
        [[ -r ${rootpxe_resolved_layout_file:-} ]] || fail "$name: missing resolved layout file"

        if [[ $expected_basis == original_fallback ]]; then
            [[ ${rootpxe_deployment_layout_changed:-} == no ]] || fail "$name: fallback must set layout_changed=no"
            grep -Fq 'INFO|Target disk fits original layout only; remaining keeps original size' "$console_log" || fail "$name: missing fallback console INFO"
            grep -Fq '目标磁盘仅能容纳原始布局，剩余空间分区保持原始大小' "$task_log" || fail "$name: missing fallback task log INFO"
            grep -Fq 'layout_validation|target disk fits original layout only; keeping remaining size' "$stage_log" || fail "$name: missing fallback stage callback"
        fi

        if jq -e '.expected.resolvedPartitionSectors != null' "$fixture" >/dev/null; then
            while IFS=$'\t' read -r pnum psec; do
                got=$(jq -er --argjson n "$pnum" '[.[] | select(.number == $n)][0].resolvedSectors' "$rootpxe_resolved_layout_file")
                [[ $got == "$psec" ]] || fail "$name: partition $pnum resolvedSectors=$got want=$psec"
            done < <(jq -r '.expected.resolvedPartitionSectors | to_entries[] | [.key, (.value|tostring)] | @tsv' "$fixture")
        fi

        if jq -e '.expected.resolvedLVBytes != null' "$fixture" >/dev/null; then
            [[ -r ${rootpxe_resolved_lvm_layout_file:-} ]] || fail "$name: missing resolved LVM layout file"
            if [[ $expected_basis == original_fallback ]]; then
                [[ $(jq -er '.freeSpacePolicy' "$rootpxe_resolved_lvm_layout_file") == preserveOriginal ]] || fail "$name: fallback LVM must force preserveOriginal"
            fi
            while IFS=$'\t' read -r lvspec lvbytes; do
                lvuuid=${lvspec#*:}
                got=$(jq -er --arg u "$lvuuid" '[.volumes[] | select(.uuid == $u)][0].resolvedBytes' "$rootpxe_resolved_lvm_layout_file")
                [[ $got == "$lvbytes" ]] || fail "$name: LV $lvuuid resolvedBytes=$got want=$lvbytes"
            done < <(jq -r '.expected.resolvedLVBytes | to_entries[] | [.key, (.value|tostring)] | @tsv' "$fixture")
        fi
    else
        case $expected_failure in
            sector_mismatch)
                [[ ${rootpxe_layout_validation_code:-} == LOGICAL_SECTOR_MISMATCH ]] || fail "$name: code=${rootpxe_layout_validation_code:-} want=LOGICAL_SECTOR_MISMATCH"
                [[ ${rootpxe_layout_validation_reason:-} == sector_alignment_failed ]] || fail "$name: reason=${rootpxe_layout_validation_reason:-} want=sector_alignment_failed"
                ;;
            too_small)
                [[ ${rootpxe_layout_validation_code:-} == INVALID_DEPLOYMENT_LAYOUT ]] || fail "$name: code=${rootpxe_layout_validation_code:-} want=INVALID_DEPLOYMENT_LAYOUT"
                [[ ${rootpxe_layout_validation_reason:-} == TARGET_DISK_TOO_SMALL ]] || fail "$name: reason=${rootpxe_layout_validation_reason:-} want=TARGET_DISK_TOO_SMALL"
                [[ ${rootpxe_layout_validation_extra:-} == "required=${expected_required} target=${fixture_target_bytes} basis=${expected_basis}" ]] || fail "$name: extra='${rootpxe_layout_validation_extra:-}' want='required=${expected_required} target=${fixture_target_bytes} basis=${expected_basis}'"
                ;;
            *)
                fail "$name: unexpected failureKind=$expected_failure"
                ;;
        esac
    fi
done
[[ $count -ge 10 ]] || fail "expected >=10 fixtures, got $count"

# Verify pxeos.checkin emits layoutCapabilities:["layout-original-fallback"]
(
    extract_func "$checkin" rootpxe_write_checkin_json_payload
    taskid=42 task_token=tok123 lmac=001122334455 sysuuid_local=sys-1 type=down
    rootpxe_deployment_identity_capabilities_json(){ printf '["hostname"]'; }
    rootpxe_deployment_identity_capabilities_valid(){ return 0; }
    rootpxe_storage_capabilities(){ return 0; }
    rootpxe_storage_helper="$tmp/storage-helper"
    printf '#!/usr/bin/env bash\nprintf "{}"\n' >"$rootpxe_storage_helper"
    chmod +x "$rootpxe_storage_helper"
    rootpxe_write_checkin_json_payload "$tmp/checkin.json"
    jq -e '(.layoutCapabilities | index("layout-original-fallback")) != null' "$tmp/checkin.json" >/dev/null || fail "checkin missing layout-original-fallback capability"
)

printf 'PASS: all %s deploy-requirement shared fixtures + checkin capability verified in PXEOS\n' "$count"
