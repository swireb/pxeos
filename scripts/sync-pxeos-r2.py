#!/usr/bin/env python3
"""将 GitHub 发布产物同步到可选的 R2 下载源。"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.request import urlopen
from zipfile import BadZipFile, ZipFile


RCLONE_PACKAGE = "rclone-v1.73.5-linux-amd64"
# https://github.com/rclone/rclone/releases/expanded_assets/v1.73.5
RCLONE_SHA256 = "932cf4b7484de74d82b4875488e0009469fd21f9904673385184520fe11a1bf0"


def install_rclone(directory: Path) -> Path:
    archive = directory / f"{RCLONE_PACKAGE}.zip"
    url = f"https://github.com/rclone/rclone/releases/download/v1.73.5/{archive.name}"
    with urlopen(url, timeout=60) as response, archive.open("wb") as output:
        shutil.copyfileobj(response, output)
    with archive.open("rb") as file:
        checksum = hashlib.file_digest(file, "sha256").hexdigest()
    if checksum != RCLONE_SHA256:
        raise ValueError("rclone archive SHA-256 mismatch")
    binary = directory / "rclone"
    with ZipFile(archive) as package, package.open(f"{RCLONE_PACKAGE}/rclone") as source, binary.open("wb") as output:
        shutil.copyfileobj(source, output)
    binary.chmod(0o700)
    return binary


def publish(args: argparse.Namespace, access_key_id: str, secret_access_key: str) -> None:
    config = {
        name: os.environ.get(name, "")
        for name in ("R2_ENDPOINT", "R2_BUCKET", "R2_PREFIX", "R2_PUBLIC_BASE_URL")
    }
    missing = [name for name, value in config.items() if not value]
    if missing:
        raise ValueError("missing Actions secrets: " + ", ".join(missing))
    endpoint, bucket, prefix, public_base = (
        config[name] for name in ("R2_ENDPOINT", "R2_BUCKET", "R2_PREFIX", "R2_PUBLIC_BASE_URL")
    )
    if not re.fullmatch(r"https://[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/?", endpoint):
        raise ValueError("R2_ENDPOINT must be the HTTPS S3 endpoint without a bucket path")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,61}[a-z0-9]", bucket):
        raise ValueError("R2_BUCKET must be a valid R2 bucket name")
    if not all(re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]*", part) for part in prefix.split("/")):
        raise ValueError("R2_PREFIX must be a relative path with non-empty segments and no . or .. segments")
    tag_prefix = "Release-" if args.channel == "latest" else "Beta-"
    if not args.tag.startswith(tag_prefix):
        raise ValueError(f"--tag for the {args.channel} channel must start with {tag_prefix}")

    version_path = f"{prefix}/{args.tag}"
    remote_version = f"r2:{bucket}/{version_path}"
    remote_channel = f"r2:{bucket}/{prefix}/{args.channel}/pxeos.json"
    artifact_dir = args.input_dir.resolve()
    with (
        tempfile.TemporaryDirectory(prefix="pxeos-r2-", dir=os.environ.get("RUNNER_TEMP") or None) as temp,
        tempfile.TemporaryDirectory(prefix=".r2-", dir=artifact_dir) as staged,
    ):
        workdir, staging_dir = Path(temp), Path(staged)
        manifest = staging_dir / "pxeos.json"
        generated = subprocess.run(
            [sys.executable, str(Path(__file__).with_name("generate-pxeos-manifest.py")),
             "--input-dir", str(artifact_dir), "--repo", args.repo, "--tag", args.tag,
             "--required-server-version", args.required_server_version, "--require-all",
             "--download-base-url", f"{public_base.removesuffix('/')}/{version_path}",
             "--output", str(manifest)],
        )
        if generated.returncode:
            raise ValueError("cannot generate the R2 download manifest")

        names = [manifest.name]
        for kernel in json.loads(manifest.read_text(encoding="utf-8"))["kernels"]:
            for asset in (kernel["kernel"], kernel["initrd"]):
                name = asset["url"].rsplit("/", 1)[-1]
                checksum = artifact_dir / f"{name}.sha256"
                if checksum.is_symlink() or not checksum.is_file():
                    raise ValueError(f"missing or invalid checksum file: {checksum.name}")
                match = re.fullmatch(rf"([0-9A-Fa-f]{{64}}) +\*?{re.escape(name)}\n", checksum.read_text(encoding="ascii"))
                if match is None or match[1].lower() != asset["sha256"]:
                    raise ValueError(f"SHA-256 checksum does not match asset: {name}")
                # Keep the original artifacts and GitHub manifest in place without copying large images.
                (staging_dir / name).hardlink_to(artifact_dir / name)
                (staging_dir / checksum.name).hardlink_to(checksum)
                names.extend((name, checksum.name))
        file_list = workdir / "files.txt"
        file_list.write_text("\n".join(names) + "\n", encoding="ascii")

        binary = install_rclone(workdir)
        environment = os.environ | {
            "RCLONE_CONFIG_R2_TYPE": "s3",
            "RCLONE_CONFIG_R2_PROVIDER": "Cloudflare",
            "RCLONE_CONFIG_R2_ENDPOINT": endpoint.removesuffix("/"),
            "RCLONE_CONFIG_R2_ACCESS_KEY_ID": access_key_id,
            "RCLONE_CONFIG_R2_SECRET_ACCESS_KEY": secret_access_key,
            "RCLONE_CONFIG_R2_NO_CHECK_BUCKET": "true",
        }
        limits = ["--config", os.devnull, "--transfers", "1", "--checkers", "1", "--buffer-size", "8Mi",
                  "--s3-chunk-size", "16Mi", "--s3-upload-concurrency", "1"]
        allowlist = ["--files-from-raw", str(file_list)]
        operations = (
            ("copy", str(staging_dir), remote_version, "--immutable", "--checksum", *allowlist),
            ("check", str(staging_dir), remote_version, "--download", "--one-way", *allowlist),
            ("copyto", str(manifest), remote_channel, "--ignore-times", "--metadata",
             "--metadata-set", "cache-control=no-store"),
        )
        for operation in operations:
            result = subprocess.run([str(binary), *operation, *limits], env=environment)
            if result.returncode:
                raise ValueError(f"rclone {operation[0]} failed with exit status {result.returncode}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check-secrets", action="store_true")
    parser.add_argument("--input-dir", type=Path)
    parser.add_argument("--repo")
    parser.add_argument("--tag")
    parser.add_argument("--required-server-version")
    parser.add_argument("--channel", choices=("latest", "beta"))
    args = parser.parse_args(argv)
    access_key_id = os.environ.get("R2_ACCESS_KEY_ID", "")
    secret_access_key = os.environ.get("R2_SECRET_ACCESS_KEY", "")
    try:
        if bool(access_key_id) != bool(secret_access_key):
            raise ValueError("R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY must be configured together")
        if not access_key_id:
            print("R2 sync skipped because both access key secrets are unset.")
        if args.check_secrets:
            with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
                output.write(f"enabled={str(bool(access_key_id)).lower()}\n")
        elif access_key_id:
            if not all((args.input_dir, args.repo, args.tag, args.required_server_version, args.channel)):
                parser.error("sync requires --input-dir, --repo, --tag, --required-server-version and --channel")
            publish(args, access_key_id, secret_access_key)
    except (BadZipFile, KeyError, OSError, ValueError) as error:
        print(f"PXEOS R2 sync: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
