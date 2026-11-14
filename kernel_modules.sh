#!/bin/bash
# Helpers shared by the kernel producer and root filesystem consumer.

rootpxe_modules_build_id() {
    local arch="$1" digest
    digest=$(
        set -o pipefail
        cd -- "$PROJECT_DIRECTORY" || exit 1
        {
            printf '%s\n' "$arch" "$KERNEL_VERSION" "$PXEOS_BUILD_VERSION"
            sha256sum "configs/kernel$arch.config" || exit 1
            find patch/kernel KernelPackages -type f -print0 |
                LC_ALL=C sort -z | xargs -0r sha256sum || exit 1
        } | sha256sum
    ) || return 1
    printf '%s\n' "${digest:0:16}"
}

rootpxe_modules_package() (
    local arch="$1" build_id="$2" release="$3" stage="$4" module
    local modules="$stage/lib/modules/$release"
    local package="$buildPath/kernel-modules/$arch.tar.gz"
    if [[ ! $release =~ ^[[:alnum:].+_-]+$ || $release != *"-pxeos-$build_id-"* ||
          ! -s $modules/modules.dep.bin || ! -s $modules/modules.alias.bin || ! -s $modules/modules.order ]]; then
        printf 'Kernel release or module dependency indexes for %s are missing or invalid.\n' "$arch" >&2
        return 1
    fi
    rm -f -- "$modules/build" "$modules/source" || return 1
    mkdir -p -- "$stage/etc/modprobe.d" || return 1
    printf '%s\n' "$release" >"$stage/etc/pxeos-storage-kernel" || return 1
    while IFS= read -r module; do
        module=${module##*/}
        module=${module%.ko}
        printf '%s\n' "${module//-/_}" || return 1
    done <"$modules/modules.order" >"$modules/pxeos-storage.modules" || return 1
    for module in libata ahci libsas; do
        if ! grep -Fxq "$module" "$modules/pxeos-storage.modules"; then
            printf 'Required kernel module %s was not installed for %s.\n' "$module" "$arch" >&2
            return 1
        fi
    done
    sed 's/^/blacklist /' "$modules/pxeos-storage.modules" >"$stage/etc/modprobe.d/pxeos-storage.conf" || return 1
    mkdir -p -- "${package%/*}" || return 1
    local archive
    archive=$(mktemp "${package}.XXXXXX") || return 1
    trap 'rm -f -- "$archive"' EXIT
    tar -czf "$archive" -C "$stage" etc lib || return 1
    mv -f -- "$archive" "$package"
)

rootpxe_modules_extract() {
    local arch="$1" overlay="$2" build_id release
    local package="$buildPath/kernel-modules/$arch.tar.gz"
    if [[ ! -r $package ]]; then
        printf 'Missing PXEOS kernel module package for %s: %s\n' "$arch" "$package" >&2
        return 1
    fi
    build_id=$(rootpxe_modules_build_id "$arch") || return 1
    if ! release=$(tar -xOzf "$package" etc/pxeos-storage-kernel) ||
       [[ ! $release =~ ^[[:alnum:].+_-]+$ || $release != *"-pxeos-$build_id-"* ]]; then
        printf 'PXEOS kernel module package does not match this %s build.\n' "$arch" >&2
        return 1
    fi
    mkdir -p -- "$overlay" || return 1
    tar -xzf "$package" -C "$overlay" || return 1
    local modules="$overlay/lib/modules/$release"
    if [[ ! -s $modules/pxeos-storage.modules || ! -s $modules/modules.dep.bin ||
          ! -s $modules/modules.alias.bin || ! -s $overlay/etc/modprobe.d/pxeos-storage.conf ]]; then
        printf 'PXEOS kernel module package for %s is incomplete.\n' "$arch" >&2
        return 1
    fi
}
