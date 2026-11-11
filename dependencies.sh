#!/bin/bash

# Distros that have been tested:
#   - Debian 11, 12
#   - Ubuntu 22.04, 24.04
#   - RHEL 8.10, 9.4
#   - Fedora 39, 40
#   - Rocky 9.4


declare -ar common_dependencies=(
    "wget"
    "tar"
    "git"
    "make"
    "gcc"
    "flex"
    "bison"
    "cpio"
    "file"
    "rsync"
    "patch"
    "unzip"
    "bzip2"
    "findutils"
    "autoconf"
    "libtool"
    "autopoint"
)

declare -ar deb_dependencies=(
    "libelf-dev"
    "xz-utils"
    "g++"
    "libncurses-dev"
)

declare -ar rhel_dependencies=(
    "elfutils-libelf-devel"
    "perl"
    "xz"
    "gcc-c++"
    "ncurses-devel"
)

declare -ar apt_acquire_options=(
    -o Acquire::Retries=1
    -o Acquire::http::Timeout=30
    -o Acquire::https::Timeout=30
)


function __epel_repo_message() {
    echo ""
    echo "Please add the EPEL repository to your system."
    echo "The EPEL repository is needed to install the following dependencies: gcc-aarch64-linux-gnu"
    echo ""
}


function checkDependencies() {
    local running_os package_list package status arm64_toolchain=gcc-aarch64-linux-gnu
    local -a dependencies
    running_os=$(grep "^ID=" /etc/os-release | cut -d'=' -f2 | tr -d '"')
    package_manager=()

    case $running_os in
        "debian" | "ubuntu")
            dependencies=("${common_dependencies[@]}" "${deb_dependencies[@]}")
            package_manager=(sudo apt-get "${apt_acquire_options[@]}" install -y)
            pkgmgr() {
                dpkg-query -W -f='${db:Status-Status}\t${binary:Package}\n'
            }
            ;;
        "rhel" | "rocky" | "fedora")
            dependencies=("${common_dependencies[@]}" "${rhel_dependencies[@]}")
            package_manager=(sudo dnf install -y)
            pkgmgr() {
                rpm -qa --qf '%{NAME}\n'
            }
            ;;
        *)
            echo "Untested OS: $running_os"
            echo "Exiting now."
            return 1
            ;;
    esac

    if [[ ${require_arm64_toolchain:-y} == y ]]; then
        dependencies+=("$arm64_toolchain")
    fi

    if ! package_list="$(pkgmgr)"; then
        echo "Failed to query installed packages. Exiting now." >&2
        return 1
    fi

    declare -A installed_packages=()
    if [[ $running_os == "debian" || $running_os == "ubuntu" ]]; then
        while IFS=$'\t' read -r status package; do
            [[ $status == "installed" && -n $package ]] || continue
            installed_packages["${package%%:*}"]=1
        done <<< "$package_list"
    else
        while IFS= read -r package; do
            [[ -n $package ]] || continue
            installed_packages["$package"]=1
        done <<< "$package_list"
    fi

    missing_packages=()
    for package in "${dependencies[@]}"; do
        if [[ -z ${installed_packages[$package]+x} ]]; then
            missing_packages+=("$package")
        fi
    done

    if [[ ( $running_os == rhel || $running_os == rocky ) &&
        ${require_arm64_toolchain:-y} == y && -z ${installed_packages[$arm64_toolchain]+x} ]]; then
        __epel_repo_message
    fi
    if [[ ${#missing_packages[@]} -ne 0 ]]; then
        echo "The following dependencies are missing: ${missing_packages[*]}"
    fi

    return 0
}


function installDependencies() {
    local install_dep=$1

    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        return 0
    fi
    if [[ $install_dep != "y" ]]; then
        echo "Exiting now, please install the packages manually or add the -i or --install-dep flag to install them automatically."
        return 1
    fi

    echo "Attempting to install missing dependencies..."
    if "${package_manager[@]}" "${missing_packages[@]}"; then
        return 0
    fi

    if [[ ${package_manager[1]-} == apt-get ]]; then
        echo "APT install failed. Refreshing package indexes before retrying once." >&2
        if sudo apt-get "${apt_acquire_options[@]}" --error-on=any update &&
            "${package_manager[@]}" "${missing_packages[@]}"; then
            return 0
        fi
        echo "APT could not install dependencies. Check network access, DNS resolution and the configured APT mirrors before retrying." >&2
    else
        echo "Failed to install dependencies, please install the packages manually. Exiting now."
    fi

    return 1
}
