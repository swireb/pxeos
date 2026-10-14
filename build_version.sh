#!/usr/bin/env bash
# 仅定义版本函数；source 本文件不会安装、下载或启动构建。

rootpxe_build_validate_version() {
    local version="${1-}"
    [[ ${#version} -le 64 && $version =~ ^(Release|Beta|Local)-[0-9]{2}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])-([01][0-9]|2[0-3])[0-5][0-9](-[0-9]+-[0-9]+)?$ ]] || {
        echo 'Invalid PXEOS_BUILD_VERSION; expected Release/Beta/Local-YYMMDD-HHmm with an optional numeric run-id/attempt suffix (max 64 characters).' >&2
        return 1
    }
}

rootpxe_build_resolve_version() {
    # 已设置但为空也属于错误，不能掩盖 CI 或操作者传参错误。
    if [[ ! -v PXEOS_BUILD_VERSION ]]; then
        if [[ ${GITHUB_ACTIONS:-false} == true ]]; then
            echo 'GitHub Actions requires canonical Release/Beta PXEOS_BUILD_VERSION before building.' >&2
            return 1
        fi
        PXEOS_BUILD_VERSION="Local-$(TZ=Asia/Shanghai date '+%y%m%d-%H%M')" || return 1
    fi
    rootpxe_build_validate_version "$PXEOS_BUILD_VERSION" || return 1
    if [[ ${GITHUB_ACTIONS:-false} == true && $PXEOS_BUILD_VERSION == Local-* ]]; then
        echo 'GitHub Actions cannot use Local PXEOS_BUILD_VERSION; a canonical Release/Beta tag is required.' >&2
        return 1
    fi
    export PXEOS_BUILD_VERSION
}

rootpxe_build_stamp_version() {
    local funcs_file="${1-}" version="${2-}" marker_count
    rootpxe_build_validate_version "$version" || return 1
    [[ -f $funcs_file && ! -L $funcs_file ]] || {
        echo 'PXEOS version stamping requires a regular copied overlay funcs.sh.' >&2
        return 1
    }
    marker_count=$(grep -c '^export initversion=' "$funcs_file") || return 1
    [[ $marker_count == 1 ]] || {
        echo 'PXEOS copied overlay must contain exactly one initversion marker.' >&2
        return 1
    }
    # version 已经过 ASCII 白名单校验，不能注入 Shell 或 sed 表达式。
    sed -i "s/^export initversion=.*$/export initversion=$version/" "$funcs_file"
}
