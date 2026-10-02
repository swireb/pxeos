# PXEOS 构建指南

PXEOS 的协议、安全、硬件与故障处理说明已按主题拆分；本页只保留构建入口、构建安全提示与文档索引。

## 创建 USB 镜像

`create-usb-image.sh` 的第一个参数是发布目录（提供 `bzImage` 与 `init.xz`），并且必须提供一个本地启动资产目录：

```sh
./create-usb-image.sh https://example.invalid/pxeos-release --boot-assets /path/to/boot-assets
```

该目录必须包含由操作者从合法构建产物取得并自行核验的 `memdisk`、`memtest.bin`、`ipxe.krn` 和 `ipxe.efi`。脚本会在创建临时镜像、写入或挂载任何设备前检查这些普通文件；缺失、HTML/文本内容或非 EFI 格式的 `ipxe.efi` 会立即失败。

## Build Help

```sh
./build.sh -h
./build.sh --help
```

## 构建命令

### Build Everything

```sh
./build.sh -n
```

### Build all inits only

```sh
./build.sh -nf
```

### Build 64 bit (x64) init

```sh
./build.sh -nfa x64
```

### Build 32 bit (x86) init

```sh
./build.sh -nfa x86
```

### Build ARM 64 bit init

```sh
./build.sh -nfa arm64
```

### Build all kernels only

```sh
./build.sh -nk
```

### Build 64 bit (x64) kernel

```sh
./build.sh -nka x64
```

### Build 32 bit (x86) kernel

```sh
./build.sh -nka x86
```

### Build ARM 64 bit kernel

```sh
./build.sh -nka arm64
```

### Verbose filesystem build (show make output on screen)

```sh
./build.sh -nfa x64 -v
```

### Download Buildroot source packages only (no full build)

```sh
./build.sh --fs-download-only -a x64
./build.sh -i --fs-download-only
```

## 源码归档下载

- 内核源码归档在构建目录缓存为 `linux-6.18.38.tar.xz`；先使用 `cdn.kernel.org`，失败后尝试 `www.kernel.org`。仅在临时文件完成下载并通过 `tar -tJf` 校验后，才替换正式缓存。
- Buildroot 源码归档仍使用原有 Buildroot 下载地址，也使用同一临时下载和归档校验策略；这与 Buildroot 构建过程中共享的 `~/.buildroot-dl` 软件包缓存不同，后者仍由 Buildroot 配置管理。
- 下载请求配置 30 秒网络操作超时、三次尝试、短暂重试间隔，以及连接拒绝和 `429`、`500`、`502`、`503`、`504` 的重试。30 秒不是整个大文件下载的总时长。
- 本仓库的回归测试只验证下载与缓存控制流；不代表完整内核、Buildroot、固件拉取或硬件构建已经通过。

