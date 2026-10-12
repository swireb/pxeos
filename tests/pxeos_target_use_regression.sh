#!/usr/bin/env bash
# 使用私有 /proc 文本、命令替身和 FD 链接核对目标使用状态；不访问块设备。
set -euo pipefail
# Windows 上的 jq 参数不应把模拟 /dev 路径改写为宿主路径。
export MSYS_NO_PATHCONV=1
real_awk=$(type -P awk)
root="$(cd "$(dirname "$0")/.." && pwd)"
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
tmp="$(mktemp -d /tmp/pxeos-target-use.XXXXXX)"
case "$tmp" in /tmp/pxeos-target-use.*) ;; *) exit 2 ;; esac
trap 'rm -rf -- "$tmp"' EXIT
for helper in rootpxe_target_use_fail rootpxe_target_stat_device_id rootpxe_target_disk_use_preflight; do
    helper_source=$(sed -n "/^${helper}() {/,/^}/p" "$funcs" | sed "s#/proc/#$tmp/proc/#g")
    # MSYS 无符号链接权限时 ln 使用文件副本；FD 存活谓词等价替身仅限测试。
    case ${OSTYPE:-} in msys*|cygwin*) helper_source=${helper_source//'-L $fd'/'-e $fd'} ;; esac
    helper_source=${helper_source//"[[ -r $tmp/proc/swaps ]]"/"[[ \$scenario != existing_unreadable_swaps && -r $tmp/proc/swaps ]]"}
    eval "$helper_source"
done
if ! declare -F rootpxe_target_disk_use_preflight >/dev/null; then
    printf 'FAIL: common target-use preflight is missing\n' >&2
    exit 1
fi
failures=0
checks=0
for scenario in unused active_unmounted_lv canonical_alias mounted_disk mounted_partition mounted_lv active_swap unrelated_swap readonly_fd write_fd readwrite_fd readonly_lv_fd write_lv_fd regular_write_fd fd_flags_invalid fd_stat_error fd_disappeared fd_reused_regular fd_reused_block fd_flags_disappeared fd_recheck_error fd_recheck_invalid invalid_json invalid_shape wrong_device lsblk_error missing_mountinfo malformed_mountinfo missing_swaps malformed_swaps missing_stat runtime_disabled runtime_enabled runtime_missing runtime_duplicate runtime_conflict runtime_badgzip missing_zcat missing_config existing_unreadable_swaps; do
    mkdir -p "$tmp/proc/self" "$tmp/proc/100/fd" "$tmp/proc/100/fdinfo"
    rm -f "$tmp/proc/100/fd/4"
    rm -f "$tmp/fd-reused"
    rm -f "$tmp/proc/config.gz"
    printf '%s\n' '1 0 0:1 / / rw - tmpfs tmpfs rw' >"$tmp/proc/self/mountinfo"
    printf 'Filename\tType\tSize\tUsed\tPriority\n' >"$tmp/proc/swaps"
    expected=0
    expected_code=''
    case "$scenario" in
        mounted_disk|mounted_partition|mounted_lv)
            id=8:0; [[ $scenario == mounted_partition ]] && id=8:1; [[ $scenario == mounted_lv ]] && id=253:0
            printf '2 1 %s / /mounted rw - ext4 /dev/mock rw\n' "$id" >>"$tmp/proc/self/mountinfo"
            expected=1; expected_code=TARGET_DISK_IN_USE ;;
        active_swap|unrelated_swap)
            printf '/dev/mockswap\tpartition\t1024\t0\t-2\n' >>"$tmp/proc/swaps"
            [[ $scenario == active_swap ]] && { expected=1; expected_code=TARGET_DISK_IN_USE; } ;;
        readonly_fd|write_fd|readwrite_fd|readonly_lv_fd|write_lv_fd|regular_write_fd|fd_flags_invalid|fd_stat_error|fd_disappeared|fd_reused_regular|fd_reused_block|fd_flags_disappeared|fd_recheck_error|fd_recheck_invalid)
            : >"$tmp/fd-target"
            ln -s "$tmp/fd-target" "$tmp/proc/100/fd/4"
            flags=0100000
            [[ $scenario == write_fd ]] && flags=0100001
            [[ $scenario == write_lv_fd ]] && flags=0100002
            [[ $scenario == readwrite_fd || $scenario == regular_write_fd ]] && flags=0100002
            [[ $scenario == fd_reused_* || $scenario == fd_flags_disappeared || $scenario == fd_recheck_* ]] && flags=0100002
            [[ $scenario == fd_flags_invalid ]] && flags=invalid
            printf 'pos:\t0\nflags:\t%s\n' "$flags" >"$tmp/proc/100/fdinfo/4"
            case "$scenario" in write_fd|readwrite_fd|write_lv_fd) expected=1; expected_code=TARGET_DISK_IN_USE ;; fd_flags_invalid|fd_stat_error|fd_recheck_error|fd_recheck_invalid) expected=1; expected_code=TARGET_DISK_STATE_UNAVAILABLE ;; esac ;;
        missing_mountinfo) rm "$tmp/proc/self/mountinfo"; expected=1; expected_code=TARGET_DISK_STATE_UNAVAILABLE ;;
        malformed_mountinfo) printf 'broken mount record\n' >"$tmp/proc/self/mountinfo"; expected=1; expected_code=TARGET_DISK_STATE_UNAVAILABLE ;;
        missing_swaps) rm "$tmp/proc/swaps"; expected=1; expected_code=TARGET_DISK_STATE_UNAVAILABLE ;;
        malformed_swaps) printf 'bad header\n' >"$tmp/proc/swaps"; expected=1; expected_code=TARGET_DISK_STATE_UNAVAILABLE ;;
        invalid_json|invalid_shape|wrong_device|lsblk_error|missing_stat) expected=1; expected_code=TARGET_DISK_STATE_UNAVAILABLE ;;
        runtime_*|missing_zcat|missing_config)
            rm "$tmp/proc/swaps"
            printf '# CONFIG_SWAP is not set\n' >"$tmp/proc/config.gz"
            case $scenario in
                runtime_enabled) printf 'CONFIG_SWAP=y\n' >"$tmp/proc/config.gz" ;;
                runtime_missing) printf 'CONFIG_OTHER=y\n' >"$tmp/proc/config.gz" ;;
                runtime_duplicate) printf '# CONFIG_SWAP is not set\n' >>"$tmp/proc/config.gz" ;;
                runtime_conflict) printf 'CONFIG_SWAP=y\n' >>"$tmp/proc/config.gz" ;;
                missing_config) rm "$tmp/proc/config.gz" ;;
            esac
            [[ $scenario == runtime_disabled ]] || { expected=1; expected_code=TARGET_DISK_STATE_UNAVAILABLE; } ;;
        existing_unreadable_swaps)
            printf '# CONFIG_SWAP is not set\n' >"$tmp/proc/config.gz"
            expected=1; expected_code=TARGET_DISK_STATE_UNAVAILABLE ;;
    esac
    status=0
    (
        readlink() { printf '%s\n' "${!#}"; }
        jq() { builtin command jq "$@" | tr -d '\r'; }
        awk() {
            if [[ ${!#} == */fdinfo/4 ]]; then
                [[ $scenario != fd_flags_disappeared ]] || rm "$tmp/proc/100/fd/4"
                : >"$tmp/fd-reused"
            fi
            # 包装函数显式保存失败，避免 Git Bash builtin command 的 errexit
            # 提前结束 fixture；生产调用的是真实 awk，不依赖此替身。
            if "$real_awk" "$@"; then return 0; else return "$?"; fi
        }
        command() {
            [[ $1 != -v || ${2:-} != stat || $scenario != missing_stat ]] || return 1
            [[ $1 != -v || ${2:-} != zcat || $scenario != missing_zcat ]] || return 1
            builtin command "$@"
        }
        zcat() { [[ $scenario != runtime_badgzip ]] || return 1; builtin command cat "${!#}"; }
        lsblk() {
            [[ $scenario == lsblk_error ]] && return 1
            [[ $scenario == invalid_json ]] && { printf 'invalid\n'; return; }
            [[ $scenario == invalid_shape ]] && { printf '%s\n' '{"blockdevices":[{"name":"/dev/mock0","type":"disk","maj:min":"bad"}]}'; return; }
            [[ $scenario == wrong_device ]] && { printf '%s\n' '{"blockdevices":[{"name":"/dev/other","type":"disk","maj:min":"8:9"}]}'; return; }
            [[ $scenario == canonical_alias ]] && { printf '%s\n' '{"blockdevices":[{"name":"/dev/mapper/alias","type":"lvm","maj:min":"8:0"}]}'; return; }
            printf '%s\n' '{"blockdevices":[{"name":"/dev/mock0","type":"disk","maj:min":"8:0","children":[{"name":"/dev/mock0p1","type":"part","maj:min":"8:1","children":[{"name":"/dev/mapper/mock-lv","type":"lvm","maj:min":"253:0"}]}]}]}'
        }
        stat() {
            local path="${!#}"
            case "$path" in
                /dev/mock0) printf 'block special file|8:0\n' ;;
                /dev/mockswap) if [[ $scenario == active_swap ]]; then printf 'block special file|fd:0\n'; else printf 'block special file|8:9\n'; fi ;;
                */fd/4)
                    [[ $scenario != readonly_lv_fd && $scenario != write_lv_fd ]] || { printf 'block special file|fd:0\n'; return; }
                    if [[ -f $tmp/fd-reused ]]; then
                        case $scenario in
                            fd_reused_regular) printf 'regular file|0:0\n'; return ;;
                            fd_reused_block) printf 'block special file|8:9\n'; return ;;
                            fd_recheck_error) return 1 ;;
                            fd_recheck_invalid) printf 'block special file|invalid\n'; return ;;
                        esac
                    fi
                    [[ $scenario == fd_stat_error ]] && return 1
                    [[ $scenario == fd_disappeared ]] && { rm "$path"; return 1; }
                    if [[ $scenario == regular_write_fd ]]; then printf 'regular file|0:0\n'; else printf 'block special file|8:1\n'; fi ;;
                *) printf 'regular file|0:0\n' ;;
            esac
        }
        if rootpxe_target_disk_use_preflight /dev/mock0; then actual=0; else actual=$?; fi
        [[ $actual -eq $expected && ${rootpxe_target_use_code:-} == "$expected_code" ]] || {
            printf 'FAIL: %s actual=%s/%s expected=%s/%s reason=%s\n' "$scenario" "$actual" "${rootpxe_target_use_code:-}" "$expected" "$expected_code" "${rootpxe_target_use_reason:-}" >&2
            exit 1
        }
    ) || status=$?
    checks=$((checks + 1))
    [[ $status -eq 0 ]] || { printf 'FAIL: %s subshell exit %s\n' "$scenario" "$status" >&2; failures=$((failures + 1)); }
done
printf 'Target use: %s cases, %s failures\n' "$checks" "$failures"
[[ $failures -eq 0 ]]
