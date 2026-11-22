#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
lib_dir="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
bin_dir="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/rootpxe-audit-fixes.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# 1. cloud-init.sh: allow CIS /var/log, /var/tmp, /var/cache, /usr/local; reject /var/lib/cloud, backslash escapes, and trailing-newline shadowing
(
    set +u
    . "$lib_dir/cloud-init.sh"
    set -u
    root_dir="$tmp/ci-root"
    mkdir -p "$root_dir/etc" "$root_dir/var" "$root_dir/usr"
    rootpxe_ci_safe_write_directory() { return 0; }
    rootpxe_ci_metadata_safe() { return 0; }
    mountpoint() { return 1; }

    # CIS separate mounts under /var and /usr/local must be allowed
    cat >"$root_dir/etc/fstab" <<'EOF'
UUID=1111 / ext4 defaults 0 1
UUID=2222 /var/log ext4 defaults 0 2
UUID=3333 /var/tmp ext4 defaults 0 2
UUID=4444 /var/cache ext4 defaults 0 2
UUID=5555 /var/log/audit ext4 defaults 0 2
UUID=6666 /usr/local ext4 defaults 0 2
EOF
    rootpxe_ci_mount_fstab "$root_dir" /var rw || fail "CIS /var/log /var/tmp /usr/local should be allowed"
    rootpxe_ci_mount_fstab "$root_dir" /usr ro || fail "CIS /usr/local should be allowed for /usr"

    # Shadowing /var/lib/cloud on last line WITHOUT trailing newline must be rejected
    printf 'UUID=1111 / ext4 defaults 0 1\nUUID=2222 /var/lib/cloud ext4 defaults 0 2' >"$root_dir/etc/fstab"
    if rootpxe_ci_mount_fstab "$root_dir" /var rw; then
        fail "shadowing /var/lib/cloud without trailing newline must be rejected"
    fi

    # Backslash octal escape in fstab mountpoint must be rejected
    printf 'UUID=1111 / ext4 defaults 0 1\nUUID=2222 /var/lib\\040cloud ext4 defaults 0 2\n' >"$root_dir/etc/fstab"
    if rootpxe_ci_mount_fstab "$root_dir" /var rw; then
        fail "escaped fstab mountpoint must be rejected"
    fi
)
pass "cloud-init fstab CIS mounts, trailing-newline check, and escape rejection"

# 2. linux-hostname.sh: trailing-newline /etc shadowing in fstab must be rejected
(
    set +u
    . "$lib_dir/cloud-init.sh"
    . "$lib_dir/linux-hostname.sh"
    set -u
    root_dir="$tmp/lh-root"
    mkdir -p "$root_dir/etc"
    hostName="web-01"
    rootpxe_ci_is_root() { return 0; }
    rootpxe_ci_safe_write_directory() { return 0; }
    rootpxe_ci_metadata_safe() { return 0; }
    mountpoint() { return 1; }
    printf 'UUID=1111 / ext4 defaults 0 1\nUUID=2222 /etc ext4 defaults 0 2' >"$root_dir/etc/fstab"
    if rootpxe_linux_hostname_preflight "$root_dir"; then
        fail "linux-hostname must reject /etc shadowing on last line without trailing newline"
    fi
)
pass "linux-hostname fstab trailing-newline check"

