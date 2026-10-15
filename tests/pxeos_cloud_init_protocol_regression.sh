#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
tmp=$(mktemp -d /tmp/pxeos-cloud-init-protocol.XXXXXX)
cleanup_fixture(){
    local cleanup_result=0
    [[ $tmp =~ ^/tmp/pxeos-cloud-init-protocol\.[A-Za-z0-9]{6}$ && -d $tmp && ! -L $tmp ]] || return 1
    if declare -F rootpxe_cloud_init_cleanup_private >/dev/null; then rootpxe_cloud_init_cleanup_private || cleanup_result=1; fi
    rm -rf -- "$tmp" || cleanup_result=1
    return "$cleanup_result"
}
trap cleanup_fixture EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
case $(uname -s) in MINGW*|MSYS*) rootpxe_ci_fixture_jq=$(command -v jq.exe); jq(){ "$rootpxe_ci_fixture_jq" -b "$@"; };; esac
[[ -r $lib/cloud-init.sh ]] || fail 'NoCloud helper is missing'
. "$lib/cloud-init.sh"
case $(uname -s) in MINGW*|MSYS*)
    rootpxe_ci_stat(){ local info; info=$(command stat -c '%h' -- "$1"); printf '%s:0:600:%s\n' "$EUID" "$info"; }
    printf 'SKIP: MSYS private-mode proof; permission calls remain asserted\n'
;; esac
eval "$(sed -n '/^rootpxe_redact_diagnostic() {$/,/^}$/p' "$lib/funcs.sh")"
for field in cloudInitUserData cloudInitNetworkConfig; do
    diagnostic=$(jq -cn --arg field "$field" --arg data $'wifi-private-marker\nquoted "value"' '{($field):$data,other:"visible"}')
    redacted=$(rootpxe_redact_diagnostic "$diagnostic")
    [[ $redacted != *wifi-private-marker* && $redacted == *'[REDACTED]'* && $redacted == *visible* ]] || fail 'diagnostic leaked Cloud-init private JSON field'
    redacted=$(rootpxe_redact_diagnostic "$field='wifi-private-marker'")
    [[ $redacted != *wifi-private-marker* ]] || fail 'diagnostic leaked quoted Cloud-init private field'
done
taskType=deploy osid=50
rootpxe_stage(){ fail 'invalid private payload reached an injection stage'; }
userdata=$'#cloud-config\r\n# 原始字节\r\nruncmd:\r\n  - [echo, "secret-$(touch /tmp/never-execute)"]\r\n\r\n'
printf '%s' "$userdata" >"$tmp/original"
hash=$(sha256sum "$tmp/original"); hash=${hash%% *}
network=$'version: 2\r\n# Wi-Fi私密内容不得输出\r\nethernets:\r\n  enp1s0:\r\n    dhcp4: true\r\n\r\n'
printf '%s' "$network" >"$tmp/network-original"
network_hash=$(rootpxe_ci_hash "$tmp/network-original")
payload=$(jq -cn --arg data "$userdata" --arg hash "$hash" --arg network "$network" --arg networkHash "$network_hash" '{type:"deploy",osid:50,cloudInitUserData:$data,cloudInitUserDataSha256:$hash,cloudInitInstanceId:("rootpxe-"+("a"*32)),cloudInitHostname:"node-1",cloudInitNetworkConfig:$network,cloudInitNetworkConfigSha256:$networkHash}')
rootpxe_apply_json_cloud_init "$payload" || fail 'valid private response rejected'
cmp -s "$tmp/original" "$cloudInitUserDataFile" || fail 'user-data bytes changed'
[[ $(rootpxe_ci_hash "$cloudInitUserDataFile") == "$hash" ]] || fail 'hash changed'
[[ -n ${cloudInitNetworkConfigFile:-} ]] || fail 'network private handle missing'
cmp -s "$tmp/network-original" "$cloudInitNetworkConfigFile" || fail 'network-config bytes changed'
rootpxe_cloud_init_private_valid || fail 'network private proof rejected'
( rootpxe_cloud_init_private_valid ) && fail 'private files accepted across BASHPID boundary'
network_file=$cloudInitNetworkConfigFile
printf 'changed' >>"$network_file"
rootpxe_cloud_init_private_valid && fail 'tampered private network file accepted'
cp "$tmp/network-original" "$network_file"
network_inode=$(rootpxe_ci_inode "$network_file")
mv "$network_file" "$tmp/network-private-original"
cp "$tmp/network-original" "$network_file"
rootpxe_cloud_init_private_valid && fail 'replacement private network inode accepted'
rm -- "$network_file"
mv "$tmp/network-private-original" "$network_file"
[[ $(rootpxe_ci_inode "$network_file") == "$network_inode" ]] || fail 'fixture failed to restore private network inode'
ln "$network_file" "$tmp/network-private-link"
rootpxe_cloud_init_private_valid && fail 'hardlinked private network file accepted'
rm -- "$tmp/network-private-link"
eval "$(declare -f rootpxe_ci_stat | sed '1s/rootpxe_ci_stat/rootpxe_ci_fixture_original_stat/')"
rootpxe_ci_stat(){
    if [[ $1 == "$network_file" ]]; then
        case ${private_unsafe_metadata:-} in owner) printf '12345:0:600:1\n'; return;; mode) printf '%s:0:666:1\n' "$EUID"; return;; esac
    fi
    rootpxe_ci_fixture_original_stat "$@"
}
for private_unsafe_metadata in owner mode; do rootpxe_cloud_init_private_valid && fail "unsafe private network metadata accepted: $private_unsafe_metadata"; done
private_unsafe_metadata=''
rootpxe_cloud_init_private_valid || fail 'restored private network metadata rejected'
rm(){ [[ ${*: -1} != "$network_file" ]] || return 1; command rm "$@"; }
rootpxe_cloud_init_cleanup_private && fail 'network private unlink failure swallowed'
unset -f rm
rootpxe_apply_cloud_init && fail 'network unlink failure left an injectable payload'
[[ $rootpxe_deployment_identity_cloud_init_result == false ]] || fail 'failed network cleanup retained injection receipt'
if [[ -n ${cloudInitUserDataFile:-} ]]; then
    rootpxe_ci_private_file_valid "$network_file" "$cloudInitNetworkConfigSha256" "$rootpxe_cloud_init_network_private_inode" "$rootpxe_cloud_init_network_private_pid" network-config && command rm -- "$network_file"
    fail 'cleanup retained a deleted user-data handle'
