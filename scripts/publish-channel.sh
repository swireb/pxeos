#!/usr/bin/env bash
# 覆盖固定频道的资源和清单；JSON 始终最后上传。
set -euo pipefail

usage() {
    echo "usage: $0 --repo OWNER/REPO --channel latest|beta --target GIT_SHA --manifest FILE --resource-dir DIR" >&2
}

repo=''
channel=''
target=''
manifest=''
resource_dir=''
gh_bin=${GH_BIN:-gh}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) repo=${2-}; shift 2 ;;
        --channel) channel=${2-}; shift 2 ;;
        --target) target=${2-}; shift 2 ;;
        --manifest) manifest=${2-}; shift 2 ;;
        --resource-dir) resource_dir=${2-}; shift 2 ;;
        *) usage; exit 2 ;;
    esac
done

[[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo 'invalid repository' >&2; exit 2; }
[[ $target =~ ^[0-9a-fA-F]{40}$ ]] || { echo 'invalid target SHA' >&2; exit 2; }
[[ -s $manifest ]] || { echo 'manifest is missing or empty' >&2; exit 2; }
[[ ! -L $manifest ]] || { echo 'manifest must not be a symlink' >&2; exit 2; }
[[ -d $resource_dir ]] || { echo 'resource directory is missing' >&2; exit 2; }

case "$channel" in
    latest) title='Latest Release'; prerelease=false; make_latest=true ;;
    beta) title='Latest Beta'; prerelease=true; make_latest=false ;;
    *) echo 'channel must be latest or beta' >&2; exit 2 ;;
esac

