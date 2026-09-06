#!/usr/bin/env bash
# Native read-only hostname CLI regression.  reged performs the real fixture
# write; the rootpxe binary is only allowed to inspect and verify the hive.
set -euo pipefail

tool=${ROOTPXE_WINDOWS_HOSTNAME_TOOL:-/usr/sbin/rootpxe-offline-identities}
minimal=${ROOTPXE_HIVEX_MINIMAL:-}
reged=${ROOTPXE_REGED:-}
cc=${CC:-cc}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_fail() {
    if "$@" >/dev/null 2>&1; then
        fail "expected rejection: $*"
    fi
}

[[ -x $tool ]] || fail "missing built tool: $tool"
[[ -n $minimal && -f $minimal ]] || fail 'set ROOTPXE_HIVEX_MINIMAL to hivex upstream images/minimal'
[[ -n $reged && -x $reged ]] || fail 'set ROOTPXE_REGED to a real reged binary'

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fixture_source=$tmp/hostname-fixture.c
fixture_tool=$tmp/hostname-fixture

cat >"$fixture_source" <<'EOF'
#include <errno.h>
#include <fcntl.h>
#include <hivex.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void fail(const char *message) { perror(message); exit(1); }
static hive_node_h add(hive_h *hive, hive_node_h parent, const char *name) {
    hive_node_h node = hivex_node_add_child(hive, parent, name);
    if (!node) fail("add hive node");
    return node;
}
static void dword(hive_h *hive, hive_node_h node, const char *key, unsigned value) {
    unsigned char data[4] = { (unsigned char)value, (unsigned char)(value >> 8),
                              (unsigned char)(value >> 16), (unsigned char)(value >> 24) };
    struct hive_set_value record = { .key = (char *)key, .t = hive_t_dword,
                                     .len = sizeof(data), .value = (char *)data };
    if (hivex_node_set_value(hive, node, &record, 0)) fail("set dword");
}
static void string(hive_h *hive, hive_node_h node, const char *key, const char *value) {
    unsigned char data[32] = {0};
    size_t length = strlen(value), i;
    struct hive_set_value record;
    if (length > 15) { errno = EINVAL; fail("fixture hostname"); }
    for (i = 0; i < length; i++) data[2 * i] = (unsigned char)value[i];
    record.key = (char *)key; record.t = hive_t_string;
    record.len = (length + 1) * 2; record.value = (char *)data;
    if (hivex_node_set_value(hive, node, &record, 0)) fail("set string");
}
static void copy(const char *source, const char *destination) {
    int in = open(source, O_RDONLY), out = open(destination, O_WRONLY | O_CREAT | O_EXCL, 0600);
    unsigned char buffer[8192]; ssize_t count;
    if (in < 0 || out < 0) fail("open fixture hive");
    while ((count = read(in, buffer, sizeof(buffer))) > 0)
        if (write(out, buffer, (size_t)count) != count) fail("write fixture hive");
    if (count < 0 || close(in) || close(out)) fail("close fixture hive");
}
static void control_set(hive_h *hive, hive_node_h root, unsigned set) {
    char name[16]; hive_node_h node, tcp, computer, active;
    if (snprintf(name, sizeof(name), "ControlSet%03u", set) >= (int)sizeof(name)) fail("control set name");
    node = add(hive, root, name);
    tcp = add(hive, add(hive, add(hive, node, "Services"), "Tcpip"), "Parameters");
    computer = add(hive, add(hive, node, "Control"), "ComputerName");
    active = add(hive, computer, "ActiveComputerName");
    computer = add(hive, computer, "ComputerName");
    string(hive, tcp, "Hostname", "BEFORE");
    string(hive, tcp, "NV Hostname", "BEFORE");
    string(hive, active, "ComputerName", "BEFORE");
    string(hive, computer, "ComputerName", "BEFORE");
}
int main(int argc, char **argv) {
    hive_h *hive; hive_node_h root, select;
    if (argc != 3) return 2;
    copy(argv[1], argv[2]);
    hive = hivex_open(argv[2], HIVEX_OPEN_WRITE); if (!hive) fail("open fixture hive");
    root = hivex_root(hive); select = add(hive, root, "Select");
    dword(hive, select, "Current", 1); dword(hive, select, "Default", 2);
    control_set(hive, root, 1); control_set(hive, root, 2);
    if (hivex_commit(hive, NULL, 0)) fail("commit fixture hive");
    hivex_close(hive); return 0;
}
EOF

"$cc" -std=c11 -D_FILE_OFFSET_BITS=64 -Wall -Wextra -Werror \
    ${CPPFLAGS:-} $(pkg-config --cflags hivex) \
    -o "$fixture_tool" "$fixture_source" ${LDFLAGS:-} $(pkg-config --libs hivex)

system=$tmp/SYSTEM
"$fixture_tool" "$minimal" "$system"

[[ $("$tool" windows-hostname-inspect "$system") == $'ControlSet001\nControlSet002' ]] ||
    fail 'inspect did not report Current and distinct Default control sets'
"$tool" windows-hostname-verify "$system" BEFORE
expect_fail "$tool" windows-hostname-verify "$system" AFTER
expect_fail "$tool" windows-hostname-verify "$system" 12345
expect_fail "$tool" windows-hostname-verify "$system" ABCDEFGHIJKLMNOP
expect_fail "$tool" windows-hostname-inspect "$minimal"
printf 'not a hive\n' >"$tmp/malformed-SYSTEM"
expect_fail "$tool" windows-hostname-inspect "$tmp/malformed-SYSTEM"

set +e
{
    for set in ControlSet001 ControlSet002; do
        printf 'ed \\%s\\Services\\Tcpip\\Parameters\\Hostname\nAFTER\n' "$set"
        printf 'ed \\%s\\Services\\Tcpip\\Parameters\\NV Hostname\nAFTER\n' "$set"
        printf 'ed \\%s\\Control\\ComputerName\\ComputerName\\ComputerName\nAFTER\n' "$set"
        printf 'ed \\%s\\Control\\ComputerName\\ActiveComputerName\\ComputerName\nAFTER\n' "$set"
    done
    printf 'q\ny\n\n'
} | "$reged" -e "$system" >/dev/null
reged_status=${PIPESTATUS[1]}
set -e
(( reged_status <= 2 )) || fail "reged hostname write failed: $reged_status"

"$tool" windows-hostname-verify "$system" AFTER
set +e
printf 'ed \\ControlSet002\\Services\\Tcpip\\Parameters\\Hostname\nDRIFT\nq\ny\n\n' |
    "$reged" -e "$system" >/dev/null
reged_status=${PIPESTATUS[1]}
set -e
(( reged_status <= 2 )) || fail "reged drift write failed: $reged_status"
expect_fail "$tool" windows-hostname-verify "$system" AFTER

printf 'PASS: native hivex hostname inspect/verify regression with reged writes\n'
