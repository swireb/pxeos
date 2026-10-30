#!/usr/bin/env bash
set -euo pipefail
export MSYS=winsymlinks:nativestrict
root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
tmp=$(mktemp -d /tmp/pxeos-cloud-init-seed.XXXXXX)
cleanup_fixture(){
    [[ $tmp =~ ^/tmp/pxeos-cloud-init-seed\.[A-Za-z0-9]{6}$ && -d $tmp && ! -L $tmp ]] || return 1
    rm -rf -- "$tmp"
}
trap cleanup_fixture EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
case $(uname -s) in MINGW*|MSYS*) rootpxe_ci_fixture_jq=$(command -v jq.exe); jq(){ "$rootpxe_ci_fixture_jq" -b "$@"; };; esac
[[ -r $lib/cloud-init.sh ]] || fail 'NoCloud helper is missing'
. "$lib/cloud-init.sh"
case $(uname -s) in MINGW*|MSYS*)
    rootpxe_ci_is_root(){ return 0; }
    rootpxe_ci_stat(){ local mode=700; [[ -d $1 ]] || mode=600; printf '0:0:%s:%s\n' "$mode" "$(command stat -c '%h' -- "$1")"; }
    printf 'SKIP: MSYS root/Unix mode; symlink/hardlink/inode/hash checks are real\n'
