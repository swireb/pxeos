# PXEOS 测试目录说明

本目录保存 PXEOS 的定向回归脚本。测试未被 CI 工作流显式调用，不等于它没有价值：许多脚本用于本地复现、发布前核对或具备特定工具链的环境验证。每个脚本均应单独运行；此目录**不提供**一键执行全部测试的入口。

## 测试边界

- **静态契约**：读取源码、配置或补丁，核对固定字符串、顺序、清单和构建配置。
- **mock/离线回归**：使用临时普通文件、临时目录或命令替身，覆盖生产函数的局部行为；通过不代表已经验证 Buildroot 产物、真实磁盘、真实设备或端到端部署。
- **真实 native 工具链**：少数脚本会调用真实 `jq`、`reged`、hivex 或 XML 工具；仍应按脚本的隔离条件执行。QEMU 与 FAT 镜像相关验证属于可选环境验证，不在普通 mock 通过的保证范围内。

从 `packages/pxeos` 目录运行 Bash 脚本的形式为：

```bash
bash tests/pxeos_os_type_regression.sh
```

Windows 上运行 Python 发布测试可使用（显式 UTF-8 避免系统默认编码影响源码读取）：

```powershell
py -3 -X utf8 -B tests/release_naming_test.py
py -3 -X utf8 -B tests/pxeos_release_manifest_test.py
py -3 -X utf8 -B tests/pxeos_build_version_test.py
```

Linux 上可使用对应的 Python 3 命令：

```bash
python3 tests/release_naming_test.py
python3 tests/pxeos_release_manifest_test.py
python3 tests/pxeos_build_version_test.py
```

## 发布与清单（3）

- `release_naming_test.py`：离线核对发布命名和选定 beta 架构契约。
- `pxeos_release_manifest_test.py`：离线核对发布清单和固定发布频道。
- `pxeos_build_version_test.py`：以只读 GitHub 查询替身、时间 fixture 和临时 overlay，核对构建前一次选定 Release/Beta 最终 tag、同一分钟重名后缀、全部架构传播、历史/频道清单与镜像同值、跨时区/跨日及不重采样、本地 `Local`、CI 缺号/非法号拒绝、复制失败不写号、控制台 API/PXEOS 分列、网络诊断安全读取，以及已选 tag 被占用时发布前失败停止。

统一版本测试只提取或调用版本函数、构建入口的依赖检查前缀及带命令替身的局部函数，不启动真实 PXEOS、内核或 initramfs 构建，不安装依赖、下载制品或访问 GitHub。Windows 的 Git Bash 可能缺少 IANA 时区数据，时间 fixture 会模拟北京时间转换并检查生产代码传入的 `Asia/Shanghai`；符号链接测试在平台不允许创建时明确跳过。通过这些测试不能推断真实 Actions、Linux 构建、设备启动或发布已验证；运行时的新版本显示仍须重新构建和发布 initramfs 才会生效。

## 构建与运行时（3）

- `pxeos_build_kernel_regression.sh`：合并的构建下载安全、依赖和内核相关回归。
- `pxeos_build_sources_test.py`：以离线 mock 核对六个自定义 Buildroot 包的 HTTPS 主/备用预置、唯一 SHA-256、实际 package 下载目录、`BR2_PRIMARY_SITE_ONLY` 跳过、`make source` 失败传播及 Release/Beta 公共构建 YAML 契约。
- `pxeos_gconv_runtime_regression.sh`：核对 libhivex 所需 glibc gconv Buildroot 配置。

`pxeos_build_kernel_regression.sh` 还提供可选的 `--arm64-initrd`（仅核对 arm64 initrd 格式）和 `--qemu`（格式核对后运行 QEMU smoke）模式；仅在相应构建/QEMU 环境具备时显式运行。`pxeos_partition_regression.sh` 的原生 FAT16/32 常规文件镜像段由 `PXEOS_FATGROW_TEST_*` 环境变量明确门控，只操作 regular image，不应据此推断真实块设备验证。

## 多播、网络与控制面（11）

