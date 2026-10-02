#!/bin/bash

[[ -z $KERNEL_VERSION ]] && KERNEL_VERSION='6.18.38'
[[ -z $BUILDROOT_VERSION ]] && BUILDROOT_VERSION='2026.02.1'

declare -ar ARCHITECTURES=("x64" "x86" "arm64")
PIPE_JOINED_ARCHITECTURES=$(IFS="|"; echo "${ARCHITECTURES[@]}"; unset IFS)

PROJECT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$PROJECT_DIRECTORY/dependencies.sh"
source "$PROJECT_DIRECTORY/download_helpers.sh"

Usage() {
    echo -e "Usage: $0 [-knfvh?] [-a x64]"
    echo -e "\t\t-a --arch [$PIPE_JOINED_ARCHITECTURES] (optional) pick the architecture to build. Default is to build for all."
    echo -e "\t\t-f --filesystem-only (optional) Build the PXEOS filesystem but not the kernel."
    echo -e "\t\t-k --kernel-only (optional) Build the PXEOS kernel but not the filesystem."
    echo -e "\t\t-p --path (optional) Specify a path to download and build the sources."
    echo -e "\t\t-n --noconfirm (optional) Build systems without confirmation."
    echo -e "\t\t-i --install-dep (optional) Attempt to install dependencies."
    echo -e "\t\t-v --verbose (optional) Show make output on screen for filesystem builds as well as write it to the log file."
    echo -e "\t\t   --fs-download-only (optional) Only download Buildroot source packages for each filesystem."
    echo -e "\t\t-h --help -? Display this message."
    exit 0
}
[[ -n "$arch" ]] && unset "$arch"

shortopts="?hkfnia:p:v"
longopts="help,kernel-only,filesystem-only,noconfirm,install-dep,arch:,path:,verbose,fs-download-only"

optargs=$(getopt -o "$shortopts" -l "$longopts" -n "$0" -- "$@")
[[ $? -ne 0 ]] && Usage

eval set -- "$optargs"

while :; do
    case $1 in
        -\? | -h | --help)
            Usage
            ;;
        -k | --kernel-only)
            buildKernelOnly="y"
            shift
            ;;
        -f | --filesystem-only)
            buildFSOnly="y"
            shift
            ;;
        -n | --noconfirm)
            confirm="n"
            shift
            ;;
        -i | --install-dep)
            installDep="y"
            shift
            ;;
        --fs-download-only)
            fsDownloadOnly="y"
            buildFSOnly="y"
            confirm="n"
            shift
            ;;
        -v | --verbose)
            verbose="y"
            shift
            ;;
        -a | --arch)
            arch=$2
            if ! echo "${ARCHITECTURES[@]}" | grep -w "$arch" >/dev/null; then
                echo "Error: Invalid architecture specified. Valid options are: $PIPE_JOINED_ARCHITECTURES"
                Usage
            fi
            shift 2
            ;;
        -p | --path)
            buildPath=$2
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Error: Invalid option."
            Usage
            ;;
    esac
done


[[ -z $arch ]] && arch="${ARCHITECTURES[*]}"
[[ -z $buildPath ]] && buildPath="$(dirname "$(readlink -f "$0")")"
[[ -z $confirm ]] && confirm="y"
[[ -z $installDep ]] && installDep="n"
[[ -z $verbose ]] && verbose="n"
[[ -z $fsDownloadOnly ]] && fsDownloadOnly="n"

if ! checkDependencies; then
    exit 1
fi
if ! installDependencies "$installDep"; then
    exit 1
fi

cd "$buildPath" || exit 1
buildPath="$(pwd -P)"

rootpxe_build_apply_patch_once() {
    local patch_file="$1"
    local forward_output reverse_output
    [[ -r $patch_file ]] || return 1
    if forward_output=$(patch --batch --forward --dry-run -p1 < "$patch_file" 2>&1); then
        if ! patch --batch --forward -p1 < "$patch_file"; then
            printf 'Failed to apply patch %s after its forward dry-run succeeded.\n' "$patch_file" >&2
            return 1
        fi
    elif reverse_output=$(patch --batch --force --reverse --dry-run -p1 < "$patch_file" 2>&1); then
        echo 'Patch already applied.'
    else
        printf 'Failed to apply patch %s. Forward dry-run output:\n%s\nReverse dry-run output:\n%s\n' \
            "$patch_file" "$forward_output" "$reverse_output" >&2
        return 1
    fi
}