;; esac
declare -f rootpxe_ci_check_prerequisites | grep -Fq 'cloud-init-network.service' || fail 'native Network mask unit missing'
fixture(){
    target="$tmp/$1"
    mkdir -p "$target/etc/cloud/cloud.cfg.d" "$target/usr/bin" "$target/var/lib/cloud"
    printf '#!/bin/sh\nexit 99\n' >"$target/usr/bin/cloud-init"
    chmod +x "$target/usr/bin/cloud-init"
    printf 'datasource_list: [ NoCloud ]\n' >"$target/etc/cloud/cloud.cfg.d/90-nocloud.cfg"
    printf 'datasource_list:\n  - NoCloud\n' >"$target/etc/cloud/cloud.cfg"
    printf '#cloud-config\r\n# 私有内容\r\nruncmd: []\r\n\r\n' >"$tmp/user-data"
    cloudInitUserDataFile="$tmp/user-data"
    cloudInitUserDataSha256=$(rootpxe_ci_hash "$cloudInitUserDataFile")
    printf 'instance-id: manual-image-instance\r\nlocal-hostname: raw-image-name\r\n# 不自动生成或渲染\r\n' >"$tmp/meta-data"
    cloudInitMetaDataFile="$tmp/meta-data"
    cloudInitMetaDataSha256=$(rootpxe_ci_hash "$cloudInitMetaDataFile")
    cloudInitNetworkConfigFile='' cloudInitNetworkConfigSha256=''
    cloudInitVendorDataFile='' cloudInitVendorDataSha256=''
}
network_fixture(){
    fixture "$1"
    printf 'version: 2\r\nethernets:\r\n  enp1s0:\r\n    dhcp4: true\r\n\r\n' >"$tmp/network-config"
    cloudInitNetworkConfigFile="$tmp/network-config"
    cloudInitNetworkConfigSha256=$(rootpxe_ci_hash "$cloudInitNetworkConfigFile")
}
vendor_fixture(){
    fixture "$1"
    printf '#cloud-config\r\n# 供应方私有原始字节\r\nruncmd: []\r\n\r\n' >"$tmp/vendor-data"
    cloudInitVendorDataFile="$tmp/vendor-data"
    cloudInitVendorDataSha256=$(rootpxe_ci_hash "$cloudInitVendorDataFile")
}
four_fixture(){
    vendor_fixture "$1"
    printf 'version: 2\nethernets: {}\n' >"$tmp/network-config"
    cloudInitNetworkConfigFile="$tmp/network-config"
    cloudInitNetworkConfigSha256=$(rootpxe_ci_hash "$cloudInitNetworkConfigFile")
}
fixture fresh
rootpxe_cloud_init_install_at_root "$target" || fail "fresh install: ${rootpxe_cloud_init_error:-}"
seed="$target/var/lib/cloud/seed/nocloud"
[[ $(find "$seed" -maxdepth 1 -type f | wc -l) == 2 ]] || fail 'seed must contain exactly two files'
cmp -s "$tmp/user-data" "$seed/user-data" || fail 'CRLF bytes changed'
cmp -s "$tmp/meta-data" "$seed/meta-data" || fail 'manual meta-data raw bytes changed'
before=$(stat -c '%d:%i' "$seed/user-data")
rootpxe_cloud_init_install_at_root "$target" || fail 'same frozen seed rejected'
[[ $(stat -c '%d:%i' "$seed/user-data") == "$before" ]] || fail 'idempotent seed was rewritten'
network_fixture network
rootpxe_cloud_init_install_at_root "$target" || fail 'three-file install rejected'
seed="$target/var/lib/cloud/seed/nocloud"
[[ $(find "$seed" -mindepth 1 -maxdepth 1 -type f | wc -l) == 3 ]] || fail 'network-config was not installed as third file'
cmp -s "$tmp/network-config" "$seed/network-config" || fail 'network-config raw bytes changed'
before=$(stat -c '%d:%i' "$seed/user-data" "$seed/meta-data" "$seed/network-config")
rootpxe_cloud_init_install_at_root "$target" || fail 'same three-file seed rejected'
[[ $(stat -c '%d:%i' "$seed/user-data" "$seed/meta-data" "$seed/network-config") == "$before" ]] || fail 'three-file seed was rewritten'
cloudInitNetworkConfigFile='' cloudInitNetworkConfigSha256=''
rootpxe_cloud_init_install_at_root "$target" && fail 'cleared network silently removed an existing network-config'
[[ $rootpxe_cloud_init_error == cloud_init_foreign_seed && -f $seed/network-config ]] || fail 'cleared network conflict not preserved'
printf 'instance-id: different-manual-task\n' >"$cloudInitMetaDataFile"
cloudInitMetaDataSha256=$(rootpxe_ci_hash "$cloudInitMetaDataFile")
rootpxe_cloud_init_install_at_root "$target" && fail 'cross-task seed accepted'
vendor_fixture vendor-only
rootpxe_cloud_init_install_at_root "$target" || fail 'vendor-only three-file install rejected'
seed="$target/var/lib/cloud/seed/nocloud"
[[ $(find "$seed" -mindepth 1 -maxdepth 1 -type f | wc -l) == 3 && ! -e $seed/network-config ]] || fail 'vendor-only expected file set mismatch'
cmp -s "$tmp/vendor-data" "$seed/vendor-data" || fail 'vendor-data raw bytes changed'
four_fixture four
rootpxe_cloud_init_install_at_root "$target" || fail 'four-file install rejected'
seed="$target/var/lib/cloud/seed/nocloud"
[[ $(find "$seed" -mindepth 1 -maxdepth 1 -type f | wc -l) == 4 ]] || fail 'vendor-data was not installed as fourth file'
cmp -s "$tmp/vendor-data" "$seed/vendor-data" || fail 'four-file vendor bytes changed'
before=$(stat -c '%d:%i' "$seed/user-data" "$seed/meta-data" "$seed/network-config" "$seed/vendor-data")
rootpxe_ci_readonly_preflight "$target" || fail 'four-file readonly retry rejected'
[[ $rootpxe_cloud_init_seed_verified == yes ]] || fail 'four-file readonly retry not verified'
rootpxe_cloud_init_install_at_root "$target" || fail 'same four-file seed rejected'
[[ $(stat -c '%d:%i' "$seed/user-data" "$seed/meta-data" "$seed/network-config" "$seed/vendor-data") == "$before" ]] || fail 'four-file seed was rewritten'
cloudInitVendorDataFile='' cloudInitVendorDataSha256=''
rootpxe_ci_readonly_preflight "$target" && fail 'readonly cleared vendor accepted existing vendor-data'
rootpxe_cloud_init_install_at_root "$target" && fail 'cleared vendor silently removed existing vendor-data'
[[ $rootpxe_cloud_init_error == cloud_init_foreign_seed && -f $seed/vendor-data ]] || fail 'cleared vendor conflict not preserved'
fixture empty-user
: >"$cloudInitUserDataFile"
cloudInitUserDataSha256=$(rootpxe_ci_hash "$cloudInitUserDataFile")
rootpxe_cloud_init_install_at_root "$target" || fail 'empty user-data seed rejected'
[[ -f $target/var/lib/cloud/seed/nocloud/user-data && ! -s $target/var/lib/cloud/seed/nocloud/user-data ]] || fail 'empty user-data seed missing'
cmp -s "$tmp/meta-data" "$target/var/lib/cloud/seed/nocloud/meta-data" || fail 'empty-user manual metadata changed'
for conflict in missing-meta tampered-meta hardlinked-meta; do
    network_fixture "$conflict"
    rootpxe_cloud_init_install_at_root "$target" || fail 'manual metadata conflict fixture'
    seed="$target/var/lib/cloud/seed/nocloud"
    case $conflict in
        missing-meta) rm -- "$seed/meta-data";;
        tampered-meta) printf 'changed' >>"$seed/meta-data";;
        hardlinked-meta) ln "$seed/meta-data" "$tmp/meta-extra-link";;
    esac
    rootpxe_ci_readonly_preflight "$target" && fail "readonly accepted $conflict"
    [[ $rootpxe_cloud_init_error == cloud_init_foreign_seed ]] || fail "$conflict reason"
