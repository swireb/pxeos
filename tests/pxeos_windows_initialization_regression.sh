#!/usr/bin/env bash
# Real hivex/reged/xmlstarlet regression for the Windows hostname/Sysprep
# matrix.  changeHostname and Sysprep are the only two controls.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
native="$root/tests/pxeos_windows_hostname_native_regression.sh"
tool=${ROOTPXE_WINDOWS_HOSTNAME_TOOL:-}; minimal=${ROOTPXE_HIVEX_MINIMAL:-}; reged=${ROOTPXE_REGED:-}
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_fail(){ if "$@" >/dev/null 2>&1; then fail "expected failure: $*"; fi; }
[[ -x $tool && -x $reged && -f $minimal ]] || fail 'set ROOTPXE_WINDOWS_HOSTNAME_TOOL, ROOTPXE_REGED and ROOTPXE_HIVEX_MINIMAL'
command -v xmlstarlet >/dev/null || fail 'xmlstarlet is required'
jq_real=$(command -v jq) || fail 'jq is required'
[[ ! -e /ntfs ]] || fail '/ntfs exists; refuse to touch a non-test mount'
tmp=$(mktemp -d); trap 'rm -rf "$tmp" /ntfs' EXIT

# Reuse the native regression's legal two-ControlSet hivex fixture.
sed -n '/^cat >"\$fixture_source" <<'"'"'EOF'"'"'$/,/^EOF$/ { /^cat >"\$fixture_source"/d; /^EOF$/d; p; }' "$native" >"$tmp/fixture.c"
[[ -s $tmp/fixture.c ]] || fail 'fixture extraction failed'
${CC:-cc} -std=c11 -D_FILE_OFFSET_BITS=64 -Wall -Wextra -Werror ${CPPFLAGS:-} $(pkg-config --cflags hivex) -o "$tmp/fixture" "$tmp/fixture.c" ${LDFLAGS:-} $(pkg-config --libs hivex)
mkdir -p "$tmp/bin" "$tmp/source/Windows/System32/config" "$tmp/source/Windows/System32/Sysprep"
"$tmp/fixture" "$minimal" "$tmp/source/Windows/System32/config/SYSTEM"
ln -s "$tool" "$tmp/bin/rootpxe-offline-identities"; ln -s "$reged" "$tmp/bin/reged"
cat >"$tmp/bin/jq" <<'EOF'
#!/usr/bin/env bash
exec "${ROOTPXE_TEST_REAL_JQ:?}" "$@"
EOF
cat >"$tmp/bin/ntfs-3g" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
src=${@: -2:1}; dest=${@: -1}; mkdir -p "$dest"; find "$dest" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; cp -a "$src/." "$dest/"
EOF
cat >"$tmp/bin/umount" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/bin/jq" "$tmp/bin/ntfs-3g" "$tmp/bin/umount"; export PATH="$tmp/bin:$PATH" ROOTPXE_TEST_REAL_JQ="$jq_real"
awk '/^rootpxe_change_hostname_registry\(\)/ {p=1} p {print} p && /^}$/ {exit}' "$funcs" >"$tmp/functions.sh"
awk '/^rootpxe_validate_windows_hostname\(\)/ {p=1} p {print} p && /^}$/ {exit}' "$funcs" >>"$tmp/functions.sh"
awk '/^rootpxe_apply_windows_hostname\(\)/ {p=1} p {print} p && /^}$/ {exit}' "$funcs" >>"$tmp/functions.sh"
source "$tmp/functions.sh"; rootpxe_stage(){ :; }
policy="$tmp/policy.json"; private="$tmp/private.json"; deploymentIdentityPolicyFile=$policy; rootpxe_deployment_initialization_private_file=$private
output_xml=/ntfs/Windows/System32/Sysprep/unattend.xml
write_private(){ printf '{"unattendXml":%s}' "$(printf '%s' "$1" | jq -Rs .)" >"$private"; }
write_policy(){ printf '{"systemIdentity":{"sysprep":%s}}' "$1" >"$policy"; }
assert_registry(){ rootpxe-offline-identities windows-hostname-verify /ntfs/Windows/System32/config/SYSTEM "$1" || fail "registry did not contain $1"; }
assert_xml_names(){ local expected="$1" count="$2" got actual; got=$(xmlstarlet sel -t -m "/*[local-name()='unattend']/*[local-name()='settings'][@pass='specialize']/*[local-name()='component'][@name='Microsoft-Windows-Shell-Setup']/*[local-name()='ComputerName']" -v . -n "$output_xml" | sort -u); actual=$(xmlstarlet sel -t -m "/*[local-name()='unattend']/*[local-name()='settings'][@pass='specialize']/*[local-name()='component'][@name='Microsoft-Windows-Shell-Setup']/*[local-name()='ComputerName']" -v . -n "$output_xml" | wc -l | tr -d ' '); [[ $got == "$expected" && $actual == "$count" ]] || fail "XML expected $count copies of $expected, got $actual: $got"; }

