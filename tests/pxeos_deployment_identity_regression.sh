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

# The management service deliberately transports rootPassword as plaintext, but
# PXEOS must never retain that value in its private payload.  The receive
# boundary hashes it through stdin, retaining only rootPasswordHash for the
# existing Linux consumer.
private_policy="$tmp/private-policy.json"
printf '%s\n' '{"version":1,"systemIdentity":{"sshLoginPublicKeys":true,"rootPassword":true}}' >"$private_policy"
deploymentIdentityPolicyFile="$private_policy"
rootpxe_deployment_initialization_private_file=''
mkpasswd_args="$tmp/mkpasswd.args"
mktemp_templates="$tmp/mktemp.templates"
mktemp_paths="$tmp/mktemp.paths"
mktemp() {
    local path
    printf '%s\n' "$1" >>"$mktemp_templates"
    path=$(command mktemp "$@") || return 1
    printf '%s\n' "$path" >>"$mktemp_paths"
    printf '%s\n' "$path"
}
cat >"$tmp/bin/mkpasswd" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$ROOTPXE_MKPASSWD_ARGS"
IFS= read -r secret || true
[[ $secret == 'eight-char-password' ]] || exit 91
printf '%s\n' '$6$fixedsalt$fixedhash'
EOF
chmod +x "$tmp/bin/mkpasswd"
curl() {
    printf '%s' '{"version":1,"sshLoginPublicKeys":["ssh-ed25519 AAAA test"],"rootPassword":"eight-char-password","unattendXml":""}'
    printf '\n200'
}
ROOTPXE_MKPASSWD_ARGS="$mkpasswd_args" rootpxe_deployment_identity_request_private || fail 'plaintext private payload was not normalized'
private_file="$rootpxe_deployment_initialization_private_file"
[[ -f $private_file && ! -L $private_file ]] || fail 'normalized private payload must be a regular file'
if [[ $(uname -s) == Linux ]]; then
    [[ $(stat -c %a "$private_file") == 600 ]] || fail 'normalized private payload must be 0600'
else
    # Git Bash maps chmod through NTFS ACLs and reports 0644 even after a
    # successful chmod 0600; the Linux runtime check remains authoritative.
    printf 'SKIP: Git Bash cannot faithfully report private-file mode\n'
fi
jq -e '.version == 1 and (.sshLoginPublicKeys | type == "array") and .rootPasswordHash == "$6$fixedsalt$fixedhash" and .unattendXml == "" and (has("rootPassword") | not)' "$private_file" >/dev/null || fail 'private payload retained plaintext or omitted hash'
[[ $(cat "$mkpasswd_args") == $'-m\nsha512\n-P\n0' ]] || fail 'mkpasswd must receive only sha512 stdin options'
! grep -Fq 'eight-char-password' "$mkpasswd_args" "$private_file" || fail 'plaintext password leaked into argument capture or normalized payload'
rootpxe_deployment_identity_cleanup_private
! grep -Fq 'rootpxe-deployment-initialization.raw.' "$mktemp_templates" || fail 'private request created a plaintext raw temporary file'
while IFS= read -r path; do [[ ! -e $path && ! -L $path ]] || fail "private temporary file was not cleaned: $path"; done <"$mktemp_paths"

# Services always include rootPassword as a string.  It may be empty when the
# root-password option is disabled, and that must not invoke the hasher.
printf '%s\n' '{"version":1,"systemIdentity":{"sshLoginPublicKeys":true}}' >"$private_policy"
deploymentIdentityPolicyFile="$private_policy"
rm -f -- "$mkpasswd_args"
curl() {
    printf '%s' '{"version":1,"sshLoginPublicKeys":["ssh-ed25519 AAAA test"],"rootPassword":"","unattendXml":""}'
    printf '\n200'
}
ROOTPXE_MKPASSWD_ARGS="$mkpasswd_args" rootpxe_deployment_identity_request_private || fail 'empty unselected rootPassword was rejected'
private_file="$rootpxe_deployment_initialization_private_file"
jq -e '.rootPasswordHash == "" and (has("rootPassword") | not)' "$private_file" >/dev/null || fail 'unselected password payload was not normalized'
[[ ! -e $mkpasswd_args ]] || fail 'unselected password unexpectedly invoked mkpasswd'
rootpxe_deployment_identity_cleanup_private

# A hashing failure must leave no private-file handle or temporary artifact.
cat >"$tmp/bin/mkpasswd" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 92
EOF
chmod +x "$tmp/bin/mkpasswd"
printf '%s\n' '{"version":1,"systemIdentity":{"rootPassword":true}}' >"$private_policy"
deploymentIdentityPolicyFile="$private_policy"
rootpxe_deployment_initialization_private_file=''
curl() {
    printf '%s' '{"version":1,"sshLoginPublicKeys":[],"rootPassword":"eight-char-password","unattendXml":""}'
    printf '\n200'
}
if rootpxe_deployment_identity_request_private; then fail 'mkpasswd failure unexpectedly succeeded'; fi
[[ -z ${rootpxe_deployment_initialization_private_file:-} ]] || fail 'mkpasswd failure left private-file handle'
while IFS= read -r path; do [[ ! -e $path && ! -L $path ]] || fail "failed private request left temporary file: $path"; done <"$mktemp_paths"
unset -f mktemp

printf 'PASS: deployment initialization plan/result omit disk identity data\n'