rootpxe_build_apply_filesystem_patches() {
    local patch_file applied=no
    # 91b1dd3 wrote a literal backslash-t into this one known LVM2 recipe.
    # Repair only that exact source state before normal idempotent patches.
    if [[ -f package/lvm2/lvm2.mk ]] && grep -Fq '\trm -f $(TARGET_DIR)/usr/lib/udev/rules.d/69-dm-lvm.rules' package/lvm2/lvm2.mk; then
        rootpxe_build_apply_patch_once "$PROJECT_DIRECTORY/patch/filesystem/lvm2-repair-literal-tab-hook.patch" || return 1
    fi
    for patch_file in \
        "$PROJECT_DIRECTORY/patch/filesystem/fs.patch" \
        "$PROJECT_DIRECTORY/patch/filesystem/lvm2-udev-sync.patch" \
        "$PROJECT_DIRECTORY/patch/filesystem/lvm2-no-systemd-autoactivation.patch"; do
        [[ -e $patch_file ]] || continue
        [[ -f $patch_file ]] || return 1
        dots " * Applying filesystem patch"
        echo
        if ! rootpxe_build_apply_patch_once "$patch_file"; then
            printf 'Failed to apply filesystem patch: %s\n' "$patch_file" >&2
            return 1
        fi
        echo "Done"
        applied=yes
    done
    [[ $applied == yes ]] || echo " * WARNING: Did not find any patch file(s), building filesystem without patches!"
}

# A new filesystem default does not replace an existing fssource<arch>/.config.
# Keep this narrow migration explicit: libhivex needs the selected glibc gconv
# modules to traverse Windows Registry key names, without overwriting any other
# local Buildroot choices in an incremental build directory.  An empty gconv
# list means copy every module and must retain that broader user choice.
rootpxe_build_sync_glibc_gconv_config() {
    local desired_config="$1" current_config="$2"
    local copy_setting='BR2_TOOLCHAIN_GLIBC_GCONV_LIBS_COPY=y'
    local list_setting='BR2_TOOLCHAIN_GLIBC_GCONV_LIBS_LIST="UTF-16 ISO8859-1"'
    local current_list module

    [[ -r $desired_config && -f $current_config ]] || return 1
    grep -Fqx "$copy_setting" "$desired_config" || return 0
    grep -Fqx "$list_setting" "$desired_config" || return 1

    if grep -Fqx '# BR2_TOOLCHAIN_GLIBC_GCONV_LIBS_COPY is not set' "$current_config"; then
        sed -i 's|^# BR2_TOOLCHAIN_GLIBC_GCONV_LIBS_COPY is not set$|BR2_TOOLCHAIN_GLIBC_GCONV_LIBS_COPY=y|' "$current_config" || return 1
    elif grep -Eq '^BR2_TOOLCHAIN_GLIBC_GCONV_LIBS_COPY=' "$current_config"; then
        sed -i "s|^BR2_TOOLCHAIN_GLIBC_GCONV_LIBS_COPY=.*$|$copy_setting|" "$current_config" || return 1
    else
        printf '%s\n' "$copy_setting" >> "$current_config" || return 1
    fi

    current_list=$(sed -n 's/^BR2_TOOLCHAIN_GLIBC_GCONV_LIBS_LIST="\(.*\)"$/\1/p' "$current_config") || return 1
    if [[ -z $current_list ]] && ! grep -Eq '^BR2_TOOLCHAIN_GLIBC_GCONV_LIBS_LIST=' "$current_config"; then
        printf '%s\n' "$list_setting" >> "$current_config" || return 1
        return 0
    fi
    [[ -z $current_list ]] && return 0
    for module in UTF-16 ISO8859-1; do
        [[ " $current_list " == *" $module "* ]] || current_list+=" $module"
    done
    sed -i "s|^BR2_TOOLCHAIN_GLIBC_GCONV_LIBS_LIST=.*$|BR2_TOOLCHAIN_GLIBC_GCONV_LIBS_LIST=\"$current_list\"|" "$current_config" || return 1
}

