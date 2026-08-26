#### Build Help
```
./build.sh -h
./build.sh --help
```

#### PXEOS 默认 Root 凭据

三种 filesystem 配置（x64、x86、arm64）均启用了 Root 密码登录；默认账号为 `root`，默认密码为 `pxeos`。修改配置后必须重新构建对应架构的 `init.xz` 才会生效。

该密码为所有设备共享的弱默认密码，不应视为加密或安全保护。仅应在隔离的管理网络中使用；在发布或接入生产网络前，必须修改默认密码。
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

自 [FOGProject/fos](https://github.com/FOGProject/fos) 对照同步的提交。历史同步主要覆盖构建、CI、Buildroot 包相关改动；运行时脚本不直接合并，但允许在完成与 RootPXE 协议、存储模型和安全边界的适配后，人工移植其中已验证的缺陷修复。不得把 FOG 的运行时脚本或服务端 endpoint 原样覆盖到 PXEOS。

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

---

### 待同步评估（2026-08-26）

核对基线为 [b740148](https://github.com/FOGProject/fos/commit/b7401483483f1ab085397d9d5be6f7590beb1b8e) 至当前 `master`：上游领先 138 个提交、涉及 78 个文件。PXEOS 本地仓库不保留该基线提交对象，不能安全地直接 `cherry-pick`；以下均为按功能人工比对、测试后移植的候选项，不属于“已同步记录”。

| 优先级 | 上游提交 | 主题与适用性 | 动作与 RootPXE 结论 |
|---|---|---|---|
| P0 | [5419788](https://github.com/FOGProject/fos/commit/5419788)、[85e8138](https://github.com/FOGProject/fos/commit/85e8138) | 主机名历史清理；前者仅移除无效的大写 `HOSTNAME_EARLY`，原始 `hostearly` 仍存在；后者将 `changeHostname` 数组化并减少重复。 | **等价重构，不直接移植。** RootPXE 应使用服务端下发的 `hostName` 与任务 `changeHostname` 契约，移除 `hostname`、`hostearly`、`HOSTNAME_EARLY` 的分裂门控。 |
| P0 | [e261c3b](https://github.com/FOGProject/fos/commit/e261c3b) | 修复 capture/restore 管道静默失败。 | **等价核对。** 本地已有 `pipefail`、`rootpxe_wait_for_writers` 等能力；逐条核对失败路径、完成回调和 attention 上报，不能盲目覆盖。 |
| P0 | [bd10d02](https://github.com/FOGProject/fos/commit/bd10d02) | 支持 10 个及以上分区的匹配。 | **直接移植候选。** 先补回归样例，确认不影响 RootPXE 镜像格式与分区参数。 |
| P0 | [19c2726](https://github.com/FOGProject/fos/commit/19c2726)、[05c2a31](https://github.com/FOGProject/fos/commit/05c2a31) | 所有 `sfdisk` 动作按逻辑扇区单位换算、逻辑扇区不匹配时拒绝写盘；覆盖 4Kn 场景。 | **直接移植候选。** 作为写盘前强校验；必须配合虚拟 512e/4Kn、真实设备回归。 |
| P0 | [3c8f014](https://github.com/FOGProject/fos/commit/3c8f014)、[1f3b095](https://github.com/FOGProject/fos/commit/1f3b095) | golden harness 与 MBR 相关测试安全网。 | **优先移植测试思路/安全网。** 先建立本地可重复分区样例，再决定运行时代码差异。 |
| P1 | [aa8ce6d](https://github.com/FOGProject/fos/commit/aa8ce6d)、[eeebaea](https://github.com/FOGProject/fos/commit/eeebaea)、[1f3b095](https://github.com/FOGProject/fos/commit/1f3b095) | MBR 扩展分区、逻辑分区创建与测试。 | **逐差异审计。** 本地已有部分相关实现，先比对后再按缺口移植，不以“上游较新”覆盖本地定制。 |
| P1 | [60cbf9d](https://github.com/FOGProject/fos/commit/60cbf9d)、[a8c617d](https://github.com/FOGProject/fos/commit/a8c617d) | LVM 每 LV 格式与扩容。 | **暂缓为独立阶段。** 与 RootPXE 后续“捕获原始分区布局、部署时固定/指定大小/百分比/剩余空间”能力关联，不与主机名功能捆绑。 |
| P1 | [0d005a1](https://github.com/FOGProject/fos/commit/0d005a1)、[8de2caa](https://github.com/FOGProject/fos/commit/8de2caa)、[0226b75](https://github.com/FOGProject/fos/commit/0226b75)、[7cb1289](https://github.com/FOGProject/fos/commit/7cb1289)、[5cbd8d9](https://github.com/FOGProject/fos/commit/5cbd8d9) | 可重复构建、下载重试、镜像与哈希验证。 | **高优先级人工同步候选。** 保留 PXEOS 自有下载源、离线策略和哈希约束。 |
| P1 | [ee9f2d9](https://github.com/FOGProject/fos/commit/ee9f2d9) | 网络诊断信息。 | **直接借鉴候选。** 输出必须过滤 execution token、SMB 密码和凭据文件路径。 |
| P2 | [49bf078](https://github.com/FOGProject/fos/commit/49bf078)、[5805397](https://github.com/FOGProject/fos/commit/5805397)、[7eec50f](https://github.com/FOGProject/fos/commit/7eec50f) | ARM64 gzip 启动、平台配置和 QEMU 验证。 | **按真实 ARM64 需求安排。** 需要 ARM64 PXE/QEMU 或实体设备验证后才引入。 |
| P2 | [574ca45](https://github.com/FOGProject/fos/commit/574ca45)、[bc9ee24](https://github.com/FOGProject/fos/commit/bc9ee24)、[07c8487](https://github.com/FOGProject/fos/commit/07c8487) | 内核 6.18.38、Realtek r8169、PCIe ASPM。 | **独立硬件栈升级。** 需网络、存储、PXE、休眠/唤醒等硬件回归，不能随功能改动升级。 |
| P3 | [408f27c](https://github.com/FOGProject/fos/commit/408f27c) | 删除未使用 NBD 内核配置。 | **低优先级可选清理。** 不影响当前 RootPXE 成像流程。 |
| 排除 | [4519e63](https://github.com/FOGProject/fos/commit/4519e63) | 自动重格式化 NVMe。 | **默认排除。** 具有破坏性，只有单独明确授权、可见告警和专门测试后才可考虑。 |
| 排除 | [5aed809](https://github.com/FOGProject/fos/commit/5aed809) | multicast 成像。 | **排除。** RootPXE 当前无 multicast 服务与任务契约。 |
| 排除 | [a89dec1](https://github.com/FOGProject/fos/commit/a89dec1) | FOG 错误上报 endpoint。 | **不直接同步。** RootPXE 已有 token + MAC + attention 协议，仅借鉴失败路径测试思路。 |
| 暂缓 | 上游 Secure Boot、UKI、USB、wipe 等大组 | 范围大且与当前主机名/成像正确性无直接耦合。 | **当前需求外。** 另立需求、方案与硬件验收后再评估。 |

结论：主机名功能优先完成自有协议适配和测试；`bd10d02`、4Kn/扇区保护、golden 安全网及静默失败等价核对列 P0。后续“单磁盘镜像（可调整大小）增强”以前述 P0 分区安全能力为前置，以 MBR 三提交差异审计和 LVM 两阶段设计为依赖；它是 RootPXE 的 Schema/API/UI/任务快照产品能力，PXEOS 仅负责采集、解析、校验与落盘，不能把 FOS 的底层脚本直接当作完整方案。其管理端入口固定为“镜像管理 → 详情”：非 `image_type=n` 分区信息只读，`image_type=n` 仅编辑部署布局，已创建任务仍使用布局快照。LVM 分区布局和硬件/内核升级不得捆绑进主机名功能。
