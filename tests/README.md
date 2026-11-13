## PXEOS 测试目录说明

- 本目录保存 PXEOS 的定向回归脚本。测试未被 CI 工作流显式调用，不等于它没有价值：许多脚本用于本地复现、发布前核对或具备特定工具链的环境验证。每个脚本均应单独运行；此目录不提供一键执行全部测试的入口。

## 部署和捕获审计集合

`pxeos_lifecycle_audit_regression.sh` 串行执行选定的 HTTP、存储控制器和 helper、数据管线、身份初始化及进度回归。每项最多 300 秒，并检查共享 slice 的内存事件。未处理的缺命令诊断按失败记录，即使脚本退出码为 0。

```shell
/home/sysadmin/.codex/bin/codex-build-test bash tests/pxeos_lifecycle_audit_regression.sh
```

部署分区/增长及消息显示契约另行补充执行，不计入上述集合：

```shell
/home/sysadmin/.codex/bin/codex-build-test bash tests/pxeos_partition_regression.sh
/home/sysadmin/.codex/bin/codex-build-test bash tests/pxeos_message_contract_regression.sh
```

分区套件要求 GNU awk（`gawk` 和 `awk` 均应使用 GNU 实现）；native FATgrow 子项还需显式提供 `PXEOS_FATGROW_TEST_BINARY` 和 `PXEOS_FATGROW_TEST_SOURCE`，缺少时会明确报告 SKIP。

该集合需要 Bash、Python、jq、timeout 及存储 helper fixture 所需本机 C/json-c/OpenSSL 开发依赖。每项结果及日志目录由入口返回；失败、超时或缺依赖不能当作通过。真实 NAS、目标磁盘与首启仍须另行补验。

## 测试边界

- 静态契约：读取源码、配置或补丁，核对固定字符串、顺序、清单和构建配置。
- mock/离线回归：使用临时普通文件、临时目录或命令替身，覆盖生产函数的局部行为；通过不代表已经验证 Buildroot 产物、真实磁盘、真实设备或端到端部署。
- 涉及启动、电源和设备操作的用例在隔离环境中运行。网络诊断保留第三方工具的原始数据，固定控制台提示单独核对格式。
- 真实 native 工具链：少数脚本会调用真实 jq、reged、hivex 或 XML 工具；仍应按脚本的隔离条件执行。QEMU 与 FAT 镜像相关验证属于可选环境验证，不在普通 mock 通过的保证范围内。

- 从 PXEOS 子模块目录运行 Bash 脚本的形式如下。

```text
# 相对主仓库根目录的工作目录
packages/pxeos
```

```shell
bash tests/pxeos_os_type_regression.sh
```

- Windows 上运行 Python 发布测试可使用（显式 UTF-8 避免系统默认编码影响源码读取）：

```powershell
py -3 -X utf8 -B tests/release_naming_test.py
py -3 -X utf8 -B tests/pxeos_release_manifest_test.py
py -3 -X utf8 -B tests/pxeos_build_version_test.py
```

- Linux 上可使用对应的 Python 3 命令：

```shell
python3 tests/release_naming_test.py
python3 tests/pxeos_release_manifest_test.py
python3 tests/pxeos_build_version_test.py
```

## 发布与清单（4）

- 脚本及核对范围如下。

```text
release_naming_test.py  # 离线核对发布命名和 Beta 全架构契约。
pxeos_release_manifest_test.py  # 离线核对发布清单和固定发布频道。
pxeos_r2_sync_test.py  # 用本地 rclone 替身验证可选配置、版本化清单 URL、上传范围和频道发布顺序。
pxeos_build_version_test.py  # 以只读 GitHub 查询替身、时间 fixture 和临时 overlay，核对构建前一次选定 Release/Beta 最终 tag、同一分钟重名后缀、全部架构传播、历史/频道清单与镜像同值、跨时区/跨日及不重采样、本地 Local、CI 缺号/非法号拒绝、复制失败不写号、控制台 API/PXEOS 分列、网络诊断安全读取，以及已选 tag 被占用时发布前失败停止。
```

在 Linux 上运行 R2 离线回归。

```shell
/home/sysadmin/.codex/bin/codex-build-test python3 -B tests/pxeos_r2_sync_test.py
```

