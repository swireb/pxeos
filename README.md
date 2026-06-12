#### Build Help
```
./build.sh -h
./build.sh --help
```
#### Build Everything
```
./build.sh -n
```
#### Build all inits only
```
./build.sh -nf
```
#### Build 64 bit (x64) init
```
./build.sh -nfa x64
```
#### Build 32 bit (x86) init
```
./build.sh -nfa x86
```
#### Build ARM 64 bit init
```
./build.sh -nfa arm64
```
#### Build all kernels only
```
./build.sh -nk
```
#### Build 64 bit (x64) kernel
```
./build.sh -nka x64
```
#### Build 32 bit (x86) kernel
```
./build.sh -nka x86
```
#### Build ARM 64 bit kernel
```
./build.sh -nka arm64
```
#### Verbose filesystem build (show make output on screen)
```
./build.sh -nfa x64 -v
```
#### Download Buildroot source packages only (no full build)
```
./build.sh --fs-download-only -a x64
./build.sh -i --fs-download-only
```

---

### FOG 上游同步记录

自 [FOGProject/fos](https://github.com/FOGProject/fos) 对照同步的提交。**仅同步构建/CI/Buildroot 包相关改动**，不同步 initrd 运行时脚本（`rootfs_overlay/bin/pxeos.*`、`funcs.sh` 等）。

| 提交 | 说明 | PXEOS 改动 |
|------|------|------------|
| [b740148](https://github.com/FOGProject/fos/commit/b7401483483f1ab085397d9d5be6f7590beb1b8e) | 升级 GitHub Actions 依赖 | `.github/workflows/beta.yml`、`release.yml`、`usb.yml`：`ubuntu-24.04`，`checkout@v6`，`upload-artifact@v7`，`download-artifact@v8`，`action-gh-release@v3` |
| [87d99ee](https://github.com/FOGProject/fos/commit/87d99eeed25cba11f8ffd31e680aab3034014725) | Buildroot 配置加速构建 | `configs/fsarm64.config`、`fsx64.config`、`fsx86.config`：共享 `~/.buildroot-dl`、按架构分离 ccache、wget/curl 超时与重试 |
| [30345ca](https://github.com/FOGProject/fos/commit/30345cadec69fdab27891f1a003886a17d9e57f2) | filesystem 构建 verbose 选项 | `build.sh`：`-v` / `--verbose` |
| [e6ef67e](https://github.com/FOGProject/fos/commit/e6ef67e2521cf87e3d4278edc9ed51ccd46a5dea) | 仅下载 Buildroot 源码包 | `build.sh`：`--fs-download-only` |
| [abf4450](https://github.com/FOGProject/fos/commit/abf44507a82911df7448ad882802689f50e8327f) | CI 缓存 DL 与 ccache | `beta.yml`：`download_filesystem_packages` job；initrd job 恢复 `~/.buildroot-dl` 与 `~/.buildroot-ccache-*` |
| [7667e9c](https://github.com/FOGProject/fos/commit/7667e9ca231fc5999efc7a1948723f646de6953e) | Cabextract 1.4 → 1.11 | `Buildroot/package/cabextract/cabextract.mk` |
| [759b8c9](https://github.com/FOGProject/fos/commit/759b8c90db2a0218a8800f39f63933684f593137) | Buildroot 升级至 2026.02.1 | `build.sh`；`configs/fs*.config`（基于 FOG defconfig，保留 PXEOS 板级/包配置） |
| [3c2394f](https://github.com/FOGProject/fos/commit/3c2394f2a49a16e59b110710cda560ce7cb3212b) | ntfs-3g 升级至 2026.2.25 | `patch/filesystem/fs.patch` |

**PXEOS 保留项（未随 FOG 覆盖）：** `hostname=pxeos`，`board/PXEOS/PXEOS/`，`BR2_PACKAGE_PARTCLONE`（0.3.47 单包），`BR2_PACKAGE_PXEOS` 等 PXEOS 专用包。