fi
[[ -f $network_file && -n ${rootpxe_cloud_init_network_private_inode:-} ]] || fail 'failed unlink lost private network ownership evidence'
rootpxe_cloud_init_cleanup_private || fail 'private network cleanup could not retry safely'
[[ ! -e $network_file && -z ${cloudInitNetworkConfigFile:-} ]] || fail 'private network cleanup retained state'
rootpxe_apply_json_cloud_init "$payload" || fail 'private response after cleanup retry'
userdata_file=$cloudInitUserDataFile
rm(){ [[ ${*: -1} != "$userdata_file" ]] || return 1; command rm "$@"; }
rootpxe_cloud_init_cleanup_private && fail 'user-data private unlink failure swallowed'
unset -f rm
private_result=0
rootpxe_cloud_init_private_valid || private_result=$?
rootpxe_apply_cloud_init && fail 'user-data unlink failure left an injectable payload'
[[ $rootpxe_deployment_identity_cloud_init_result == false ]] || fail 'failed user-data cleanup retained injection receipt'
rootpxe_cloud_init_cleanup_private || fail 'user-data cleanup retry failed'
[[ $private_result != 0 ]] || fail 'partial cleanup left a reusable payload without its network-config'
rootpxe_apply_json_cloud_init "$payload" || fail 'private response after user-data cleanup retry'
[[ ! -e /tmp/never-execute ]] || fail 'user-data was executed'
for filter in 'del(.cloudInitInstanceId)' '.cloudInitUserDataSha256="bad"' '.cloudInitInstanceId="task-token"' '.cloudInitHostname="bad\nname"' '.cloudInitUserData="x"' '.cloudInitUserData=("x"*65537)' '.osid=9' '.type="capture"' '.cloudInitHostname=3' 'del(.cloudInitNetworkConfig)' 'del(.cloudInitNetworkConfigSha256)' 'del(.cloudInitNetworkConfig,.cloudInitNetworkConfigSha256)' '.cloudInitNetworkConfig=null' '.cloudInitNetworkConfig=3' '.cloudInitNetworkConfigSha256=false' '.cloudInitNetworkConfigSha256=""' '.cloudInitNetworkConfigSha256=("0"*64)' '.cloudInitNetworkConfig=""' '.cloudInitNetworkConfig="version: 2\u0000"' '.cloudInitNetworkConfig=("x"*65537)' '.cloudInitNetworkConfig=("中"*21846)'; do
    bad=$(jq -c "$filter" <<<"$payload")
    rootpxe_apply_json_cloud_init "$bad" >"$tmp/rejected-output" 2>&1 && fail "accepted malformed fields: $filter"
    [[ -z ${cloudInitUserDataFile:-} && -z ${cloudInitNetworkConfigFile:-} ]] || fail 'failed parse retained a usable private handle'
    [[ ! -s $tmp/rejected-output ]] || fail 'rejected private data was printed'
