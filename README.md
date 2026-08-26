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

构建配置使用共享 `~/.buildroot-dl` 下载缓存、按架构分离的 ccache，并包含 wget/curl 超时与重试设置；历史依据见[上游同步](docs/上游同步.md#历史构建与-ci-同步记录)。

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