- 统一版本测试只提取或调用版本函数、构建入口的依赖检查前缀及带命令替身的局部函数，不启动真实 PXEOS、内核或 initramfs 构建，不安装依赖、下载制品或访问 GitHub。Windows 的 Git Bash 可能缺少 IANA 时区数据，时间 fixture 会模拟北京时间转换并检查生产代码传入的北京时间时区；符号链接测试在平台不允许创建时明确跳过。通过这些测试不能推断真实 Actions、Linux 构建、设备启动或发布已验证；运行时的新版本显示仍须重新构建和发布 initramfs 才会生效。

```text
# 生产代码传入的北京时间时区
Asia/Shanghai
```

## 构建与运行时（4）

- 脚本及核对范围如下。

```text
pxeos_build_kernel_regression.sh  # 合并的构建下载安全、依赖和内核相关回归。
pxeos_build_dependencies_test.py  # 用包管理器替身核对 ARM64 交叉编译器需求、自动安装开关、APT 索引刷新与单次重试，以及 DNF 安装路径。
pxeos_build_sources_test.py  # 以离线 mock 核对六个自定义 Buildroot 包的 HTTPS 主/备用预置、唯一 SHA-256、实际 package 下载目录、BR2_PRIMARY_SITE_ONLY 跳过、make source 失败传播及 Release/Beta 公共构建 YAML 契约。
pxeos_gconv_runtime_regression.sh  # 核对 libhivex 所需 glibc gconv Buildroot 配置。
```

- 内核构建回归还提供可选模式，仅在相应构建/QEMU 环境具备时显式运行。分区回归的原生 FAT16/32 常规文件镜像段由环境变量明确门控，只操作 regular image，不应据此推断真实块设备验证。

```text
# 内核构建回归脚本及可选模式
pxeos_build_kernel_regression.sh
--arm64-initrd  # 仅核对 arm64 initrd 格式
--qemu          # 格式核对后运行 QEMU smoke
# 分区回归脚本及原生 FAT 镜像测试环境变量
pxeos_partition_regression.sh
PXEOS_FATGROW_TEST_*
```

## 网络与控制面（2）

- 脚本及核对范围如下。

```text
pxeos_network_storage_regression.sh  # 合并的网络故障诊断、存储和相关离线回归。
pxeos_task_identity_regression.sh  # 核对普通 JSON/form 存储身份、捕获协议、初始化回调和确认空磁盘结果。
```


## 捕获、恢复、存储与分区（19）

- 脚本及核对范围如下。

```text
pxeos_capture_regression.sh  # 核对捕获/恢复管线失败、完成回调、许可与源盘布局/extfs；原执行发布恢复矩阵见 storage controller Python 入口。
pxeos_capture_resume_regression.sh  # 核对捕获元数据、私有副本清理及磁盘许可；不通过发现旧 marker 接管已发布代际。
pxeos_restore_preflight_regression.sh  # 核对恢复制品的离线预检。
pxeos_partition_regression.sh  # 合并的分区安全与布局回归。
pxeos_layout_alignment_regression.sh  # 核对 4Kn 等扇区/布局对齐契约。
pxeos_disk_health_regression.sh  # 核对磁盘健康盘点及上报接口。
pxeos_hardware_inventory_regression.sh  # 核对任务 check-in 后的硬件盘点、PXE 启动网卡标识及限额，使用临时设备夹具和 HTTP 替身。
pxeos_partition_progress_regression.sh  # 核对分区计划、进度 flush 与 LVM 事实。
pxeos_timeline_order_regression.sh  # 使用临时普通文件和真实入口的安全叶级替身，核对准备心跳、pending计划先发、真实零进度开始、部署各镜像类型、MBR-only、初始化续跑、重试/执行身份隔离，以及停止采样并等待在途HTTP替身子进程后才结束数据阶段；不访问真实磁盘或网络，不重排历史事件。
pxeos_partclone_progress_regression.sh  # 核对 Partclone 文本模式 stderr 进度适配。
pxeos_partclone_vt_progress_regression.sh  # 核对 Partclone VT/VCSA 快照进度解析。
pxeos_lvm_console_regression.sh  # 核对 LVM 控制台激活与消息处理。
pxeos_lvm_schema_jq_regression.sh  # 以真实 jq 核对 LVM capture schema 过滤程序。
pxeos_lvm_udev_rules_regression.sh  # 核对 LVM udev 同步及移除 systemd 专用自动激活规则。
pxeos_lvm_multi_regression.sh  # 核对同一磁盘上 1/2/3/5 组彼此独立的一 PV/一 VG/多 linear LV，覆盖正序与倒序布局；默认执行叶级集成回归。
pxeos_mbr_partition_contract_regression.sh  # 核对 DOS/MBR 分区编号、32 位 LBA 与 GPT 边界契约，同时检查 Schema object 和 resolved partition array 两种输入形态。
pxeos_small_disk_layout_regression.sh  # 真实 jq 解析旧 v1/v2 GPT/MBR 布局，验证 1TB 源盘前 300GB 分区部署到 500GB、原始位置不变、不可缩小及远处分区拒绝；真实 sfdisk 仅写临时普通文件，核对 128/512 条目 GPT 的紧凑原始布局、备份空间恰好容纳/少一扇区、UUID/磁盘标识及 usable LBA 读回，不接触物理磁盘。
pxeos_lvm_naming_contract.sh  # 核对 pinned LVM2 官方名称 127 字节边界、保留前缀/内部片段及连字符转义 mapper 名边界。
pxeos_lvm_capture_scan_contract.sh  # 核对 LVM 初次扫描 warning、目标 PV 缺失时 fail-closed，以及普通无 LVM 盘的正向路径。
```