done
for conflict in cache disabled foreign extra hardlink symlink; do
    fixture "$conflict"
    case $conflict in
        cache) mkdir "$target/var/lib/cloud/instances";;
        disabled) printf '' >"$target/etc/cloud/cloud-init.disabled";;
        foreign) mkdir -p "$target/var/lib/cloud/seed/nocloud-net";;
        extra) mkdir -p "$target/var/lib/cloud/seed/nocloud"; printf 'unknown' >"$target/var/lib/cloud/seed/nocloud/vendor-data";;
        hardlink) rootpxe_cloud_init_install_at_root "$target"; ln "$target/var/lib/cloud/seed/nocloud/user-data" "$tmp/extra-link";;
        symlink) mv "$target/var/lib/cloud" "$target/var/lib/foreign"; if ! ln -s foreign "$target/var/lib/cloud"; then printf 'SKIP: native symlink creation denied by Windows\n'; continue; fi;;
    esac
    rootpxe_cloud_init_install_at_root "$target" && fail "accepted $conflict"
    case $conflict in cache) expected=cloud_init_cache_not_clean;; disabled) expected=cloud_init_explicitly_disabled;; foreign|extra|hardlink) expected=cloud_init_foreign_seed;; symlink) expected=cloud_init_target_path_unsafe;; esac
    [[ $rootpxe_cloud_init_error == "$expected" ]] || fail "$conflict reason: $rootpxe_cloud_init_error"
done
for conflict in missing-network tampered-network extra-network hardlinked-network symlink-network; do
    network_fixture "$conflict"
    rootpxe_cloud_init_install_at_root "$target" || fail 'network conflict fixture install'
    seed="$target/var/lib/cloud/seed/nocloud"
    case $conflict in
        missing-network) rm -- "$seed/network-config";;
        tampered-network) printf 'changed' >>"$seed/network-config";;
        extra-network) printf 'foreign' >"$seed/vendor-data";;
        hardlinked-network) ln "$seed/network-config" "$tmp/network-extra-link";;
        symlink-network) rm -- "$seed/network-config"; if ! ln -s /dev/null "$seed/network-config"; then printf 'SKIP: network symlink creation denied by Windows\n'; continue; fi;;
    esac
    rootpxe_ci_readonly_preflight "$target" && fail "readonly accepted $conflict"
    [[ $rootpxe_cloud_init_error == cloud_init_foreign_seed ]] || fail "$conflict reason"
done
network_fixture metadata-network
rootpxe_cloud_init_install_at_root "$target" || fail 'network metadata fixture install'
eval "$(declare -f rootpxe_ci_stat | sed '1s/rootpxe_ci_stat/rootpxe_ci_fixture_original_stat/')"
rootpxe_ci_stat(){
    if [[ $1 == "$target/var/lib/cloud/seed/nocloud/network-config" ]]; then
        case ${network_unsafe_metadata:-} in owner) printf '12345:0:600:1\n'; return;; mode) printf '0:0:666:1\n'; return;; esac
    fi
    rootpxe_ci_fixture_original_stat "$@"
}
for network_unsafe_metadata in owner mode; do
    rootpxe_ci_readonly_preflight "$target" && fail "readonly accepted unsafe network $network_unsafe_metadata"
    [[ $rootpxe_cloud_init_error == cloud_init_foreign_seed ]] || fail 'unsafe network metadata reason'
