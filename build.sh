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
    [[ -r $patch_file ]] || return 1
    if patch --batch --forward --dry-run -p1 < "$patch_file" >/dev/null; then
        patch --batch --forward -p1 < "$patch_file"
    elif patch --batch --force --reverse --dry-run -p1 < "$patch_file" >/dev/null; then
        echo 'Patch already applied.'
    else
        return 1
    fi
}


function buildFilesystem() {
    local arch="$1"
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
    if [[ -f $PROJECT_DIRECTORY/patch/filesystem/fs.patch ]]; then
        dots " * Applying filesystem patch"
        echo
        if ! rootpxe_build_apply_patch_once "$PROJECT_DIRECTORY/patch/filesystem/fs.patch"; then
            echo "Failed"
            exit 1
        fi
        echo "Done"
    else
        echo " * WARNING: Did not find any patch file(s), building filesystem without patches!"
    fi
    dots "Preparing code"
    if [[ ! -f .packConfDone ]]; then
        cat "$PROJECT_DIRECTORY/Buildroot/package/newConf.in" >> package/Config.in
        touch .packConfDone
    fi
    rsync -avPrI "$PROJECT_DIRECTORY/Buildroot/" . > /dev/null
    sed -i "s/^export initversion=[0-9][0-9]*$/export initversion=$(date +%Y%m%d)/" board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh
    if [[ ! -f .config ]]; then
        cp "$PROJECT_DIRECTORY/configs/fs$arch.config" .config
        case "${arch}" in
            x64)
                make oldconfig
                ;;
            x86)
                make ARCH=i486 oldconfig
                ;;
            arm64)
                make ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- oldconfig
                ;;
            *)
                make oldconfig
                ;;
        esac
    fi
    echo "Done"

    if [[ $fsDownloadOnly == "y" ]]; then
        echo "Downloading Buildroot source packages for $arch ..."
        make source
        cd ..
        echo "$arch filesystem packages downloaded. Exiting."
        return 0
    fi

    if [[ $confirm != n ]]; then
        read -rp "We are ready to build. Would you like to edit the config file [y|n]?" config
        if [[ $config == y ]]; then
            case "${arch}" in
                x64)
                    make menuconfig
                    ;;
                x86)
                    make ARCH=i486 menuconfig
                    ;;
                arm64)
                    make ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- menuconfig
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
                    make ARCH=i486 oldconfig
                    ;;
                arm64)
                    make ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- oldconfig
                    ;;
                *)
                    make oldconfig
                    ;;
            esac
        fi
        read -rp "We are ready to build are you [y|n]?" ready
        if [[ $ready == n ]]; then
            echo "Nothing to build!? Skipping."
            cd ..
            return
        fi
    fi

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
