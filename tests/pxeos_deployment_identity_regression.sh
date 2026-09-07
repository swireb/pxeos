#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

source "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/deployment-identity.sh"

policy="$tmp/policy"
deploymentIdentityPolicyFile="$policy"
osid=50
printf '%s\n' '{"version":1,"systemIdentity":{"machineId":true,"sshHostKeys":true}}' >"$policy"
changeHostname=false
rootpxe_deployment_identity_policy_enabled || fail 'Linux initialization policy was rejected'
rootpxe_deployment_identity_linux_policy_enabled || fail 'Linux policy was not selected'
rootpxe_deployment_identity_private_enabled && fail 'non-secret policy requested private payload'

printf '%s\n' '{"version":1,"systemIdentity":{"sysprep":true}}' >"$policy"
osid=9
rootpxe_deployment_identity_windows_policy_enabled || fail 'Windows Sysprep policy was rejected'
rootpxe_deployment_identity_private_enabled || fail 'Sysprep must request its private payload'

printf '%s\n' '{"version":1,"systemIdentity":{}}' >"$policy"
changeHostname=true
rootpxe_deployment_identity_policy_enabled || fail 'computer-name-only policy was rejected'

mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s' '{"plan":{"version":1,"planId":"plan-1"},"planHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","attempt":3}'
printf '\n200'
EOF
chmod +x "$tmp/bin/curl"
PATH="$tmp/bin:$PATH"
pxeapi=https://example.invalid/service/
taskid=7
task_token=token
mac=001122334455
progress_attempt=3
rootpxe_deployment_identity_request_plan
jq -e '.plan | (has("topology") | not) and (has("disks") | not) and (has("systemIdentity") | not)' "$rootpxe_deployment_identity_plan_file" >/dev/null || fail 'plan included generated system identity data'

captured="$tmp/result.json"
curl() {
    local data
    while (($#)); do
        if [[ $1 == --data-binary ]]; then data=$2; shift 2; continue; fi
        shift
    done
    printf '%s' "$data" >"$captured"
    printf '\n200'
}
rootpxe_deployment_identity_report_result true true true false false false || fail 'result report failed'
jq -e '.result | has("hostname") and has("machineId") and has("sshHostKeys") and (has("storage") | not)' "$captured" >/dev/null || fail 'result carried removed identity data'

printf 'PASS: deployment initialization plan/result omit disk identity data\n'
