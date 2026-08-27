#!/bin/bash

archive_is_valid_tar_xz() {
    local archive_path=$1
    tar -tJf "$archive_path" >/dev/null 2>&1
}


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
