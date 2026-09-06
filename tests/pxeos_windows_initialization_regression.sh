#!/usr/bin/env bash
# Real hivex/reged/xmlstarlet regression for the production Windows initializer.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
native="$root/tests/pxeos_windows_hostname_native_regression.sh"
tool=${ROOTPXE_WINDOWS_HOSTNAME_TOOL:-}
minimal=${ROOTPXE_HIVEX_MINIMAL:-}
reged=${ROOTPXE_REGED:-}
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_fail(){ if "$@" >/dev/null 2>&1; then fail "expected failure: $*"; fi; }
[[ -x $tool && -x $reged && -f $minimal ]] || fail 'set ROOTPXE_WINDOWS_HOSTNAME_TOOL, ROOTPXE_REGED and ROOTPXE_HIVEX_MINIMAL'
command -v xmlstarlet >/dev/null || fail 'xmlstarlet is required'
jq_real=$(command -v jq) || fail 'jq is required'
jq_windows_native=0
case $(uname -s) in
    CYGWIN*|MINGW*|MSYS*)
        if command -v ldd >/dev/null 2>&1 && ! ldd "$jq_real" 2>&1 | grep -qiE 'cygwin1\.dll|msys-2\.0\.dll'; then
            jq_windows_native=1
        fi
        ;;
esac
export ROOTPXE_TEST_REAL_JQ="$jq_real" ROOTPXE_TEST_WINDOWS_NATIVE_JQ="$jq_windows_native"
[[ ! -e /ntfs ]] || fail '/ntfs exists; refuse to touch a non-test mount'
tmp=$(mktemp -d); trap 'rm -rf "$tmp" /ntfs' EXIT
# Reuse the native regression's legal two-ControlSet hivex fixture.
sed -n '/^cat >"\$fixture_source" <<'"'"'EOF'"'"'$/,/^EOF$/ { /^cat >"\$fixture_source"/d; /^EOF$/d; p; }' "$native" >"$tmp/fixture.c"
[[ -s $tmp/fixture.c ]] || fail 'fixture extraction failed'
${CC:-cc} -std=c11 -D_FILE_OFFSET_BITS=64 -Wall -Wextra -Werror ${CPPFLAGS:-} $(pkg-config --cflags hivex) -o "$tmp/fixture" "$tmp/fixture.c" ${LDFLAGS:-} $(pkg-config --libs hivex)
mkdir -p "$tmp/bin" "$tmp/source/Windows/System32/config" "$tmp/source/Windows/System32/Sysprep"
"$tmp/fixture" "$minimal" "$tmp/source/Windows/System32/config/SYSTEM"
ln -s "$tool" "$tmp/bin/rootpxe-offline-identities"; ln -s "$reged" "$tmp/bin/reged"
# Linux and Cygwin/MSYS jq execute directly. A native Windows jq needs binary
# stdout and Windows paths; PXEOS itself always uses the normal Linux path.
cat >"$tmp/bin/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -n ${ROOTPXE_TEST_REAL_JQ:-} ]] || exit 127
if [[ ${ROOTPXE_TEST_WINDOWS_NATIVE_JQ:-0} != 1 ]]; then
    exec "$ROOTPXE_TEST_REAL_JQ" "$@"
