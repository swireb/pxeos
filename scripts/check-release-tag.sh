#!/usr/bin/env bash
# 历史发布 tag 是不可变下载 URL 的一部分，创建前必须保持唯一。
set -euo pipefail

repo=''
tag=''
gh_bin=${GH_BIN:-gh}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) repo=${2-}; shift 2 ;;
        --tag) tag=${2-}; shift 2 ;;
        *) echo "usage: $0 --repo OWNER/REPO --tag HISTORICAL_TAG" >&2; exit 2 ;;
    esac
done

[[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo 'invalid repository' >&2; exit 2; }
[[ $tag =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $tag != latest && $tag != beta ]] || {
    echo 'invalid historical release tag' >&2
    exit 2
}

error_file=$(mktemp)
trap 'rm -f "$error_file"' EXIT
for endpoint in "repos/$repo/git/ref/tags/$tag" "repos/$repo/releases/tags/$tag"; do
    if "$gh_bin" api "$endpoint" >/dev/null 2>"$error_file"; then
        echo "historical release tag already exists: $tag" >&2
        exit 1
    elif ! grep -q 'HTTP 404' "$error_file"; then
        cat "$error_file" >&2
        exit 1
    fi
done