- 上述脚本均按单脚本独立运行；本目录仍不提供一键 full suite，也不因此宣称 CI、真实磁盘或实机部署已验证。

## Windows、Linux 名称、显示与部署身份（12）

- 脚本及核对范围如下。

```text
pxeos_xml_command_regression.sh  # 以私有文件和命令 mock 覆盖 Sysprep XML 写入路径。
pxeos_windows_initialization_regression.sh  # 以真实 hivex/reged/XML 工具覆盖 Windows 主机名与 Sysprep 模板开关矩阵，模板原字节、固定或缺失名称不覆盖、管理名不影响注入及注入回执。
pxeos_windows_hostname_native_regression.sh  # 以真实 reged 写入测试 hive，并由 native 工具只读核验两个 ControlSet 的主机名。
pxeos_windows_display_registry_regression.sh  # 解析只读 MountedDevices 文本导出，不打开真实 hive 或块设备。
pxeos_sysprep_path_regression.sh  # 核对 Sysprep 路径大小写发现、链接拒绝和歧义拒绝。
pxeos_offline_hostname_contract_regression.sh  # 以临时注册表路径和 wrapper 提取核对离线主机名协议。
pxeos_os_type_regression.sh  # 核对系统 ID 到内部诊断名称的稳定映射。
pxeos_display_metadata_regression.sh  # 以临时库存和边界 stub 核对显示元数据。
pxeos_identity_preflight_order_regression.sh  # 核对部署入口中 Windows XML、NoCloud 注入、冻结回执的顺序及旧执行器缺失。
pxeos_deployment_identity_regression.sh  # 核对部署身份工具的 XML 能力门槛与身份契约。
pxeos_linux_hostname_regression.sh  # 真实普通文件事务覆盖 Linux 单标签校验、主机名/回环自身 hosts 更新、CRLF/注释/远端保留、旧名缺失与本机映射去重、路径/模式/硬链接拒绝、回读回滚、外来 inode 不覆盖、清理失败留证、SELinux 配置和工具不参与流程、许可目标唯一根、只读重试和命名四态；不要求 Cloud-init 包或干净缓存/seed。
pxeos_template_injection_regression.sh  # 私有普通文件与设备/XML 边界替身覆盖 v5/v2 新能力、Windows 固定或缺失计算机名称原字节、Cloud 手工名称/固定实例标识/其他元数据键、名称开启仍允许空用户配置、checkin 跳过未使用的管理名称校验、restore 尾部名称隔离和模板只报告注入成功；不证明真实 XML 工具、注册表、磁盘或首启行为。
```

