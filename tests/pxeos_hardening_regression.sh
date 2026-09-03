#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
progress_lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/partclone-progress.sh"
restore_preflight="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/restore-preflight.sh"
capture_recovery="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/capture-recovery.sh"
upload="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.upload"
imgcomplete="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.imgcomplete"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/rootpxe-hardening.XXXXXX")
trap 'rm -rf -- "$tmp"; [[ -n ${rootpxe_last_diagnostic_file:-} ]] && rm -f -- "$rootpxe_last_diagnostic_file"' EXIT
test_funcs="$tmp/funcs.sh"
# The production library imports an absolute Buildroot companion.  These
# ordinary-file tests do not call that companion, so remove only this import.
sed -e '/partition-funcs\.sh/d' -e '/restore-preflight\.sh/d' -e '/capture-recovery\.sh/d' "$funcs" >"$test_funcs"
cp "$progress_lib" "$tmp/partclone-progress.sh"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
must_have(){ grep -Fq -- "$2" "$1" || fail "missing $2 in $1"; }
must_not_have(){ if grep -Fq -- "$2" "$1"; then fail "forbidden $2 in $1"; fi; }

# B: an invalid or absent restore format must not start FIFO/producer setup,
# and no restore path may discard partclone CRC failures.
must_not_have "$funcs" '--ignore_crc'
set +e
(
    set +eu; source "$test_funcs"; set -euo pipefail
    type=down imgFormat=invalid imgLegacy=
    mkfifo(){ printf 'mkfifo-called\n'; return 99; }
    handleError(){ printf 'handleError:%s\n' "$1"; exit 77; }
    writeImage "$tmp/source.img" "$tmp/target.img" ""
) >"$tmp/invalid-format.log" 2>&1
rc=$?
set -e
[[ $rc -eq 77 ]] || fail "invalid-format rc=$rc"
grep -Fq 'IMAGE_FORMAT_INVALID' "$tmp/invalid-format.log" || fail invalid-format-reason
! grep -Fq 'mkfifo-called' "$tmp/invalid-format.log" || fail invalid-format-created-fifo

# A missing selected MBR is rejected before either sector-format validation or
# table clearing, including callers that bypass the downloader preflight.
set +e
(
    set +eu; source "$test_funcs"; set -euo pipefail
    nombr=0 type=down
    sfdiskPartitionFileName(){ sfdiskoriginalpartitionfilename="$tmp/d1.partitions"; }
    MBRFileName(){ printf -v "$3" '%s' "$tmp/missing.mbr"; }
    validateImageSectorSize(){ printf 'sector-check\n' >>"$tmp/mbr-order.log"; }
    clearPartitionTables(){ printf 'clear-table\n' >>"$tmp/mbr-order.log"; }
    handleError(){ exit 77; }
    restorePartitionTablesAndBootLoaders /dev/target 1 "$tmp" 1 all
) >"$tmp/mbr-order-run.log" 2>&1
rc=$?
set -e
[[ $rc -eq 77 ]] || fail "missing-mbr rc=$rc"
[[ ! -e $tmp/mbr-order.log ]] || fail missing-mbr-started-destructive-path

# A/G: known secret values with shell and sed metacharacters never reach the
# diagnostic, and an over-limit callback is visibly truncated and saved 0600.
set +eu; source "$test_funcs"; set -euo pipefail
task_token='tok/ab&\[]*?$'
smb_password='pwd/ab&\[]*?$'
secret_message="token=$task_token password=$smb_password credential=third-secret"
redacted=$(rootpxe_redact_diagnostic "$secret_message")
for secret in "$task_token" "$smb_password" third-secret; do
    [[ $redacted != *"$secret"* ]] || fail "redaction-leaked-special-value"
done
large="$(head -c 300000 /dev/zero | tr '\0' x | fold -w 64) password=$smb_password"
rootpxe_bound_callback_message "$large" >"$tmp/bounded-message"
bounded=$(<"$tmp/bounded-message")
bytes=$(LC_ALL=C printf '%s' "$bounded" | wc -c)
[[ $bytes -le 262144 ]] || fail "callback-message-too-large:$bytes"
[[ $bounded == *'[TRUNCATED: full diagnostic retained locally]' ]] || fail callback-truncation-marker
[[ -f ${rootpxe_last_diagnostic_file:-} ]] || fail callback-private-log-missing
[[ $(stat -c %a "$rootpxe_last_diagnostic_file") == 600 ]] || fail callback-private-log-mode
! grep -Fq -- "$smb_password" "$rootpxe_last_diagnostic_file" || fail callback-private-log-secret
utf8_complete(){
    local expected=0 byte
    while read -r byte; do
        [[ $byte =~ ^[0-9]+$ ]] || continue
        if (( expected > 0 )); then
            (( byte >= 128 && byte <= 191 )) || return 1
            expected=$((expected - 1)); continue
        fi
        case $byte in
            [0-9]|[1-9][0-9]|1[01][0-9]|12[0-7]) ;;
            19[4-9]|2[01][0-9]|22[0-3]) expected=1 ;;
            22[4-9]|23[0-9]) expected=2 ;;
            24[0-4]) expected=3 ;;
            *) return 1 ;;
        esac
    done < <(LC_ALL=C printf '%s' "$1" | od -An -tu1)
    (( expected == 0 ))
}
utf8_large='界'
while (( $(LC_ALL=C printf '%s' "$utf8_large" | wc -c) < 300000 )); do utf8_large+="$utf8_large"; done
LC_ALL=C rootpxe_bound_callback_message "$utf8_large" >"$tmp/callback-c-locale"
utf8_bounded=$(<"$tmp/callback-c-locale")
utf8_complete "$utf8_bounded" || fail callback-c-locale-invalid-utf8
[[ $(LC_ALL=C printf '%s' "$utf8_bounded" | wc -c) -le 262144 ]] || fail callback-c-locale-too-large
[[ $utf8_bounded == *'[TRUNCATED: full diagnostic retained locally]' ]] || fail callback-c-locale-no-marker