# 在任何远端调用前严格验证频道文件名和下载 schema。
manifest_state=$(python3 - "$manifest" "$channel" "$repo" "$resource_dir" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

manifest_path = pathlib.Path(sys.argv[1])
channel = sys.argv[2]
repo = sys.argv[3]
resource_dir = pathlib.Path(sys.argv[4])
if manifest_path.name != "pxeos.json" or manifest_path.is_symlink():
    raise SystemExit("manifest filename does not match the requested channel")
try:
    document = json.loads(manifest_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid manifest: {error}")
if set(document) != {"kernels"} or not isinstance(document["kernels"], list):
    raise SystemExit("manifest must contain only a kernels list")
mapping = {"x86": ("bzImage32", "init_32.xz"), "x64": ("bzImage", "init.xz"), "arm64": ("arm_Image", "arm_init.cpio.gz")}
tag_pattern = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
seen = set()
for entry in document["kernels"]:
    if not isinstance(entry, dict) or set(entry) != {"arch", "version", "kernel", "initrd"}:
        raise SystemExit("manifest contains an invalid kernel entry")
    if entry["arch"] not in mapping or entry["arch"] in seen or not isinstance(entry["version"], str) or not tag_pattern.fullmatch(entry["version"]) or entry["version"] in {"latest", "beta"}:
        raise SystemExit("manifest contains an invalid architecture or version")
    seen.add(entry["arch"])
    for asset, filename in zip((entry["kernel"], entry["initrd"]), mapping[entry["arch"]]):
        if not isinstance(asset, dict) or set(asset) != {"url", "sha256"}:
            raise SystemExit("manifest contains an invalid asset")
        path = resource_dir / filename
        if not isinstance(asset["url"], str) or asset["url"] != f"https://github.com/{repo}/releases/download/{channel}/{filename}" or not isinstance(asset["sha256"], str) or len(asset["sha256"]) != 64 or not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
            raise SystemExit("manifest asset fields must be strings")
        hasher = hashlib.sha256()
        with path.open("rb") as file:
            for chunk in iter(lambda: file.read(1024 * 1024), b""):
                hasher.update(chunk)
        if hasher.hexdigest() != asset["sha256"]:
            raise SystemExit("manifest hash does not match a local resource")
if channel == "latest" and seen != set(mapping):
    raise SystemExit("latest manifest must contain all three architectures")
print("empty" if not document["kernels"] else "ready")
PY
) || exit $?

# 一个空清单不移动固定 tag，也不创建空频道 release。
if [[ $manifest_state == empty ]]; then
    echo "skip $channel: manifest has no complete kernel/initrd pair"
    exit 0
fi

python3 - "$resource_dir" <<'PY'
import hashlib
import pathlib
import re
import sys

resource_dir = pathlib.Path(sys.argv[1])
asset_names = (
    "bzImage32",
    "init_32.xz",
    "bzImage",
    "init.xz",
    "arm_Image",
    "arm_init.cpio.gz",
)
for filename in asset_names:
    path = resource_dir / filename
    checksum_path = resource_dir / f"{filename}.sha256"
    if path.is_symlink() or checksum_path.is_symlink():
        raise SystemExit(f"invalid resource symlink: {filename}")
    if not path.exists():
        if checksum_path.exists():
            raise SystemExit(f"orphan checksum: {filename}.sha256")
        continue
    if not path.is_file() or path.stat().st_size == 0:
        raise SystemExit(f"invalid resource: {filename}")
    if not checksum_path.is_file() or checksum_path.stat().st_size == 0:
        raise SystemExit(f"missing checksum: {filename}.sha256")
    try:
        text = checksum_path.read_bytes().decode("ascii")
    except (OSError, UnicodeDecodeError) as error:
        raise SystemExit(f"invalid checksum: {filename}.sha256: {error}")
    if text.count("\n") != 1 or not text.endswith("\n"):
        raise SystemExit(f"checksum must contain one line: {filename}.sha256")
    match = re.fullmatch(
        rf"(?P<digest>[0-9A-Fa-f]{{64}}) +(?P<binary>\*)?{re.escape(filename)}\n",
        text,
    )
    if match is None:
        raise SystemExit(f"checksum path does not match asset: {filename}.sha256")
    hasher = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            hasher.update(chunk)
    if hasher.hexdigest().lower() != match.group("digest").lower():
        raise SystemExit(f"checksum does not match asset: {filename}")
PY

ref_endpoint="repos/$repo/git/ref/tags/$channel"
refs_endpoint="repos/$repo/git/refs"
release_endpoint="repos/$repo/releases"
error_file=$(mktemp)
trap 'rm -f "$error_file"' EXIT

# 所有读取都在移动 mutable ref 前完成。仅 HTTP 404 可按首次创建处理。
if "$gh_bin" api "$ref_endpoint" >/dev/null 2>"$error_file"; then
    ref_exists=true
elif grep -q 'HTTP 404' "$error_file"; then
    ref_exists=false
else
    cat "$error_file" >&2
    exit 1
fi

if release_metadata=$("$gh_bin" api "$release_endpoint/tags/$channel" -q '(.id|tostring) + ":" + (.immutable|tostring)' 2>"$error_file"); then
    release_id=${release_metadata%%:*}
    immutable=${release_metadata#*:}
    [[ $release_id =~ ^[0-9]+$ ]] || { echo "channel release $channel has an invalid ID" >&2; exit 1; }
    [[ $immutable == false ]] || { echo "channel release $channel is immutable" >&2; exit 1; }
    release_exists=true
elif grep -q 'HTTP 404' "$error_file"; then
    release_exists=false
else
    cat "$error_file" >&2
    exit 1
fi

if [[ $ref_exists == true ]]; then
    "$gh_bin" api --method PATCH "$refs_endpoint/tags/$channel" -f sha="$target" -F force=true
else
    "$gh_bin" api --method POST "$refs_endpoint" -f ref="refs/tags/$channel" -f sha="$target"
fi

if [[ $release_exists == true ]]; then
    "$gh_bin" api --method PATCH "$release_endpoint/$release_id" \
        -f name="$title" \
        -f body="PXEOS download manifest for this channel." \
        -F prerelease="$prerelease" \
        -f make_latest="$make_latest"
else
    "$gh_bin" api --method POST "$release_endpoint" \
        -f tag_name="$channel" \
        -f target_commitish="$target" \
        -f name="$title" \
        -f body="PXEOS download manifest for this channel." \
        -F prerelease="$prerelease" \
        -f make_latest="$make_latest"
fi

for asset in bzImage32 init_32.xz bzImage init.xz arm_Image arm_init.cpio.gz; do
    if [[ -e "$resource_dir/$asset" ]]; then
        "$gh_bin" release upload "$channel" "$resource_dir/$asset" "$resource_dir/$asset.sha256" --clobber --repo "$repo"
    fi
done
"$gh_bin" release upload "$channel" "$manifest#$(basename "$manifest")" --clobber --repo "$repo"
