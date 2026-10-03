#!/usr/bin/env python3
"""从 PXEOS 发行产物生成清单。

省略下载频道时，资源 URL 固定指向传入的历史 release tag；显式指定
``latest`` 或 ``beta`` 时，资源 URL 指向对应的可变频道。
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys


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
    parser.add_argument("--download-channel", choices=("latest", "beta"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--require-all", action="store_true")
    return parser.parse_args()


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def asset(path: Path, repository: str, channel: str) -> dict[str, str]:
    return {
        "url": f"https://github.com/{repository}/releases/download/{channel}/{path.name}",
        "sha256": digest(path),
    }


def generate(
    input_dir: Path, repository: str, tag: str, channel: str | None, require_all: bool
) -> dict[str, list[dict[str, object]]]:
    if not REPOSITORY_PATTERN.fullmatch(repository):
        raise ValueError("--repo must be an owner/repository reference")
    if not TAG_PATTERN.fullmatch(tag) or tag in MUTABLE_ALIASES:
        raise ValueError("--tag must be a historical release tag, not latest or beta")
    download_ref = tag if channel is None else channel

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
                    "kernel": asset(kernel, repository, download_ref),
                    "initrd": asset(initrd, repository, download_ref),
                }
            )
        elif require_all:
            missing.append(architecture)

    if missing:
        raise ValueError("missing complete kernel/initrd pairs for: " + ", ".join(missing))
    return {"kernels": kernels}


def main() -> int:
    args = parse_arguments()
    try:
        manifest = generate(args.input_dir, args.repo, args.tag, args.download_channel, args.require_all)
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