- Windows 原生主机名回归与初始化回归都需要下列环境变量，以及用于 fixture 的 C 编译器、pkg-config 和 hivex 开发头文件/库。后者还要求实际 xml、jq，并以目标挂载路径不存在为隔离前提；不要在已挂载或真实目标盘环境中运行。满足隔离条件后可分别显式执行。

```text
# 两个脚本都要求的环境变量
ROOTPXE_WINDOWS_HOSTNAME_TOOL
ROOTPXE_HIVEX_MINIMAL
ROOTPXE_REGED
# 初始化回归的隔离前提：此路径必须不存在
/ntfs
```

```shell
bash tests/pxeos_windows_hostname_native_regression.sh
bash tests/pxeos_windows_initialization_regression.sh
```

## 原生 Cloud-init（6）

- 脚本及核对范围如下。

```text
pxeos_cloud_init_protocol_regression.sh  # 真实 jq 二次验证 v5 八个私有字段、空用户正文及真实空字节散列、UTF-8/CRLF、网络与供应方空值对、三个各 64 KiB 的总体大响应通过标准输入解析、四个私密文件的 BASHPID/inode/权限证明、独立及组合 unlink 故障后的整份失效与安全重试、旧键/缺失或关闭策略拒绝、四正文及供应方字段与路径脱敏、能力异常不生成请求及模板仅上报注入回执。
pxeos_cloud_init_permit_regression.sh  # 真实首次单盘和MPA许可与source checkin链；覆盖两/三/四文件注入、冻结私密配置、v5能力、许可映射与错误设备拒绝，重试进入rw直接补齐配置，已有缓存保留，以及普通部署/捕获/Windows绕过。
pxeos_cloud_init_seed_regression.sh  # 普通文件覆盖两/三/四文件原始字节、旧内容/半成文件补齐、空用户正文、可选旧文件删除、缓存/其他seed/未知文件保留；NoCloud单行配置/root0644/缺目录自动创建，公用路径安全、预装/禁用、写入失败及重试、SELinux配置和工具不参与流程。
pxeos_cloud_init_mounts_regression.sh  # 设备边界替身覆盖独立usr/var、全部PV与挂载身份/借用清理；目录交换验证独立usr中的init根结构及许可/挂载/清理失败，独立var seed与根etc配置位置，以及拒绝etc/Cloud配置遮盖但允许无关resolv.conf条目。
pxeos_cloud_init_roots_regression.sh  # 普通目录验证有/无release的安全passwd/init根结构、目标内init与usr-merge链接、拒绝boot/home/usr/release-only及不安全根；Cloud注入与离线名称共用真实根发现/全部PV许可，同根去重，拒绝不同根、身份冲突及未许可PV。
pxeos_linux_root_chain_regression.sh  # ordinary/lvm/usr/negative四组逐项输出CASE与计数；串联真实枚举、候选探测、安全根结构、独立usr和唯一选择器，只替换设备事实/LVM报告/mount叶边界与普通夹具owner。覆盖ext2/3/4/XFS、实际init/链接差异、多PV、跨VG usr的设备/UUID/mapper、PARTUUID、无关inactive VG及许可/清理失败；四组须分别受限串行运行。
```

- 上述 fixture 不执行目标 Cloud-init、user-data、真实磁盘、真实 mount 或 LVM。MSYS 使用明确的 Unix 属主/模式替身，Windows 原生符号链接可能因权限拒绝而跳过；SELinux 相关命令使用失败且记录调用的替身，确认初始化不调用它们；不代表真实目标已关闭 SELinux 或已验证首启。

## API、注册、审计与控制台（6）

- 脚本及核对范围如下。

```text
pxeos_api_business_regression.sh  # 合并核对 check-in JSON、业务逻辑和控制台相关回归。
pxeos_audit_regression.sh  # 离线核对审计项和关键源码/补丁约束。
pxeos_hardening_regression.sh  # 以临时文件和 mock 覆盖加固相关失败路径。
pxeos_manual_registration_regression.sh  # 以 endpoint、控制台和重启 mock 覆盖手工注册客户端。
pxeos_mpa_permit_regression.sh  # 以临时文件覆盖 MPA 下载许可的本地分派。
pxeos_php_retirement_regression.sh  # 旧 PHP 运行时及产品 USB 制作/发布入口退役、本地诊断/badblocks mock 和强制 checkin 边界。
```