# F: only the precise metadata-free MSR and BIOS boot GUID cases may grow.
schema_msr="$tmp/schema-msr.json"; schema_efi="$tmp/schema-efi.json"; resolved="$tmp/resolved.json"
printf '%s' '{"partitions":[{"number":1,"originalSectors":100,"fs":"","role":"msr","typeGuid":"e3c9e316-0b5c-4db8-817d-f92df00215ae"}]}' >"$schema_msr"
printf '%s' '{"partitions":[{"number":1,"originalSectors":100,"fs":"","role":"efi","typeGuid":"c12a7328-f81f-11d2-ba4b-00a0c93ec93b"}]}' >"$schema_efi"
printf '%s' '[{"number":1,"resolvedSectors":200}]' >"$resolved"
command -v jq >/dev/null 2>&1 || fail jq-required
rootpxe_validate_growth_capability "$schema_msr" "$resolved" || fail msr-growth-rejected
if rootpxe_validate_growth_capability "$schema_efi" "$resolved"; then fail efi-empty-fs-growth-accepted; fi
schema_fat512="$tmp/schema-fat512.json"; schema_fat4096="$tmp/schema-fat4096.json"; schema_fat_missing_logical="$tmp/schema-fat-missing-logical.json"; resolved_same="$tmp/resolved-same.json"
printf '%s' '{"logicalSectorBytes":512,"partitions":[{"number":1,"originalSectors":100,"fs":"vfat","role":"efi","typeGuid":""}]}' >"$schema_fat512"
printf '%s' '{"logicalSectorBytes":4096,"partitions":[{"number":1,"originalSectors":100,"fs":"vfat","role":"efi","typeGuid":""}]}' >"$schema_fat4096"
printf '%s' '{"partitions":[{"number":1,"originalSectors":100,"fs":"vfat","role":"efi","typeGuid":""}]}' >"$schema_fat_missing_logical"
printf '%s' '[{"number":1,"resolvedSectors":100}]' >"$resolved_same"
fsck.fat(){ :; }; pxeosfatgrow(){ :; }
rootpxe_validate_growth_capability "$schema_fat512" "$resolved" || fail fat-512-growth-rejected
if rootpxe_validate_growth_capability "$schema_fat4096" "$resolved"; then fail fat-4096-growth-accepted; fi
if rootpxe_validate_growth_capability "$schema_fat_missing_logical" "$resolved"; then fail fat-missing-logical-growth-accepted; fi
unset -f fsck.fat pxeosfatgrow
rootpxe_validate_growth_capability "$schema_fat4096" "$resolved_same" || fail fat-same-size-rejected

# Integration names: capture resume and full restore preflight are exercised
# by their dedicated capture/partition suites; keep this test tied to them.
must_have "$restore_preflight" 'rootpxe_validate_restore_artifacts'
must_have "$funcs" 'rootpxe_request_disk_permit_batch'
must_have "$upload" 'rootpxe_capture_resume_published'
must_have "$capture_recovery" 'rootpxe_capture_publish_metadata'