- `multicast-callback-session-regression.sh`：核对多播回调会话与磁盘许可绑定。
- `multicast-capability.test.sh`：以命令 mock 核对 udp-receiver 能力探测和传输模式限制。
- `multicast-deadline-regression.sh`：以真实 `jq` 和临时请求核对多播截止时间处理。
- `multicast-error-diagnostics.test.sh`：以 curl mock 核对多播错误诊断输出。
- `multicast-monitor-http-cancel-regression.sh`：核对 watchdog 故障、接收进程终止和状态清理。
- `multicast-number-identity-regression.sh`：真实jq核对有符号64位上限编号的文本往返、非法编号和JSON数字拒绝、第二版能力、环境及私有上下文、七类专用请求、普通回调完整身份、错响应拒绝、切单播清理、路径穿越保护及已确认空磁盘返回值。
- `multicast-protocol-regression.sh`：核对多播协议请求与会话字段；当前脚本硬编码 `/c/Windows/System32/jq.exe`。
- `multicast-writeimage-regression.sh`：核对多播写入失败、进程终止和 FIFO 清理。
- `pxeos_multicast_architecture_regression.sh`：核对多架构多播接收依赖、内核能力和构建映射。
- `pxeos_https_control_regression.sh`：以 `jq` 和临时文件核对 HTTPS 参数、请求截止、脱敏和 curl PID 清理。
- `pxeos_network_storage_regression.sh`：合并的网络故障诊断、存储和相关离线回归。

- 编号回归在Git Bash与原生jq可执行；若探测到Cygwin正则引擎不支持既有512次重复上限，仅在抽取fixture中把令牌上界缩窄到255，测试令牌为32字符，全部身份和HTTP断言保留，生产校验不改。这不等于已运行Linux或BusyBox，真实权限、设备及已构建PXEOS仍需独立验证。

## 捕获、恢复、存储与分区（17）

- `pxeos_capture_regression.sh`：合并核对 capture 收尾、发布与进度管线。
- `pxeos_capture_resume_regression.sh`：核对 capture marker、恢复衔接和交接状态。
- `pxeos_restore_preflight_regression.sh`：核对恢复制品的离线预检。
- `pxeos_partition_regression.sh`：合并的分区安全与布局回归。
- `pxeos_layout_alignment_regression.sh`：核对 4Kn 等扇区/布局对齐契约。
- `pxeos_disk_health_regression.sh`：核对磁盘健康盘点及上报接口。
- `pxeos_partition_progress_regression.sh`：核对分区计划、进度 flush 与 LVM 事实。
- `pxeos_partclone_progress_regression.sh`：核对 Partclone 文本模式 stderr 进度适配。
- `pxeos_partclone_vt_progress_regression.sh`：核对 Partclone VT/VCSA 快照进度解析。
- `pxeos_lvm_console_regression.sh`：核对 LVM 控制台激活与消息处理。
- `pxeos_lvm_schema_jq_regression.sh`：以真实 `jq` 核对 LVM capture schema 过滤程序。
- `pxeos_lvm_udev_rules_regression.sh`：核对 LVM udev 同步及移除 systemd 专用自动激活规则。
- `pxeos_var_mount_regression.sh`：核对原生 NoCloud 的独立 `/var` 许可、全部 PV、挂载身份与借用清理。
- `pxeos_lvm_multi_regression.sh`：核对同一磁盘上 1/2/3/5 组彼此独立的一 PV/一 VG/多 linear LV，覆盖正序与倒序布局；默认执行叶级集成回归。
- `pxeos_mbr_partition_contract_regression.sh`：核对 DOS/MBR 分区编号、32 位 LBA 与 GPT 边界契约，同时检查 Schema object 和 resolved partition array 两种输入形态。
- `pxeos_lvm_naming_contract.sh`：核对 pinned LVM2 官方名称 127 字节边界、保留前缀/内部片段及连字符转义 mapper 名边界。
- `pxeos_lvm_capture_scan_contract.sh`：核对 LVM 初次扫描 warning、目标 PV 缺失时 fail-closed，以及普通无 LVM 盘的正向路径。

上述脚本均按单脚本独立运行；本目录仍不提供一键 full suite，也不因此宣称 CI、真实磁盘或实机部署已验证。

## Windows、Linux 名称、显示与部署身份（12）

