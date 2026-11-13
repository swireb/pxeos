#!/usr/bin/env python3
"""从 PXEOS 发行产物生成清单。

省略下载频道时，资源 URL 固定指向传入的历史 release tag；显式指定
``latest`` 或 ``beta`` 时，资源 URL 指向对应的可变频道。
指定 ``--download-base-url`` 时，资源 URL 使用给定的 HTTPS 版本目录。
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit


ARCHITECTURES = (
    ("x86", "bzImage32", "init_32.xz"),
    ("x64", "bzImage", "init.xz"),
    ("arm64", "arm_Image", "arm_init.cpio.gz"),
)
TAG_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
REPOSITORY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
MUTABLE_ALIASES = {"latest", "beta"}


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--required-server-version", required=True)
    download = parser.add_mutually_exclusive_group()
    download.add_argument("--download-channel", choices=("latest", "beta"))
    download.add_argument("--download-base-url")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--require-all", action="store_true")
    return parser.parse_args()


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def https_base_url(value: str, label: str) -> str:
    error = f"{label} must be an HTTPS URL without credentials, query or fragment"
    if not re.fullmatch(r"https://[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+(?:/[A-Za-z0-9._~-]+)*/?", value):
        raise ValueError(error)
    url = urlsplit(value)
    path = url.path.rstrip("/")
    if any(segment in {".", ".."} for segment in path.split("/")):
        raise ValueError(f"{label} has an invalid path")
    return f"https://{url.netloc}{path}"


def asset(path: Path, download_base: str) -> dict[str, str]:
    return {
        "url": f"{download_base}/{path.name}",
        "sha256": digest(path),
    }


def generate(
    input_dir: Path, repository: str, tag: str, channel: str | None, require_all: bool, required_server_version: str,
    download_base_url: str | None = None,
) -> dict[str, object]:
    if not re.fullmatch(r"(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})", required_server_version) or any(int(part) > 65535 for part in required_server_version.split(".")):
        raise ValueError("--required-server-version must have three components in 0..65535 without leading zeros or suffixes")
    if not REPOSITORY_PATTERN.fullmatch(repository):
        raise ValueError("--repo must be an owner/repository reference")
    if not TAG_PATTERN.fullmatch(tag) or tag in MUTABLE_ALIASES:
        raise ValueError("--tag must be a historical release tag, not latest or beta")
    download_ref = tag if channel is None else channel
    download_base = (
        https_base_url(download_base_url, "--download-base-url")
        if download_base_url is not None
        else f"https://github.com/{repository}/releases/download/{download_ref}"
    )

    kernels: list[dict[str, object]] = []
    missing: list[str] = []
    for architecture, kernel_name, initrd_name in ARCHITECTURES:
        kernel = input_dir / kernel_name
        initrd = input_dir / initrd_name
        kernel_present = kernel.exists() or kernel.is_symlink()
        initrd_present = initrd.exists() or initrd.is_symlink()
        for path, present in ((kernel, kernel_present), (initrd, initrd_present)):
            if present and (path.is_symlink() or not path.is_file() or path.stat().st_size == 0):
                raise ValueError(f"asset is not a non-empty regular file: {path.name}")
        kernel_ok = kernel_present
        initrd_ok = initrd_present
        if kernel_ok and initrd_ok:
            kernels.append(
                {
                    "arch": architecture,
                    "version": tag,
                    "kernel": asset(kernel, download_base),
                    "initrd": asset(initrd, download_base),
                }
            )
        elif require_all:
            missing.append(architecture)

    if missing:
        raise ValueError("missing complete kernel/initrd pairs for: " + ", ".join(missing))
    return {"requiredServerVersion": required_server_version, "kernels": kernels}


def main() -> int:
    args = parse_arguments()
    try:
        manifest = generate(
            args.input_dir, args.repo, args.tag, args.download_channel, args.require_all,
            args.required_server_version, args.download_base_url,
        )
    except (OSError, ValueError) as error:
        print(f"pxeos manifest: {error}", file=sys.stderr)
        return 1

    try:
        args.output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    except OSError as error:
        print(f"pxeos manifest: cannot write {args.output}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
