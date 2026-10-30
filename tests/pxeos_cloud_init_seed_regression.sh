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
    rootpxe_ci_stat(){ local mode=700; [[ -d $1 ]] || mode=600; [[ $1 != */99-rootpxe-nocloud.cfg ]] || mode=644; printf '0:0:%s:%s\n' "$mode" "$(command stat -c '%h' -- "$1")"; }
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
overwrite_failures=0
for old_seed in different partial; do
    if ! (
        fixture "overwrite-$old_seed"
        mkdir -p "$target/var/lib/cloud/seed/nocloud"
        printf 'old configuration\n' >"$target/var/lib/cloud/seed/nocloud/user-data"
        chmod 600 "$target/var/lib/cloud/seed/nocloud/user-data"
        if [[ $old_seed == different ]]; then printf 'instance-id: old\n' >"$target/var/lib/cloud/seed/nocloud/meta-data"; chmod 600 "$target/var/lib/cloud/seed/nocloud/meta-data"; fi
        rootpxe_cloud_init_install_at_root "$target" || fail "existing $old_seed seed rejected instead of overwritten"
        cmp -s "$cloudInitUserDataFile" "$target/var/lib/cloud/seed/nocloud/user-data" && cmp -s "$cloudInitMetaDataFile" "$target/var/lib/cloud/seed/nocloud/meta-data" || fail 'old seed was not replaced'
    ); then overwrite_failures=$((overwrite_failures + 1)); fi
done
[[ $overwrite_failures == 0 ]] || fail 'ordinary seed overwrite regressions'
assert_nocloud_config(){
    local config="$target/etc/cloud/cloud.cfg.d/99-rootpxe-nocloud.cfg"
    [[ -f $config && ! -L $config ]] || fail 'NoCloud boot config was not installed'
    printf 'datasource_list: [NoCloud]\n' | cmp -s - "$config" || fail 'NoCloud boot config bytes changed'
    [[ $(rootpxe_ci_stat "$config") == 0:0:644:1 ]] || fail 'NoCloud boot config metadata'
}
for shape in two network vendor four; do
    case $shape in two) fixture "$shape";; network) network_fixture "$shape";; vendor) vendor_fixture "$shape";; four) four_fixture "$shape";; esac
    rootpxe_cloud_init_install_at_root "$target" || fail "$shape injection"
    seed="$target/var/lib/cloud/seed/nocloud"
    for file in user-data meta-data network-config vendor-data; do
        case $file in user-data) source=$cloudInitUserDataFile;; meta-data) source=$cloudInitMetaDataFile;; network-config) source=$cloudInitNetworkConfigFile;; vendor-data) source=$cloudInitVendorDataFile;; esac
        if [[ -n $source ]]; then
            cmp -s "$source" "$seed/$file" || fail "$shape $file raw bytes changed"
            [[ $(rootpxe_ci_stat "$seed/$file") == 0:0:600:1 ]] || fail "$shape $file metadata"
        else [[ ! -e $seed/$file ]] || fail "$shape unexpected optional file"; fi
    done
    assert_nocloud_config
    rootpxe_cloud_init_install_at_root "$target" || fail "$shape repeat injection"