rootpxe_build_olddefconfig() {
    case "$1" in
        x64) make olddefconfig ;;
        x86) make ARCH=i486 olddefconfig ;;
        arm64) make ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig ;;
        *) make olddefconfig ;;
    esac
}


rootpxe_build_normalize_backup_site_config() {
    local config_file="$1" temporary_file line line_ending changed=0

    [[ -f $config_file && ! -L $config_file ]] || return 1
    temporary_file=$(mktemp "${config_file}.tmp.XXXXXX") || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        line_ending=''
        if [[ $line == *$'\r' ]]; then
            line=${line%$'\r'}
            line_ending=$'\r'
        fi
        case "$line" in
            'BR2_BACKUP_SITE="http://sources.buildroot.net/"'|\
            'BR2_BACKUP_SITE="http://sources.buildroot.net"'|\
            'BR2_BACKUP_SITE="https://sources.buildroot.net/"')
                line='BR2_BACKUP_SITE="https://sources.buildroot.net"'
                changed=1
                ;;
        esac
        printf '%s%s\n' "$line" "$line_ending" >> "$temporary_file" || {
            rm -f -- "$temporary_file"
            return 1
        }
    done < "$config_file"
    if [[ $changed == 1 ]]; then
        mv -fT -- "$temporary_file" "$config_file" || {
            rm -f -- "$temporary_file"
            return 1
        }
    else
        rm -f -- "$temporary_file"
    fi
}


rootpxe_build_verified_source_spec() {
    case "$1" in
        cabextract) printf '%s\n' 'CABEXTRACT|1.11|cabextract-1.11.tar.gz|https://www.cabextract.org.uk|b5546db1155e4c718ff3d4b278573604f30dd64c3c5bfd4657cd089b823a3ac6|https://www.cabextract.org.uk/cabextract-1.11.tar.gz|https://deb.debian.org/debian/pool/main/c/cabextract/cabextract_1.11.orig.tar.gz' ;;
        chntpw) printf '%s\n' 'CHNTPW|140201|chntpw-source-140201.zip|https://pogostick.net/~pnh/ntpasswd|96e20905443e24cba2f21e51162df71dd993a1c02bfa12b1be2d0801a4ee2ccc|https://pogostick.net/~pnh/ntpasswd/chntpw-source-140201.zip|https://distfiles.macports.org/chntpw/chntpw-source-140201.zip' ;;
        libhivex) printf '%s\n' 'LIBHIVEX|1.3.24|hivex-1.3.24.tar.gz|https://download.libguestfs.org/hivex|a52fa45cecc9a78adb2d28605d68261e4f1fd4514a778a5473013d2ccc8a193c|https://download.libguestfs.org/hivex/hivex-1.3.24.tar.gz|https://deb.debian.org/debian/pool/main/h/hivex/hivex_1.3.24.orig.tar.gz' ;;
        partclone) printf '%s\n' 'PARTCLONE|0.3.48|partclone-0.3.48.tar.gz|https://github.com/Thomas-Tsai/partclone/archive/0.3.48|af4f1c93fb2401eb617f1eafc13f115d7f583f6851a8195728d17b520fec7685|https://github.com/Thomas-Tsai/partclone/archive/0.3.48/partclone-0.3.48.tar.gz|https://codeload.github.com/Thomas-Tsai/partclone/tar.gz/refs/tags/0.3.48' ;;
        testdisk) printf '%s\n' 'TESTDISK|7.2|testdisk-7.2.tar.bz2|https://www.cgsecurity.org|f8343be20cb4001c5d91a2e3bcd918398f00ae6d8310894a5a9f2feb813c283f|https://www.cgsecurity.org/testdisk-7.2.tar.bz2|https://distfiles.macports.org/testdisk/testdisk-7.2.tar.bz2' ;;
        partimage) printf '%s\n' 'PARTIMAGE|0.6.9|partimage-0.6.9.tar.bz2|https://downloads.sourceforge.net/project/partimage/stable/0.6.9|753a6c81f4be18033faed365320dc540fe5e58183eaadcd7a5b69b096fec6635|https://downloads.sourceforge.net/project/partimage/stable/0.6.9/partimage-0.6.9.tar.bz2|https://deb.debian.org/debian/pool/main/p/partimage/partimage_0.6.9.orig.tar.bz2' ;;
        *) return 1 ;;
    esac
}


