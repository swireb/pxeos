#!/usr/bin/env bash
# 历史发布 tag 是不可变下载 URL 的一部分，创建前必须保持唯一。
set -euo pipefail

repo=''
tag=''
fallback_tag=''
gh_bin=${GH_BIN:-gh}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) repo=${2-}; shift 2 ;;
        --tag) tag=${2-}; shift 2 ;;
        --fallback-tag) fallback_tag=${2-}; shift 2 ;;
        *) echo "usage: $0 --repo OWNER/REPO --tag HISTORICAL_TAG [--fallback-tag FALLBACK_TAG]" >&2; exit 2 ;;
    esac
done

[[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo 'invalid repository' >&2; exit 2; }
[[ $tag =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $tag != latest && $tag != beta ]] || {
    echo 'invalid historical release tag' >&2
    exit 2
}
if [[ -n $fallback_tag ]]; then
    [[ $fallback_tag =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $fallback_tag != latest && $fallback_tag != beta && $fallback_tag != "$tag" ]] || {
        echo 'invalid fallback historical release tag' >&2
        exit 2
    }
fi

error_file=$(mktemp)
trap 'rm -f "$error_file"' EXIT

tag_state() {
    local candidate=$1 endpoint
    for endpoint in "repos/$repo/git/ref/tags/$candidate" "repos/$repo/releases/tags/$candidate"; do
        if "$gh_bin" api "$endpoint" >/dev/null 2>"$error_file"; then
            return 10
        elif ! grep -Eq '(^|[^0-9])HTTP 404([^0-9]|$)' "$error_file"; then
            cat "$error_file" >&2
            return 20
        fi
    done
    return 0
}

tag_status=0
tag_state "$tag" || tag_status=$?
if [[ $tag_status == 0 ]]; then
    [[ -z $fallback_tag ]] || echo "$tag"
    exit 0
fi
case $tag_status in
    10)
        if [[ -z $fallback_tag ]]; then
            echo "historical release tag already exists: $tag" >&2
            exit 1
        fi
        fallback_status=0
        tag_state "$fallback_tag" || fallback_status=$?
        if [[ $fallback_status == 0 ]]; then
            echo "$fallback_tag"
            exit 0
        fi
        case $fallback_status in
            10) echo "historical release tag already exists: $fallback_tag" >&2 ;;
            *) exit 1 ;;
        esac
        exit 1
        ;;
    *) exit 1 ;;
esac
