#!/usr/bin/env bash
# nvme-cli 2.15 会按 FNA 扩大 format 范围；只测 fake nvme，绝不格式化设备。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
export MSYS_NO_PATHCONV=1
for helper in rootpxe_nvme_format_scope_safe rootpxe_plan_deploy_disk_operation rootpxe_nvme_reformat_to_sector_size; do
    eval "$(sed -n "/^${helper}() {/,/^}/p" "$funcs")"
done
if ! declare -F rootpxe_nvme_format_scope_safe >/dev/null; then
    printf 'FAIL: NVMe format scope gate missing\n' >&2; exit 1
fi
tmp=$(mktemp -d /tmp/pxeos-nvme-scope.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
printf 'sector-size: 4096\n' >"$tmp/table"
checks=0 failures=0
for scenario in fna0 fna2 fna1 missing fractional string null negative oversized badjson commandfail changed_after_permit matching; do
    trace="$tmp/$scenario.trace"; : >"$trace"
    (
        jq() { builtin command jq "$@" | tr -d '\r'; }
        nvme() {
            if [[ $1 == format ]]; then printf 'format\n' >>"$trace"; return; fi
            [[ $1 == id-ctrl ]] || return 1
            case $scenario in
                commandfail) return 1 ;;
                badjson) printf invalid ;;
                missing) printf '{}' ;;
                fractional) printf '{"fna":0.5}' ;;
                string) printf '{"fna":"0"}' ;;
                null) printf '{"fna":null}' ;;
                negative) printf '{"fna":-1}' ;;
                oversized) printf '{"fna":256}' ;;
                fna1) printf '{"fna":1}' ;;
                fna2) printf '{"fna":2}' ;;
                changed_after_permit) if [[ ${phase:-} == execute ]]; then printf '{"fna":1}'; else printf '{"fna":0}'; fi ;;
                *) printf '{"fna":0}' ;;
            esac
        }
        blockdev() { [[ $scenario == matching ]] && printf 4096 || printf 512; }
        rootpxe_disk_stable_identity() { printf SERIAL; }
        rootpxe_nvme_find_metadata_free_lbaf() { printf 1; }
        rootpxe_nvme_permit_matches() { :; }
        rootpxe_nvme_wait_for_cancel() { :; }
        rootpxe_require_unused_target_disks() { :; }
        rootpxe_stage() { :; }
        rootpxe_nvme_wait_for_reenumeration() { :; }
        phase=plan; plan_rc=0
        rootpxe_plan_deploy_disk_operation /dev/nvme0n1 "$tmp/table" || plan_rc=$?
        case $scenario in
            fna0|fna2|changed_after_permit|matching) [[ $plan_rc == 0 ]] || exit 1 ;;
            *) [[ $plan_rc != 0 && ${rootpxe_nvme_format_scope_reason:-} == format_scope_* ]] || exit 1; exit 0 ;;
        esac
        [[ $scenario != matching ]] || { [[ $rootpxe_planned_disk_operation == deploy_write ]] || exit 1; exit 0; }
        phase=execute; run_rc=0
        rootpxe_nvme_reformat_to_sector_size /dev/nvme0n1 4096 SERIAL || run_rc=$?
        if [[ $scenario == changed_after_permit ]]; then
            [[ $run_rc != 0 && ${rootpxe_nvme_format_scope_reason:-} == format_scope_unsafe && ! -s $trace ]] || exit 1
        else
            [[ $run_rc == 0 && $(<"$trace") == format ]] || exit 1
        fi
    ) || { printf 'FAIL: %s\n' "$scenario" >&2; failures=$((failures+1)); }
    checks=$((checks+1))
done
printf 'NVMe scope: %s cases, %s failures\n' "$checks" "$failures"
[[ $failures == 0 ]]