### 手工注册 HTTPS 跨组件集成

主仓的 `backend/internal/httpapi/manual_registration_pxeos_integration_test.go` 串联真实 HTTPS 服务、实际注册审批与临时 SQLite，以及 PXEOS 生产注册脚本中的 curl/jq 和 S99 启动分支。服务端和客户端均在启动测试运行器的独立网络命名空间内，控制台选择使用替身；不访问宿主总线、真实存储或块设备。

先在受限测试窗口编译 HTTP API 包的测试二进制，将其保存到主仓 `backend/.build-cache` 内。以下为专用入口，从主仓根目录调用；`HTTPAPI_TEST_BINARY` 指向该二进制的绝对路径。编译和执行均须经过 `codex-build-test` 及已核对的资源包装器：共享父限额 8 GiB 内存/32 GiB swap，子任务 2 GiB 内存/0 swap、单 CPU，磁盘上的 `TMPDIR`，Go 使用 `GOMAXPROCS=1`、`GOMEMLIMIT=768MiB` 和 `-p 1`。专用入口只执行固定测试名，不接受额外测试参数。

```shell
bash packages/pxeos/tests/run-startup-regression.sh --manual-http-integration "$HTTPAPI_TEST_BINARY"
```

19个用例覆盖仅注册、注册后部署、注册后采集三种模式各自的正常提交、首次 commit 已完成但回复连接断开后的幂等重放、提交前取消、确认时返回编辑后重新确认、确认后注册权限撤销，以及部署镜像变为未就绪时的服务端拒绝。部署网络用例额外覆盖按模板录入五项系统网络信息、无效 IP 修改后重试，以及带网络信息的 commit 回复丢失重放；核对主机字段与冻结后的任务模板。检查实际数据库只产生一份主机/任务、S99 消费六字段 handoff 后的任务身份与 deploy→down/capture→up 映射、交接文件删除，以及仅注册、取消或拒绝后不进入任务分支。仅注册完成后的明确关机选择与取消后的单次重启请求均由记录脚本模拟；没有执行真实电源命令。2026-11-14 专用运行实际通过19/19，未跳过；普通 Go 测试未进入隔离运行器时会明确跳过本测试。

S99 测试副本只替换一次 handoff 目录赋值，其他分支执行生产代码；任务入口使用记录桩保存已消费字段，并在隔离目录创建 recovery 标记后退出。逐例清除标记，避免用例间污染。本验证不执行真实任务 check-in、镜像传输、磁盘写入或任务完成后的真实电源动作。维护模式的 PE 由 iPXE 直接 SAN 引导，实机 PE 启动不属于这些用例的验证范围。

## 脚本审计回归（3）

- 脚本及核对范围如下。

```text
pxeos_script_audit_regression.sh  # 提取局部函数，以命令替身覆盖扩展分区、SATA/NVMe 名称碰撞、坏分区 dump、单文件恢复、printf、控制字符及数组作用域、恢复格式与选择、时间显示、hash 前置门禁、磁盘容量、假钟倒计时、压缩参数、主机名、库存与 LVM probe 清理、算术错误传播。
pxeos_script_io_regression.sh  # 以临时普通文件核对 NFS/SMB 的 EXIT/INT/TERM 四份 Cloud-init 私有文件清理及自有派生计划清理、umask/trap 保留、缺库及 source 失败、入口停止、有限设备重读、raw 引导区逻辑字节、GPT backup 与 raw 区分及坏 raw 在清表前拒绝、日志折行、严格 JSON 响应、任务库存/磁盘健康/非镜像完成的 HTTP 失败门禁，以及大于 2^31 和接近 GPT 安全整数上界的 LBA 精确读回。设备重读和写入只调用函数替身，不执行真实 sfdisk、nvme 或 LVM。
pxeos_task_http_regression.sh  # 以 curl 替身核对私有 form/JSON 文件原始字节、无附加换行、curl 参数和 stdin、EOF、真实返回码、重定向拒绝及成功/失败/信号/临时目录失败后的清理。
```

- Git Bash 可显式补齐工具路径及设备字符串转换边界，例如：