- `pxeos_xml_command_regression.sh`：以私有文件和命令 mock 覆盖 Sysprep XML 写入路径。
- `pxeos_windows_initialization_regression.sh`：以真实 hivex/reged/XML 工具覆盖 Windows 主机名与 Sysprep 模板开关矩阵，模板原字节、固定或缺失名称不覆盖、管理名不影响注入及注入回执。
- `pxeos_windows_hostname_native_regression.sh`：以真实 `reged` 写入测试 hive，并由 native 工具只读核验两个 ControlSet 的主机名。
- `pxeos_windows_display_registry_regression.sh`：解析只读 MountedDevices 文本导出，不打开真实 hive 或块设备。
- `pxeos_sysprep_path_regression.sh`：核对 Sysprep 路径大小写发现、链接拒绝和歧义拒绝。
- `pxeos_offline_hostname_contract_regression.sh`：以临时注册表路径和 wrapper 提取核对离线主机名协议。
- `pxeos_os_type_regression.sh`：核对系统 ID 到内部诊断名称的稳定映射。
- `pxeos_display_metadata_regression.sh`：以临时库存和边界 stub 核对显示元数据。
- `pxeos_identity_preflight_order_regression.sh`：核对部署入口中 Windows XML、NoCloud 注入、冻结回执的顺序及旧执行器缺失。
- `pxeos_deployment_identity_regression.sh`：核对部署身份工具的 XML 能力门槛与身份契约。
- `pxeos_linux_hostname_regression.sh`：真实普通文件事务覆盖 Linux 单标签校验、主机名/回环自身 hosts 更新、CRLF/注释/远端保留、旧名缺失与本机映射去重、路径/模式/硬链接拒绝、回读回滚、外来 inode 不覆盖、清理失败留证、标签工具分支、许可目标唯一根、只读重试和命名四态；不要求 Cloud-init 包或干净缓存/seed。
- `pxeos_template_injection_regression.sh`：私有普通文件与设备/XML 边界替身覆盖 v5/v2 新能力、Windows 固定或缺失计算机名称原字节、Cloud 手工名称/固定实例标识/其他元数据键、名称开启仍允许空用户配置、checkin 跳过未使用的管理名称校验、restore 尾部名称隔离和模板只报告注入成功；不证明真实 XML 工具、注册表、磁盘或首启行为。

`pxeos_windows_hostname_native_regression.sh` 与 `pxeos_windows_initialization_regression.sh` 都需要 `ROOTPXE_WINDOWS_HOSTNAME_TOOL`、`ROOTPXE_HIVEX_MINIMAL`、`ROOTPXE_REGED`，以及用于 fixture 的 C 编译器、`pkg-config` 和 hivex 开发头文件/库。后者还要求实际 `xml`、`jq`，并以 `/ntfs` **不存在**为隔离前提；不要在已挂载或真实目标盘环境中运行。满足隔离条件后可分别显式执行：

```bash
bash tests/pxeos_windows_hostname_native_regression.sh
bash tests/pxeos_windows_initialization_regression.sh
```

## 原生 Cloud-init（5）

- `pxeos_cloud_init_protocol_regression.sh`：真实 jq 二次验证 v5 八个私有字段、空用户正文及真实空字节散列、UTF-8/CRLF、网络与供应方空值对、三个各 64 KiB 的总体大响应通过标准输入解析、四个私密文件的 BASHPID/inode/权限证明、独立及组合 unlink 故障后的整份失效与安全重试、旧键/缺失或关闭策略拒绝、四正文及供应方字段与路径脱敏、能力异常不生成请求及模板仅上报注入回执。
- `pxeos_cloud_init_permit_regression.sh`：真实首次单盘和 MPA 单盘计划、许可响应、登记及校验，真实 source JSON checkin 后调用两文件、三文件或四文件安装器；覆盖冻结 meta、空用户/网络/供应方配置、两 permit 的 v5 与 JSON 数组能力声明、异常能力不发请求、缺失/损坏映射、错误设备/操作及普通部署/捕获绕过。
- `pxeos_cloud_init_seed_regression.sh`：普通临时目录覆盖两文件、三文件或四文件原字节、空用户文件、冻结 meta、内容完全一致时的只读幂等、清空网络或供应方配置不删除已有文件、额外/缺失/篡改、foreign seed/缓存/禁用、链接、网络及供应方阶段回滚与外来内容保留、半份 seed 拒绝和 SELinux 工具分支；内容相等不证明同一任务归属。
- `pxeos_cloud_init_mounts_regression.sh`：设备边界替身覆盖独立只读程序分区探测不依赖 Cloud 路径、变量分区仍严格拒绝遮盖、全部物理卷许可、挂载歧义、借用与失败清理证据。
- `pxeos_cloud_init_roots_regression.sh`：Cloud 注入与离线名称共用真实根发现/全部物理卷许可，对同一根去重，拒绝两个不同根、候选身份冲突及未许可物理卷。