fi
args=()
for arg in "$@"; do
    if [[ $arg == /* && -e $arg ]]; then
        args+=("$(cygpath -w "$arg")")
    else
        args+=("$arg")
    fi
done
exec "$ROOTPXE_TEST_REAL_JQ" -b "${args[@]}"
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
chmod +x "$tmp/bin/jq" "$tmp/bin/ntfs-3g" "$tmp/bin/umount"; PATH="$tmp/bin:$PATH"
# Extract the production functions, preserving implementation rather than reimplementing it.
awk '/^rootpxe_change_hostname_registry\(\)/ {p=1} p {print} p && /^}$/ {exit}' "$funcs" >"$tmp/functions.sh"
awk '/^rootpxe_validate_windows_hostname\(\)/ {p=1} p {print} p && /^}$/ {exit}' "$funcs" >>"$tmp/functions.sh"
awk '/^rootpxe_apply_windows_hostname\(\)/ {p=1} p {print} p && /^}$/ {exit}' "$funcs" >>"$tmp/functions.sh"
source "$tmp/functions.sh"; rootpxe_stage(){ :; }
policy="$tmp/policy.json"; private="$tmp/private.json"; deploymentIdentityPolicyFile=$policy; rootpxe_deployment_initialization_private_file=$private
output_xml=/ntfs/Windows/System32/Sysprep/unattend.xml
write_private() {
    printf '{"unattendXml":%s}' "$(printf '%s' "$1" | jq -Rs .)" >"$private"
}
write_policy() {
    printf '{"systemIdentity":{"sysprep":true,"sysprepComputerNameMode":"%s"}}' "$1" >"$policy"
}
assert_registry() {
    rootpxe-offline-identities windows-hostname-verify /ntfs/Windows/System32/config/SYSTEM "$1" || fail "registry did not contain $1 in every selected ControlSet"
}
assert_platform_names() {
    local expected="$1" count="$2" got actual_count
    got=$(xmlstarlet sel -t -m "/*[local-name()='unattend']/*[local-name()='settings'][@pass='specialize']/*[local-name()='component'][@name='Microsoft-Windows-Shell-Setup']/*[local-name()='ComputerName']" -v . -n "$output_xml" | sort -u)
    actual_count=$(xmlstarlet sel -t -m "/*[local-name()='unattend']/*[local-name()='settings'][@pass='specialize']/*[local-name()='component'][@name='Microsoft-Windows-Shell-Setup']/*[local-name()='ComputerName']" -v . -n "$output_xml" | wc -l | tr -d ' ')
    [[ $got == "$expected" && $actual_count == "$count" ]] || fail "platform XML expected $count copies of $expected, got $actual_count: $got"
}
# hostname-only must not parse or repair a pre-existing malformed unattend.xml.
printf 'bad xml' >"$tmp/source/Windows/System32/Sysprep/unattend.xml"
printf '{"systemIdentity":{"sysprep":false}}' >"$policy"; changeHostname=true; hostName=HOST-ONE
rootpxe_apply_windows_hostname "$tmp/source" || fail 'hostname-only failed'
assert_registry HOST-ONE
[[ $(cat "$tmp/source/Windows/System32/Sysprep/unattend.xml") == 'bad xml' ]] || fail 'hostname-only touched XML'
# Sysprep-only XML mode is byte-for-byte and must not call reged.
xml='<?xml version="1.0"?><unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"><ComputerName>USER</ComputerName></component></settings></unattend>'
printf '%s' "$xml" >"$tmp/expected.xml"
mv "$tmp/bin/reged" "$tmp/bin/reged.real"
printf '#!/usr/bin/env bash\nexit 97\n' >"$tmp/bin/reged"; chmod +x "$tmp/bin/reged"
write_private "$xml"; write_policy xml; changeHostname=false; hostName=''
rootpxe_apply_windows_hostname "$tmp/source" || fail 'sysprep-only xml failed'
cmp -s "$tmp/expected.xml" "$output_xml" || fail 'xml mode changed bytes'
rm "$tmp/bin/reged"; mv "$tmp/bin/reged.real" "$tmp/bin/reged"
# Platform mode updates every architecture-specific Shell-Setup component.
multi_xml='<?xml version="1.0"?><unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"><ComputerName>AMD</ComputerName></component><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64"><ComputerName>ARM</ComputerName></component></settings></unattend>'
write_private "$multi_xml"; write_policy platform; changeHostname=false; hostName=TASK-MULTI
rootpxe_apply_windows_hostname "$tmp/source" || fail 'sysprep-only platform failed'
assert_platform_names TASK-MULTI 2
# A component with no ComputerName must receive one; other architectures still update.
count_zero_xml='<?xml version="1.0"?><unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"></component><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64"><ComputerName>ARM</ComputerName></component></settings></unattend>'
write_private "$count_zero_xml"; write_policy platform; changeHostname=false; hostName=TASK-ZERO
rootpxe_apply_windows_hostname "$tmp/source" || fail 'platform did not add missing ComputerName'
assert_platform_names TASK-ZERO 2
# Invalid platform templates must fail before a misleading partial customization.
duplicate_xml='<?xml version="1.0"?><unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"><ComputerName>A</ComputerName><ComputerName>B</ComputerName></component></settings></unattend>'
write_private "$duplicate_xml"; write_policy platform; changeHostname=false; hostName=TASK-DUP
expect_fail rootpxe_apply_windows_hostname "$tmp/source"
missing_component_xml='<?xml version="1.0"?><unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="specialize"><component name="Other-Component" processorArchitecture="amd64"><ComputerName>A</ComputerName></component></settings></unattend>'
write_private "$missing_component_xml"; write_policy platform; changeHostname=false; hostName=TASK-MISS
expect_fail rootpxe_apply_windows_hostname "$tmp/source"
wrong_namespace_xml='<?xml version="1.0"?><unattend xmlns="urn:rootpxe-invalid"><settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"><ComputerName>A</ComputerName></component></settings></unattend>'
write_private "$wrong_namespace_xml"; write_policy platform; changeHostname=false; hostName=TASK-NS
expect_fail rootpxe_apply_windows_hostname "$tmp/source"
# Registry and XML settings are independent: XML mode keeps the user-provided name.
write_private "$xml"; write_policy xml; changeHostname=true; hostName=REG-XML
rootpxe_apply_windows_hostname "$tmp/source" || fail 'hostname plus XML Sysprep failed'
assert_registry REG-XML
cmp -s "$tmp/expected.xml" "$output_xml" || fail 'XML mode changed user-selected ComputerName with hostname enabled'
# Platform mode uses the task hostname while the registry update follows the same name.
write_private "$multi_xml"; write_policy platform; changeHostname=true; hostName=REG-PLATFORM
rootpxe_apply_windows_hostname "$tmp/source" || fail 'hostname plus platform Sysprep failed'
assert_registry REG-PLATFORM
assert_platform_names REG-PLATFORM 2
# A failing reged process, and a failed native post-write verification, both fail closed.
mv "$tmp/bin/reged" "$tmp/bin/reged.real"
printf '#!/usr/bin/env bash\nexit 3\n' >"$tmp/bin/reged"; chmod +x "$tmp/bin/reged"
changeHostname=true; hostName=REG-FAIL
expect_fail rootpxe_change_hostname_registry "$tmp/source"
rm "$tmp/bin/reged"; mv "$tmp/bin/reged.real" "$tmp/bin/reged"
mv "$tmp/bin/rootpxe-offline-identities" "$tmp/bin/rootpxe-offline-identities.real"
cat >"$tmp/bin/rootpxe-offline-identities" <<EOF
#!/usr/bin/env bash
if [[ \$1 == windows-hostname-inspect ]]; then exec "$tool" "\$@"; fi
exit 1
EOF
chmod +x "$tmp/bin/rootpxe-offline-identities"
expect_fail rootpxe_change_hostname_registry "$tmp/source"
rm "$tmp/bin/rootpxe-offline-identities"; mv "$tmp/bin/rootpxe-offline-identities.real" "$tmp/bin/rootpxe-offline-identities"
printf 'PASS: production Windows initialization hostname/Sysprep regression\n'