done
empty_payload=$(jq -c '.cloudInitNetworkConfig="" | .cloudInitNetworkConfigSha256=""' <<<"$payload")
rootpxe_apply_json_cloud_init "$empty_payload" || fail 'empty network pair rejected'
[[ -z ${cloudInitNetworkConfigFile:-} && -z ${cloudInitNetworkConfigSha256:-} ]] || fail 'empty network created private state'
rootpxe_cloud_init_cleanup_private || fail 'empty network private cleanup failed'
[[ ! -e $network_file ]] || fail 'private network file leaked after malformed response'
taskType=capture
rootpxe_apply_json_cloud_init "$payload" && fail 'capture accepted private data'
rootpxe_apply_json_cloud_init '{}' || fail 'empty capture must bypass'
taskType=deploy osid=9
rootpxe_apply_json_cloud_init '{}' || fail 'empty Windows must bypass'
taskType=deploy osid=50
rootpxe_apply_json_cloud_init '{}' || fail 'ordinary Linux must bypass'
[[ -z ${cloudInitUserDataFile:-} && -z ${cloudInitNetworkConfigFile:-} ]] || fail 'stale private handle retained'
checkin="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.checkin"
awk '/^rootpxe_json_get_string\(\)/,/^checkin_rootpxe\(\)/{if($0 ~ /^checkin_rootpxe\(\)/) exit; print}' "$checkin" >"$tmp/parser"
. "$tmp/parser"
rootpxe_deployment_identity_windows_hostname_capability_installed(){ return 1; }
rootpxe_deployment_identity_windows_sysprep_capability_installed(){ return 1; }
rootpxe_multicast_runtime_ready(){ return 1; }
taskid=1 task_token=private-token lmac=001122334455
rootpxe_write_checkin_json_payload "$tmp/request" || fail 'request generation failed'
jq -e '.cloudInitCapability=="linux-nocloud-v2" and (has("postDeployScriptCapability")|not) and all(.deploymentIdentityCapabilities[]; startswith("linux-")|not)' "$tmp/request" >/dev/null || fail 'obsolete or missing capabilities'
[[ $(grep -Fc 'cloudInitCapability=linux-nocloud-v2' "$lib/funcs.sh") == 2 ]] || fail 'scalar/batch disk permits did not upgrade capability'
for field in cloudInitNetworkConfig cloudInitNetworkConfigSha256; do
    policy_payload=$(jq -cn --arg field "$field" '{type:"deploy",osid:50,deploymentIdentityPolicy:{version:1,systemIdentity:{sysprep:false},cloudInit:false}} | .[$field]="private-wifi-marker"')
    rootpxe_apply_json_deployment_identity_policy "$policy_payload" >"$tmp/rejected-output" 2>&1 && fail 'disabled Cloud-init policy accepted network fields'
    [[ ! -s $tmp/rejected-output ]] || fail 'policy rejection leaked private network data'
done
for field in cloudInitUserData cloudInitUserDataSha256 cloudInitInstanceId cloudInitHostname cloudInitNetworkConfig cloudInitNetworkConfigSha256; do
    policy_payload=$(jq -cn --arg field "$field" '{type:"deploy",osid:50} | .[$field]="private-marker"')
    rootpxe_apply_json_deployment_identity_policy "$policy_payload" >"$tmp/rejected-output" 2>&1 && fail 'missing policy accepted Cloud-init private fields'
    [[ ! -s $tmp/rejected-output ]] || fail 'missing-policy rejection leaked private fields'
done
rootpxe_apply_json_deployment_identity_policy '{}' || fail 'ordinary task without policy must remain valid'
rootpxe_cloud_init_cleanup_private || fail 'private cleanup failed'
printf 'PASS: NoCloud v2 six-field protocol, private network proofs/cleanup failure invalidation, raw bytes/empty pair, no execution or leakage\n'
