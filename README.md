## PXEOS 构建指南

- PXEOS 的协议、安全、硬件与故障处理说明已按主题拆分；本页只保留构建入口、构建安全提示与文档索引。

## 构建帮助

```shell
./build.sh -h
./build.sh --help
```

## 构建命令

## 构建全部产物

```shell
./build.sh -n
```

## 仅构建全部 initramfs

```shell
./build.sh -nf
```

## 构建 x64 initramfs

```shell
./build.sh -nfa x64
```

## 构建 x86 initramfs

```shell
./build.sh -nfa x86
```

## 构建 ARM64 initramfs

```shell
./build.sh -nfa arm64
```

## 仅构建全部内核

```shell
./build.sh -nk
```

## 构建 x64 内核

```shell
./build.sh -nka x64
```

## 构建 x86 内核

```shell
./build.sh -nka x86
```

## 构建 ARM64 内核

```shell
./build.sh -nka arm64
```

## 显示 filesystem 构建详细输出

```shell
./build.sh -nfa x64 -v
```

## 仅下载 Buildroot 源码包

```shell
./build.sh --fs-download-only -a x64
./build.sh -i --fs-download-only
```

## 源码归档下载

- 内核源码归档在构建目录缓存，先使用 CDN 下载域名，失败后尝试备用域名。仅在临时文件完成下载并通过归档校验后，才替换正式缓存。

```text
# 内核源码归档
linux-6.18.38.tar.xz
# 优先与备用下载域名
cdn.kernel.org
www.kernel.org
```

```shell
# 归档校验命令
tar -tJf
```

- Buildroot 源码归档仍使用原有 Buildroot 下载地址，也使用同一临时下载和归档校验策略；这与 Buildroot 构建过程中共享的软件包缓存不同，后者仍由 Buildroot 配置管理。

```text
# Buildroot 共享软件包下载缓存
~/.buildroot-dl
```

- 下载请求配置 30 秒网络操作超时、三次尝试、短暂重试间隔，以及连接拒绝和 429、500、502、503、504 的重试。30 秒不是整个大文件下载的总时长。
- 本仓库的回归测试只验证下载与缓存控制流；不代表完整内核、Buildroot、固件拉取或硬件构建已经通过。

