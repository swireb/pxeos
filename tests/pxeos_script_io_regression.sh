#!/usr/bin/env bash
# 会话、日志与分区读回的离线回归；所有设备命令都是函数替身。
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/task-http-test-support.sh"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
funcs="$overlay/usr/share/pxeos/lib/funcs.sh"
. "$overlay/usr/share/pxeos/lib/restore-preflight.sh"
export PATH="$root/tests/fixtures/msys-tools:$PATH"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
failures=0 cases=0
fail() { printf 'FAIL: %s\n' "$*" >&2; return 1; }
load() {
    local source=${2:-$funcs} body first
    first=$(grep -m1 "^$1() *[({]" "$source")
    if [[ $first == *'}' ]]; then body=$first; else body=$(sed -n "/^$1() [({]/,/^}/p" "$source"); fi
    [[ -n $body ]] || fail "missing $1" || return 1
    body=${body//\/tmp\/pxeos.smb.credentials/$tmp\/pxeos.smb.credentials}
    body=${body//\/tmp\/pxeos.failure_action/$tmp\/failure_action}
    body=${body//exec \/bin\/pxeos/rootpxe_test_exec}
    eval "$body"
}
run() { cases=$((cases+1)); if ( "$@" ); then printf 'PASS: %s\n' "$1"; else failures=$((failures+1)); printf 'FAIL CASE: %s\n' "$1" >&2; fi; }
handleError() { printf 'mock-error:%s\n' "$*" >&2; exit 77; }
debugPause() { :; }
statusReporter=''
load killStatusReporter || exit 1
for name in rootpxe_cleanup_session rootpxe_cleanup_smb_credentials rootpxe_clear_smb_plaintext rootpxe_cleanup_task_json rootpxe_prepare_smb_credentials runPartprobe restoreGRUB rootpxe_task_console_failure rootpxe_redact_diagnostic rootpxe_utf8_safe_prefix rootpxe_console_message rootpxe_error_response_reason rootpxe_error_wait_for_retry; do load "$name" || exit 1; done
for name in rootpxe_register_derived_layout_file rootpxe_cleanup_derived_layout_files; do
    if grep -q "^$name() {" "$funcs"; then load "$name" || exit 1; fi
done
if [[ -r $overlay/usr/share/pxeos/lib/task-http.sh ]]; then . "$overlay/usr/share/pxeos/lib/task-http.sh"; fi
. "$overlay/usr/share/pxeos/lib/cloud-init.sh"

test_smb_umask_traps() {
    local protocol=smb smb_username=fixture-user smb_password=fixture-password smb_domain='' before_mask before_trap
    before_mask=$(umask); trap ':' INT; before_trap=$(trap -p INT)
    rootpxe_prepare_smb_credentials || return 1
    [[ $(umask) == "$before_mask" ]] || fail 'SMB changed caller umask' || return 1
    [[ $(trap -p INT) == "$before_trap" ]] || fail 'SMB overwrote caller trap' || return 1
    [[ -f $smb_credentials_file ]] || return 1
    rootpxe_cleanup_smb_credentials
}
test_download_session_cleanup() {
    local protocol signal status expected marker
    load rootpxe_download_cleanup_initialization_private "$overlay/bin/pxeos.download"
. "$overlay/usr/share/pxeos/lib/cloud-init.sh"
    case $(uname -s) in MINGW*|MSYS*) rootpxe_ci_stat(){ printf '%s:0:600:%s\n' "$EUID" "$(stat -c %h -- "$1")"; }; printf 'SKIP: MSYS private file mode\n';; esac
    for protocol in nfs smb; do for signal in EXIT INT TERM; do
        marker="$tmp/$protocol-$signal"
        mkdir -p "$marker"; : >"$marker/layout"; : >"$marker/script"; : >"$marker/private"
        status=0
        (
            deploymentLayoutFile="$marker/layout"
            cloudInitUserDataFile=$(mktemp /tmp/rootpxe-cloud-init.XXXXXX) || exit 9
            printf '#cloud-config\nruncmd: []\n' >"$cloudInitUserDataFile"
            chmod 600 "$cloudInitUserDataFile" || exit 9
            cloudInitUserDataSha256=$(rootpxe_ci_hash "$cloudInitUserDataFile") || exit 9
            rootpxe_cloud_init_private_inode=$(rootpxe_ci_inode "$cloudInitUserDataFile") || exit 9
            rootpxe_cloud_init_private_pid=$BASHPID
            printf '%s\n' "$cloudInitUserDataFile" >"$marker/owned-data-path"
            cloudInitMetaDataFile=$(mktemp /tmp/rootpxe-cloud-meta.XXXXXX) || exit 9
            printf 'instance-id: manual-signal-fixture\n' >"$cloudInitMetaDataFile"
            chmod 600 "$cloudInitMetaDataFile" || exit 9
            cloudInitMetaDataSha256=$(rootpxe_ci_hash "$cloudInitMetaDataFile") || exit 9
            rootpxe_cloud_init_meta_private_inode=$(rootpxe_ci_inode "$cloudInitMetaDataFile") || exit 9
            rootpxe_cloud_init_meta_private_pid=$BASHPID
            printf '%s\n' "$cloudInitMetaDataFile" >>"$marker/owned-data-path"
            cloudInitNetworkConfigFile=$(mktemp /tmp/rootpxe-cloud-network.XXXXXX) || exit 9
            printf 'version: 2\nethernets: {}\n' >"$cloudInitNetworkConfigFile"
            chmod 600 "$cloudInitNetworkConfigFile" || exit 9
            cloudInitNetworkConfigSha256=$(rootpxe_ci_hash "$cloudInitNetworkConfigFile") || exit 9
            rootpxe_cloud_init_network_private_inode=$(rootpxe_ci_inode "$cloudInitNetworkConfigFile") || exit 9
            rootpxe_cloud_init_network_private_pid=$BASHPID
            printf '%s\n' "$cloudInitNetworkConfigFile" >>"$marker/owned-data-path"
            cloudInitVendorDataFile=$(mktemp /tmp/rootpxe-cloud-vendor.XXXXXX) || exit 9
            printf '#cloud-config\nruncmd: []\n' >"$cloudInitVendorDataFile"
            chmod 600 "$cloudInitVendorDataFile" || exit 9
            cloudInitVendorDataSha256=$(rootpxe_ci_hash "$cloudInitVendorDataFile") || exit 9
            rootpxe_cloud_init_vendor_private_inode=$(rootpxe_ci_inode "$cloudInitVendorDataFile") || exit 9
            rootpxe_cloud_init_vendor_private_pid=$BASHPID
            printf '%s\n' "$cloudInitVendorDataFile" >>"$marker/owned-data-path"
            rootpxe_cloud_init_valid_pid=$BASHPID
            export -n rootpxe_cloud_init_valid_pid rootpxe_cloud_init_meta_private_pid rootpxe_cloud_init_meta_private_inode rootpxe_cloud_init_network_private_pid rootpxe_cloud_init_network_private_inode rootpxe_cloud_init_vendor_private_pid rootpxe_cloud_init_vendor_private_inode
            rootpxe_resolved_layout_file=$(mktemp /tmp/rootpxe-resolved-layout.XXXXXX)
            rootpxe_resolved_lvm_layout_file=$(mktemp /tmp/rootpxe-resolved-lvm.XXXXXX)
            printf '%s\n' "$rootpxe_resolved_layout_file" "$rootpxe_resolved_lvm_layout_file" >"$marker/owned-derived-paths"
            rootpxe_register_derived_layout_file "$rootpxe_resolved_layout_file" || exit 9
            rootpxe_register_derived_layout_file "$rootpxe_resolved_lvm_layout_file" || exit 9
            rootpxe_cleanup_deployment_partition_file() { :; }
            rootpxe_deployment_identity_cleanup_private() { rm -f "$marker/private"; }
            rootpxe_multicast_cleanup() { : >"$marker/multicast-cleaned"; }
            smb_username=user smb_password=password smb_domain=''
            rootpxe_prepare_smb_credentials || exit 9
            sed -n '/^trap rootpxe_download_cleanup_initialization_private EXIT$/,/^trap .* TERM$/p' "$overlay/bin/pxeos.download" >"$marker/traps"
            . "$marker/traps"
            case $signal in EXIT) exit 0 ;; INT) kill -INT "$BASHPID" ;; TERM) kill -TERM "$BASHPID" ;; esac
            : >"$marker/continued-after-signal"
        ) || status=$?
        case $signal in EXIT) expected=0 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
        [[ $status == "$expected" ]] || fail "$protocol $signal exit=$status expected=$expected" || return 1
        [[ ! -e $marker/layout && -e $marker/script && ! -e $marker/private && ! -e $marker/continued-after-signal && -e $marker/multicast-cleaned ]] || fail "$protocol $signal omitted session cleanup or removed foreign script" || return 1
        while IFS= read -r owned_data; do [[ ! -e $owned_data ]] || fail "$protocol $signal retained private Cloud-init data" || return 1; done <"$marker/owned-data-path"
        while IFS= read -r owned_path; do [[ ! -e $owned_path ]] || fail "$protocol $signal retained owned derived layout" || return 1; done <"$marker/owned-derived-paths"
    done; done
}
test_owned_derived_layout_cleanup() {
    local unknown="$tmp/unknown-layout" old_inode status=0
    test_owned_one=$(mktemp /tmp/rootpxe-resolved-layout.XXXXXX)
    test_owned_two=$(mktemp /tmp/rootpxe-resolved-lvm.XXXXXX)
    trap 'rm -f -- "$test_owned_one" "$test_owned_two"' EXIT
    : >"$unknown"
    rootpxe_resolved_layout_file=$test_owned_one rootpxe_resolved_lvm_layout_file=$test_owned_two
    if declare -F rootpxe_register_derived_layout_file >/dev/null; then
        rootpxe_register_derived_layout_file "$test_owned_one" || return 1
        rootpxe_register_derived_layout_file "$test_owned_two" || return 1
    fi
    rootpxe_cleanup_deployment_partition_file() { :; }
    rootpxe_cleanup_task_json
    [[ ! -e $test_owned_one && ! -e $test_owned_two && -e $unknown ]] || fail 'owned derived layout files not cleaned' || return 1
    [[ ! ${rootpxe_resolved_layout_file+x} && ! ${rootpxe_resolved_lvm_layout_file+x} ]] || fail 'derived layout variables retained' || return 1
    test_owned_one=$(mktemp /tmp/rootpxe-resolved-layout.XXXXXX)
    rootpxe_register_derived_layout_file "$test_owned_one" || return 1
    mv "$test_owned_one" "$tmp/moved-owned-layout"
    printf 'foreign replacement' >"$test_owned_one"
    rootpxe_resolved_layout_file=$test_owned_one rootpxe_resolved_lvm_layout_file=$unknown
    rootpxe_cleanup_task_json
    [[ -e $test_owned_one && -e $unknown ]] || fail 'stale/unknown layout path removed'
}
test_core_libraries_fail_closed() {
    local library status
    mkdir -p "$tmp/core"
    # Only the definition/import prefix is sourced; never the kernel args or
    # PXEOS entry point. Every companion is an ordinary fixture script.
    sed -n '1,/^rootpxe_partition_progress_initialize_runtime()/p' "$funcs" | sed '$d' | sed "s|/usr/share/pxeos/lib|$tmp/missing-installed|g" >"$tmp/core/funcs.sh"
    printf '\nrootpxe_source_core_library storage-io.sh || return 1\n' >>"$tmp/core/funcs.sh"
    for library in log-paths.sh partition-funcs.sh restore-preflight.sh capture-recovery.sh deployment-identity.sh cloud-init.sh linux-hostname.sh partclone-progress.sh task-http.sh storage-io.sh; do printf ':\n' >"$tmp/core/$library"; done
    for library in partition-funcs.sh restore-preflight.sh capture-recovery.sh deployment-identity.sh cloud-init.sh linux-hostname.sh partclone-progress.sh task-http.sh storage-io.sh; do
        mv "$tmp/core/$library" "$tmp/core/$library.saved"
        status=0; ( . "$tmp/core/funcs.sh"; ) >"$tmp/core/out" 2>&1 || status=$?
        mv "$tmp/core/$library.saved" "$tmp/core/$library"
        [[ $status != 0 ]] || fail "missing mandatory library ignored: $library" || return 1
    done
    printf 'return 9\n' >"$tmp/core/partition-funcs.sh"
    status=0; ( . "$tmp/core/funcs.sh"; ) >/dev/null 2>&1 || status=$?
    [[ $status != 0 ]] || fail 'core source error ignored'
}
test_entry_source_guards() {
    local path
    while IFS= read -r path; do
        grep -Eq '^\. /usr/share/pxeos/lib/funcs\.sh \|\| exit 1$' "$path" || fail "entry continues after failed core import: ${path##*/}" || return 1
    done < <(grep -l '^\. /usr/share/pxeos/lib/funcs.sh' "$overlay"/bin/pxeos*)
}
test_reread_retry() {
    local attempts=0 busy_until=2 rc=0
    umount() { [[ $* == '/ntfs /bcdstore' ]] || exit 99; }
    udevadm() { [[ $* == 'settle --timeout=5' ]] || exit 99; }
    blockdev() { attempts=$((attempts+1)); [[ $* == '--rereadpt /dev/mock' ]] || exit 99; ((attempts>busy_until)); }
    sleep() { :; }
    runPartprobe /dev/mock || return 1
    [[ $attempts == 3 ]] || fail 'transient reread not retried' || return 1
    busy_until=99
    ( runPartprobe /dev/mock ) >/dev/null 2>&1 || rc=$?
    [[ $rc != 0 ]] || fail 'permanent reread failure hidden'
}
test_grub_logical_bytes() {
    local bytes selected_raw="$tmp/raw-boot" size item status=0
    MBRFileName() { printf -v "$3" '%s' "$selected_raw"; }
    rootpxe_require_unused_target_disks() { : >"$tmp/grub-gate"; }
    dd() { printf '%s\n' "$*" >"$tmp/dd-args"; }
    du() { printf '8 %s\n' "$selected_raw"; }
    runPartprobe() { :; }
    for bytes in 512 4096 32256 1048576; do
        truncate -s "$bytes" "$selected_raw"
        restoreGRUB /dev/mock 1 "$tmp" '' || return 1
        [[ $(cat "$tmp/dd-args") == *"count=$((bytes/512))" ]] || fail "GRUB used allocation instead of $bytes byte length" || return 1
    done
    for bytes in 0 513; do
        truncate -s "$bytes" "$selected_raw"; rm -f "$tmp/dd-args" "$tmp/grub-gate"
        status=0; ( restoreGRUB /dev/mock 1 "$tmp" '' ) >/dev/null 2>&1 || status=$?
        [[ $status != 0 && ! -e $tmp/dd-args && ! -e $tmp/grub-gate ]] || fail 'malformed boot length reached disk gate/writer' || return 1
    done
}
test_gpt_backup_is_not_raw_boot() {
    local type=down mbrfile='' directory="$tmp/gpt-artifacts" status nombr=0
    mkdir -p "$directory"
    for name in MBRFileName hasGRUB hasGrubFileName; do load "$name" || return 1; done
    rootpxe_require_unused_target_disks() { : >"$tmp/raw-gate"; }
    dd() { printf '%s\n' "$*" >"$tmp/raw-dd"; }
    runPartprobe() { :; }
    truncate -s 4096 "$directory/d1.mbr"
    restoreGRUB /dev/mock 1 "$directory" true || return 1
    [[ ! -e $tmp/raw-dd ]] || fail 'GPT backup-only artifact copied as raw boot' || return 1
    truncate -s 4096 "$directory/d1.grub.mbr"
    restoreGRUB /dev/mock 1 "$directory" true || return 1
    [[ $(cat "$tmp/raw-dd") == *"if=$directory/d1.grub.mbr"* ]] || fail 'GPT GRUB raw artifact not selected' || return 1
    for size in 0 513 1049088; do
        truncate -s "$size" "$directory/d1.grub.mbr"; rm -f "$tmp/raw-dd" "$tmp/raw-gate"
        status=0; ( restoreGRUB /dev/mock 1 "$directory" true ) >/dev/null 2>&1 || status=$?
        [[ $status != 0 && ! -e $tmp/raw-dd && ! -e $tmp/raw-gate ]] || fail 'invalid GPT raw artifact reached writer' || return 1
    done
    # The real top-level selector must reject a broken raw artifact before
    # either sector-format validation or table clearing can run.
    load restorePartitionTablesAndBootLoaders || return 1
    sfdiskPartitionFileName() { sfdiskoriginalpartitionfilename="$directory/d1.partitions"; }
    getDesiredPartitionTableType() { table_type=GPT; }
    validateImageSectorSize() { : >"$tmp/raw-sector-check"; }
    clearPartitionTables() { : >"$tmp/raw-table-clear"; }
    for size in 0 513 1049088; do
        truncate -s "$size" "$directory/d1.grub.mbr"
        status=0
        ( set +u; restorePartitionTablesAndBootLoaders /dev/mock 1 "$directory" 50 all ) >/dev/null 2>&1 || status=$?
        [[ $status != 0 && ! -e $tmp/raw-sector-check && ! -e $tmp/raw-table-clear && ! -e $tmp/raw-dd ]] || fail 'broken GPT raw artifact reached top-level destructive path' || return 1
    done
    # A marker/raw file for another disk, or the generic fallback, must never
    # be selected as the absent d1 GPT raw artifact.
    mv "$directory/d1.grub.mbr" "$directory/d2.grub.mbr"
    truncate -s 512 "$directory/fallback.mbr"; mbrfile="$directory/fallback.mbr"
    restoreGRUB /dev/mock 1 "$directory" true || return 1
    [[ ! -e $tmp/raw-dd ]] || fail 'GPT absent raw artifact used mismatched disk/fallback' || return 1
}
test_console_failure_width() {
    local task_token=fixture-secret text
    local -A rootpxe_task_log_state=()
    text="$(printf 'word %.0s' {1..40}) token=$task_token CODE=TEST_FAILURE"
    rootpxe_task_log_append() { printf '%s\n' "$*" >>"$tmp/details"; }
    rootpxe_task_log_notice() { :; }
    rootpxe_task_console_failure ERROR "$text" >"$tmp/console"
    awk 'length($0)>80 {bad=1} END{exit(bad ? 1 : 0)}' "$tmp/console" || fail 'failure summary exceeds 80 columns' || return 1
    ! grep -Fq "$task_token" "$tmp/console" "$tmp/details" || fail 'failure summary leaked token'
}
test_error_json_types() {
    local taskid=1 task_token=fixture-token mac=fixture-mac pxeapi=https://example.invalid/ web='' mc=no call_index=0 status=0
    rootpxe_require_task_context() { :; }
    rootpxe_bound_callback_message() { printf '%s' "$1"; }
    rootpxe_console_message() { :; }
    rootpxe_task_console_failure() { :; }
    rootpxe_reset_disk_permit_retry_state() { : >"$tmp/reset-permit"; }
    rootpxe_task_log_release_pin() { :; }
    rootpxe_test_exec() { exit 88; }
    date() { printf '100\n'; }
    sleep() { : >"$tmp/slept"; exit 95; }
    curl() { task_http_test_decode_curl_args "$@"; set -- "${task_http_test_curl_args[@]}";
        local calls=0
        [[ ! -f $tmp/http-calls ]] || calls=$(cat "$tmp/http-calls")
        printf '%s' "$((calls+1))" >"$tmp/http-calls"
        if [[ $* == *'/error' ]]; then printf ' { "accepted" : true, "waitSec" : 60, "failureAction" : "shutdown" }\n200'; else printf '{ "status" : "cancelled" }'; fi
    }
    ( rootpxe_error_wait_for_retry fixture CODE console_shown ) >/dev/null 2>&1 || status=$?
    [[ $status == 2 && ! -e $tmp/slept && $(cat "$tmp/failure_action") == shutdown ]] || fail 'spaced typed JSON not accepted/parsed' || return 1
    # A string accepted flag must retry instead of arming the timeout.
    rm -f "$tmp/failure_action" "$tmp/slept"
    curl() { task_http_test_decode_curl_args "$@"; set -- "${task_http_test_curl_args[@]}"; printf '{"accepted":"true","waitSec":60,"failureAction":"shutdown"}\n200'; }
    status=0; ( rootpxe_error_wait_for_retry fixture CODE console_shown ) >/dev/null 2>&1 || status=$?
    [[ $status == 95 && -e $tmp/slept && ! -e $tmp/failure_action ]] || fail 'nonboolean accepted armed timeout'
    rm -f "$tmp/failure_action" "$tmp/reset-permit" "$tmp/slept"
    local TASK_HTTP_TEST_STATUS=302
    curl() { task_http_test_decode_curl_args "$@"; set -- "${task_http_test_curl_args[@]}"; printf '{"accepted":true,"waitSec":60,"failureAction":"shutdown","status":"queued"}\n200'; }
    status=0; ( rootpxe_error_wait_for_retry fixture CODE console_shown ) >/dev/null 2>&1 || status=$?
    [[ $status == 95 && ! -e $tmp/failure_action && ! -e $tmp/reset-permit ]] || fail '302 malicious body accepted/resumed' || return 1
    TASK_HTTP_TEST_STATUS=200
    curl() {
        task_http_test_decode_curl_args "$@"; set -- "${task_http_test_curl_args[@]}"
        if [[ $* == *'/error' ]]; then printf '{"accepted":true,"waitSec":60,"failureAction":"shutdown"}\n200'; else printf 'HTTP/1.1 302 Redirect\r\n\r\n' >"$task_http_test_header_file"; printf '{"status":"queued"}'; fi
    }
    status=0; ( rootpxe_error_wait_for_retry fixture CODE console_shown ) >/dev/null 2>&1 || status=$?
    [[ $status == 95 && ! -e $tmp/reset-permit && $(cat "$tmp/failure_action") == shutdown ]] || fail '302 queued status resumed task'
}
test_inventory_redirect_guard() {
    local body task_mode=1 taskid=1 task_token=fixture-token mac=fixture-mac poststring=fixture=yes rootpxe_api=https://example.invalid/ status=0
    body=$(sed -n '/^count=0$/,/^done$/p' "$overlay/bin/pxeos.inventory")
    local TASK_HTTP_TEST_STATUS=302
    dots() { :; }
    usleep() { : >"$tmp/inventory-retry"; exit 93; }
    curl() { task_http_test_decode_curl_args "$@"; set -- "${task_http_test_curl_args[@]}"; printf '%s\n' "$*" >"$tmp/inventory-argv"; printf 'malicious-redirect-body'; }
    ( eval "$body" ) >/dev/null 2>&1 || status=$?
    [[ $status == 93 && -e $tmp/inventory-retry ]] || fail 'task inventory accepted redirect stdout despite failed request' || return 1
    task_mode=0 status=0
    ( eval "$body" ) >/dev/null 2>&1 || status=$?
    [[ $status == 0 && $(cat "$tmp/inventory-argv") == *'-Lksf'* ]] || fail 'tokenless legacy inventory transport changed'
}
test_disk_health_private_task_http() {
    local taskType=deploy taskid=1 task_token='health-fixture+/= token' mac=fixture-mac rootpxe_api=https://example.invalid/ status fixture_native_status=0
    local TASK_HTTP_TEST_STATUS=200 health_report='{"version":1,"disks":[{"device":"/dev/mock","status":"unknown"}]}'
    load rootpxe_send_disk_health "$overlay/usr/share/pxeos/lib/disk-health.sh" || return 1
    rootpxe_require_task_context() { :; }
    rootpxe_console_message() { :; }
    rootpxe_collect_disk_health() { printf '%s' "$health_report"; }
    curl() {
        printf '%s\n' "$@" >"$tmp/health-native-argv"
        task_http_test_decode_curl_args "$@"; set -- "${task_http_test_curl_args[@]}"
        [[ $* == *"token=$task_token"* ]] || exit 91
        printf '{"success":true}'
        return "$fixture_native_status"
    }
    rootpxe_send_disk_health || fail 'normal disk health telemetry failed' || return 1
    ! grep -Fq "$task_token" "$tmp/health-native-argv" || fail 'disk health token remained in native argv' || return 1
    ! grep -Eq '(^-L|^--location)' "$tmp/health-native-argv" || fail 'disk health still follows redirects' || return 1
    grep -Fxq -- '--connect-timeout' "$tmp/health-native-argv" && grep -Fxq -- '5' "$tmp/health-native-argv" && grep -Fxq -- '20' "$tmp/health-native-argv" || fail 'disk health timeout contract changed' || return 1
    TASK_HTTP_TEST_STATUS=302
    rootpxe_send_disk_health || fail 'nonempty failed telemetry must remain nonblocking' || return 1
    health_report='{"version":1,"disks":[]}' status=0
    rootpxe_send_disk_health || status=$?
    [[ $status == 2 ]] || fail 'empty-report special return changed' || return 1
    TASK_HTTP_TEST_STATUS=200 fixture_native_status=7
    health_report='{"version":1,"disks":[{"device":"/dev/mock","status":"unknown"}]}'
    rootpxe_send_disk_health || fail 'native telemetry failure became blocking'
}
test_nonimage_finish_http_gate() {
    local taskid=1 task_token=finish-fixture mac=fixture-mac mactosend=fixture-mac sysuuid=fixture-uuid rootpxe_api=https://example.invalid/ count=0 res='' status body fixture_native_status=0
    local TASK_HTTP_TEST_STATUS=200
    body=$(sed -n '/^while true; do$/,/^done$/p' "$overlay/bin/pxeos.nonimgcomplete")
    curl() { task_http_test_decode_curl_args "$@"; printf '{"success":true}'; return "$fixture_native_status"; }
    usleep() { : >"$tmp/nonimage-retry"; exit 95; }
    status=0; ( eval "$body" ) >/dev/null 2>&1 || status=$?
    [[ $status == 0 && ! -e $tmp/nonimage-retry ]] || fail 'normal non-image finish did not succeed' || return 1
    TASK_HTTP_TEST_STATUS=302
    status=0; ( eval "$body" ) >/dev/null 2>&1 || status=$?
    [[ $status == 95 && -e $tmp/nonimage-retry ]] || fail 'redirect success body ended non-image task' || return 1
    TASK_HTTP_TEST_STATUS=200 fixture_native_status=7; rm -f "$tmp/nonimage-retry"
    status=0; ( eval "$body" ) >/dev/null 2>&1 || status=$?
    [[ $status == 95 && -e $tmp/nonimage-retry ]] || fail 'native failure body ended non-image task'
}
test_large_lba_readback() {
    local body start=2147483648 size=2147483649 total target_bytes template="$tmp/template" plan="$tmp/plan" number=caller-number extra=caller-extra
    body=$(sed -n '/^rootpxe_apply_deployment_layout() {/,/^}/p' "$funcs")
    [[ $body != *'%12d'* ]] || fail 'layout uses signed integer printf for large LBA' || return 1
    for name in rootpxe_apply_deployment_layout rootpxe_sfdisk_layout_fingerprint rootpxe_validate_partition_lba_contract; do load "$name" || return 1; done
    rootpxe_lvm_json_jq() { command jq "$@"; }
    rootpxe_cleanup_deployment_partition_file() { :; }
    rootpxe_require_unused_target_disks() { :; }
    rootpxe_layout_apply_failed() { fail "$*"; }
    rootpxe_layout_readback_failed() { fail "$*"; }
    rootpxe_log_raw_file() { rootpxe_log_raw_path=$(mktemp "$tmp/raw.XXXXXX"); }
    rootpxe_log_publish() { :; }
    udevadm() { [[ $* == 'settle --timeout=5' ]] || exit 99; }
    blockdev() { case $1 in --getss) printf '512' ;; --getsize64) printf '%s' "$target_bytes" ;; --rereadpt) : ;; *) exit 99 ;; esac; }
    flock() { shift; [[ $1 == sfdisk ]] || exit 99; if [[ $2 == -d ]]; then cat "$tmp/written"; else cat >"$tmp/written"; fi; }
    rootpxe_resolved_layout_file=$plan rootpxe_deployment_layout_changed=yes
    for start in 2147483648 4503599627370400; do
        total=$((start+size+2048)); target_bytes=$((total*512))
        printf '[{"number":1,"kind":"primary","startSectors":%s,"resolvedSectors":%s}]\n' "$start" "$size" >"$plan"
        printf 'label: gpt\nlabel-id: 11111111-1111-1111-1111-111111111111\ndevice: /dev/source\nunit: sectors\nsector-size: 512\nfirst-lba: 34\nlast-lba: %s\n/dev/source1 : start=2048, size=4096, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4\n' "$((total-34))" >"$template"
        rootpxe_apply_deployment_layout /dev/mock "$template" || return 1
        [[ $number == caller-number && $extra == caller-extra && $size == 2147483649 && -n $start ]] || fail 'layout scratch variables polluted caller' || return 1
        grep -Eq "start=[[:space:]]*$start, size=[[:space:]]*$size," "$tmp/written" || fail 'large GPT geometry was truncated' || return 1
        rm -f "$rootpxe_deployment_partition_file"; rmdir "${rootpxe_deployment_partition_file%/*}" || return 1
    done
}

run test_smb_umask_traps
run test_download_session_cleanup
run test_owned_derived_layout_cleanup
run test_core_libraries_fail_closed
run test_entry_source_guards
run test_reread_retry
run test_grub_logical_bytes
run test_gpt_backup_is_not_raw_boot
run test_console_failure_width
run test_error_json_types
run test_inventory_redirect_guard
run test_disk_health_private_task_http
run test_nonimage_finish_http_gate
run test_large_lba_readback
printf 'script IO regression: %s cases, %s failures\n' "$cases" "$failures"
((failures==0))