```shell
export PATH="/usr/bin:/bin:$PWD/tests/fixtures/msys-tools:$PATH"
export MSYS2_ARG_CONV_EXCL=/dev/
bash tests/pxeos_script_audit_regression.sh
bash tests/pxeos_script_io_regression.sh
bash tests/pxeos_task_http_regression.sh
```

- HTTP 测试支持脚本只在测试中读取真实包装器生成的私有请求文件并提供模拟 HTTP header，再交给原有 fixture 的精确字段断言。它不替代生产 curl；不会删去任务、许可或身份断言。MSYS 不能证明原生 Linux 的 0700/0600、FD flag、符号链接、锁与设备行为，相关替身/跳过必须单独列出。大 LBA 回归在当前 gawk 下核对读回和浮点格式契约，不声称实际运行了旧版 mawk。无需真实构建、安装、下载或网络连接。

```text
# HTTP 测试支持脚本
task-http-test-support.sh
```

## Fixtures（两类）

- Windows 显示注册表 fixture 下的注册表导出文本样本用于对应回归，覆盖有效、缺失、空、损坏和冲突的 MountedDevices 导出，不是注册表 hive。

```text
# fixture 目录、文本扩展名与对应回归脚本
fixtures/windows-display-registry/
.reg
pxeos_windows_display_registry_regression.sh
```

- Buildroot LVM2 配方和 udev 修补 fixture 用于对应回归，对照上游配方和修补语义。

```text
# Buildroot LVM2 配方与 udev 修补 fixture
fixtures/buildroot-2026.02.1-lvm2.mk
fixtures/lvm2-udev-sync-91b1dd3.patch
# 对应回归脚本
pxeos_lvm_udev_rules_regression.sh
```

## 网络存储离线回归

- `pxeos_storage_helper_test.py` 使用本机 C 编译器、`pkg-config`、json-c 和 OpenSSL 开发依赖编译并运行临时测试程序，覆盖有界流、对象回执、解析和身份系统调用顺序。文件系统 fixture 会在测试的私有工作目录创建并清理数据，单个测试流超过 200 MiB。运行前将 `TMPDIR` 指向磁盘目录，避免将测试数据写入 tmpfs。
- `storage_helper_fixture.c`是配套本地隔离fixture，不构建Buildroot产物，不应挂载或访问真实NAS/块设备。身份顺序注入用例不能代替真实数值UID/GID权限验证。
- `pxeos_storage_controller_test.py` 使用 Python、Bash、jq 和私有临时普通文件调用当前 `storage-io.sh` 控制流，以受控进程/回调替身核对原 owner/attempt、身份/能力拒绝、发布前各失败点、冻结 finish、只读收尾、原代际发布/回滚、只清原范围、等待 helper 后释放及失败不释放。旧 marker 或目录名不能认领已发布执行，越出原 shadow 的 payload 在 helper 命令前拒绝；SMB 挂载取消仍须等待实际子进程。该入口不编译 C，不访问真实 NAS 或块设备，不能代替原生 helper/身份验证。
- `storage-test-support.sh` 是存储相关 shell/Python fixture 共用的测试支持文件，不是独立测试入口。它加载当前控制器、构造认证 JSON/owner/attempt/boot 上下文并限定私有工作区；仅在原生进程边界提供能力/连接/preflight 替身，在管线回归中以受限普通文件替代远端字节读写，保留真实 producer、压缩与 wait 控制流，不提供真实挂载或 NAS 变更。
- `pxeos_capture_regression.sh` 覆盖捕获和还原管线、完成回调、许可、源盘布局与 extfs。`pxeos_capture_resume_regression.sh` 覆盖元数据校验、私有副本清理与许可。`pxeos_capture_direct_regression.sh` 覆盖直接捕获的 MAC 暂存和发布，原执行恢复由 controller Python 入口覆盖。
- `pxeos_network_storage_regression.sh` 核对网络存储及 SSH 调试入口。Partclone 和任务标识使用各自的定向回归入口。

