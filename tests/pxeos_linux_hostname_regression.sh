#!/usr/bin/env bash
# 真实离线配置事务与四态分派；仅替换块设备/mount和MSYS权限/标签叶边界。
set -euo pipefail
export MSYS=winsymlinks:nativestrict
root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
tmp=$(mktemp -d /tmp/pxeos-linux-hostname.XXXXXX)
cleanup_fixture(){
    local result=0
    [[ $tmp =~ ^/tmp/pxeos-linux-hostname\.[A-Za-z0-9]{6}$ && -d $tmp && ! -L $tmp ]] || return 1
    if declare -F rootpxe_cloud_init_cleanup_private >/dev/null; then rootpxe_cloud_init_cleanup_private || result=1; fi
    rm -rf -- "$tmp" || result=1
    return "$result"
}
trap cleanup_fixture EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
case $(uname -s) in MINGW*|MSYS*) rootpxe_ci_fixture_jq=$(command -v jq.exe); jq(){ "$rootpxe_ci_fixture_jq" -b "$@"; };; esac
. "$lib/cloud-init.sh"
[[ -r $lib/linux-hostname.sh ]] || fail 'safe Linux offline hostname helper is missing'
. "$lib/linux-hostname.sh"
. "$lib/deployment-identity.sh"
case $(uname -s) in MINGW*|MSYS*)
    rootpxe_ci_is_root(){ return 0; }
    rootpxe_ci_stat(){
        local owner=0 mode=644
        [[ ! -d $1 ]] || mode=700
        case $1 in */.rootpxe-hostname.*/*) mode=600;; /tmp/rootpxe-cloud-init.*|/tmp/rootpxe-cloud-meta.*|/tmp/rootpxe-cloud-network.*) owner=$EUID; mode=600;; esac
        if [[ $1 == "${unsafe_path:-}" ]]; then
            case ${unsafe_kind:-} in owner) owner=12345;; mode) mode=666;; executable) mode=755;; esac
        fi
        printf '%s:0:%s:%s\n' "$owner" "$mode" "$(command stat -c '%h' -- "$1")"
    }
    printf 'SKIP: MSYS native root/Unix modes; metadata rejection uses explicit substitutes\n'
;; esac
case $(uname -s) in MINGW*|MSYS*) ;; *) [[ $EUID == 0 ]] || { printf 'SKIP: native Linux root required for offline target metadata tests\n'; exit 0; };; esac
eval "$(declare -f rootpxe_ci_stat | sed '1s/rootpxe_ci_stat/rootpxe_lh_fixture_base_stat/')"
rootpxe_ci_stat(){
    if [[ $1 == "${unsafe_path:-}" ]]; then
        case ${unsafe_kind:-} in owner) printf '12345:0:644:1\n'; return;; mode) printf '0:0:666:1\n'; return;; executable) printf '0:0:755:1\n'; return;; esac
    fi
    rootpxe_lh_fixture_base_stat "$@"
}
taskType=deploy osid=50 changeHostname=true hostName=node-new
deploymentIdentityPolicyFile="$tmp/policy"
printf '{"version":1,"systemIdentity":{"sysprep":false},"taskHostname":"node-new","cloudInit":false}\n' >"$deploymentIdentityPolicyFile"
for hostName in bad.name -bad bad- ''; do rootpxe_linux_hostname_task_valid && fail 'invalid managed Linux name accepted'; done
hostName=node-new
rootpxe_linux_hostname_task_valid || fail 'valid frozen Linux task name rejected'
printf '{"version":1,"systemIdentity":{"sysprep":false},"taskHostname":"different","cloudInit":false}\n' >"$deploymentIdentityPolicyFile"
rootpxe_linux_hostname_task_valid && fail 'mutable name differed from frozen policy'
printf '{"version":1,"systemIdentity":{"sysprep":false},"taskHostname":"node-new","cloudInit":false}\n' >"$deploymentIdentityPolicyFile"
fixture(){
    target="$tmp/$1"
    mkdir -p "$target/etc" "$target/var/lib/cloud/instances" "$target/var/lib/cloud/seed/nocloud"
    printf 'node-old\n' >"$target/etc/hostname"
    printf '# keep node-old comment\r\n127.0.0.1\tlocalhost localhost.localdomain node-old # node-old comment\r\n127.2.3.4 node-old alias-old\n::1 localhost node-old\n192.0.2.7 node-old node-old.example\n' >"$target/etc/hosts"
    printf 'foreign seed must not be read or removed\n' >"$target/var/lib/cloud/seed/nocloud/vendor-data"
    chmod 644 "$target/etc/hostname" "$target/etc/hosts"
    unsafe_path='' unsafe_kind=''
}
# 读回工具的状态与输出必须同时可信；不能让两个空值/非法值相等变成幂等或成功回执。
eval "$(declare -f rootpxe_ci_hash | sed '1s/rootpxe_ci_hash/rootpxe_lh_fixture_base_hash/')"
eval "$(declare -f rootpxe_ci_inode | sed '1s/rootpxe_ci_inode/rootpxe_lh_fixture_base_inode/')"
proof_fault_case(){
    local rootpxe_lh_fixture_fault="$1" rootpxe_lh_fixture_mode="$2"
    (
        fixture "proof-$rootpxe_lh_fixture_fault-$rootpxe_lh_fixture_mode"
        local bad=0 readonly=no
        case $rootpxe_lh_fixture_fault in
            hash-actual|hash-expected|inode-preflight|label-*)
                readonly=yes
                printf 'node-new\n' >"$target/etc/hostname"
                printf '127.0.0.1 localhost\n127.0.1.1 node-new\n' >"$target/etc/hosts"
                ;;
            inode-final) rm -- "$target/etc/hostname";;
        esac
        rootpxe_ci_hash(){
            case $rootpxe_lh_fixture_fault:$1 in
                hash-actual:"$target"/etc/hostname|hash-actual:"$target"/etc/hosts|hash-expected:-|hash-owned:*.new|hash-owned:*.old)
                    case $rootpxe_lh_fixture_mode in
                        nonzero) rootpxe_lh_fixture_base_hash "$1"; return 1;;
                        empty) return 0;;
                        invalid) printf 'invalid-sha256\n'; return 0;;
                    esac;;
            esac
            rootpxe_lh_fixture_base_hash "$@"
        }
        rootpxe_ci_inode(){
            case $rootpxe_lh_fixture_fault:$1 in
                inode-preflight:"$target"/etc/hostname|inode-preflight:"$target"/etc/hosts|inode-stage:"$target"/etc/.rootpxe-hostname.*|inode-owned:*.new|inode-owned:*.old|inode-final:"$target"/etc/hostname)
                    case $rootpxe_lh_fixture_fault:$1 in inode-stage:*/*/.rootpxe-hostname.*/*) rootpxe_lh_fixture_base_inode "$@"; return;; esac
                    case $rootpxe_lh_fixture_mode in
                        nonzero) rootpxe_lh_fixture_base_inode "$1"; return 1;;
                        empty) return 0;;
                        invalid) printf 'invalid-inode\n'; return 0;;
                    esac;;
            esac
            rootpxe_lh_fixture_base_inode "$@"
        }
        if [[ $rootpxe_lh_fixture_fault == label-* ]]; then
            mkdir -p "$target/etc/selinux/target/contexts/files"
            printf 'SELINUX=enforcing\nSELINUXTYPE=target\n' >"$target/etc/selinux/config"
            printf 'fixture' >"$target/etc/selinux/target/contexts/files/file_contexts"
            rootpxe_ci_label_tools_ready(){ return 0; }
            rootpxe_ci_expected_label(){
                case $rootpxe_lh_fixture_fault in
                    label-empty) return 0;;
                    label-invalid) printf 'invalid-label\n'; return 0;;
                esac
                printf 'system_u:object_r:net_conf_t:s0\n'
                [[ $rootpxe_lh_fixture_fault != label-expected-nonzero ]]
            }
            rootpxe_ci_read_label(){
                case $rootpxe_lh_fixture_fault in
                    label-empty) return 0;;
                    label-invalid) printf 'invalid-label\n'; return 0;;
                esac
                printf 'system_u:object_r:net_conf_t:s0\n'
                [[ $rootpxe_lh_fixture_fault != label-actual-nonzero ]]
            }
        fi
        # 保留真实 preflight/transaction/receipt，只替换设备选择和挂载叶边界。
        rootpxe_linux_select_unique_root_for_targets(){ rootpxe_linux_selected_disk=/dev/A; rootpxe_linux_selected_candidate='/dev/Ap1|ext4|||'; }
        rootpxe_verify_disk_permit_binding(){ [[ $1 == /dev/A && $2 == deploy_write ]]; }
        rootpxe_ci_mount_root(){ ci_mounted_root="$target"; }
        mountpoint(){ return 1; }
        rootpxe_stage(){ :; }
        if [[ $readonly == yes ]]; then
            rootpxe_linux_hostname_preflight "$target" && bad=1
            [[ $rootpxe_linux_hostname_verified != yes ]] || bad=1
        fi
        rootpxe_deployment_identity_hostname_result=false
        rootpxe_apply_linux_hostname_for_targets /dev/A && bad=1
        [[ $rootpxe_deployment_identity_hostname_result != true && $rootpxe_linux_hostname_verified != yes ]] || bad=1
        case $rootpxe_lh_fixture_fault in
            inode-stage|inode-owned|inode-final)
                [[ -n $(find "$target/etc" -maxdepth 1 -name '.rootpxe-hostname.*' -print) ]] || bad=1;;
        esac
        [[ $bad == 0 ]] || { printf 'FAIL: untrusted read proof accepted or evidence lost: %s/%s\n' "$rootpxe_lh_fixture_fault" "$rootpxe_lh_fixture_mode" >&2; return 1; }
        printf 'PASS: failed read proof is fail-closed: %s/%s\n' "$rootpxe_lh_fixture_fault" "$rootpxe_lh_fixture_mode"
    )
}
proof_failures=0
for proof_fault in hash-actual hash-expected hash-owned inode-preflight inode-stage inode-owned inode-final; do
    for proof_mode in nonzero empty invalid; do proof_fault_case "$proof_fault" "$proof_mode" || proof_failures=$((proof_failures+1)); done
done
for proof_fault in label-expected-nonzero label-actual-nonzero label-empty label-invalid; do
    proof_fault_case "$proof_fault" label || proof_failures=$((proof_failures+1))
done
[[ $proof_failures == 0 ]] || fail "$proof_failures unsafe hash/inode/label read-proof branches"
fixture basic
before=$(stat -c '%d:%i' "$target/etc/hostname" "$target/etc/hosts")
rootpxe_linux_hostname_write_at_root "$target" || fail "basic hostname transaction: ${rootpxe_initialization_failure_reason:-}"
[[ $(<"$target/etc/hostname") == node-new ]] || fail 'hostname bytes not updated'
printf '# keep node-old comment\r\n127.0.0.1\tlocalhost localhost.localdomain node-new # node-old comment\r\n127.2.3.4 node-new alias-old\n::1 localhost node-new\n192.0.2.7 node-old node-old.example\n' >"$tmp/expected-hosts"
cmp -s "$tmp/expected-hosts" "$target/etc/hosts" || { diff -u "$tmp/expected-hosts" "$target/etc/hosts" || :; fail 'hosts changed comments, remote names, whitespace or CRLF'; }
[[ $(stat -c '%d:%i' "$target/etc/hostname" "$target/etc/hosts") == "$before" ]] || fail 'existing config inode/metadata replaced'
[[ $(<"$target/var/lib/cloud/seed/nocloud/vendor-data") == 'foreign seed must not be read or removed' ]] || fail 'offline name inspected/changed Cloud-init seed'
rootpxe_linux_hostname_preflight "$target" || fail 'idempotent hostname readonly preflight'
[[ $rootpxe_linux_hostname_verified == yes ]] || fail 'same-name config not accepted read-only'
for old in absent empty localhost no-loopback already-new missing-hosts; do
    fixture "$old"
    case $old in
        absent) rm -- "$target/etc/hostname";;
        empty) : >"$target/etc/hostname";;
        localhost) printf 'localhost\n' >"$target/etc/hostname";;
        no-loopback) printf '192.0.2.7 node-old # preserved\n' >"$target/etc/hosts";;
        already-new) printf '127.0.0.1 localhost\n127.0.1.1 node-new\n' >"$target/etc/hosts";;
        missing-hosts) rm -- "$target/etc/hosts";;
    esac
    rootpxe_linux_hostname_write_at_root "$target" || fail "$old hostname transaction"
    [[ $(<"$target/etc/hostname") == node-new ]] || fail "$old hostname readback"
    [[ $(grep -Ec '^127\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+node-new([[:space:]]|$)' "$target/etc/hosts") == 1 ]] || fail "$old append/dedup loopback binding"
    [[ $old != missing-hosts ]] || grep -Fxq '127.0.0.1 localhost' "$target/etc/hosts" || fail 'new hosts omitted localhost'
done
for conflict in hostname-link hosts-link owner mode executable etc-mount etc-child-mount; do
    fixture "$conflict"
    case $conflict in
        hostname-link) ln "$target/etc/hostname" "$tmp/hard-hostname";;
        hosts-link) ln "$target/etc/hosts" "$tmp/hard-hosts";;
        owner|mode|executable) unsafe_path="$target/etc/hosts"; unsafe_kind=$conflict;;
        etc-mount) printf 'UUID=anything /etc ext4 defaults 0 0\n' >"$target/etc/fstab";;
        etc-child-mount) printf 'UUID=anything /etc/hosts ext4 defaults 0 0\n' >"$target/etc/fstab";;
    esac
    rootpxe_linux_hostname_preflight "$target" && fail "unsafe path/metadata accepted: $conflict"
    [[ $(<"$target/etc/hostname") == node-old ]] || fail "$conflict changed target before preflight"
done
fixture symlink
mv "$target/etc/hosts" "$target/etc/foreign-hosts"
if ln -s foreign-hosts "$target/etc/hosts" && [[ -L $target/etc/hosts ]]; then
    rootpxe_linux_hostname_preflight "$target" && fail 'symlink hosts accepted'
else printf 'SKIP: native hosts symlink semantics unavailable\n'; fi
fixture rollback
before=$(stat -c '%d:%i' "$target/etc/hostname" "$target/etc/hosts")
cp "$target/etc/hosts" "$tmp/original-hosts"
eval "$(declare -f rootpxe_lh_write_bytes | sed '1s/rootpxe_lh_write_bytes/rootpxe_lh_fixture_write_bytes/')"
rootpxe_lh_write_bytes(){ [[ $2 != */hosts || $1 != *.new ]] || return 1; rootpxe_lh_fixture_write_bytes "$@"; }
rootpxe_linux_hostname_write_at_root "$target" && fail 'hosts write failure accepted'
[[ $(<"$target/etc/hostname") == node-old ]] && cmp -s "$tmp/original-hosts" "$target/etc/hosts" || fail 'controlled rollback did not restore both files'
[[ $(stat -c '%d:%i' "$target/etc/hostname" "$target/etc/hosts") == "$before" ]] || fail 'rollback lost original inodes'
[[ -z $(find "$target/etc" -maxdepth 1 -name '.rootpxe-hostname.*' -print) ]] || fail 'successful rollback retained stage'
unset -f rootpxe_lh_write_bytes
eval "$(declare -f rootpxe_lh_fixture_write_bytes | sed '1s/rootpxe_lh_fixture_write_bytes/rootpxe_lh_write_bytes/')"
fixture readback-failure
cp "$target/etc/hosts" "$tmp/readback-original-hosts"
rootpxe_lh_write_bytes(){ rootpxe_lh_fixture_write_bytes "$@" || return; [[ $2 != */hosts || $1 != *.new ]] || printf 'corrupt-readback\n' >>"$2"; }
rootpxe_linux_hostname_write_at_root "$target" && fail 'bad readback accepted'
[[ $rootpxe_initialization_failure_reason == linux_hostname_readback_failed && $(<"$target/etc/hostname") == node-old ]] && cmp -s "$tmp/readback-original-hosts" "$target/etc/hosts" || fail 'readback failure did not restore original config'
fixture foreign-replacement
rootpxe_lh_write_bytes(){
    if [[ $2 == */hosts && $1 == *.new ]]; then mv -- "$2" "$tmp/foreign-original-hosts"; printf 'foreign-preserved\n' >"$2"; return 1; fi
    rootpxe_lh_fixture_write_bytes "$@"
}
rootpxe_linux_hostname_write_at_root "$target" && fail 'foreign replacement accepted'
[[ $rootpxe_initialization_failure_reason == linux_hostname_rollback_failed && $(<"$target/etc/hosts") == foreign-preserved ]] || fail 'rollback overwrote foreign replacement'
[[ -n $(find "$target/etc" -maxdepth 1 -name '.rootpxe-hostname.*' -print) ]] || fail 'failed rollback discarded evidence'
rootpxe_linux_hostname_preflight "$target" && fail 'unproved transaction evidence ignored on retry'
unset -f rootpxe_lh_write_bytes
eval "$(declare -f rootpxe_lh_fixture_write_bytes | sed '1s/rootpxe_lh_fixture_write_bytes/rootpxe_lh_write_bytes/')"
fixture cleanup-failure
rm(){ [[ ${*: -1} != *.new ]] || return 1; command rm "$@"; }
rootpxe_linux_hostname_write_at_root "$target" && fail 'stage cleanup failure accepted'
unset -f rm
[[ $rootpxe_initialization_failure_reason == linux_hostname_cleanup_failed ]] || fail 'cleanup failure reason lost'
[[ -n $(find "$target/etc" -maxdepth 1 -name '.rootpxe-hostname.*' -print) ]] || fail 'cleanup failure evidence discarded'
fixture selinux
mkdir -p "$target/etc/selinux/target/contexts/files"
printf 'SELINUX=enforcing\nSELINUXTYPE=target\n' >"$target/etc/selinux/config"
printf 'fixture' >"$target/etc/selinux/target/contexts/files/file_contexts"
rootpxe_ci_label_tools_ready(){ return 1; }
rootpxe_linux_hostname_preflight "$target" && fail 'missing native label tools accepted'
[[ $(<"$target/etc/hostname") == node-old ]] || fail 'label prerequisite rejected after mutation'
rootpxe_ci_label_tools_ready(){ return 0; }
rootpxe_ci_expected_label(){ printf 'system_u:object_r:net_conf_t:s0\n'; }
rootpxe_ci_read_label(){ printf 'system_u:object_r:net_conf_t:s0\n'; }
rootpxe_ci_write_label(){ printf '%s|%s\n' "$1" "$2" >>"$tmp/labels"; }
rootpxe_linux_hostname_write_at_root "$target" || fail 'target policy label branch rejected'
grep -Fq 'hostname.new|system_u:object_r:net_conf_t:s0' "$tmp/labels" || fail 'hostname final-path staging label not verified'
grep -Fq 'hosts.new|system_u:object_r:net_conf_t:s0' "$tmp/labels" || fail 'hosts final-path staging label not verified'
rootpxe_ci_read_label(){ printf 'system_u:object_r:wrong_t:s0\n'; }
rootpxe_linux_hostname_preflight "$target" && fail 'unverified existing label accepted'
unset -f rootpxe_ci_read_label
rootpxe_ci_read_label(){ printf 'system_u:object_r:net_conf_t:s0\n'; }
# 真正目标集合选择/ro→rw/cleanup；只替换设备盘点与mount叶边界。
fixture targets
rootpxe_verify_disk_permit_binding(){ [[ $2 == deploy_write && ( $1 == /dev/A || $1 == /dev/B ) ]]; }
rootpxe_find_linux_root_filesystem(){ [[ $1 != /dev/B || ${two_roots:-no} == yes ]] || return 20; printf '%sp1|ext4|||\n' "$1"; }
rootpxe_ci_device_is_block(){ [[ $1 == /dev/Ap1 || $1 == /dev/Bp1 ]]; }
readlink(){ [[ $1 != -f || ${@: -1} != /dev/* ]] || { printf '%s\n' "${@: -1}"; return; }; command readlink "$@"; }
stat(){ [[ $1 != -c || $2 != %r ]] || { printf '101\n'; return; }; command stat "$@"; }
rootpxe_ci_mount_root(){ ci_mounted_root="$target"; printf '%s\n' "$4" >>"$tmp/phases"; }
mountpoint(){ return 1; }
umount(){ fail 'borrowed target mount was unmounted'; }
rootpxe_stage(){ :; }
rootpxe_apply_linux_hostname_for_targets /dev/A /dev/B || fail 'unique root among data disks rejected'
[[ $(<"$tmp/phases") == $'ro\nrw' && $rootpxe_deployment_identity_hostname_result == true ]] || fail 'offline name permit/readonly/write/receipt ordering'
rootpxe_apply_linux_hostname_for_targets /dev/A /dev/B || fail 'same hostname readonly retry rejected'
[[ $(<"$tmp/phases") == $'ro\nrw\nro' ]] || fail 'same hostname retry mounted writable'
two_roots=yes
rootpxe_apply_linux_hostname_for_targets /dev/A /dev/B && fail 'multiple Linux roots guessed first target'
[[ $rootpxe_deployment_identity_hostname_result == false ]] || fail 'ambiguous roots left success receipt'
two_roots=no
rootpxe_apply_linux_hostname_for_targets /dev/A /dev/FOREIGN && fail 'unauthorized disk reached root lookup'
eval "$(declare -f rootpxe_ci_cleanup_mounts | sed '1s/rootpxe_ci_cleanup_mounts/rootpxe_lh_fixture_cleanup_mounts/')"
rootpxe_ci_cleanup_mounts(){ return 1; }
rootpxe_apply_linux_hostname_for_targets /dev/A /dev/B && fail 'mount cleanup failure accepted'
[[ $rootpxe_deployment_identity_hostname_result == false ]] || fail 'mount cleanup failure left success receipt'
unset -f rootpxe_ci_cleanup_mounts
eval "$(declare -f rootpxe_lh_fixture_cleanup_mounts | sed '1s/rootpxe_lh_fixture_cleanup_mounts/rootpxe_ci_cleanup_mounts/')"
# 四态分派：Cloud开启时绝不调用离线改名；回执只在注入及清理完成后设置。
eval "$(sed -n '/^rootpxe_apply_hostname_for_disk() {$/,/^}$/p' "$lib/funcs.sh")"
rootpxe_apply_linux_hostname_for_targets(){ printf 'offline\n' >>"$tmp/offline-calls"; }
for cloud in false true; do
    printf '{"version":1,"systemIdentity":{"sysprep":false},"taskHostname":"node-new","cloudInit":%s}\n' "$cloud" >"$deploymentIdentityPolicyFile"
    for changeHostname in false true; do
        : >"$tmp/offline-calls"
        rootpxe_apply_hostname_for_disk /dev/A || fail 'four-state hostname dispatch rejected'
        if [[ $cloud == false && $changeHostname == true ]]; then [[ -s $tmp/offline-calls ]] || fail 'offline name branch not called'
        else [[ ! -s $tmp/offline-calls ]] || fail 'four-state dispatch ran forbidden offline name branch'; fi
    done
done
printf 'PASS: Linux offline hostname/hosts transaction, metadata/labels/rollback, unique permitted roots and four-state dispatch\n'