构建配置使用共享 `~/.buildroot-dl` 下载缓存和按架构分离的 ccache；历史依据见[上游同步](docs/上游同步.md#历史构建与-ci-同步记录)。

## 三架构产物与构建安全

| 架构 | 内核产物 | initramfs 产物 |
|---|---|---|
| x64 | `bzImage` | `init.xz` |
| x86 | `bzImage32` | `init_32.xz` |
| arm64 | `arm_Image` | `arm_init.cpio.gz` |

修改 initramfs、内核或驱动配置后，必须按目标架构重新构建同批次的内核与 initramfs 产物；发布或回退不得只替换单个内核或 initramfs。完整硬件验证边界见[硬件兼容性](docs/硬件兼容性.md#构建与回退边界)。

## 发布下载清单

正式和测试发布均生成 `pxeos.json`。文件只包含 `kernels` 数组；每个完整架构 pair 记录其 `arch`、历史 `version`、内核和 initramfs 的 GitHub Release 下载 URL 及实际 SHA-256。x86、x64 与 arm64 的文件名遵循上表，URL 固定指向对应的可变频道。

正式发布显示名示例为 `Release-261002-1530`，测试发布显示名示例为 `Beta-261002-1530`；两者均使用北京时间 `YYMMDD-HHmm`。首次历史 tag 与显示名相同；同一分钟发现已有 ref 或 Release 时，仅历史 tag 追加 `-<run-id>-<attempt>`，显示名不变；追加后的 tag 仍冲突或 API 返回非 404 时会停止，不会覆盖历史发布。固定 `latest` 和 `beta` Release 分别显示为 `Latest Release` 和 `Latest Beta`，覆盖本批次二进制、对应 SHA-256 文件及各自清单；清单 URL 固定指向该频道，`version` 仍是历史构建 tag。正式历史发布与 `latest` 均不是 prerelease；测试历史发布与 `beta` 均为 prerelease，且 `beta` 不会成为 GitHub Latest。频道更新仅允许这两个 tag，遇到不可变 Release、403 或其他非 404 API 错误会失败停止。固定频道覆盖不是原子操作，下载端应先校验资源的 SHA-256；校验失败时重新获取 JSON 后再重试下载，避免使用更新过程中的混合批次。`make_latest` 使用 GitHub Releases Update API 的字符串字段，详见[GitHub REST 文档](https://docs.github.com/en/rest/releases/releases#update-a-release)。

正式工作流无自定义 dispatch 输入，并始终构建三种架构的完整内核和 initramfs pair。测试工作流仅提供 `arm64`、`x64` 和 `x86` 三个勾选项；每个勾选项同时控制该架构的内核和 initramfs。至少选择一种架构后，成功完成的工作流会先发布历史版本，再自动更新对应固定频道。

F2FS 内核支持变更需要重新构建对应架构的内核。FAT16/32 扩容工具属于 initramfs 包：已有 `fssource<arch>` 构建缓存时，先在对应目录执行 `make pxeos-rebuild`，再重新生成 initramfs；全新构建会自动包含该包。该工具只面向 512-byte logical-sector FAT16/32 分区，不能替代分区表布局步骤。其 Linux 常规文件镜像验证尚待具备 Linux 工具链的环境完成，因此在该验证完成前不得将其标记为已发布或已通过实机验证。

## SSH 调试模式

内核参数传入 `isdebug=yes` 时，PXEOS 只完成网络初始化并显示非回环全局 IPv4 地址和 `ssh root@IP` 连接提示，随后保持 SSH 与本地控制台可用。该模式不读取 RootPXE 任务、不挂载存储、不扫描或写入磁盘，也不会自动重启或关机；调试人员登录后自行执行需要排查的脚本。未取得全局 IPv4 时，控制台会提示检查网络配置、DHCP 状态和网线连接。

PXEOS 自身固定控制台提示统一采用 ASCII 英文：横幅为 80 列 ASCII 边框，普通消息使用 `[INFO]`、`[WARN]` 或 `[ERROR]` 级别列；交互输入提示使用同一列格式且不自行换行；进度操作保持 `[INFO]  Operation ... Done` 的单行形式。SSH 调试入口会显示 `Mode: SSH debug.`、`Interface: <name> (<cidr>).` 和 `SSH command: ssh root@<ip>`。`pxeos.inventory` 与 `pxeos.sysinfo` 的数据表、菜单和诊断原始内容为结构化视图，保留其必要布局；其中固定说明、警告和输入提示仍使用上述级别列。内核、DHCP、SSH 服务及 Partclone 等第三方程序的原始输出不由 PXEOS 重排。

## 手动注册 PXEOS

内核参数 `mode=manreg` 会在 RAID 发现和普通任务前启动 `pxeos.man.reg`。此入口只执行带 SPKI pin 的 HTTPS 控制面请求，不会探测、组装、挂载、格式化或写入本地磁盘。必须同时传入 `pxeapi=https://.../service/pxeos/`、`manual_token` 和格式严格为 `sha256//<base64-sha256>` 的 `manual_spki_pin`；`manual_arch`、`manual_platform` 也会按内核参数安全白名单导入。

交互使用 Buildroot `dialog` 的标准 mixedform：Tab/Shift-Tab 切换用户名和遮蔽密码字段，Enter 提交，Esc 请求服务端取消。登录后所有 `none`、`deploy`、`capture` 任务均依次选择镜像和可选分组（`0` 为 `No group`），列表可分页。确认页显示服务器确认的主机、任务、镜像、分组和覆盖风险；提交只建立服务端后续正常 iPXE/check-in 链，不在客户端执行部署。提交网络中断会使用原 ticket 保持确认状态后重试；取消失败会留在交互界面供重试，绝不自动重启。

三套 initramfs 配置均启用 `dialog`，并已通过既有 `BR2_PACKAGE_LIBCURL_CURL` 提供 `curl`。更新这些脚本、依赖或配置后，按目标架构重建内核和 initramfs；本仓库 mock 回归仅覆盖客户端控制流，不等同于真实 TTY、Buildroot 构建或设备启动验证。

## 文档索引

- [安全配置](docs/安全配置.md)：默认 Root 凭据与敏感信息边界。
- [上游同步](docs/上游同步.md)：历史构建/CI 与 FOG 官方提交同步记录。
- [硬件兼容性](docs/硬件兼容性.md)：Linux 6.18.38、ARM64、Realtek、r8169、ASPM 与构建验证边界。
- [RootPXE 集成](docs/RootPXE集成.md)：Schema、布局、LVM、主机名、NVMe、permit 与重试闭环。
- [故障处理](docs/故障处理.md)：capture/restore、attention、finish 与联调清单。
- [文档格式](docs/文档格式.md)：现有文档格式规范。
- [测试目录说明](tests/README.md)：说明定向回归脚本、运行边界和 fixtures 的用途。