# 3. uefi-boot.sh: efibootmgr v18 optional hex suffix appended after .efi
(
    set +u
    . "$lib_dir/uefi-boot.sh"
    set -u
    declare -a uefi_entries=()
    declare -A uefi_labels=()
    uefi_order=''
    uefi_work="$tmp/uefi-work"
    mkdir -p "$uefi_work"
    efibootmgr() {
        printf 'BootOrder: 0001\nBoot0001* ubuntu\tHD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0x100000)/\\EFI\\ubuntu\\shimx64.efi0000424f\n'
    }
    rootpxe_uefi_read_entries || fail "read_entries failed on v18 suffix"
    [[ ${#uefi_entries[@]} -eq 1 ]] || fail "expected 1 uefi entry"
    IFS='|' read -r id active num kind sig start size path cls <<<"${uefi_entries[0]}"
    [[ $path == '\efi\ubuntu\shimx64.efi' ]] || fail "unexpected parsed uefi path: $path"
)
pass "uefi-boot efibootmgr v18 optional hex suffix stripping"

# 4. restore-preflight.sh: mps:all rejects corrupt/missing d1.mbr; mpa:mbr succeeds without dNpP.img
(
    set +u
    . "$lib_dir/restore-preflight.sh"
    set -u
    img_mps="$tmp/img-mps"
    mkdir -p "$img_mps"
    printf '1:512\n' >"$img_mps/d1.size"
    printf 'label: dos\n/dev/sda1 : start=2048, size=100, type=83\n' >"$img_mps/d1.partitions"
    printf 'img' >"$img_mps/d1p1.img"
    # d1.mbr intentionally missing
    if rootpxe_validate_restore_artifacts "$img_mps" mps all; then
        fail "mps:all must fail when d1.mbr is missing"
    fi

    img_mpa="$tmp/img-mpa"
    mkdir -p "$img_mpa"
    printf '1:512\n' >"$img_mpa/d1.size"
    printf 'label: dos\n/dev/sda1 : start=2048, size=100, type=83\n' >"$img_mpa/d1.partitions"
    head -c 512 /dev/zero >"$img_mpa/d1.mbr"
    # No d1p1.img on purpose for mpa:mbr
    rootpxe_validate_restore_artifacts "$img_mpa" mpa mbr || fail "mpa:mbr must not require dNpP.img payloads"
)
pass "restore-preflight mps:all boot artifact gate and mpa:mbr payload exemption"

# 5. display-metadata.sh: safe octal unescaping without \c truncation or double-decoding
(
    set +u
    . "$lib_dir/display-metadata.sh"
    set -u
    [[ $(rootpxe_display_metadata_unescape_fstab_field '/srv\040data') == '/srv data' ]] || fail "unescape space"
    [[ $(rootpxe_display_metadata_unescape_fstab_field '/a\134040') == '/a\040' ]] || fail "no double decode"
    [[ $(rootpxe_display_metadata_unescape_fstab_field '/a\cb\040d') == '/a\cb d' ]] || fail "no \\c truncation"
    if rootpxe_display_metadata_unescape_fstab_field '/a\012b' >/dev/null 2>&1; then fail "must reject newline"; fi
    if rootpxe_display_metadata_unescape_fstab_field '/a\000b' >/dev/null 2>&1; then fail "must reject NUL"; fi
)
pass "display-metadata octal unescape safety"

# 6. storage-io.sh: retry reset clears direct-capture state variables
(
    set +u
    . "$lib_dir/storage-io.sh"
    set -u
    rootpxe_cleanup_task_json() { :; }
    rootpxe_deployment_identity_cleanup_private() { :; }
    rootpxe_capture_direct=yes
    rootpxe_capture_stopped=yes
    rootpxe_capture_released=yes
    rootpxe_capture_published_attempt=3
    rootpxe_capture_nfs_version=4.1
    rootpxe_capture_smb_version=3.0
    rootpxe_capture_disks_string=/dev/sda
    progress_attempt=3
    rootpxe_storage_reset_retry_state
    [[ -z ${rootpxe_capture_direct:-} ]] || fail "rootpxe_capture_direct not cleared"
    [[ -z ${rootpxe_capture_stopped:-} ]] || fail "rootpxe_capture_stopped not cleared"
    [[ -z ${rootpxe_capture_released:-} ]] || fail "rootpxe_capture_released not cleared"
    [[ -z ${rootpxe_capture_published_attempt:-} ]] || fail "rootpxe_capture_published_attempt not cleared"
    [[ -z ${progress_attempt:-} ]] || fail "progress_attempt not cleared"
)
pass "storage-io retry state reset clears capture-direct globals"

# 7. deploy-control.sh: retry cleanup deactivates LVM VGs on real mountinfo path
(
    set +u
    . "$lib_dir/deploy-control.sh"
    set -u
    baseline="$tmp/mountinfo-baseline"
    cat /proc/self/mountinfo >"$baseline"
    called_vgchange=no
    vgchange() { [[ $1 == -an ]] && called_vgchange=yes; return 0; }
    rootpxe_deploy_retry_cleanup "$baseline" /proc/self/mountinfo || fail "deploy retry cleanup failed"
    [[ $called_vgchange == yes ]] || fail "expected vgchange -an during deploy retry cleanup"
)
pass "deploy-control retry cleanup deactivates active LVM VGs"

# 8. deployment-identity.sh: report_result normalizes missing trailing slash on web
(
    set +u
    . "$lib_dir/deployment-identity.sh"
    set -u
    captured_url=""
    rootpxe_deployment_identity_policy_enabled() { return 0; }
    rootpxe_task_identity_json() { printf '%s' "$1"; }
    rootpxe_task_curl() {
        local arg last=""
        for arg in "$@"; do last="$arg"; done
        printf '%s' "$last" >"$tmp/report-url"
        printf '{"success":true}\n200'
    }
    rootpxe_deployment_identity_plan_file="$tmp/plan.json"
    printf '{"plan":{"planId":"P1"},"planHash":"H1"}\n' >"$rootpxe_deployment_identity_plan_file"
    pxeapi="http://127.0.0.1:8080/pxe/v1"
    taskid=7 task_token="tok" mac="aa:bb:cc:dd:ee:ff" progress_attempt=1
    rootpxe_deployment_identity_report_result true false false || fail "report_result failed"
    captured_url=$(<"$tmp/report-url")
    [[ $captured_url == "http://127.0.0.1:8080/pxe/v1/deployment-identity-result" ]] || fail "unexpected URL: $captured_url"
)
pass "deployment-identity report_result URL slash normalization"

# 9. funcs.sh: saveGRUB uses blockdev --getss, redact covers unattendXml & cloud-init temp paths,
#    update_disk_permit_binding_path rebinds NVMe path, correctVistaMBR uses pxeosmbrfix,
#    find_windows_system_partition fails closed on umount error
(
    funcs_dir="$tmp/funcs-sandbox"
    mkdir -p "$funcs_dir"
    cp "$lib_dir"/*.sh "$funcs_dir/"
    sed "s|/tmp/log|$tmp/log|g" "$lib_dir/log-paths.sh" >"$funcs_dir/log-paths.sh"
    sed -i -e "s|^rootpxe_log_paths_lib=.*|rootpxe_log_paths_lib=$funcs_dir/log-paths.sh|" "$funcs_dir/funcs.sh"
    set +u
    . "$funcs_dir/funcs.sh"
    set -u

    # 9a. Redaction
    out=$(rootpxe_redact_diagnostic 'unattendXml=<xml>secret</xml> path=/tmp/rootpxe-cloud-init.Ab12Cd')
    [[ $out != *'secret'* && $out != *'Ab12Cd'* ]] || fail "redaction missed unattendXml or cloud-init path: $out"

    # 9b. Disk permit path update after NVMe reformat
    rootpxe_disk_permit_disk_map_file="$tmp/permit-map.tsv"
    printf '/dev/nvme0n1\tnvme-eui-1\tnvme_format+deploy_write\n' >"$rootpxe_disk_permit_disk_map_file"
    rootpxe_disk_permit_bound_disk='/dev/nvme0n1'
    rootpxe_disk_stable_identity() { [[ $1 == /dev/nvme1n1 ]] && echo 'nvme-eui-1' || echo 'other-id'; }
    if rootpxe_update_disk_permit_binding_path /dev/nvme0n1 /dev/nvme2n1; then
        fail "permit rebind must reject mismatched stable identity"
    fi
    rootpxe_update_disk_permit_binding_path /dev/nvme0n1 /dev/nvme1n1 || fail "update permit binding failed"
    [[ $(<"$rootpxe_disk_permit_disk_map_file") == $'/dev/nvme1n1\tnvme-eui-1\tnvme_format+deploy_write' && $rootpxe_disk_permit_bound_disk == '/dev/nvme1n1' ]] || fail "permit map not rebound"

    # 9c. saveGRUB respects 4Kn sector size
    dd_args=""
    type=up
    flock() { printf '/dev/nvme0n1p1 : start=        2048, size= 100, type=83\n'; }
    blockdev() { [[ $1 == --getss ]] && echo 4096; }
    dd() { dd_args="$*"; }
    set +e
    saveGRUB /dev/nvme0n1 1 "$tmp"
    rc=$?
    set -e
    [[ $rc -eq 0 && $dd_args == *'bs=4096'* ]] || fail "saveGRUB did not use 4096 sector size (rc=$rc): $dd_args"

    # 9d. correctVistaMBR uses pxeosmbrfix (not fogmbrfix)
    grep -Fq 'pxeosmbrfix' "$lib_dir/funcs.sh" || fail "pxeosmbrfix missing in funcs.sh"
    ! grep -Fq 'fogmbrfix' "$lib_dir/funcs.sh" || fail "fogmbrfix still referenced in funcs.sh"

    # 9e. find_windows_system_partition fails closed when umount fails
    mkdir() { return 0; }
    getPartitions() { parts="/dev/sda1"; }
    fsTypeSetting() { fstype="ntfs"; }
    mountpoint() { return 0; }
    ntfs-3g() { return 0; }
    umount() { return 1; }
    set +e
    rootpxe_find_windows_system_partition /dev/sda
    rc=$?
    set -e
    [[ $rc -eq 12 ]] || fail "expected rc=12 when umount /ntfs fails, got $rc"
)
pass "funcs.sh redaction, NVMe permit rebind, saveGRUB 4Kn, pxeosmbrfix, and ntfs umount fail-closed"

# 10. pxeos.mount: host:port and IPv6 syntax check (static + parser check)
grep -Fq 'mount_port' "$bin_dir/pxeos.mount" || fail "pxeos.mount missing host:port/IPv6 parser"
grep -Fq 'prepareUploadLocation "$imagePath" || handleError' "$bin_dir/pxeos.upload" || fail "pxeos.upload missing prepareUploadLocation guard"
grep -Fq -- '--data-urlencode "partitionInventory@$rootpxe_partition_inventory_file"' "$bin_dir/pxeos.imgcomplete" || fail "pxeos.imgcomplete still passes inventory via argv"
pass "pxeos.mount / pxeos.upload / pxeos.imgcomplete contracts"

echo "ALL AUDIT CAPTURE/DEPLOY/INJECTION PXEOS TESTS PASSED"
