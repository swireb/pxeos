#!/usr/bin/env bash
# Exercise the production Sysprep XML path with private files and command
# mocks only.  It never mounts a real filesystem or touches a block device.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_fail() { if "$@" >/dev/null 2>&1; then fail "expected failure: $*"; fi; }

for config in "$root/configs/fsx64.config" "$root/configs/fsx86.config" "$root/configs/fsarm64.config"; do
    grep -Fxq 'BR2_PACKAGE_XMLSTARLET=y' "$config" || fail "XMLStarlet package disabled in $config"
done
! grep -Fq 'xmlstarlet ' "$funcs" || fail 'production Sysprep path still invokes xmlstarlet'
grep -Fq 'xml val -w "$xml_tmp"' "$funcs" || fail 'production XML validation does not invoke xml'
grep -Fq 'rows=$(xml sel ' "$funcs" || fail 'production XML selection does not invoke xml'
grep -Fq 'xml ed -L ' "$funcs" || fail 'production XML editing does not invoke xml'

mkdir -p "$tmp/bin" "$tmp/source/Windows/System32/Sysprep"
cat >"$tmp/bin/jq" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *' -e '*) exit 0 ;;
    *' -j '*) for last; do :; done; cat "$last" ;;
    *) exit 1 ;;
esac
EOF
cat >"$tmp/bin/ntfs-3g" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source=${@: -2:1}
target=${@: -1}
mkdir -p "$target"
cp -a "$source/." "$target/"
EOF
cat >"$tmp/bin/umount" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$tmp/bin/xml" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$XML_TRACE"
[[ ${XML_FAIL:-} != "$1" ]] || exit 73
case "$1" in
    val) exit 0 ;;
    sel)
        case " $* " in
            *'count('* ) printf 'amd64|0\n' ;;
            *) printf '%s\n' PXEHOST ;;
        esac
        ;;
    ed)
        for last; do :; done
        printf '<unattend>PXEHOST</unattend>' >"$last"
        ;;
    *) exit 74 ;;
esac
EOF
chmod +x "$tmp/bin/jq" "$tmp/bin/ntfs-3g" "$tmp/bin/umount" "$tmp/bin/xml"

awk '/^rootpxe_validate_windows_hostname\(\)/ {p=1} p {print} p && /^}$/ {exit}' "$funcs" >"$tmp/functions.sh"
awk '/^rootpxe_apply_windows_hostname\(\)/ {p=1} p {print} p && /^}$/ {exit}' "$funcs" | sed -e "s|/tmp/ntfs-mount-output|$tmp/mount-output|g" -e "s|/ntfs|$tmp/ntfs|g" >>"$tmp/functions.sh"
source "$tmp/functions.sh"
rootpxe_stage() { :; }

policy="$tmp/policy.json"
private="$tmp/private.xml"
printf '{"systemIdentity":{"sysprep":true}}\n' >"$policy"
printf '%s\n' '<unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"/></settings></unattend>' >"$private"
deploymentIdentityPolicyFile="$policy"
rootpxe_deployment_initialization_private_file="$private"
changeHostname=true
hostName=PXEHOST
export PATH="$tmp/bin:$PATH"
XML_TRACE="$tmp/xml.trace"
export XML_TRACE

rootpxe_apply_windows_hostname "$tmp/source" || fail 'Sysprep XML path rejected fixed xml command'
grep -Eq '^val -w .+' "$XML_TRACE" || fail 'xml val arguments were not forwarded'
grep -Eq '^sel -t -m .+count\(' "$XML_TRACE" || fail 'xml sel discovery arguments were not forwarded'
grep -Eq '^ed -L -s .+ -t elem -n ComputerName -v PXEHOST ' "$XML_TRACE" || fail 'xml ed arguments were not forwarded'
[[ $(grep -Ec '^sel -t -m ' "$XML_TRACE") -eq 2 ]] || fail 'xml sel verification call missing'

: >"$XML_TRACE"
XML_FAIL=val
export XML_FAIL
expect_fail rootpxe_apply_windows_hostname "$tmp/source"
grep -Eq '^val -w .+' "$XML_TRACE" || fail 'xml val failure was not exercised'

printf 'PASS: PXEOS XML command runtime regression\n'