- 构建配置使用共享下载缓存和按架构分离的 ccache；历史依据见[上游同步](docs/上游同步.md#历史构建与-ci-同步记录)。

```text
# 共享下载缓存
~/.buildroot-dl
```

## 三架构产物与构建安全

- 三架构分别使用以下内核和 initramfs 产物。

```text
# x64：内核与 initramfs
bzImage
init.xz
# x86：内核与 initramfs
bzImage32
init_32.xz
# arm64：内核与 initramfs
arm_Image
arm_init.cpio.gz
```

- 修改 initramfs、内核或驱动配置后，必须按目标架构重新构建同批次的内核与 initramfs 产物；发布或回退不得只替换单个内核或 initramfs。完整硬件验证边界见[硬件兼容性](docs/硬件兼容性.md#构建与回退边界)。

## 镜像发布号与本地构建

- Release/Beta 工作流在任何下载或构建 job 开始前，通过唯一的发布元数据 job 按北京时间生成一次 Release 或 Beta 历史 tag，并只读查询历史 tag/ref 是否已存在。同一分钟重名时，此时就选定带 run-id/attempt 后缀的最终历史 tag。所有架构的构建、历史发布和清单版本都复用这个完整 tag；构建或发布阶段不再次采样时间。发布前重新只读检查已选定的 tag，发现被占用或查询失败即停止，不临时换号。

```text
# 唯一的发布元数据 job
release_metadata
# 历史 tag 格式及可选后缀
Release-YYMMDD-HHmm
Beta-YYMMDD-HHmm
-<run-id>-<attempt>
# 复用完整 tag 的清单与字段
pxeos.json
version
```

- 构建脚本接收构建版本环境变量，一次校验后将同一值写入各架构构建目录中复制后的 overlay；源码版本变量保持未构建占位。普通本地构建未设置该环境变量时，一次生成北京时间的本地版本号，表示本地未发布构建。需要复现已知发布号时可显式传入完整值。

```text
# 构建脚本与版本环境变量
build.sh
PXEOS_BUILD_VERSION
# 源码版本变量与未构建占位
funcs.sh
initversion=unbuilt
# 本地未发布构建版本格式
Local-YYMMDD-HHmm
```

```shell
PXEOS_BUILD_VERSION=Release-261014-0101-1234-2 ./build.sh -nf
PXEOS_BUILD_VERSION=Local-261014-0101 ./build.sh -nfa x64
```

- 允许的值仅为 Release、Beta 或 Local 的上述日期时间格式，可选数字 run-id/attempt 后缀，总长度不超过 64 个 ASCII 字符；空值、空白、换行、旧纯日期号和其他内容会被拒绝。GitHub Actions 构建必须提供已选定的 Release/Beta 历史 tag；缺失、非法或 Local 值会在依赖安装、源码下载和构建前失败。

- 运行时控制台与网络故障诊断统一显示镜像内的完整历史 tag；本地镜像显示本地版本号。控制台另外显示来自服务端 health 的协议号，不用来判断本机镜像版本。服务端内核配置页继续显示清单中的历史版本，因此只有使用同批次发布的内核/initramfs 和清单时才会一致。本修改须重新构建、发布并让客户端启动新 initramfs 后生效；已有制品和已启动的旧镜像不会因网页或 health 更新而自动改变版本号。

```text
# 镜像版本显示
PXEOS version: <完整历史 tag>
Local-...
# API 协议显示
API version: 1
# 清单中的历史版本字段
version
```

## 脚本审计与运行边界

- 脚本离线回归覆盖 DOS 扩展分区识别、分区设备名精确匹配与坏 dump 拒绝、旧 Windows 镜像路径逐轮重置、格式串与路径控制字符、统一恢复格式、时间显示、库存编码、压缩参数和会话清理。分区布局保留 MBR/GPT 原有编号及 LBA 门禁，并以浮点整数格式输出大 LBA 后做精确读回。GPT 的 MBR 文件是 sgdisk backup；只有独立的 GRUB MBR 文件可作为 raw 引导区恢复，且必须是可读普通文件、512 字节整倍数、大小不超过捕获上界 1 MiB。核心库加载失败会停止入口；清理信号不会继续部署。

```text
# GPT 的 sgdisk backup
dN.mbr
# 可作为 raw 引导区恢复的独立文件
dN.grub.mbr
```

- 带任务凭据的 HTTP 请求使用一次性私有目录和请求文件，保持 curl stdin、原有超时及错误码，禁止重定向，并拒绝缺失或非法 HTTP 状态。多播取消仍定位真实 curl PID。任务令牌不再直接出现在这些 curl 的参数中，但当前 iPXE 内核命令行仍可能包含执行令牌，其他进程参数也不因此获得完整保密保证。本次按用户选择保留既有 TLS 信任配置：普通私有 CA/IP 部署的 curl 选项及手工注册的 HTTPS/pin 约束均未改为新信任体系。

```text
# 普通私有 CA/IP 部署保留的 curl 选项
-k
```

- Cloud-init v5 的 user-data、meta-data、可选 network-config 和 vendor-data 均为可手工编辑的模板，由后端仅替换显式宏并在任务创建时一次渲染冻结。PXEOS 只校验八个私有正文/散列字段并离线注入，不渲染或强制改名；固定名称、手填实例标识和原生元数据键保持原字节。linux-nocloud-v5 允许空用户文件并核对真实空字节散列；网络和供应方各非空时增加对应文件，共两个、三个或四个文件。空可选项不创建私有句柄或种子文件，也不删除外来目标文件。模板只报告注入成功，名称回执为 false；SHA-256 只证明内容一致，不能单独证明历史归属。关闭 Cloud-init 不下发正文，捕获不注入；PXEOS 不解析 YAML、不执行目标程序，不引入签名协议或 PKI。

- 计算机名称规则、四态路由和冻结语义统一见根项目 [主机名称策略](../../docs/主机名称策略.md)。名称回执只证明离线文件更新或平台名称配置注入成功，不证明目标开机行为；客户端协议、seed 和受控回滚边界见 [RootPXE 集成](docs/RootPXE集成.md)。

- 以下仍是有意保留的边界：缺少稳定磁盘身份拒绝部署，同容量多盘匹配有歧义时拒绝恢复，可调整镜像不支持部署到更小的磁盘，固定镜像不支持 LVM。XFS 捕获预检允许在获得读写捕获许可后读写挂载并回放日志。共享存储上的捕获发布锁不能按本机 PID 自动删除未知 owner，异常退出后的锁需在确认归属后处理。LVM 包装器只关闭本次子进程中已验证的自有日志 FD；外来 FD 和真实 native 错误继续触发原有失败门禁，不启用全局 FD warning 抑制。

```text
# XFS 捕获预检要求的读写许可
capture_read_write
```

- 静态报告中的三参数 awk 匹配调用在三种目标配置已启用的 gawk 环境中可用；NVMe 重枚举结果已有调用端消费；分区单选 1..10 与现行 API 一致；sgdisk 保留 MBR 的含义也不能推出它会擦掉刚恢复的 GRUB（见[上游手册](https://android.googlesource.com/platform/external/gptfdisk/+/0b5f4df3392ebae7b9a97e8f8d642ca81caa2b26/sgdisk.8)）。这些项不按报告推断改写运行策略。测试入口及 Git Bash 环境替身说明见[测试目录说明](tests/README.md)；本轮验证只使用离线 mock 和普通临时文件，不代表 Buildroot 构建、真实设备、客户端启动或端到端部署已验证。

```text
# 静态报告涉及的调用与命令
awk match()
sgdisk -z
```

## 发布下载清单

- 正式和测试发布均生成发布下载清单。文件只包含内核数组；每个完整架构 pair 记录其架构、历史版本、内核和 initramfs 的 GitHub Release 下载 URL 及实际 SHA-256。x86、x64 与 arm64 的文件名遵循上述产物。正式历史发布附件中的清单 URL 固定指向该历史 tag；正式 latest 频道另有独立的频道清单，测试发布继续使用 beta 频道清单。

```text
# 发布下载清单及其顶层数组
pxeos.json
kernels
# 完整架构 pair 中的架构与历史版本字段
arch
version
```

- 正式发布显示名示例与测试发布显示名示例均使用北京时间。首次历史 tag 与显示名相同；同一分钟发现已有 ref 或 Release 时，仅历史 tag 追加 run-id/attempt 后缀，显示名不变；追加后的 tag 仍冲突或 API 返回非 404 时会停止，不会覆盖历史发布。固定 latest 和 beta Release 分别显示为正式与测试频道名，覆盖本批次二进制、对应 SHA-256 文件及各自频道清单；频道清单 URL 固定指向该频道，版本字段仍是历史构建 tag，正式历史发布附件中的清单 URL 不会随频道更新而改变。正式历史发布与 latest 均不是 prerelease；测试历史发布与 beta 均为 prerelease，且 beta 不会成为 GitHub Latest。频道更新仅允许这两个 tag，遇到不可变 Release、403 或其他非 404 API 错误会失败停止。固定频道覆盖不是原子操作，下载端应先校验资源的 SHA-256；校验失败时重新获取 JSON 后再重试下载，避免使用更新过程中的混合批次。最新发布标记使用 GitHub Releases Update API 的字符串字段，详见[GitHub REST 文档](https://docs.github.com/en/rest/releases/releases#update-a-release)。

```text
# 正式与测试发布显示名示例
Release-261002-1530
Beta-261002-1530
# 北京时间格式与历史 tag 可选后缀
YYMMDD-HHmm
-<run-id>-<attempt>
# 固定频道 tag 与显示名
latest -> Latest Release
beta -> Latest Beta
# 清单中的历史版本字段
version
# GitHub Releases Update API 的字符串字段
make_latest
```

- 正式工作流无自定义 dispatch 输入，并始终构建三种架构的完整内核和 initramfs pair。测试工作流仅提供 arm64、x64 和 x86 三个勾选项；每个勾选项同时控制该架构的内核和 initramfs。至少选择一种架构后，成功完成的工作流会先发布历史版本，再自动更新对应固定频道。

- F2FS 内核支持变更需要重新构建对应架构的内核。FAT16/32 扩容工具属于 initramfs 包：已有对应架构构建缓存时，先在对应目录重新构建 PXEOS 包，再重新生成 initramfs；全新构建会自动包含该包。该工具只面向 512-byte logical-sector FAT16/32 分区，不能替代分区表布局步骤。其 Linux 常规文件镜像验证尚待具备 Linux 工具链的环境完成，因此在该验证完成前不得将其标记为已发布或已通过实机验证。

```text
# 各架构已有的构建缓存目录
fssource<arch>
```

```shell
make pxeos-rebuild
```

- 三份 initramfs 配置把旧的 HTTP、尾斜杠备份源规范为无尾斜杠的 HTTPS 地址；该斜杠拼接问题与镜像缺少特定自定义归档是两个独立问题。构建会迁移已有配置中这三种已知旧值，不会改写自定义镜像、空值或只允许主站的配置。

```text
# 被规范的备份源字段及目标地址
BR2_BACKUP_SITE
https://sources.buildroot.net
# 已有配置文件
.config
# 不改写的只允许主站配置
BR2_PRIMARY_SITE_ONLY=y
```

- 构建前会把下列六个本仓库自定义包预置到 Buildroot 实际打印出的 package 下载目录，缓存和下载都必须与各自唯一的 SHA-256 一致；标准 Buildroot 依赖仍由 Buildroot 的正常下载逻辑处理。所有预置 URL 均为 HTTPS，冷缓存下载、元数据/哈希校验或源码下载命令失败都会终止构建。

```text
# Buildroot 实际打印出的 package 下载目录变量
DL_DIR
```

```shell
make source
```

- cabextract 1.11：主入口为 cabextract.org.uk；已核验备用入口为 Debian 原始源码包。
- chntpw 140201：主入口为 pogostick.net；已核验备用入口为 MacPorts distfiles。
- hivex 1.3.24：主入口为 download.libguestfs.org；已核验备用入口为 Debian 原始源码包。
- partclone 0.3.50：主入口为 GitHub archive；已核验备用入口为 codeload（同一上游的另一入口，不是独立镜像）。
- testdisk 7.2：主入口为 cgsecurity.org；已核验备用入口为 MacPorts distfiles。
- partimage 0.6.9：主入口为 SourceForge；已核验备用入口为 Debian 原始源码包。

- 若用户显式启用只允许主站的配置，预置步骤不访问上述入口，交由 Buildroot 按该受限策略下载。该机制不关闭 TLS 或 Buildroot 的哈希校验；本仓库的 mock 回归只证明控制流和拒绝行为，不等同于完整 Buildroot、镜像站、设备或发布构建成功。

```text
BR2_PRIMARY_SITE_ONLY=y
```

- 不能只替换备用站域名来补救缺包：例如 Void 等镜像的归档路径可能按包名和版本分目录，是否可用必须逐包、逐版本核验。

- Release 与 Beta 共用源码下载和三种架构的编译缓存配置，并在共同的预下载、内核和 initrd 构建阶段采用一致步骤；Beta 仍受所选架构门控，Release 保持全架构发布。

## SSH 调试模式

- 内核参数启用 SSH 调试时，PXEOS 只完成网络初始化并显示非回环全局 IPv4 地址和 SSH 连接提示，随后保持 SSH 与本地控制台可用。该模式不读取 RootPXE 任务、不挂载存储、不扫描或写入磁盘，也不会自动重启或关机；调试人员登录后自行执行需要排查的脚本。未取得全局 IPv4 时，控制台会提示检查网络配置、DHCP 状态和网线连接。

```text
isdebug=yes  # 启用 SSH 调试模式
```

```shell
ssh root@IP
```

- PXEOS 自身固定控制台提示统一采用 ASCII 英文：横幅为 80 列 ASCII 边框，普通消息使用级别列；交互输入提示使用同一列格式且不自行换行；进度操作保持单行形式。SSH 调试入口会显示模式、接口和 SSH 命令。库存与系统信息工具的数据表、菜单和诊断原始内容为结构化视图，保留其必要布局；其中固定说明、警告和输入提示仍使用上述级别列。内核、DHCP、SSH 服务及 Partclone 等第三方程序的原始输出不由 PXEOS 重排。

```text
# 普通消息级别列
[INFO]
[WARN]
[ERROR]
# 单行进度形式
[INFO]  Operation ... Done
# SSH 调试入口显示
Mode: SSH debug.
Interface: <name> (<cidr>).
SSH command: ssh root@<ip>
# 库存与系统信息工具
pxeos.inventory
pxeos.sysinfo
```

## 手动注册 PXEOS

- 手动注册内核参数会在 RAID 发现和普通任务前启动注册入口。此入口只执行带 SPKI pin 的 HTTPS 控制面请求，不会探测、组装、挂载、格式化或写入本地磁盘。必须同时传入完整 HTTPS 控制 URL、手动令牌和严格格式的 SPKI pin；架构与平台也会按内核参数安全白名单导入。

```text
mode=manreg                         # 启动手动注册模式
pxeapi=https://.../pxe/v1/    # 必须传入的 HTTPS 控制 URL
manual_token                        # 必须传入的手动令牌
manual_spki_pin                     # 必须传入的 SPKI pin
sha256//<base64-sha256>             # SPKI pin 的严格格式
manual_arch                         # 安全白名单导入的架构参数
manual_platform                     # 安全白名单导入的平台参数
# 手动注册入口
pxeos.man.reg
```

- 交互使用 Buildroot dialog 的标准 mixedform：Tab/Shift-Tab 切换用户名和遮蔽密码字段，Enter 提交，Esc 请求服务端取消。登录后所有无任务、部署、捕获任务均依次选择镜像和可选分组，列表可分页。确认页显示服务器确认的主机、任务、镜像、分组和覆盖风险；提交只建立服务端后续正常 iPXE/check-in 链，不在客户端执行部署。提交网络中断会使用原 ticket 保持确认状态后重试；取消失败会留在交互界面供重试，绝不自动重启。

```text
# 依次选择镜像和可选分组的任务类型
none
deploy
capture
# 不选择分组的值与显示名称
0 -> No group
```

- 三套 initramfs 配置均启用 dialog，并已通过既有 libcurl 配置提供 curl。更新这些脚本、依赖或配置后，按目标架构重建内核和 initramfs；本仓库 mock 回归仅覆盖客户端控制流，不等同于真实 TTY、Buildroot 构建或设备启动验证。

```text
# 已提供 curl 的既有配置
BR2_PACKAGE_LIBCURL_CURL
```

## 文档索引

- [安全配置](docs/安全配置.md)：默认 Root 凭据与敏感信息边界。
- [上游同步](docs/上游同步.md)：历史构建/CI 与 FOG 官方提交同步记录。
- [硬件兼容性](docs/硬件兼容性.md)：Linux 6.18.38、ARM64、Realtek、r8169、ASPM 与构建验证边界。
- [RootPXE 集成](docs/RootPXE集成.md)：Schema、布局、LVM、主机名、NVMe、permit 与重试闭环。
- [故障处理](docs/故障处理.md)：capture/restore、attention、finish 与联调清单。
- [文档格式](docs/文档格式.md)：现有文档格式规范。
- [测试目录说明](tests/README.md)：说明定向回归脚本、运行边界和 fixtures 的用途。