rootpxe_build_verified_source_metadata() {
    local prefix=$1 expected_version=$2 expected_source=$3 expected_site=$4 printvars_output
    local -a printvars_lines
    local line dl_dir='' seen_version='' seen_source='' seen_site='' seen_dl_dir=''

    printvars_output=$(make -s printvars VARS="${prefix}_VERSION ${prefix}_SOURCE ${prefix}_SITE ${prefix}_DL_DIR" QUOTED_VARS= RAW_VARS=) || return 1
    [[ $printvars_output != *$'\r'* ]] || return 1
    mapfile -t printvars_lines <<< "$printvars_output"
    [[ ${#printvars_lines[@]} -eq 4 ]] || return 1
    for line in "${printvars_lines[@]}"; do
        case "$line" in
            "${prefix}_VERSION=${expected_version}")
                [[ -z $seen_version ]] || return 1
                seen_version=y
                ;;
            "${prefix}_SOURCE=${expected_source}")
                [[ -z $seen_source ]] || return 1
                seen_source=y
                ;;
            "${prefix}_SITE=${expected_site}")
                [[ -z $seen_site ]] || return 1
                seen_site=y
                ;;
            "${prefix}_DL_DIR="*)
                [[ -z $seen_dl_dir ]] || return 1
                seen_dl_dir=y
                dl_dir=${line#"${prefix}_DL_DIR="}
                ;;
            *) return 1 ;;
        esac
    done
    [[ $seen_version == y && $seen_source == y && $seen_site == y && $seen_dl_dir == y ]] || return 1
    [[ -n $dl_dir && $dl_dir == /* && $dl_dir != ' '* && $dl_dir != *' ' && $dl_dir != *$'\t'* && $dl_dir != *\"* && $dl_dir != *\'* ]] || return 1
    printf '%s\n' "$dl_dir"
}


rootpxe_build_verified_source_hash() {
    local package=$1 source_name=$2 expected_hash=$3 hash_file actual_hash

    hash_file="$PROJECT_DIRECTORY/Buildroot/package/$package/$package.hash"
    actual_hash=$(awk -v source_name="$source_name" '
        $1 == "sha256" && $3 == source_name { count++; hash = $2 }
        END { if (count == 1) print hash; else exit 1 }
    ' "$hash_file") || return 1
    [[ $actual_hash =~ ^[0-9a-f]{64}$ && $actual_hash == "$expected_hash" ]] || return 1
}


rootpxe_build_seed_verified_source() {
    local package=$1 spec prefix expected_version expected_source expected_site expected_hash primary_url backup_url
    local dl_dir destination

    spec=$(rootpxe_build_verified_source_spec "$package") || return 1
    IFS='|' read -r prefix expected_version expected_source expected_site expected_hash primary_url backup_url <<< "$spec"
    [[ -n $prefix && -n $expected_version && -n $expected_source && -n $expected_site && -n $expected_hash && -n $primary_url ]] || return 1
    grep -Fqx "BR2_PACKAGE_${prefix}=y" .config || return 0
    dl_dir=$(rootpxe_build_verified_source_metadata "$prefix" "$expected_version" "$expected_source" "$expected_site") || {
        echo "Failed to resolve ${prefix} source metadata from Buildroot printvars." >&2
        return 1
    }
    rootpxe_build_verified_source_hash "$package" "$expected_source" "$expected_hash" || {
        echo "Failed to validate ${package} package hash metadata." >&2
        return 1
    }
    [[ ! -L $dl_dir && ( ! -e $dl_dir || -d $dl_dir ) ]] || {
        echo "Refusing non-directory or symbolic-link ${prefix}_DL_DIR: $dl_dir" >&2
        return 1
    }
    mkdir -p -- "$dl_dir" || return 1
    [[ -d $dl_dir && ! -L $dl_dir ]] || return 1
    destination="$dl_dir/$expected_source"
    if [[ -n $backup_url ]]; then
        download_file_sha256 "$destination" "$expected_hash" "$primary_url" "$backup_url"
    else
        download_file_sha256 "$destination" "$expected_hash" "$primary_url"
    fi
}


rootpxe_build_seed_verified_sources() {
    local package

    [[ -r .config && ! -L .config ]] || return 1
    grep -Fqx 'BR2_PRIMARY_SITE_ONLY=y' .config && return 0
    for package in cabextract chntpw libhivex partclone testdisk partimage; do
        rootpxe_build_seed_verified_source "$package" || return 1
    done
}


function buildFilesystem() {
    local arch="$1" filesystem_config="$PROJECT_DIRECTORY/configs/fs$1.config"
    local brURL="https://buildroot.org/downloads/buildroot-$BUILDROOT_VERSION.tar.xz"
    local archive="buildroot-$BUILDROOT_VERSION.tar.xz"
    echo "Preparing buildroot $BUILDROOT_VERSION on $arch build:"
    if [[ ! -d fssource$arch ]]; then
        if ! archive_is_valid_tar_xz "$archive"; then
            dots "Downloading buildroot source package"
            echo
            download_tar_xz "$archive" "$brURL" || return 1
        fi
        dots "Extracting buildroot sources"
        if ! tar xJf "$archive" || ! mv "buildroot-$BUILDROOT_VERSION" "fssource$arch"; then
            echo "Failed"
            return 1
        fi
        echo "Done"
    fi
    cd "fssource$arch" || { echo "Couldn't change directory to fssource$arch"; exit 1; }
    rootpxe_build_apply_filesystem_patches || return 1
    dots "Preparing code"
    if [[ ! -f .packConfDone ]]; then
        cat "$PROJECT_DIRECTORY/Buildroot/package/newConf.in" >> package/Config.in
        touch .packConfDone
    fi
    rsync -avPrI "$PROJECT_DIRECTORY/Buildroot/" . > /dev/null
    sed -i "s/^export initversion=[0-9][0-9]*$/export initversion=$(date +%Y%m%d)/" board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh
    if [[ ! -f .config ]]; then
        cp "$filesystem_config" .config
    fi
    rootpxe_build_normalize_backup_site_config .config || return 1
    rootpxe_build_sync_glibc_gconv_config "$filesystem_config" .config || return 1
    rootpxe_build_olddefconfig "$arch" || return 1
    echo "Done"

    if [[ $fsDownloadOnly == "y" ]]; then
        echo "Downloading Buildroot source packages for $arch ..."
        rootpxe_build_seed_verified_sources || return 1
        make source || return 1
        cd .. || return 1
        echo "$arch filesystem packages downloaded. Exiting."
        return 0
    fi

    if [[ $confirm != n ]]; then
        read -rp "We are ready to build. Would you like to edit the config file [y|n]?" config
        if [[ $config == y ]]; then
            case "${arch}" in
                x64)
                    make menuconfig || return 1
                    ;;
                x86)
                    make ARCH=i486 menuconfig || return 1
                    ;;
                arm64)
                    make ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- menuconfig || return 1
                    ;;
                *)
                    make menuconfig || return 1
                    ;;
            esac
            rootpxe_build_normalize_backup_site_config .config || return 1
            rootpxe_build_sync_glibc_gconv_config "$filesystem_config" .config || return 1
            rootpxe_build_olddefconfig "$arch" || return 1
        else
            echo "Ok, configuration was normalized with make olddefconfig."
        fi
        read -rp "We are ready to build are you [y|n]?" ready
        if [[ $ready == n ]]; then
            echo "Nothing to build!? Skipping."
            cd ..
            return
        fi
    fi

    rootpxe_build_seed_verified_sources || return 1

    if [[ $verbose == "y" ]]; then
        case "${arch}" in
            x64)
                make | tee "buildroot$arch.log"
                status=${PIPESTATUS[0]}
                ;;
            x86)
                make ARCH=i486 | tee "buildroot$arch.log"
                status=${PIPESTATUS[0]}
                ;;
            arm64)
                make ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- | tee "buildroot$arch.log"
                status=${PIPESTATUS[0]}
                ;;
            *)
                make | tee "buildroot$arch.log"
                status=${PIPESTATUS[0]}
                ;;
        esac
    else
        bash -c "while true; do echo \$(date) - building ...; sleep 30s; done" &
        PING_LOOP_PID=$!
        case "${arch}" in
            x64)
                make > "buildroot$arch.log" 2>&1
                status=$?
                ;;
            x86)
                make ARCH=i486 > "buildroot$arch.log" 2>&1
                status=$?
                ;;
            arm64)
                make ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- > "buildroot$arch.log" 2>&1
                status=$?
                ;;
            *)
                make > "buildroot$arch.log" 2>&1
                status=$?
                ;;
        esac
        kill $PING_LOOP_PID
    fi

    [[ $status -gt 0 ]] && tail "buildroot$arch.log" && exit $status
    cd ..
    [[ ! -d dist ]] && mkdir dist
    cd dist || { echo "Couldn't change directory to dist"; exit 1; }
    case "${arch}" in
        x64)
            compiledfile="../fssource$arch/output/images/rootfs.ext2.xz"
            initfile='init.xz'
            ;;
        x86)
            compiledfile="../fssource$arch/output/images/rootfs.ext2.xz"
            initfile='init_32.xz'
            ;;
        arm64)
            compiledfile="../fssource$arch/output/images/rootfs.cpio.gz"
            initfile='arm_init.cpio.gz'
            ;;
    esac
    [[ -f $compiledfile ]] || { echo 'File not found.'; cd ..; return 1; }
    cp "$compiledfile" "$initfile" || { cd ..; return 1; }
    sha256sum "$initfile" > "${initfile}.sha256" || { cd ..; return 1; }
    cd ..
}

function buildKernel() {
    local arch="$1"
    local kernelCDNURL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VERSION:0:1}.x/linux-$KERNEL_VERSION.tar.xz"
    local kernelFallbackURL="https://www.kernel.org/pub/linux/kernel/v${KERNEL_VERSION:0:1}.x/linux-$KERNEL_VERSION.tar.xz"
    local archive="linux-$KERNEL_VERSION.tar.xz"
    echo "Preparing kernel $KERNEL_VERSION on $arch build:"
    if ! archive_is_valid_tar_xz "$archive"; then
        dots "Downloading kernel source"
        echo
        download_tar_xz "$archive" "$kernelCDNURL" "$kernelFallbackURL" || return 1
    fi
    [[ -d kernelsource$arch ]] && rm -rf "kernelsource$arch"
    dots "Extracting kernel source"
    if ! tar xJf "$archive" || ! mv "linux-$KERNEL_VERSION" "kernelsource$arch"; then
        echo "Failed"
        return 1
    fi
    echo "Done"

    dots "Adding kernel packages"
    addKernelPackages
    echo "Done"

    if [[ ! -d linux-firmware ]]; then
        dots "Cloning Linux firmware repository"
        git clone git://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git >/dev/null 2>&1
        echo "Done"
    else
        dots "Updating Linux firmware repository"
        cd linux-firmware || { echo "Couldn't change directory to linux-firmware"; exit 1; }
        git pull --rebase >/dev/null 2>&1
        cd ..
        echo "Done"
    fi
    dots "Copying firmware files"
    cp -r linux-firmware "kernelsource$arch/"
    echo "Done"

    dots "Preparing kernel source"
    cd "kernelsource$arch" || { echo "Couldn't change directory to kernelsource$arch"; exit 2; }
    make mrproper
    cp "$PROJECT_DIRECTORY/configs/kernel$arch.config" .config
    echo "Done"
    if [[ -f $PROJECT_DIRECTORY/patch/kernel/linux.patch ]]; then
        dots " * Applying patch"
        echo
        if ! rootpxe_build_apply_patch_once "$PROJECT_DIRECTORY/patch/kernel/linux.patch"; then
            echo "Failed"
            exit 1
        fi
    else
        echo " * WARNING: Did not find a patch file building vanilla kernel without patches!"
    fi
    if [[ $confirm != n ]]; then
        read -rp "We are ready to build. Would you like to edit the config file [y|n]?" config
        if [[ $config == y ]]; then
            case "${arch}" in
                x64)
                    make menuconfig
                    ;;
                x86)
                    make ARCH=i386 menuconfig
                    ;;
                arm64)
                    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- menuconfig
                    ;;
                *)
                    make menuconfig
                    ;;
            esac
        else
            echo "Ok, running make oldconfig instead to ensure the config is clean."
            case "${arch}" in
                x64)
                    make oldconfig
                    ;;
                x86)
                    make ARCH=i386 oldconfig
                    ;;
                arm64)
                    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- oldconfig
                    ;;
                *)
                    make oldconfig
                    ;;
            esac
        fi
        read -rp "We are ready to build are you [y|n]?" ready
        if [[ $ready == y ]]; then
            echo "This make take a long time. Get some coffee, you'll be here a while!"
            case "${arch}" in
                x64)
                    make -j "$(nproc)" bzImage
                    status=$?
                    ;;
                x86)
                    make ARCH=i386 -j "$(nproc)" bzImage
                    status=$?
                    ;;
                arm64)
                    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j "$(nproc)" Image
                    status=$?
                    ;;
                *)
                    make -j "$(nproc)" bzImage
                    status=$?
                    ;;
            esac
        else
            echo "Nothing to build!? Skipping."
            cd ..
            return
        fi
        [[ $status -gt 0 ]] && exit $status
    else
        case "${arch}" in
            x64)
                make oldconfig
                make -j "$(nproc)" bzImage
                status=$?
                ;;
            x86)
                make ARCH=i386 oldconfig
                make ARCH=i386 -j "$(nproc)" bzImage
                status=$?
                ;;
            arm64)
                make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- oldconfig
                make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j "$(nproc)" Image
                status=$?
                ;;
            *)
                make oldconfig
                make -j "$(nproc)" bzImage
                status=$?
                ;;
        esac
    fi
    [[ $status -gt 0 ]] && exit $status
    cd ..
    mkdir -p dist
    cd dist || { echo "Couldn't change directory to dist"; exit 1; }
    case "$arch" in
        x64)
            compiledfile="../kernelsource$arch/arch/x86/boot/bzImage"
            kernelfile='bzImage'
            ;;
        x86)
            compiledfile="../kernelsource$arch/arch/x86/boot/bzImage"
            kernelfile='bzImage32'
            ;;
        arm64)
            compiledfile="../kernelsource$arch/arch/$arch/boot/Image"
            kernelfile='arm_Image'
            ;;
    esac
    [[ -f $compiledfile ]] || { echo 'File not found.'; cd ..; return 1; }
    cp "$compiledfile" "$kernelfile" || { cd ..; return 1; }
    sha256sum "$kernelfile" > "${kernelfile}.sha256" || { cd ..; return 1; }
    cd ..
}

function dots() {
    local pad
    pad=$(printf "%0.1s" "."{1..60})
    printf " * %s%*.*s" "$1" 0 $((60-${#1})) "$pad"
    return 0
}

function addKernelPackages() {
    local source_kernel_package_dir="$PROJECT_DIRECTORY/KernelPackages"
    local target_kernel_dir="$buildPath/kernelsource$arch"

    find "$source_kernel_package_dir" -type f | while read -r source_file; do
        # Get the relative path from the package directory to the source file
        local relative_path="${source_file#"$source_kernel_package_dir"/}"

        # Find the corresponding destination path
        local destination_file="$target_kernel_dir/$relative_path"
        local destination_dir
        destination_dir="$(dirname "$destination_file")"

        mkdir -p "$destination_dir"

        # Append if the destination file exists, otherwise copy
        if [[ -e "$destination_file" ]]; then
            cat "$source_file" >> "$destination_file"
        else
            cp "$source_file" "$destination_file"
        fi
    done
}


for buildArch in $arch
do
    if [[ -z $buildKernelOnly ]]; then
        buildFilesystem "$buildArch" || exit $?
    fi
    if [[ -z $buildFSOnly ]]; then
        buildKernel "$buildArch" || exit $?
    fi
done