上述 fixture 不执行目标 Cloud-init、user-data、真实磁盘、真实 mount 或 LVM。MSYS 使用明确的 Unix 属主/模式替身，Windows 原生符号链接可能因权限拒绝而跳过；SELinux 工具分支使用替身，不代表工具包、目标策略或真实首启执行已验证。

## API、注册、审计与控制台（6）

- `pxeos_api_business_regression.sh`：合并核对 check-in JSON、业务逻辑和控制台相关回归。
- `pxeos_audit_regression.sh`：离线核对审计项和关键源码/补丁约束。
- `pxeos_hardening_regression.sh`：以临时文件和 mock 覆盖加固相关失败路径。
- `pxeos_manual_registration_regression.sh`：以 endpoint、控制台和重启 mock 覆盖手工注册客户端。
- `pxeos_mpa_permit_regression.sh`：以临时文件覆盖 MPA 下载许可的本地分派。
- `pxeos_usb_console_regression.sh`：核对 USB 镜像控制台菜单与显示参数。

## 脚本审计回归（3）

- `pxeos_script_audit_regression.sh`：提取局部函数，以命令替身覆盖扩展分区、SATA/NVMe 名称碰撞、坏分区 dump、旧 Windows 分片、printf、控制字符及数组作用域、恢复格式与选择、时间显示、hash 前置门禁、磁盘容量、假钟倒计时、压缩参数、主机名、库存与 LVM probe 清理、算术错误传播和存储空间列。
- `pxeos_script_io_regression.sh`：以临时普通文件核对 NFS/SMB 的 EXIT/INT/TERM 四份 Cloud-init 私有文件清理及自有派生计划清理、umask/trap 保留、缺库及 source 失败、入口停止、有限设备重读、raw 引导区逻辑字节、GPT backup 与 raw 区分及坏 raw 在清表前拒绝、日志折行、严格 JSON 响应、任务库存/磁盘健康/非镜像完成的 HTTP 失败门禁，以及大于 2^31 和接近 GPT 安全整数上界的 LBA 精确读回。设备重读和写入只调用函数替身，不执行真实 `sfdisk`、`nvme` 或 LVM。
- `pxeos_task_http_regression.sh`：以 curl 替身核对私有 form/JSON 文件原始字节、无附加换行、curl 参数和 stdin、EOF、真实返回码、重定向拒绝及成功/失败/信号/临时目录失败后的清理。多播真实 mock curl PID 和取消继续由 `pxeos_https_control_regression.sh` 等现有回归覆盖。

Git Bash 可显式补齐工具路径及设备字符串转换边界，例如：

```bash
export PATH="/usr/bin:/bin:$PWD/tests/fixtures/msys-tools:$PATH"
export MSYS2_ARG_CONV_EXCL=/dev/
bash tests/pxeos_script_audit_regression.sh
bash tests/pxeos_script_io_regression.sh
bash tests/pxeos_task_http_regression.sh
```

`task-http-test-support.sh` 只在测试中读取真实包装器生成的私有请求文件并提供模拟 HTTP header，再交给原有 fixture 的精确字段断言。它不替代生产 curl；不会删去任务、许可或身份断言。MSYS 不能证明原生 Linux 的 0700/0600、FD flag、符号链接、锁与设备行为，相关替身/跳过必须单独列出。大 LBA 回归在当前 gawk 下核对读回和浮点格式契约，不声称实际运行了旧版 mawk。无需真实构建、安装、下载或网络连接。

## Fixtures（两类）

1. `fixtures/windows-display-registry/` 下的 `.reg` 文本样本用于 `pxeos_windows_display_registry_regression.sh`，覆盖有效、缺失、空、损坏和冲突的 MountedDevices 导出，不是注册表 hive。
2. `fixtures/buildroot-2026.02.1-lvm2.mk` 与 `fixtures/lvm2-udev-sync-91b1dd3.patch` 用于 `pxeos_lvm_udev_rules_regression.sh`，对照上游 Buildroot LVM2 配方和 udev 修补语义。
