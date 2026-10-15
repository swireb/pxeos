#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/task-http-test-support.sh"
export TASK_HTTP_TEST_EXPAND_JSON=yes
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

source "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/deployment-identity.sh"

# Buildroot's XMLStarlet package installs the CLI as `xml`.  The capability
# gate must test that exact runtime contract, rather than accepting another
# host-provided command name.
xml_capability_bin="$tmp/xml-capability-bin"
mkdir -p "$xml_capability_bin"
cat >"$xml_capability_bin/jq" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$xml_capability_bin/ntfs-3g" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$xml_capability_bin/jq" "$xml_capability_bin/ntfs-3g"
if (PATH="$xml_capability_bin"; rootpxe_deployment_identity_windows_sysprep_capability_installed); then
    fail 'Sysprep capability accepted without the Buildroot xml command'
fi
cat >"$xml_capability_bin/xml" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$xml_capability_bin/xml"
(PATH="$xml_capability_bin"; rootpxe_deployment_identity_windows_sysprep_capability_installed) || fail 'Sysprep capability rejected the Buildroot xml command'

for config in "$root/configs/fsx64.config" "$root/configs/fsx86.config" "$root/configs/fsarm64.config"; do
    grep -Fxq 'BR2_PACKAGE_XMLSTARLET=y' "$config" || fail "XMLStarlet package disabled in $config"
done

policy="$tmp/policy"
deploymentIdentityPolicyFile="$policy"
osid=50 changeHostname=false
printf '%s\n' '{"version":1,"systemIdentity":{"sysprep":false},"cloudInit":true}' >"$policy"
rootpxe_deployment_identity_policy_enabled || fail 'Cloud-init plan gate rejected'
rootpxe_deployment_identity_private_enabled && fail 'Linux must not fetch Windows XML'
printf '%s\n' '{"version":1,"systemIdentity":{"sysprep":true},"cloudInit":false}' >"$policy"
osid=9
rootpxe_deployment_identity_windows_policy_enabled || fail 'Windows Sysprep policy rejected'
rootpxe_deployment_identity_private_enabled || fail 'Sysprep private payload gate rejected'
printf '%s\n' '{"version":1,"systemIdentity":{"sysprep":false},"cloudInit":false}' >"$policy"
changeHostname=true
rootpxe_deployment_identity_policy_enabled || fail 'Windows name-only gate rejected'
captured="$tmp/request"
curl(){
    task_http_test_decode_curl_args "$@"; set -- "${task_http_test_curl_args[@]}"
    printf '%s' '{"plan":{"version":1,"planId":"plan-1"},"planHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","attempt":3}'
    printf '\n200'
}
pxeapi=https://example.invalid/service/ taskid=7 task_token=private-token mac=001122334455 progress_attempt=3
rootpxe_deployment_identity_request_plan || fail 'plan request failed'
curl(){
    task_http_test_decode_curl_args "$@"; set -- "${task_http_test_curl_args[@]}"
    while (($#)); do
        if [[ $1 == --data-binary ]]; then printf '%s' "$2" >"$captured"; shift 2; continue; fi
        shift
    done
    printf '\n200'
}
rootpxe_deployment_identity_report_result true false false || fail 'result rejected'
jq -e '.taskId==7 and .attempt==3 and .planId=="plan-1" and .result=={hostname:true,sysprep:false,cloudInit:false}' "$captured" >/dev/null || fail 'result fields or binding changed'
printf '%s\n' '{"version":1,"systemIdentity":{"sysprep":true},"cloudInit":false}' >"$policy"
changeHostname=false
curl(){ task_http_test_decode_curl_args "$@"; printf '{"version":1,"unattendXml":"<unattend>fixture</unattend>"}\n200'; }
rootpxe_deployment_identity_request_private || fail 'Windows-only XML payload rejected'
jq -e 'keys==["unattendXml","version"] and .unattendXml=="<unattend>fixture</unattend>"' "$rootpxe_deployment_initialization_private_file" >/dev/null || fail 'private payload contains extra material'
rootpxe_deployment_identity_cleanup_private
osid=50
rootpxe_deployment_identity_private_enabled && fail 'Linux fetched private XML'
rm -f -- "$rootpxe_deployment_identity_plan_file"
printf 'PASS: Windows capability, native Cloud-init plan gate and three-field result\n'