done
fixture empty-user
: >"$cloudInitUserDataFile"
rootpxe_cloud_init_install_at_root "$target" || fail 'empty user-data injection'
[[ -f $target/var/lib/cloud/seed/nocloud/user-data && ! -s $target/var/lib/cloud/seed/nocloud/user-data ]] || fail 'empty user-data missing'
fixture missing-config-directory
rm "$target/etc/cloud/cloud.cfg.d/90-nocloud.cfg"; rmdir "$target/etc/cloud/cloud.cfg.d"
rootpxe_cloud_init_install_at_root "$target" || fail 'NoCloud config directory creation'
assert_nocloud_config
fixture existing-config
printf 'datasource_list: [None]\n' >"$target/etc/cloud/cloud.cfg.d/99-rootpxe-nocloud.cfg"
chmod 600 "$target/etc/cloud/cloud.cfg.d/99-rootpxe-nocloud.cfg"
rootpxe_cloud_init_install_at_root "$target" || fail 'dedicated config update'
assert_nocloud_config
rm "$target/etc/cloud/cloud.cfg.d/99-rootpxe-nocloud.cfg"
rootpxe_ci_readonly_preflight "$target" || fail 'readonly path preflight'
[[ ! -e $target/etc/cloud/cloud.cfg.d/99-rootpxe-nocloud.cfg ]] || fail 'readonly preflight wrote config'
rootpxe_cloud_init_install_at_root "$target" || fail 'matching seed missing boot config'
assert_nocloud_config
four_fixture optional-removal
rootpxe_cloud_init_install_at_root "$target" || fail 'optional-removal setup'
cloudInitNetworkConfigFile='' cloudInitVendorDataFile=''
rootpxe_cloud_init_install_at_root "$target" || fail 'old optional files removal'
[[ ! -e $target/var/lib/cloud/seed/nocloud/network-config && ! -e $target/var/lib/cloud/seed/nocloud/vendor-data ]] || fail 'unconfigured optional files survived'
fixture preserved-state
mkdir -p "$target/var/lib/cloud/instances/old" "$target/var/lib/cloud/data" "$target/var/lib/cloud/seed/nocloud-net" "$target/var/lib/cloud/seed/nocloud"
printf 'cached\n' >"$target/var/lib/cloud/instances/old/marker"
printf 'other seed\n' >"$target/var/lib/cloud/seed/nocloud-net/user-data"
printf 'unknown\n' >"$target/var/lib/cloud/seed/nocloud/unknown-file"
rootpxe_cloud_init_install_at_root "$target" || fail 'cache/other seed/unknown file blocked injection'
[[ $(<"$target/var/lib/cloud/instances/old/marker") == cached && $(<"$target/var/lib/cloud/seed/nocloud-net/user-data") == 'other seed' && $(<"$target/var/lib/cloud/seed/nocloud/unknown-file") == unknown ]] || fail 'unrelated cloud state changed'
for unsafe in file-symlink hardlink mode parent-symlink; do
    (
        fixture "unsafe-$unsafe"
        seed="$target/var/lib/cloud/seed/nocloud"; mkdir -p "$seed"
        printf 'old\n' >"$seed/user-data"; chmod 644 "$seed/user-data"
        case $unsafe in
            file-symlink) rm "$seed/user-data"; if ! ln -s /dev/null "$seed/user-data"; then exit 0; fi;;
            hardlink) ln "$seed/user-data" "$tmp/unsafe-extra-link";;
            mode) chmod 666 "$seed/user-data";;
            parent-symlink) mv "$target/var/lib/cloud" "$target/var/lib/foreign"; if ! ln -s foreign "$target/var/lib/cloud"; then exit 0; fi;;
        esac
        rootpxe_cloud_init_install_at_root "$target" && fail 'unsafe seed path accepted'
        [[ $rootpxe_cloud_init_error == cloud_init_target_path_unsafe ]] || fail 'unsafe seed path error'
    ) || fail "unsafe path $unsafe"
done
for invalid in disabled missing-package masked; do
    fixture "$invalid"
    case $invalid in
        disabled) : >"$target/etc/cloud/cloud-init.disabled"; expected=cloud_init_explicitly_disabled;;
        missing-package) rm "$target/usr/bin/cloud-init"; expected=cloud_init_not_installed;;
        masked) mkdir -p "$target/etc/systemd/system"; if ! ln -s /dev/null "$target/etc/systemd/system/cloud-init-network.service"; then continue; fi; expected=cloud_init_explicitly_disabled;;
    esac
    rootpxe_cloud_init_install_at_root "$target" && fail "accepted $invalid"
    [[ $rootpxe_cloud_init_error == "$expected" && ! -e $target/var/lib/cloud/seed ]] || fail 'package/disabled failure mutated seed'
done
(
    fixture write-failure
    cp(){ [[ $1 == -- && $2 == "$cloudInitMetaDataFile" ]] && return 1; command cp "$@"; }
    rootpxe_cloud_init_install_at_root "$target" && fail 'copy failure accepted'
    [[ $rootpxe_cloud_init_error == cloud_init_seed_io_failed && -f $target/var/lib/cloud/seed/nocloud/user-data ]] || fail 'copy error did not preserve actual partial result'
    unset -f cp
    rootpxe_cloud_init_install_at_root "$target" || fail 'partial injection could not be overwritten on retry'
    assert_nocloud_config
) || fail 'ordinary copy failure/retry'
(
    fixture config-permission-failure
    chmod(){ [[ ${@: -1} != */99-rootpxe-nocloud.cfg ]] || return 1; command chmod "$@"; }
    rootpxe_cloud_init_install_at_root "$target" && fail 'NoCloud chmod failure accepted'
    [[ $rootpxe_cloud_init_error == cloud_init_seed_io_failed ]] || fail 'NoCloud chmod error not propagated'
) || fail 'NoCloud write failure'
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
        [[ ! -e $selinux_calls ]] || fail "SELinux $selinux_case invoked policy/label tools"
        selinux_after=$(find "$target" -path '*/etc/selinux/*' -type f -exec sha256sum {} +; sha256sum "$target/.autorelabel")
        [[ $selinux_before == "$selinux_after" ]] || fail 'SELinux system files were changed'
        for file in user-data meta-data network-config vendor-data; do cmp -s "$tmp/$file" "$target/var/lib/cloud/seed/nocloud/$file" || fail 'seed bytes changed in SELinux-independent path'; done
        printf 'PASS: cloud-init does not inspect or alter SELinux: %s\n' "$selinux_case"
    ) || fail "SELinux-independent cloud-init: $selinux_case"
done
printf 'PASS: ordinary two/three/four-file seed injection, overwrite/retry, optional removal, preserved state, path safety and SELinux-independent\n'