# D: multi-disk restore permissions are bound to the original device path as
# well as its stable identity.  A permitted identity on a different path must
# never authorize the current disk after enumeration changes.
binding_file="$tmp/batch-bindings.json"
disk_map="$tmp/batch-map.tsv"
printf '%s\n' '[{"targetId":"ID_A","operation":"deploy_write"},{"targetId":"ID_B","operation":"nvme_format+deploy_write"}]' >"$binding_file"
printf '%s\n' $'/dev/alpha\tID_A\tdeploy_write' $'/dev/beta\tID_B\tnvme_format+deploy_write' >"$disk_map"
rootpxe_disk_permit_bindings_file="$binding_file"
rootpxe_disk_permit_disk_map_file="$disk_map"
pxeapi=https://test/
taskid=1 task_token=0123456789abcdef mac=000c2958c550
rootpxe_disk_stable_identity(){ case "$1" in /dev/alpha) printf '%s\n' ID_A;; /dev/beta) printf '%s\n' ID_B;; /dev/swapped) printf '%s\n' ID_B;; *) return 1;; esac; }
rootpxe_require_task_context(){ return 0; }
curl(){ printf '%s\n' '{"granted":true,"targets":[{"operation":"nvme_format+deploy_write","targetId":"ID_B"},{"operation":"deploy_write","targetId":"ID_A"}]}' 200; }
rootpxe_request_disk_permit_batch ID_A deploy_write ID_B nvme_format+deploy_write || fail batch-valid-server-response-rejected
for batch_response in \
    '{"granted":true,"targets":[{"targetId":"ID_A","operation":"deploy_write"}]}' \
    '{"granted":true,"targets":[{"targetId":"ID_A","operation":"deploy_write"},{"targetId":"ID_B","operation":"nvme_format+deploy_write"},{"targetId":"ID_C","operation":"deploy_write"}]}' \
    '{"granted":true,"targets":[{"targetId":"ID_A","operation":"deploy_write"},{"targetId":"ID_A","operation":"deploy_write"}]}' \
    '{"granted":true,"targets":[{"targetId":1,"operation":"deploy_write"},{"targetId":"ID_B","operation":"nvme_format+deploy_write"}]}'; do
    curl(){ printf '%s\n' "$batch_response" 200; }
    if rootpxe_request_disk_permit_batch ID_A deploy_write ID_B nvme_format+deploy_write; then fail batch-invalid-response-accepted; fi
done
batch_calls=0
rootpxe_request_disk_permit_batch(){ batch_calls=$((batch_calls + 1)); [[ $batch_calls -ge 2 ]] && return 0; return 11; }
sleep(){ :; }
rootpxe_wait_for_disk_permit_batch ID_A deploy_write || fail batch-network-retry-rejected
[[ $batch_calls -eq 2 ]] || fail batch-network-retry-count
rootpxe_request_disk_permit_batch(){ return 10; }
if rootpxe_wait_for_disk_permit_batch ID_A deploy_write; then fail batch-cancel-accepted; else [[ $? -eq 10 ]] || fail batch-cancel-code; fi
rootpxe_verify_disk_permit_binding /dev/alpha deploy_write || fail batch-bound-disk-rejected
rootpxe_verify_disk_permit_binding /dev/beta deploy_write || fail batch-nvme-deploy-downgrade-rejected
if rootpxe_verify_disk_permit_binding /dev/swapped deploy_write; then fail batch-path-swap-accepted; fi
if rootpxe_verify_disk_permit_binding /dev/alpha nvme_format+deploy_write; then fail batch-operation-escalation-accepted; fi

# Deployment mpa selection needs complete image facts and ignores fdrive: the
# image's ordered dN.size facts alone decide the ordered target set.
mpa_image="$tmp/mpa-image"; mkdir "$mpa_image"
printf '%s\n' '1:100' >"$mpa_image/d1.size"
printf '%s\n' '2:200' >"$mpa_image/d2.size"
printf '%s\n' 'sector-size: 512' >"$mpa_image/d1.partitions"
printf '%s\n' 'sector-size: 512' >"$mpa_image/d2.partitions"
printf x >"$mpa_image/d1.mbr"; printf x >"$mpa_image/d2.mbr"
fdrive=/dev/third type=down imgType=mpa imagePath="$mpa_image" isdebug=
lsblk(){ printf '%s\n' '/dev/first 1G' '/dev/second 1G' '/dev/third 1G'; }
blockdev(){ case "$1:$2" in --getsize64:/dev/first) printf '%s\n' 100;; --getsize64:/dev/second) printf '%s\n' 200;; --getsize64:/dev/third) printf '%s\n' 300;; --getss:/dev/first|--getss:/dev/second|--getss:/dev/third) printf '%s\n' 512;; *) return 1;; esac; }
rootpxe_console_message(){ :; }
resolve_path(){ printf '%s\n' "$1"; }
normalize(){ printf '%s' "$1"; }
handleError(){ return 97; }
rootpxe_fixed_restore_disk_facts(){
    [[ -s "$1/d1.size" && -s "$1/d2.size" && -s "$1/d1.partitions" && -s "$1/d2.partitions" ]] || return 1
    printf '%s\n' '1|100' '2|200'
}
rootpxe_disk_stable_identity(){ case "$1" in /dev/first) printf '%s\n' ID_FIRST;; /dev/second) printf '%s\n' ID_SECOND;; *) return 1;; esac; }
disks='/dev/first /dev/second'
rootpxe_plan_mpa_disk_permits "$mpa_image" || fail mpa-plan-rejected
[[ ${rootpxe_mpa_permit_is_batch:-} == yes && ${rootpxe_mpa_permit_args[*]} == 'ID_FIRST deploy_write ID_SECOND deploy_write' ]] || fail mpa-plan-not-per-disk
if getHardDisk; then fail mpa-fdrive-outside-mapping-accepted; fi
fdrive=
getHardDisk || fail mpa-mapping-rejected
[[ $disks == '/dev/first /dev/second' && $hd == /dev/first ]] || fail "mpa-fdrive-expanded-set:$disks"
rm -f "$mpa_image/d2.size"
if getHardDisk; then fail mpa-missing-size-fell-back-to-enumeration; fi

printf 'PASS: PXEOS hardening regression\n'
