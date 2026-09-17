#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/create-usb-image.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

grep -Fq 'insmod all_video' "$script" || fail '缺少 all_video'
for entry in '1. PXEOS Image Deploy/Capture' '2. Perform Full Host Registration and Inventory' '3. Quick Registration and Inventory' '4. Client System Information (Compatibility)' '6. PXEOS Debug Kernel'; do
    block=$(awk -v entry="$entry" '$0 == "menuentry \"" entry "\" {" { inside=1 } inside { print } inside && $0 == "}" { exit }' "$script")
    [ -n "$block" ] || fail "找不到 PXEOS 条目: $entry"
    printf '%s\n' "$block" | grep -Fq 'set gfxpayload=1024x768,auto' || fail "PXEOS 条目缺少 1024x768 gfxpayload: $entry"
    printf '%s\n' "$block" | grep -Fq 'fbcon=font:VGA8x16' || fail "PXEOS 条目缺少 8x16 framebuffer 字体: $entry"
done

for entry in '5. Run Memtest86+' '7. PXEOS iPXE Jumpstart BIOS' '8. PXEOS iPXE Jumpstart EFI'; do
    block=$(awk -v entry="$entry" '$0 == "menuentry \"" entry "\" {" { inside=1 } inside { print } inside && $0 == "}" { exit }' "$script")
    [ -n "$block" ] || fail "找不到非 PXEOS 条目: $entry"
    if printf '%s\n' "$block" | grep -Eq 'gfx(mode|payload)|vga=|efifb:'; then
        fail "非 PXEOS 条目被显示配置污染: $entry"
    fi
done

if grep -Eq 'vga=0x317|video=efifb:' "$script"; then
    fail 'USB GRUB 配置不得携带网络 PXE 专用内核参数'
fi
echo 'PASS: PXEOS USB console regression'
