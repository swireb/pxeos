# PXEOS 构建指南

PXEOS 的协议、安全、硬件与故障处理说明已按主题拆分；本页只保留构建入口、构建安全提示与文档索引。

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

## 文档索引

- [安全配置](docs/安全配置.md)：默认 Root 凭据与敏感信息边界。
- [上游同步](docs/上游同步.md)：历史构建/CI 与 FOG 官方提交同步记录。
- [硬件兼容性](docs/硬件兼容性.md)：Linux 6.18.38、ARM64、Realtek、r8169、ASPM 与构建验证边界。
- [RootPXE 集成](docs/RootPXE集成.md)：Schema、布局、LVM、主机名、NVMe、permit 与重试闭环。
- [故障处理](docs/故障处理.md)：capture/restore、attention、finish 与联调清单。
- [文档格式](docs/文档格式.md)：现有文档格式规范。
