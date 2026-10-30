#!/usr/bin/env bash
# 仅提取被测函数，以普通临时文件和函数替身验证；绝不调用真实磁盘工具。
set -uo pipefail
shopt -s extglob
root=$(cd "$(dirname "$0")/.." && pwd)
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
export PATH="$root/tests/fixtures/msys-tools:$PATH"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
failures=0
cases=0
fail() { printf 'FAIL: %s\n' "$*" >&2; return 1; }
check_eq() { [[ $1 == "$2" ]] || fail "$3: expected [$2], got [$1]"; }
load_function() {
    local body
    body=$(sed -n "/^$1() {/,/^}/p" "$funcs")
    [[ -n $body ]] || fail "missing function: $1" || return 1
    body=${body//\/tmp\/move/$tmp\/move}
    body=${body//\/tmp\/rootpxe-lvm/$tmp\/probe-lvm}
    eval "$body"
}
run_case() {
    cases=$((cases + 1))
    if ( "$@" ); then
        printf 'PASS: %s\n' "$1"
    else
        failures=$((failures + 1))
        printf 'FAIL CASE: %s\n' "$1" >&2
    fi
}
handleError() { fail "$*"; exit 77; }
debugEcho() { :; }
debugPause() { :; }
majorDebugEcho() { :; }
majorDebugPause() { :; }
rootpxe_console_message() { :; }
# 即使遗漏 mock，也不得触及真实设备、网络或 VG。
sfdisk() { handleError 'unexpected native sfdisk'; }
nvme() { handleError 'unexpected native nvme'; }
lvm() { handleError 'unexpected native lvm'; }
curl() { handleError 'unexpected network'; }
for name in partitionIsDosExtended movePartition getFSID getValidRestorePartitions MBRFileName getPartBlockSize rootpxe_safe_relative_path calculate calculate_float sec2string restorePartition rootpxe_validate_deployment_layout findHDDInfo rootpxe_nvme_wait_for_cancel uploadFormat rootpxe_validate_windows_hostname getGraphics doInventory rootpxe_lvm_capture_preflight_single savePartitionTablesAndBootLoaders; do
    load_function "$name" || exit 1
done
if grep -q '^rootpxe_effective_img_format() {' "$funcs"; then load_function rootpxe_effective_img_format; fi

test_dos_extended() {
    local got mock_scheme=dos mock_parttype=5 item
    getPartitionEntryScheme() { scheme=$mock_scheme; }
    getPartType() { parttype=$mock_parttype; }
    for item in 5 f 85 0x5 0xf 0x85; do
        mock_parttype=$item
        got=$(partitionIsDosExtended /dev/mock1)
        check_eq "$got" yes "DOS extended type $item" || return 1
    done
    mock_parttype=83
    check_eq "$(partitionIsDosExtended /dev/mock1)" no 'DOS data partition' || return 1
    mock_scheme=gpt mock_parttype=5
    check_eq "$(partitionIsDosExtended /dev/mock1)" no 'GPT is not DOS extended' || return 1
    mock_scheme=''
    check_eq "$(partitionIsDosExtended /dev/mock1)" no 'unknown scheme'
}
move_fixture() {
    local prefix=$1
    printf 'label: dos\ndevice: %s\nunit: sectors\n' "${prefix%[0-9]}"
    printf '%s1 : start=2048, size=1024, type=83\n' "$prefix"
    printf '%s10 : start=32768, size=8192, type=83\n' "$prefix"
    printf '%s2 : start=8192, size=2048, type=83\n' "$prefix"
    printf '%s20 : start=65536, size=8192, type=83\n' "$prefix"
}
setup_move_mocks() {
    getDiskFromPartition() { disk=/dev/mock; }
    saveSfdiskPartitions() { printf '%s\n' "$dump" >"$2"; return "${save_rc:-0}"; }
    processSfdisk() {
        printf '%s|%s|%s\n' "$2" "$3" "$4" >"$tmp/process"
        [[ ${process_empty:-no} == yes ]] || cat "$1"
        return "${process_rc:-0}"
    }
    applySfdiskPartitions() { printf '%s\n' "$1" >"$tmp/applied"; }
    ismajordebug=0
    rm -f -- "$tmp/applied" "$tmp/process"
}
test_move_exact_partition() {
    local prefix dump
    setup_move_mocks
    for prefix in /dev/sda /dev/nvme0n1p; do
        dump=$(move_fixture "$prefix")
        movePartition "${prefix}2" "${prefix}1" || return 1
        check_eq "$(cat "$tmp/process")" "move|${prefix}2|3072" 'exact previous/current row' || return 1
        [[ -s $tmp/applied ]] || fail 'valid move did not reach mocked writer' || return 1
    done
}
test_move_invalid_dump() {
    local dump save_rc=0 process_rc=0 process_empty=no rc item
    setup_move_mocks
    for item in missing duplicate negative invalid zero dump_failure processor_failure processor_empty; do
        dump=$(move_fixture /dev/sda)
        save_rc=0 process_rc=0 process_empty=no
        case $item in
            missing) dump=${dump/\/dev\/sda1 : start=2048, size=1024, type=83/} ;;
            duplicate) dump+=$'\n/dev/sda1 : start=2048, size=1024, type=83' ;;
            negative) dump=${dump/start=2048/start=-1} ;;
            invalid) dump=${dump/size=1024/size=invalid} ;;
            zero) dump=${dump/size=1024/size=0} ;;
            dump_failure) save_rc=9 ;;
            processor_failure) process_rc=9 ;;
            processor_empty) process_empty=yes ;;
        esac
        rm -f -- "$tmp/applied" "$tmp/process"
        rc=0; movePartition /dev/sda2 /dev/sda1 >/dev/null 2>&1 || rc=$?
        [[ $rc != 0 && ! -e $tmp/applied ]] || fail "invalid dump reached writer or returned success: $item rc=$rc" || return 1
    done
}
test_fsid_exact_partition() {
    local prefix fsid_dump mock_flock_rc=0
    getDiskFromPartition() { disk=/dev/mock; }
    flock() { printf '%s\n' "$fsid_dump"; return "$mock_flock_rc"; }
    for prefix in /dev/sda /dev/nvme0n1p; do
        fsid_dump=$(printf '%s1 : start=2048, size=1024, Id=83\n%s10 : start=4096, size=1024, Id=82\n' "$prefix" "$prefix")
        getFSID "${prefix}1" || return 1
        check_eq "$fsid" 83 'FSID exact first column' || return 1
    done
}
test_fsid_invalid_dump() {
    local fsid_dump mock_flock_rc=0 status item
    getDiskFromPartition() { disk=/dev/mock; }
    flock() { printf '%s\n' "$fsid_dump"; return "$mock_flock_rc"; }
    for item in missing duplicate malformed dump_failure; do
        fsid_dump='/dev/sda1 : start=2048, size=1024, Id=83'
        mock_flock_rc=0
        case $item in
            missing) fsid_dump='/dev/sda10 : start=2048, size=1024, Id=82' ;;
            duplicate) fsid_dump+=$'\n/dev/sda1 : start=2048, size=1024, Id=82' ;;
            malformed) fsid_dump='/dev/sda1 : start=2048, size=1024, Id=invalid' ;;
            dump_failure) mock_flock_rc=9 ;;
        esac
        fsid=stale
        status=0; getFSID /dev/sda1 >/dev/null 2>&1 || status=$?
        [[ $status != 0 && -z $fsid ]] || fail "invalid FSID accepted or retained stale value: $item" || return 1
    done
}
test_restore_paths_reset() {
    local image="$tmp/windows" osid=5 imgFormat=0 imgPartitionType=all
    mkdir -p "$image"
    : >"$image/d1p1.img"; : >"$image/d1p3.img"
    getPartitions() { parts='/dev/mock1 /dev/mock2 /dev/mock3'; }
    getPartitionNumber() { part_number=${1##*[!0-9]}; }
    getValidRestorePartitions /dev/mock 1 "$image" ''
    check_eq "$restoreparts" '/dev/mock1 /dev/mock3' 'missing single payload excludes only partition 2' || return 1
    : >"$image/d1p2.img"
    getValidRestorePartitions /dev/mock 1 "$image" ''
    check_eq "$restoreparts" '/dev/mock1 /dev/mock2 /dev/mock3' 'complete single-file artifacts'
}
test_printf_data() {
    local type=up mbrfile='' selected='' pbs='' expected="$tmp/100%backup/d1.mbr"
    hasGRUB() { hasGRUB=0; }
    MBRFileName "$tmp/100%backup" 1 selected ''
    check_eq "$selected" "$expected" 'capture MBR percent path' || return 1
    mkdir -p "$tmp/100%backup"; : >"$expected"
    type=down
    MBRFileName "$tmp/100%backup" 1 selected ''
    check_eq "$selected" "$expected" 'restore MBR percent path' || return 1
    blockdev() { printf '4096%%mock'; }
    getPartBlockSize /dev/mock1 pbs
    check_eq "$pbs" '4096%mock' 'block size is printf data' || return 1
    blockdev() { return 9; }
    if getPartBlockSize /dev/mock1 pbs; then fail 'blockdev failure hidden by printf'; return 1; fi
}
test_path_controls() {
    local input
    check_eq "$(rootpxe_safe_relative_path /folder/image)" folder/image 'one leading slash' || return 1
    for input in $'a\n../../x' $'a\r/x' $'a\t/x' $'a\177/x' $'a\001/x' //folder/x a/../x a/./x a//x a/ ''; do
        if rootpxe_safe_relative_path "$input" >/dev/null; then fail "unsafe path accepted: $(printf '%q' "$input")"; return 1; fi
    done
}
test_path_array_local() {
    local before
    _rootpxe_parts=(caller sentinel)
    before=$(declare -p _rootpxe_parts)
    rootpxe_safe_relative_path safe/image >/dev/null || return 1
    check_eq "$(declare -p _rootpxe_parts)" "$before" 'caller array survives path validation'
}

test_duration_unambiguous() {
    local item seconds expected
    for item in '0|00:00:00' '1|00:00:01' '60|00:01:00' '303|00:05:03' '3600|01:00:00' '86400|1 day 00:00:00' '172803|2 days 00:00:03'; do
        IFS='|' read -r seconds expected <<<"$item"
        check_eq "$(sec2string "$seconds")" "$expected" "duration $seconds" || return 1
    done
}
setup_restore_mocks() {
    getDiskFromPartition() { disk=/dev/mock; }
    getPartitionNumber() { part_number=${1##*[!0-9]}; }
    getPartType() { parttype=83; }
    rootpxe_partition_progress_item() { :; }
    rootpxe_partition_progress_clear_current_item() { :; }
    runPartprobe() { :; }
    resetFlag() { :; }
    EBRFileName() { ebrfilename="$tmp/no-ebr"; }
    writeImage() { printf '%s|%s\n' "$1" "$2" >"$tmp/restored"; }
}
test_restore_local_partition_number() {
    local imgType=mps imgFormat=0 imgPartitionType=2 osid=50 part_number=99
    mkdir -p "$tmp/selected"; : >"$tmp/selected/d1p2.img"
    setup_restore_mocks
    restorePartition /dev/mock2 1 "$tmp/selected" '' || return 1
    [[ -s $tmp/restored ]] || fail 'caller part_number suppressed selected partition' || return 1
    check_eq "$part_number" 99 'caller partition number preserved' || return 1
    rm -f "$tmp/restored"
    imgPartitionType=1
    restorePartition /dev/mock2 1 "$tmp/selected" '' || return 1
    [[ ! -e $tmp/restored ]] || fail 'unselected partition restored'
}
test_effective_restore_format() {
    local imgType=n imgFormat=0 imgPartitionType=all osid=50 part_number=0
    mkdir -p "$tmp/current"; : >"$tmp/current/d1p1.img"
    setup_restore_mocks
    getPartitions() { parts=/dev/mock1; }
    getValidRestorePartitions /dev/mock 1 "$tmp/current" ''
    check_eq "$restoreparts" /dev/mock1 'current single artifact selected' || return 1
    restorePartition /dev/mock1 1 "$tmp/current" '' || return 1
    check_eq "$(cat "$tmp/restored")" "$tmp/current/d1p1.img|/dev/mock1" 'restore uses exact artifact'
}
test_layout_hash_early_gate() {
    local schemaHash='' schemaRevision=1 status item good_hash
    good_hash=$(printf 'a%.0s' {1..64})
    : >"$tmp/schema"; : >"$tmp/layout"
    rootpxe_canonical_json_hash() { printf '%s' "$good_hash"; }
    jq() { : >"$tmp/jq-probe"; return 9; }
    for item in '' malformed "$(printf 'b%.0s' {1..64})"; do
        schemaHash=$item
        rm -f "$tmp/jq-probe"
        status=0; rootpxe_validate_deployment_layout /dev/mock "$tmp/schema" "$tmp/layout" || status=$?
        [[ $status != 0 && ! -e $tmp/jq-probe ]] || fail 'schema hash not rejected before layout/device probes' || return 1
    done
    schemaHash=$good_hash
    rootpxe_validate_deployment_layout /dev/mock "$tmp/schema" "$tmp/layout" >/dev/null 2>&1 || :
    [[ -e $tmp/jq-probe ]] || fail 'matching hash did not reach layout validation'
}
test_selected_disk_size() {
    local imgType=n type=down hd='' disks='' diskSize='' layPartSize='' mock_disk_size=4398046511104
    getHardDisk() { hd=/dev/xvda; disks=$hd; }
    dots() { :; }
    validResizeOS() { :; }
    rootpxe_console_message() { printf '%s\n' "$*" >>"$tmp/disk-console"; }
    lsblk() { printf '%s\n' "$*" >"$tmp/lsblk-args"; printf '%s\n' "$mock_disk_size"; }
    findHDDInfo >/dev/null || return 1
    [[ $(cat "$tmp/lsblk-args") != *'-I '* ]] || fail 'selected Xen disk still major-filtered' || return 1
    check_eq "$diskSize" "$mock_disk_size" 'selected disk byte size' || return 1
    check_eq "$(grep -c 'Using disk device' "$tmp/disk-console")" 1 'device message once' || return 1
    mock_disk_size=invalid
    local status=0
    ( findHDDInfo ) >/dev/null 2>&1 || status=$?
    [[ $status != 0 ]] || fail 'invalid selected disk size accepted'
}
test_nvme_countdown_elapsed() {
    local PXEOS_NVME_FORMAT_COUNTDOWN_SEC=3 mock_tick=0 mock_read_mode=eof read_count=0
    # Bash SECONDS is used as a monotonic elapsed clock; the fixture replaces
    # it with an ordinary local variable so no real wait is required.
    local SECONDS=0
    date() { printf '%s\n' "$mock_tick"; }
    sleep() { mock_tick=$((mock_tick + 1)); SECONDS=$((SECONDS + 1)); }
    read() { read_count=$((read_count + 1)); if [[ $mock_read_mode == fast_key ]]; then reply=x; return 0; fi; return 1; }
    rootpxe_stage() { :; }
    rootpxe_nvme_wait_for_cancel </dev/null || return 1
    (( mock_tick >= 3 )) || fail 'EOF consumed countdown without elapsed time' || return 1
    mock_read_mode=fast_key mock_tick=0 SECONDS=0 read_count=0
    rootpxe_nvme_wait_for_cancel || return 1
    (( mock_tick >= 3 )) || fail 'fast non-cancel keys consumed countdown' || return 1
    mock_read_mode=cancel
    read() { reply=C; return 0; }
    if rootpxe_nvme_wait_for_cancel; then fail 'C did not cancel'; return 1; fi
    PXEOS_NVME_FORMAT_COUNTDOWN_SEC=0 mock_tick=0
    rootpxe_nvme_wait_for_cancel || return 1
    check_eq "$mock_tick" 0 'zero countdown'
}
test_upload_compression_args() {
    local imgType=n imgFormat=0 PIGZ_COMP=-6 writer_pids=() item status
    : >"$tmp/capture-input"
    nproc() { printf '2\n'; }
    mkfifo() { : >"$tmp/fifo-called"; : >"$1"; }
    pigz() { printf '%s\n' "$#" >"$tmp/compressor-argc"; printf '%s\n' "$*" >"$tmp/compressor-args"; command cat; }
    zstdmt() { pigz "$@"; }
    rootpxe_storage_write_payload() { command cat >"$1.000"; }
    uploadFormat "$tmp/capture-input" "$tmp/capture-output" || return 1
    wait "$rootpxe_last_writer_pid" || return 1
    check_eq "$(cat "$tmp/compressor-argc")" 1 'gzip level uses one parameter' || return 1
    PIGZ_COMP=-9
    uploadFormat "$tmp/capture-input" "$tmp/capture-output" || return 1
    wait "$rootpxe_last_writer_pid" || return 1
    check_eq "$(cat "$tmp/compressor-args")" -9 'single gzip level preserved' || return 1
    imgFormat=5 PIGZ_COMP=-9
    uploadFormat "$tmp/capture-input" "$tmp/capture-output" || return 1
    wait "$rootpxe_last_writer_pid" || return 1
    check_eq "$(cat "$tmp/compressor-args")" '--rsyncable -9' 'single zstd level preserved' || return 1
    imgFormat=5 PIGZ_COMP=0
    rm -f "$tmp/compressor-argc"
    uploadFormat "$tmp/capture-input" "$tmp/uncompressed-output" || return 1
    wait "$rootpxe_last_writer_pid" || return 1
    [[ ! -e $tmp/compressor-argc ]] || fail 'uncompressed capture used compressor' || return 1
    for item in '0|-10' '0|-6 --rsyncable' '5|-10' '5|--help' '5|-3 --help'; do
        IFS='|' read -r imgFormat PIGZ_COMP <<<"$item"
        rm -f "$tmp/fifo-called" "$tmp/compressor-argc"
        status=0; ( uploadFormat "$tmp/missing-fifo" "$tmp/invalid-output"; wait ) >/dev/null 2>&1 || status=$?
        [[ $status != 0 && ! -e $tmp/fifo-called && ! -e $tmp/compressor-argc ]] || fail "invalid compression reached setup: $item" || return 1
    done
}
test_windows_hostname_edges() {
    local value
    for value in host H A1 A-B 1HOST HOST1; do rootpxe_validate_windows_hostname "$value" || fail "valid hostname $value" || return 1; done
    for value in -HOST HOST- - 123 '' A_B A.B 'longer-than-15-chars'; do
        if rootpxe_validate_windows_hostname "$value"; then fail "invalid hostname $value"; return 1; fi
    done
}
test_graphics_object_array() {
    local vendor=caller-vendor product=caller-product graphics_json
    lshw() { printf '%s\n' "$graphics_json"; }
    graphics_json='{"vendor":"Vendor  Name","product":"Single GPU"}'
    graphics_vendors_array=(stale); graphics_products_array=(stale)
    getGraphics
    check_eq "$inventory_graphics_vendor" 'Vendor  Name' 'single graphics object' || return 1
    check_eq "${graphics_vendors_array[*]}|${graphics_products_array[*]}" 'Vendor  Name|Single GPU' 'inventory display array setters' || return 1
    check_eq "$vendor|$product" 'caller-vendor|caller-product' 'graphics local fields' || return 1
    check_eq "$(printf '%s' "$inventory_graphics_vendor64" | base64 -d)" 'Vendor  Name' 'graphics base64 exact bytes' || return 1
    graphics_json='[{"vendor":"One","product":"GPU 1"},{"vendor":"Two","product":"GPU 2"}]'
    getGraphics
    check_eq "$inventory_graphics_product" 'GPU 1,GPU 2' 'graphics array'
}
test_inventory_base64_bytes() {
    local hd=/dev/mock mock_inventory='  Vendor   with preserved spaces and more than seventy-six encoded columns  '
    getGraphics() { :; }
    dmidecode() { printf '%s' "$mock_inventory"; }
    hdparm() { printf 'Model=fixture\n'; }
    smartctl() { return 1; }
    cat() { if [[ $1 == /proc/meminfo ]]; then printf 'MemTotal: 1024 kB\n'; else command cat "$@"; fi; }
    doInventory
    [[ $sysman64 != *$'\n'* ]] || fail 'inventory base64 line-wrapped' || return 1
    check_eq "$(printf '%s' "$sysman64" | base64 -d)" "$mock_inventory" 'inventory base64 preserves whitespace without newline'
}
test_lvm_probe_cleanup() {
    local part_number=0 parts='' status=0
    getPartitions() { parts=/dev/mock1; }
    getPartitionNumber() { part_number=1; }
    blkid() { printf 'LVM2_member'; }
    pvs() { :; }; vgs() { :; }; lvs() { :; }
    blockdev() { printf '4096'; }
    rootpxe_lvm_reset_capture_facts() { rm -f -- "${rootpxe_lvm_facts_file:-}" "${rootpxe_lvm_lv_facts_file:-}"; }
    rootpxe_lvm_capture_report() { : >"$1"; }
    rootpxe_lvm_json_jq() {
        [[ $1 == -r ]] || return 0
        case "$*" in
            *'.pv[]'*) printf '/dev/mock1\tpv-uuid\tvg\tvg-uuid\t4096\t512\n' ;;
            *'.vg[]'*) printf 'vg\tvg-uuid\t512\t0\n' ;;
            *'.lv[]'*) printf 'bad\tlv-uuid\t/dev/vg/bad\t1024\t-wi-a-----\tlinear\t\t\t\t\n' ;;
        esac
    }
    rootpxe_lvm_trim() { printf '%s' "$1"; }
    rootpxe_lvm_safe_identifier() { return 0; }
    rootpxe_lvm_validate_vg_name() { return 0; }
    rootpxe_lvm_validate_mapper_name() { return 1; }
    rootpxe_lvm_remove_probe_files() { rm -f -- "$@"; }
    rootpxe_lvm_capture_preflight_single /dev/mock "$tmp" || status=$?
    [[ $status != 0 ]] || fail 'invalid LV unexpectedly accepted' || return 1
    [[ -z $(find "$tmp" -maxdepth 1 -name 'probe-lvm-*' -print) ]] || fail 'LV failure leaked probe file'
}
test_calculate_failure_status() {
    local expression
    check_eq "$(calculate '(1+2)*4')" 12 'integer arithmetic' || return 1
    check_eq "$(calculate_float '1/4')" 0.250000 'float arithmetic' || return 1
    for expression in '' '1+' 'system("false")' $'1\n+2' '1e3' "$(printf '1%.0s' {1..4097})"; do
        if calculate "$expression" >/dev/null 2>&1; then fail 'invalid integer arithmetic accepted'; return 1; fi
        if calculate_float "$expression" >/dev/null 2>&1; then fail 'invalid float arithmetic accepted'; return 1; fi
    done
    # PXEOS uses gawk; host awk variants disagree about division-by-zero status.
    # Inject a tool failure to test propagation independently of the host dialect.
    awk() { return 9; }
    if calculate '1/0' >/dev/null 2>&1; then fail 'integer arithmetic tool failure hidden'; return 1; fi
    if calculate_float '1/0' >/dev/null 2>&1; then fail 'float arithmetic tool failure hidden'; return 1; fi
}
test_mbr_capture_done_once() {
    sfdiskPartitionFileName() { sfdiskoriginalpartitionfilename="$tmp/d1.partitions"; sfdiskminimumfilename="$tmp/d1.minimum.partitions"; }
    hasGPT() { hasgpt=0; }
    flock() { :; }
    runPartprobe() { :; }
    saveGRUB() { :; }
    saveAllEBRs() { :; }
    dots() { :; }
    local imgType=mps capture_output
    capture_output=$(savePartitionTablesAndBootLoaders /dev/mock 1 "$tmp" 50 all '')
    check_eq "$(grep -Fxc Done <<<"$capture_output")" 1 'one MBR capture completion message'
}

run_case test_dos_extended
run_case test_move_exact_partition
run_case test_move_invalid_dump
run_case test_fsid_exact_partition
run_case test_fsid_invalid_dump
run_case test_restore_paths_reset
run_case test_printf_data
run_case test_path_controls
run_case test_path_array_local
run_case test_duration_unambiguous
run_case test_restore_local_partition_number
run_case test_effective_restore_format
run_case test_layout_hash_early_gate
run_case test_selected_disk_size
run_case test_nvme_countdown_elapsed
run_case test_upload_compression_args
run_case test_windows_hostname_edges
run_case test_graphics_object_array
run_case test_inventory_base64_bytes
run_case test_lvm_probe_cleanup
run_case test_calculate_failure_status
run_case test_mbr_capture_done_once
printf 'script audit regression: %s cases, %s failures\n' "$cases" "$failures"
(( failures == 0 ))
