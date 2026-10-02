#!/bin/bash

archive_is_valid_tar_xz() {
    local archive_path=$1
    tar -tJf "$archive_path" >/dev/null 2>&1
}


file_matches_sha256() {
    local file_path=$1 expected_hash=$2 actual_hash

    [[ -f $file_path && ! -L $file_path ]] || return 1
    [[ $expected_hash =~ ^[0-9a-f]{64}$ ]] || return 1
    actual_hash=$(sha256sum -- "$file_path") || return 1
    actual_hash=${actual_hash%% *}
    [[ $actual_hash == "$expected_hash" ]]
}


download_file_sha256() (
    local destination=$1 expected_hash=$2 temporary_path='' url status
    shift 2

    cleanup_download_temp() {
        [[ -z ${temporary_path:-} ]] || rm -f -- "$temporary_path"
        return 0
    }
    trap cleanup_download_temp EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    [[ $# -gt 0 ]] || {
        echo "No download URLs were provided for $destination" >&2
        return 1
    }
    [[ $expected_hash =~ ^[0-9a-f]{64}$ ]] || {
        echo "Invalid expected SHA-256 for $destination" >&2
        return 1
    }
    [[ ! -L $destination ]] || {
        echo "Refusing symbolic-link cache path: $destination" >&2
        return 1
    }
    if [[ -e $destination && ! -f $destination ]]; then
        echo "Cache path is not a regular file: $destination" >&2
        return 1
    fi
    if [[ -f $destination ]] && file_matches_sha256 "$destination" "$expected_hash"; then
        echo "Reusing SHA-256 verified source archive: $destination"
        return 0
    fi
    if [[ -e $destination ]]; then
        echo "Existing source archive has an unexpected SHA-256; preserving it until replacement is verified: $destination" >&2
    fi

    temporary_path=$(mktemp "${destination}.tmp.XXXXXX") || {
        echo "Failed to create a temporary download file beside $destination" >&2
        return 1
    }

    for url in "$@"; do
        [[ $url == https://* ]] || {
            echo "Refusing non-HTTPS source URL: $url" >&2
            continue
        }
        echo "Downloading SHA-256 protected source archive from: $url"
        if wget --timeout=30 --tries=3 --waitretry=2 --retry-connrefused \
            --retry-on-http-error=429,500,502,503,504 -O "$temporary_path" "$url"; then
            if file_matches_sha256 "$temporary_path" "$expected_hash"; then
                if mv -fT -- "$temporary_path" "$destination"; then
                    temporary_path=''
                    echo "Downloaded and SHA-256 verified source archive: $destination"
                    return 0
                fi
                echo "Failed to replace source archive with verified download: $destination" >&2
            else
                echo "Downloaded source archive has an unexpected SHA-256: $url" >&2
            fi
        else
            status=$?
            echo "Download failed: URL=$url exit_code=$status" >&2
        fi
        : >"$temporary_path"
    done

    echo "Unable to download a SHA-256 verified source archive for $destination" >&2
    return 1
)


download_tar_xz() (
    local archive_path=$1
    local temporary_path url status
    shift

    cleanup_download_temp() {
        if [[ -n ${temporary_path:-} ]]; then
            rm -f -- "$temporary_path"
        fi
        return 0
    }
    trap cleanup_download_temp EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if [[ $# -eq 0 ]]; then
        echo "No download URLs were provided for $archive_path" >&2
        return 1
    fi

    if [[ -d $archive_path ]]; then
        echo "Source archive path is a directory, refusing to replace it: $archive_path" >&2
        return 1
    fi

    if [[ -f $archive_path ]] && archive_is_valid_tar_xz "$archive_path"; then
        echo "Reusing verified source archive: $archive_path"
        return 0
    fi

    if [[ -e $archive_path ]]; then
        echo "Existing source archive is invalid; keeping it until a verified replacement is downloaded: $archive_path" >&2
    fi

    temporary_path="$(mktemp "${archive_path}.tmp.XXXXXX")" || {
        echo "Failed to create a temporary download file beside $archive_path" >&2
        return 1
    }

    for url in "$@"; do
        echo "Downloading source archive from: $url"
        if wget --timeout=30 --tries=3 --waitretry=2 --retry-connrefused \
            --retry-on-http-error=429,500,502,503,504 -O "$temporary_path" "$url"; then
            if archive_is_valid_tar_xz "$temporary_path"; then
                if mv -f -- "$temporary_path" "$archive_path"; then
                    echo "Downloaded and verified source archive: $archive_path"
                    return 0
                fi
                echo "Failed to replace source archive with verified download: $archive_path" >&2
            else
                echo "Downloaded archive is not a valid tar.xz: $url" >&2
            fi
        else
            status=$?
            echo "Download failed: URL=$url exit_code=$status" >&2
        fi
        : >"$temporary_path"
    done

    echo "Unable to download a verified source archive for $archive_path" >&2
    return 1
)
