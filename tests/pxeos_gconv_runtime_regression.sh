#!/usr/bin/env bash
# Buildroot contract for the glibc conversion modules required by libhivex.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/build.sh"
offline_identities_mk="$root/Buildroot/package/rootpxe-offline-identities/rootpxe-offline-identities.mk"
expected_copy='BR2_TOOLCHAIN_GLIBC_GCONV_LIBS_COPY=y'
expected_list='BR2_TOOLCHAIN_GLIBC_GCONV_LIBS_LIST="UTF-16 ISO8859-1"'

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

# Extract the module basenames from the relevant upstream glibc gconv mapping,
# rather than treating the Buildroot list as an arbitrary string.  UTF-16LE
# reaches the UTF-16 module, while ISO-8859-1 reaches ISO8859-1.
gconv_modules="$tmp/gconv-modules"
cat >"$gconv_modules" <<'EOF'
module  UTF-16LE//    INTERNAL    UTF-16    1
module  INTERNAL      UTF-16LE//  UTF-16    1
module  ISO-8859-1//  INTERNAL    ISO8859-1 1
module  INTERNAL      ISO-8859-1// ISO8859-1 1
EOF
module_for() {
    awk -v encoding="$1//" '$1 == "module" && $2 == encoding && $3 == "INTERNAL" { print $4; exit }' "$gconv_modules"
}
utf16_module="$(module_for UTF-16LE)"
latin1_module="$(module_for ISO-8859-1)"
[[ $utf16_module == UTF-16 && $latin1_module == ISO8859-1 ]] || fail 'gconv 编码到模块映射异常'

for config in "$root"/configs/fsx64.config "$root"/configs/fsx86.config "$root"/configs/fsarm64.config; do
    grep -Fqx "$expected_copy" "$config" || fail "$config 未启用 gconv 模块复制"
    grep -Fqx "$expected_list" "$config" || fail "$config 未限制为 Hivex 所需的 gconv 模块"
    config_list="$(sed -n 's/^BR2_TOOLCHAIN_GLIBC_GCONV_LIBS_LIST="\(.*\)"$/\1/p' "$config")"
    for module in "$utf16_module" "$latin1_module"; do
        [[ " $config_list " == *" $module "* ]] || fail "$config 缺少 $module 所需 gconv 模块"
    done
done

grep -Fq 'rootpxe_build_sync_glibc_gconv_config' "$build" || fail '构建脚本未同步已有 .config 的 gconv 设置'
grep -Fqx 'ROOTPXE_OFFLINE_IDENTITIES_VERSION = 2' "$offline_identities_mk" || fail '离线身份 helper 未升级本地包版本以触发增量重编'
grep -Fq 'make olddefconfig' "$build" || fail '构建脚本未以非交互方式规范化同步后的配置'
grep -Fq 'rootpxe_build_olddefconfig "$arch" || return 1' "$build" || fail 'olddefconfig 失败未向构建调用方传播'

desired="$tmp/desired.config"
current="$tmp/current.config"
printf '%s\n%s\n' "$expected_copy" "$expected_list" >"$desired"
printf '%s\n%s\n' '# BR2_TOOLCHAIN_GLIBC_GCONV_LIBS_COPY is not set' 'BR2_TOOLCHAIN_GLIBC_GCONV_LIBS_LIST="KOI8-R"' >"$current"

eval "$(sed -n '/^rootpxe_build_sync_glibc_gconv_config()/,/^}/p' "$build")"
rootpxe_build_sync_glibc_gconv_config "$desired" "$current" || fail '已有配置 gconv 同步失败'
grep -Fqx "$expected_copy" "$current" || fail '已有配置未启用 gconv 模块复制'
grep -Fqx 'BR2_TOOLCHAIN_GLIBC_GCONV_LIBS_LIST="KOI8-R UTF-16 ISO8859-1"' "$current" || fail '已有配置未保留自定义模块并合并最小 gconv 模块清单'
if grep -Fq '# BR2_TOOLCHAIN_GLIBC_GCONV_LIBS_COPY is not set' "$current"; then
    fail '已有配置保留了互斥的 gconv 禁用项'
fi

printf '%s\n%s\n' "$expected_copy" 'BR2_TOOLCHAIN_GLIBC_GCONV_LIBS_LIST=""' >"$current"
rootpxe_build_sync_glibc_gconv_config "$desired" "$current" || fail '全量 gconv 配置同步失败'
grep -Fqx 'BR2_TOOLCHAIN_GLIBC_GCONV_LIBS_LIST=""' "$current" || fail '全量 gconv 配置不应被缩减为最小模块集'

eval "$(sed -n '/^rootpxe_build_olddefconfig()/,/^}/p' "$build")"
make() { return 23; }
rootpxe_build_olddefconfig x64 && fail 'olddefconfig 工具失败未被保留'
unset -f make

printf 'PASS: PXEOS Hivex gconv 运行时构建契约。\n'
