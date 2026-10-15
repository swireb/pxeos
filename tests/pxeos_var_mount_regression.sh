#!/usr/bin/env bash
# 独立 /var 的许可、全部PV、挂载身份及本次所有权清理由原生NoCloud fixture核对。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
exec bash "$root/tests/pxeos_cloud_init_mounts_regression.sh"