done
network_unsafe_metadata=''
for conflict in missing-vendor tampered-vendor extra-vendor hardlinked-vendor symlink-vendor; do
    four_fixture "$conflict"
    rootpxe_cloud_init_install_at_root "$target" || fail 'vendor conflict fixture install'
    seed="$target/var/lib/cloud/seed/nocloud"
    case $conflict in
        missing-vendor) rm -- "$seed/vendor-data";;
        tampered-vendor) printf 'changed' >>"$seed/vendor-data";;
        extra-vendor) printf 'foreign' >"$seed/unknown-data";;
        hardlinked-vendor) ln "$seed/vendor-data" "$tmp/vendor-extra-link";;
        symlink-vendor) rm -- "$seed/vendor-data"; if ! ln -s /dev/null "$seed/vendor-data"; then printf 'SKIP: vendor symlink creation denied by Windows\n'; continue; fi;;
    esac
    rootpxe_ci_readonly_preflight "$target" && fail "readonly accepted $conflict"
    [[ $rootpxe_cloud_init_error == cloud_init_foreign_seed ]] || fail "$conflict reason"
done
four_fixture metadata-vendor
rootpxe_cloud_init_install_at_root "$target" || fail 'vendor metadata fixture install'
rootpxe_ci_stat(){
    if [[ $1 == "$target/var/lib/cloud/seed/nocloud/vendor-data" ]]; then
        case ${vendor_unsafe_metadata:-} in owner) printf '12345:0:600:1\n'; return;; mode) printf '0:0:666:1\n'; return;; esac
    fi
    rootpxe_ci_fixture_original_stat "$@"
}
for vendor_unsafe_metadata in owner mode; do
    rootpxe_ci_readonly_preflight "$target" && fail "readonly accepted unsafe vendor $vendor_unsafe_metadata"
    [[ $rootpxe_cloud_init_error == cloud_init_foreign_seed ]] || fail 'unsafe vendor metadata reason'
done
vendor_unsafe_metadata=''
fixture masked-network
mkdir -p "$target/etc/systemd/system"
if ln -s /dev/null "$target/etc/systemd/system/cloud-init-network.service"; then
    rootpxe_cloud_init_install_at_root "$target" && fail 'masked native Network service accepted'
    [[ $rootpxe_cloud_init_error == cloud_init_explicitly_disabled ]] || fail 'native Network mask reason'
    [[ ! -e $target/var/lib/cloud/seed ]] || fail 'native Network mask rejected after mutation'
else
    printf 'SKIP: native Network mask symlink creation denied by Windows\n'