# OFF/OFF does not mount or modify either registry or unattend XML.
printf 'sentinel' >"$tmp/source/Windows/System32/Sysprep/unattend.xml"; write_policy false; changeHostname=false; hostName=''
rootpxe_apply_windows_hostname "$tmp/source" || fail 'OFF/OFF rejected'
[[ $(cat "$tmp/source/Windows/System32/Sysprep/unattend.xml") == sentinel ]] || fail 'OFF/OFF touched XML'

# ON/OFF uses the direct registry path and never parses existing XML.
printf 'bad xml' >"$tmp/source/Windows/System32/Sysprep/unattend.xml"; changeHostname=true; hostName=HOST-ONE
rootpxe_apply_windows_hostname "$tmp/source" || fail 'ON/OFF failed'; assert_registry HOST-ONE
[[ $(cat "$tmp/source/Windows/System32/Sysprep/unattend.xml") == 'bad xml' ]] || fail 'ON/OFF touched XML'

# OFF/ON writes the supplied custom XML byte-for-byte and cannot invoke reged.
xml='<?xml version="1.0"?><unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"><ComputerName>USER</ComputerName></component></settings></unattend>'
printf '%s' "$xml" >"$tmp/expected.xml"; write_private "$xml"; write_policy true; changeHostname=false; hostName=''
mv "$tmp/bin/reged" "$tmp/bin/reged.real"; printf '#!/usr/bin/env bash\nexit 97\n' >"$tmp/bin/reged"; chmod +x "$tmp/bin/reged"
rootpxe_apply_windows_hostname "$tmp/source" || fail 'OFF/ON failed'; cmp -s "$tmp/expected.xml" "$output_xml" || fail 'OFF/ON changed supplied XML'

# ON/ON must update only the Shell-Setup ComputerName in the supplied XML,
# and must not use the direct registry route.
multi_xml='<?xml version="1.0"?><unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"><ComputerName>AMD</ComputerName></component><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64"></component></settings></unattend>'
write_private "$multi_xml"; changeHostname=true; hostName=TASK-MULTI
rootpxe_apply_windows_hostname "$tmp/source" || fail 'ON/ON failed'; assert_xml_names TASK-MULTI 2
rm "$tmp/bin/reged"; mv "$tmp/bin/reged.real" "$tmp/bin/reged"

# A malformed specialize shell setup is rejected before it can be published.
bad_xml='<?xml version="1.0"?><unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"><ComputerName>A</ComputerName><ComputerName>B</ComputerName></component></settings></unattend>'
write_private "$bad_xml"; changeHostname=true; hostName=TASK-BAD; expect_fail rootpxe_apply_windows_hostname "$tmp/source"

# A direct-registry write or its native readback failure is fail-closed.
write_policy false; mv "$tmp/bin/reged" "$tmp/bin/reged.real"; printf '#!/usr/bin/env bash\nexit 3\n' >"$tmp/bin/reged"; chmod +x "$tmp/bin/reged"; changeHostname=true; hostName=REG-FAIL; expect_fail rootpxe_change_hostname_registry "$tmp/source"
rm "$tmp/bin/reged"; mv "$tmp/bin/reged.real" "$tmp/bin/reged"
printf 'PASS: production Windows hostname/Sysprep matrix regression\n'