网络存储、手工注册和存储控制器测试会执行 PXEOS 启动或电源操作脚本。三个入口自动使用 `run-startup-regression.sh`，需要采用合并 `/usr` 布局的 Linux、bubblewrap 和可用的用户命名空间。隔离中只读挂载 PXEOS 源码和运行依赖，使用独立的进程与网络命名空间、设备目录和临时目录。宿主总线不可见，电源管理命令映射到拒绝替身。隔离建立失败时退出。使用 `bash tests/run-startup-regression.sh --probe` 查看隔离属性，使用 `bash tests/pxeos_startup_isolation_test.sh` 验证隔离建立失败和伪造标记都会被拒绝。这两个检查均不执行电源命令。

将 `TMPDIR` 指向磁盘上的可写目录后，从子模块根执行：

```shell
python3 -B tests/pxeos_storage_controller_test.py
python3 -B tests/pxeos_storage_helper_test.py
bash tests/pxeos_capture_regression.sh
bash tests/pxeos_capture_resume_regression.sh
bash tests/pxeos_network_storage_regression.sh
bash tests/pxeos_manual_registration_regression.sh
bash tests/pxeos_partclone_progress_regression.sh
bash tests/pxeos_task_identity_regression.sh
```

三架构构建需核对 helper 及依赖进入各自的 initramfs。真实存储需验证 NFS 3/4.0/4.1/4.2 和 SMB 2.1/3.0/3.0.2/3.1.1 的固定及自动协商、实际挂载和非 guest 会话、NFS AUTH_SYS `0/0` 与 NAS 权限、原工作者未停保护、可信同一主机跨 boot 恢复、数据管线失败及响应丢失。完整范围见根项目[存储系统待验矩阵](../../../docs/存储系统.md#初始化边界与未验证事项)。

### 本地读取性能对照

从 PXEOS 仓库运行。基线提交必须存在于本地 Git 历史，脚本通过 `git show` 读取该提交的 C 源码和 Bash 控制器。运行环境需要 Linux、Python 3.11+、Bash、jq、C 编译器和 json-c/OpenSSL 开发依赖。编译参数默认取自 `pkg-config`，也可用 `ROOTPXE_STORAGE_BENCHMARK_FLAGS` 指定可直接执行的目标 ABI 所需的头文件和链接参数。

```bash
/home/sysadmin/.codex/bin/codex-build-test python3 -B tests/pxeos_storage_read_benchmark.py --baseline 00384223
```

`old` 用 `cat` 向 FIFO 写入，模拟旧版直接读取的数据路径。`baseline` 和 `current` 运行各自的 C 存储助手及 Bash 控制器，由本地替身应答存储检查点。三条路径都用同一个 96 MiB 暖缓存普通文件和接收端 `sha256sum`，两条助手路径还校验其返回的 SHA-256 和字节数。脚本在 1 路和 4 路并发下分别轮换三种路径的执行顺序，各测 3 次并输出吞吐和 CPU 时间中位数。另测一轮记录控制器的 `jq` 调用次数，计数轮的耗时不计入中位数。基准不经过 NAS 或网络，共享主机负载会影响实测耗时，结果无法外推到万台部署。

`pxeos_image_format_regression.sh` 覆盖仅 Gzip/Zstd、级别 0 真正未压缩、退役格式拒绝以及超过 200 MiB 的单文件编解码往返；Partclone 使用普通文件复制替身。

`pxeos_checkin_format_regression.sh` 以真实 JSON parser 验证 0 保留、退役格式及非法级别拒绝，存储清理专用响应不要求镜像编解码字段。

`pxeos_single_payload_regression.sh` 运行真实 LVM 捕获叶函数和 DD 捕获分支，仅模拟设备/Partclone，验证超过 200 MiB 的 LVM 数据不会截断且 DD 最终文件名与恢复一致。

## Linux UEFI 启动项回归

- 下列套件覆盖加载器与架构、GPT/MBR 身份、原条目复用、激活和启动顺序、NVRAM 失败、正常及初始化续跑完成门槛与退出清理。Windows、其它系统和 BIOS 跳过新逻辑。

```shell
/home/sysadmin/.codex/bin/codex-build-test bash tests/pxeos_uefi_boot_regression.sh
```

- 使用自包含合成 PE 头、真实普通目录、固件文本和有状态命令叶替身，不挂载本机设备或写入真实 NVRAM；不等同于真实 FAT16/32、Secure Boot 或固件首启验证。后端另覆盖 Linux 专用返回链、受管理旧脚本升级和自定义脚本保留。