fi
fixture empty
mkdir -p "$target/var/lib/cloud/seed/nocloud"
inode=$(stat -c '%d:%i' "$target/var/lib/cloud/seed/nocloud")
rootpxe_cloud_init_install_at_root "$target" || fail 'empty seed directory rejected'
[[ $(stat -c '%d:%i' "$target/var/lib/cloud/seed/nocloud") == "$inode" ]] || fail 'original empty directory inode changed'
fixture missing
rm -- "$target/usr/bin/cloud-init"
rootpxe_cloud_init_install_at_root "$target" && fail 'missing package accepted'
[[ $rootpxe_cloud_init_error == cloud_init_not_installed ]] || fail 'missing package reason'
fixture half-seed
mkdir -p "$target/var/lib/cloud/seed/nocloud"
cp "$tmp/user-data" "$target/var/lib/cloud/seed/nocloud/user-data"
rootpxe_cloud_init_install_at_root "$target" && fail 'half-published seed accepted'
[[ $rootpxe_cloud_init_error == cloud_init_foreign_seed ]] || fail 'half-seed reason'
fixture rollback
mkdir -p "$target/var/lib/cloud/seed/nocloud"
inode=$(stat -c '%d:%i' "$target/var/lib/cloud/seed/nocloud")
eval "$(declare -f rootpxe_ci_move | sed '1s/rootpxe_ci_move/rootpxe_ci_original_move/')"
rootpxe_ci_move(){ [[ $2 != */meta-data ]] || return 1; rootpxe_ci_original_move "$@"; }
rootpxe_cloud_init_install_at_root "$target" && fail 'publish failure accepted'
[[ $rootpxe_cloud_init_error == cloud_init_seed_publish_failed ]] || fail 'publish reason'
[[ $(stat -c '%d:%i' "$target/var/lib/cloud/seed/nocloud") == "$inode" ]] || fail 'rollback replaced empty inode'
[[ -z $(find "$target/var/lib/cloud/seed/nocloud" -mindepth 1 -print) ]] || fail 'partial seed survived rollback'
[[ -z $(find "$target/var/lib/cloud/seed" -name '.nocloud.new.*' -print) ]] || fail 'stage survived rollback'
unset -f rootpxe_ci_move
eval "$(declare -f rootpxe_ci_original_move | sed '1s/rootpxe_ci_original_move/rootpxe_ci_move/')"
four_fixture vendor-publish-rollback
mkdir -p "$target/var/lib/cloud/seed/nocloud"
inode=$(stat -c '%d:%i' "$target/var/lib/cloud/seed/nocloud")
rootpxe_ci_move(){ [[ $2 != */vendor-data ]] || return 1; rootpxe_ci_original_move "$@"; }
rootpxe_cloud_init_install_at_root "$target" && fail 'vendor publish failure accepted'
[[ $rootpxe_cloud_init_error == cloud_init_seed_publish_failed ]] || fail 'vendor publish reason'
[[ $(stat -c '%d:%i' "$target/var/lib/cloud/seed/nocloud") == "$inode" ]] || fail 'vendor rollback replaced original empty inode'
[[ -z $(find "$target/var/lib/cloud/seed/nocloud" -mindepth 1 -print) && -z $(find "$target/var/lib/cloud/seed" -name '.nocloud.new.*' -print) ]] || fail 'vendor rollback left owned files/stage'
unset -f rootpxe_ci_move
eval "$(declare -f rootpxe_ci_original_move | sed '1s/rootpxe_ci_original_move/rootpxe_ci_move/')"
four_fixture vendor-foreign-rollback
mkdir -p "$target/var/lib/cloud/seed/nocloud"
rootpxe_ci_move(){
    if [[ $2 == */vendor-data ]]; then printf 'foreign-preserved' >"$2"; return 1; fi
    rootpxe_ci_original_move "$@"
}
rootpxe_cloud_init_install_at_root "$target" && fail 'foreign vendor publish race accepted'
[[ $rootpxe_cloud_init_error == cloud_init_seed_publish_failed ]] || fail 'foreign vendor publish reason'
[[ $(<"$target/var/lib/cloud/seed/nocloud/vendor-data") == foreign-preserved ]] || fail 'vendor rollback deleted foreign content'
[[ $(find "$target/var/lib/cloud/seed/nocloud" -mindepth 1 -maxdepth 1 -type f | wc -l) == 1 && -z $(find "$target/var/lib/cloud/seed" -name '.nocloud.new.*' -print) ]] || fail 'foreign vendor rollback retained owned files/stage'
unset -f rootpxe_ci_move
eval "$(declare -f rootpxe_ci_original_move | sed '1s/rootpxe_ci_original_move/rootpxe_ci_move/')"
network_fixture network-publish-rollback
mkdir -p "$target/var/lib/cloud/seed/nocloud"
inode=$(stat -c '%d:%i' "$target/var/lib/cloud/seed/nocloud")
rootpxe_ci_move(){
    if [[ $2 == */network-config ]]; then printf 'foreign-preserved' >"$target/var/lib/cloud/seed/nocloud/vendor-data"; return 1; fi
    rootpxe_ci_original_move "$@"
}
rootpxe_cloud_init_install_at_root "$target" && fail 'network publish failure accepted'
[[ $rootpxe_cloud_init_error == cloud_init_seed_publish_failed ]] || fail 'network publish reason'
[[ $(stat -c '%d:%i' "$target/var/lib/cloud/seed/nocloud") == "$inode" ]] || fail 'network rollback replaced original empty inode'
[[ $(<"$target/var/lib/cloud/seed/nocloud/vendor-data") == foreign-preserved ]] || fail 'network rollback deleted foreign content'
[[ ! -e $target/var/lib/cloud/seed/nocloud/user-data && ! -e $target/var/lib/cloud/seed/nocloud/meta-data && ! -e $target/var/lib/cloud/seed/nocloud/network-config ]] || fail 'network rollback left owned files'
[[ -z $(find "$target/var/lib/cloud/seed" -name '.nocloud.new.*' -print) ]] || fail 'network rollback left its stage'
unset -f rootpxe_ci_move
eval "$(declare -f rootpxe_ci_original_move | sed '1s/rootpxe_ci_original_move/rootpxe_ci_move/')"
# SELinux is the image/system administrator's responsibility. Even a residual
# /etc/selinux directory must not make PXEOS read policy or call label tools.
for selinux_case in residual absent disabled enforcing malformed; do
    (
        four_fixture "selinux-$selinux_case"
        if [[ $selinux_case != absent ]]; then
            mkdir -p "$target/etc/selinux"
            printf 'fixture semanage settings\n' >"$target/etc/selinux/semanage.conf"
            case $selinux_case in
                disabled|enforcing) printf 'SELINUX=%s\nSELINUXTYPE=target\n' "$selinux_case" >"$target/etc/selinux/config";;
                malformed) printf 'not a valid SELinux configuration\n' >"$target/etc/selinux/config";;
            esac
        fi
        printf 'system-owned sentinel\n' >"$target/.autorelabel"
        selinux_before=$(find "$target" -path '*/etc/selinux/*' -type f -exec sha256sum {} +; sha256sum "$target/.autorelabel")
        selinux_calls="$tmp/cloud-selinux-$selinux_case.calls"
        export SELINUX_TOOL_CALLS="$selinux_calls"
        tool_dir="$tmp/tools-$selinux_case"
        mkdir "$tool_dir"
        for tool in matchpathcon getfattr setfattr selinuxenabled sestatus getenforce setenforce restorecon chcon; do
            cat >"$tool_dir/$tool" <<'TOOL'
