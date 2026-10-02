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

Windows 上运行两个 Python 发布测试可使用：

```powershell
py -3 tests/release_naming_test.py
py -3 tests/pxeos_release_manifest_test.py
```

Linux 上可使用对应的 Python 3 命令：

```bash
python3 tests/release_naming_test.py
python3 tests/pxeos_release_manifest_test.py
```

## 发布与清单（2）

- `release_naming_test.py`：离线核对发布命名和选定 beta 架构契约。
- `pxeos_release_manifest_test.py`：离线核对发布清单和固定发布频道。

## 构建与运行时（3）

- `pxeos_build_kernel_regression.sh`：合并的构建下载安全、依赖和内核相关回归。
- `pxeos_build_sources_test.py`：以离线 mock 核对六个自定义 Buildroot 包的 HTTPS 主/备用预置、唯一 SHA-256、实际 package 下载目录、`BR2_PRIMARY_SITE_ONLY` 跳过、`make source` 失败传播及 Release/Beta 公共构建 YAML 契约。
- `pxeos_gconv_runtime_regression.sh`：核对 libhivex 所需 glibc gconv Buildroot 配置。

`pxeos_build_kernel_regression.sh` 还提供可选的 `--arm64-initrd`（仅核对 arm64 initrd 格式）和 `--qemu`（格式核对后运行 QEMU smoke）模式；仅在相应构建/QEMU 环境具备时显式运行。`pxeos_partition_regression.sh` 的原生 FAT16/32 常规文件镜像段由 `PXEOS_FATGROW_TEST_*` 环境变量明确门控，只操作 regular image，不应据此推断真实块设备验证。

## 多播、网络与控制面（10）

- `multicast-callback-session-regression.sh`：核对多播回调会话与磁盘许可绑定。
- `multicast-capability.test.sh`：以命令 mock 核对 udp-receiver 能力探测和传输模式限制。
- `multicast-deadline-regression.sh`：以真实 `jq` 和临时请求核对多播截止时间处理。
- `multicast-error-diagnostics.test.sh`：以 curl mock 核对多播错误诊断输出。
- `multicast-monitor-http-cancel-regression.sh`：核对 watchdog 故障、接收进程终止和状态清理。
- `multicast-protocol-regression.sh`：核对多播协议请求与会话字段；当前脚本硬编码 `/c/Windows/System32/jq.exe`。
- `multicast-writeimage-regression.sh`：核对多播写入失败、进程终止和 FIFO 清理。
- `pxeos_multicast_architecture_regression.sh`：核对多架构多播接收依赖、内核能力和构建映射。
- `pxeos_https_control_regression.sh`：以 `jq` 和临时文件核对 HTTPS 参数、请求截止、脱敏和 curl PID 清理。
- `pxeos_network_storage_regression.sh`：合并的网络故障诊断、存储和相关离线回归。

## 捕获、恢复、存储与分区（13）

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
- `pxeos_var_mount_regression.sh`：核对独立 `/var` 初始化时的 fstab 挂载处理。

## Windows、显示与部署身份（11）

- `pxeos_xml_command_regression.sh`：以私有文件和命令 mock 覆盖 Sysprep XML 写入路径。
- `pxeos_windows_initialization_regression.sh`：以真实 hivex/reged/XML 工具覆盖 Windows 主机名与 Sysprep 开关矩阵。
- `pxeos_windows_hostname_native_regression.sh`：以真实 `reged` 写入测试 hive，并由 native 工具只读核验两个 ControlSet 的主机名。
- `pxeos_windows_display_registry_regression.sh`：解析只读 MountedDevices 文本导出，不打开真实 hive 或块设备。
- `pxeos_sysprep_path_regression.sh`：核对 Sysprep 路径大小写发现、链接拒绝和歧义拒绝。
- `pxeos_offline_hostname_contract_regression.sh`：以临时注册表路径和 wrapper 提取核对离线主机名协议。
- `pxeos_os_type_regression.sh`：核对系统 ID 到内部诊断名称的稳定映射。
- `pxeos_display_metadata_regression.sh`：以临时库存和边界 stub 核对显示元数据。
- `pxeos_identity_preflight_regression.sh`：核对 Linux 身份写入前的完整预检。
- `pxeos_identity_preflight_order_regression.sh`：核对部署入口中身份预检、主机名写入和初始化素材的顺序。
- `pxeos_deployment_identity_regression.sh`：核对部署身份工具的 XML 能力门槛与身份契约。

`pxeos_windows_hostname_native_regression.sh` 与 `pxeos_windows_initialization_regression.sh` 都需要 `ROOTPXE_WINDOWS_HOSTNAME_TOOL`、`ROOTPXE_HIVEX_MINIMAL`、`ROOTPXE_REGED`，以及用于 fixture 的 C 编译器、`pkg-config` 和 hivex 开发头文件/库。后者还要求实际 `xml`、`jq`，并以 `/ntfs` **不存在**为隔离前提；不要在已挂载或真实目标盘环境中运行。满足隔离条件后可分别显式执行：

```bash
bash tests/pxeos_windows_hostname_native_regression.sh
bash tests/pxeos_windows_initialization_regression.sh
```

## API、注册、审计与控制台（6）

- `pxeos_api_business_regression.sh`：合并核对 check-in JSON、业务逻辑和控制台相关回归。
- `pxeos_audit_regression.sh`：离线核对审计项和关键源码/补丁约束。
- `pxeos_hardening_regression.sh`：以临时文件和 mock 覆盖加固相关失败路径。
- `pxeos_manual_registration_regression.sh`：以 endpoint、控制台和重启 mock 覆盖手工注册客户端。
- `pxeos_mpa_permit_regression.sh`：以临时文件覆盖 MPA 下载许可的本地分派。
- `pxeos_usb_console_regression.sh`：核对 USB 镜像控制台菜单与显示参数。

## Fixtures（两类）

1. `fixtures/windows-display-registry/` 下的 `.reg` 文本样本用于 `pxeos_windows_display_registry_regression.sh`，覆盖有效、缺失、空、损坏和冲突的 MountedDevices 导出，不是注册表 hive。
2. `fixtures/buildroot-2026.02.1-lvm2.mk` 与 `fixtures/lvm2-udev-sync-91b1dd3.patch` 用于 `pxeos_lvm_udev_rules_regression.sh`，对照上游 Buildroot LVM2 配方和 udev 修补语义。