#!/bin/sh
printf '%s\n' "${0##*/}" >>"$SELINUX_TOOL_CALLS"
exit 127
TOOL
            chmod +x "$tool_dir/$tool"
        done
        export PATH="$tool_dir:$PATH"
        awk(){
            case "$*" in *"$target/etc/selinux/"*) printf 'policy-read\n' >>"$selinux_calls"; return 1;; esac
            command awk "$@"
        }
        rootpxe_cloud_init_install_at_root "$target" || fail "SELinux $selinux_case affected seed installation: ${rootpxe_cloud_init_error:-}"
        rootpxe_ci_readonly_preflight "$target" || fail "SELinux $selinux_case affected readonly retry"
        [[ $rootpxe_cloud_init_seed_verified == yes ]] || fail 'readonly seed was not verified'
        [[ ! -e $selinux_calls ]] || fail "SELinux $selinux_case invoked policy/label tools"
        selinux_after=$(find "$target" -path '*/etc/selinux/*' -type f -exec sha256sum {} +; sha256sum "$target/.autorelabel")
        [[ $selinux_before == "$selinux_after" ]] || fail 'SELinux system files were changed'
        for file in user-data meta-data network-config vendor-data; do cmp -s "$tmp/$file" "$target/var/lib/cloud/seed/nocloud/$file" || fail 'seed bytes changed in SELinux-independent path'; done
        printf 'PASS: cloud-init does not inspect or alter SELinux: %s\n' "$selinux_case"
    ) || fail "SELinux-independent cloud-init: $selinux_case"
done
fixture stage-permission-failure
chmod(){ [[ ${*: -1} != */.nocloud.new.* ]] || return 1; command chmod "$@"; }
rootpxe_cloud_init_install_at_root "$target" && fail 'stage permission failure accepted'
unset -f chmod
[[ $rootpxe_cloud_init_error == cloud_init_seed_io_failed ]] || fail 'stage permission failure was not an IO error'
[[ ! -d $target/var/lib/cloud/seed || -z $(find "$target/var/lib/cloud/seed" -name '.nocloud.new.*' -print) ]] || fail 'stage permission failure left owned stage'
fixture cleanup-failure
rootpxe_ci_move(){ return 1; }
rootpxe_ci_transaction_cleanup(){ return 1; }
rootpxe_cloud_init_install_at_root "$target" && fail 'cleanup failure accepted'
[[ $rootpxe_cloud_init_error == cloud_init_seed_rollback_failed ]] || fail 'rollback failure reason'
[[ -n $(find "$target/var/lib/cloud/seed" -name '.nocloud.new.*' -print) ]] || fail 'rollback failure evidence discarded'
printf 'PASS: native two/three/four-file seed, vendor bytes/readonly retry/conflicts/rollback/foreign preservation/SELinux-independent\n'
