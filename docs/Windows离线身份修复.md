## RootPXE 离线身份修复工具

- `rootpxe-offline-identities` 是 PXEOS 内的原生离线修复工具，提供 `windows-repair` 和 `efi-repair` 两个子命令。
- 它只接受部署任务已经冻结的 manifest 与 plan，不生成磁盘标识、分区 GUID、文件系统 UUID、machine-id 或 SSH 密钥。
- 普通镜像部署由 PXEOS 自动生成输入并调用本工具，管理员不需要手动注入命令、构造计划或直接写目标磁盘。
- 管理页面在镜像新增和编辑表单的“部署设置”区域提供“随机化存储标识”和“初始化系统身份”。新增的存储标识、Linux `machine-id` 和 SSH 主机密钥选项默认关闭；既有主机名选项保持原有默认行为。
- 部署策略、服务端计划与结果回传协议见 [部署身份初始化](../../docs/部署身份初始化.md)，PXEOS 调用链见 [RootPXE 集成](RootPXE集成.md)。

## 职责边界

- `windows-repair` 只修复已离线挂载的 Windows BCD、SYSTEM 根键 `MountedDevices` 和可选 `ReAgent.xml` 中与计划映射精确对应的引导引用。
- `windows-repair` 不写 MBR 磁盘签名、GPT 磁盘 GUID、GPT 分区 GUID、EFI NVRAM 或 `winre.wim`，也不随机生成任何标识。调用方负责先按服务端 plan 写入磁盘和分区标识。
- `efi-repair` 是 Windows 与 Linux 共用的 EFI `Boot####` NVRAM device-path 修复器。它只处理受控的 `efivarfs` 与服务端计划中许可的分区映射。
- Linux 的磁盘和文件系统 UUID 写入、`fstab`、`crypttab`、GRUB、BLS、`grubenv`、initramfs、`machine-id` 与 SSH 主机密钥由 PXEOS shell 调用其它工具完成，不属于这两个 C 子命令的职责。
- Cygwin 仅用于 Windows 开发宿主上的原生编译和测试；它不是 PXEOS 运行时依赖，也不替代 Buildroot 目标构建。

## 调用顺序与输入边界

- 对启用存储标识的任务，调用方先以未改变的目标布局执行 `preflight`，随后写入 plan 指定的磁盘和分区标识，再依次执行 `apply` 与 `verify`。
- 同一个计划的三个阶段必须使用同一份规范化 manifest、`plan` 和 `planHash`。阶段目录保留给同一计划的安全重试和排障，输入漂移、计划漂移、路径越界、符号链接或不精确映射都会失败。
- manifest 和 plan 是任务生成的私有普通输入文件。调用方为每个阶段提供新的 result 输出路径，不能复用旧 result；`windows-repair` 用排他创建拒绝已有路径，`efi-repair` 先写私有临时文件再 rename 到 result 路径。
- 下面命令仅说明 PXEOS 内部受控调用形态，不能由管理员以自造 plan 对生产磁盘直接执行。

```shell
rootpxe-offline-identities windows-repair --manifest "$windows_manifest" --plan "$plan_wrapper" --result "$preflight_result" --phase preflight
rootpxe-offline-identities windows-repair --manifest "$windows_manifest" --plan "$plan_wrapper" --result "$apply_result" --phase apply
rootpxe-offline-identities windows-repair --manifest "$windows_manifest" --plan "$plan_wrapper" --result "$verify_result" --phase verify
```

```shell
rootpxe-offline-identities efi-repair --manifest "$efi_manifest" --plan "$plan_wrapper" --result "$preflight_result" --phase preflight
rootpxe-offline-identities efi-repair --manifest "$efi_manifest" --plan "$plan_wrapper" --result "$apply_result" --phase apply
rootpxe-offline-identities efi-repair --manifest "$efi_manifest" --plan "$plan_wrapper" --result "$verify_result" --phase verify
```

- Windows manifest 版本为 1，包含已挂载 Windows 卷内的 `windowsRoot`、同一稳定目标根的 `stateRoot`、`volumes`、实际 BCD hive 路径、SYSTEM hive 路径和可选 `ReAgent.xml` 路径。Windows 修复使用 `windowsRoot`，EFI 三阶段在该 `stateRoot` 下保存状态。
- EFI manifest 版本为 1，必须包含受控目标根 `stateRoot`、`efiVarFs` 与完整的 `volumes` 映射；阶段状态保存在目标根下的 `.rootpxe-offline-identities/<planId>/efi`。
- 每个卷映射都必须提供 `diskBinding`、分区号、旧/新磁盘标识、旧/新分区 GUID、旧/新偏移、大小和逻辑扇区字节数。工具逐项与 wrapper 中 `plan.topology.disks` 的旧布局和 `plan.disks` 的新布局按目标设备、绑定、分区号及标识精确核对。
- GPT 新分区必须提供 `partitionGuid`。MBR 没有该字段，省略时合法；提供非空值会被拒绝。新分区通过 `targetDevice` 与旧拓扑中的分区唯一关联。
- `plan` 是服务端返回的完整 wrapper，必须含正整数 `attempt`、64 位小写十六进制 `planHash`，以及含 `version: 1`、`planId`、`topology.disks` 和 `disks` 的 `plan` 对象。

## 三阶段与安全重试

- `preflight` 先解析、校验输入和全部受控文件，在目标根创建权限为 0700 的计划阶段目录，保存规范化输入、原件和候选副本。只有候选副本可重建、可重新打开后，才写入完整预检标记。
- `apply` 逐个把当前内容与保存备份逐字比较；原件漂移立即停止。若中断前内容已经等于同一规范输入的候选内容，会跳过该项并继续。Windows 的 BCD、SYSTEM 和 XML 候选内容通过 fsync 与同目录 rename 安装；EFI 变量直接写入后立即读回核对。
- `verify` 重新核对保存的 manifest 与 `{plan, planHash}`，并逐字比较已安装文件和候选副本。只有此阶段的成功结果可作为引用已安装的证据。
- BCD、SYSTEM、XML 或 NVRAM 之间没有跨文件原子事务。已写入部分保留在阶段目录中，只允许输入完全相同的同一计划重试；相同 `planId` 但不同 `planHash`、plan 映射或 manifest 映射不可复用。
- 工具拒绝卷外路径、规范化后不在受许可卷内的路径、非普通文件、符号链接、重复映射和无法精确匹配的映射。

## Windows 离线引用修复

- `windows-repair` 要求至少一个 BCD store 与 SYSTEM hive。它拒绝 dirty hive、`.LOG1` 或 `.LOG2`、损坏 BCD 长度、未知 device record 和非空的未支持恢复字段。
- BCD 只修改 `Objects/*/Elements/*/Element` 中附加对象 GUID 后的 device binary record：类型 6 按完整 GPT disk 加 partition GUID 或完整 MBR signature 加 offset 映射更新；类型 0 只递归其内嵌 record；类型 5 保持。元素开头的 16-byte BCD 附加对象 GUID 不变。
- SYSTEM 的 `MountedDevices` 只更新完整匹配的 12-byte MBR 或 24-byte `DMIO:ID:` GPT 值。盘符和 Volume 值名、NTFS serial 均不改写。
- XML 禁止外部实体。`WinreLocation` 与 `ImageLocation` 的 `guid`、`id`、`offset` 仅按精确磁盘标识和 offset 更新；`WinreBCD` 的对象 GUID 不属于磁盘定位，不改写。未配置的全零位置保持不变。
- 未提供 `ReAgent.xml` 时，结果中的 `winreApplicable` 与 `winre` 均为 `false`，表示没有适用项，不能解释为 WinRE 已修复。

## EFI 修复与降级条件

- PXEOS 根据冻结的 ESP 类型和受控挂载中的真实 EFI 可执行文件判定目标是否为 UEFI；PXEOS 自身通过 PXE 或 USB 启动的传输方式不参与该判定。纯 BIOS 目标不调用 EFI 修复。
- `efi-repair` 只遍历受控 `efivarfs` 内符合 EFI 全局变量 GUID 的 `Boot####` 普通文件，并只更新与计划映射唯一匹配的 HD() 节点。格式损坏、重复匹配、变量漂移或候选不一致均会失败。
- 当 `efivarfs` 不可访问时，或者原生修复报告 `matched: 0` 时，受控 ESP 必须含当前架构的标准 fallback：x86_64 为 `EFI/BOOT/BOOTX64.EFI`，aarch64 为 `EFI/BOOT/BOOTAA64.EFI`，i386 为 `EFI/BOOT/BOOTIA32.EFI`。
- fallback 只能从 plan 对应并由 PXEOS 受控挂载的 ESP 检查。仅在 NTFS Windows 卷找到 loader、仅存在 GRUB，或仅存在 Windows loader 都不构成 fallback 成功证据。
- EFI result 的 `available` 表示原生工具是否可安全访问 `efivarfs`。`preflight` 的 `matched` 是匹配到的 HD() 节点数量；`apply` 和 `verify` 的 `matched` 是已保存变量清单数量。
- EFI 的 `updated` 只计本次 `apply` 直接写入并读回成功的变量。重试时已等于候选内容的变量不计入，`preflight` 和 `verify` 均为 0。`verified` 只在 `verify` 阶段全部变量读回候选内容一致时为真。调用方在 `preflight` 后还会核对非零匹配或受控 ESP fallback。
- Windows EFI `apply` 只接受可访问 `efivarfs` 且 `updated` 为数值的原生结果；原生 `apply` 的 `verified:false` 是正常阶段语义。只有 `verify` 阶段要求 `verified:true`。

## 结果解释

- `windows-repair` 的 result 始终包含 `storage: false`。这表示该子命令没有写磁盘标识，不表示部署存储步骤失败。
- `windows-repair` 的 `bcd`、`mountedDevices`、`winre` 与 `winreApplicable` 只说明该子命令的阶段结果；它不报告 EFI 或 WIM 成功。
- `efi-repair` 的 result 在 `efivarfs` 不可用时可返回 `efi.available: false`。是否接受该情形由 PXEOS 以受控 ESP fallback 决定，而不是把它当作 NVRAM 已修复。
- 任务最终结果由 PXEOS 汇总磁盘标识写入、Windows 或 Linux 引用修复、EFI 验证及其它启用策略后再回传，不能把单个子命令 result 当作完整部署成功证明。

## Buildroot 集成与架构状态

- Buildroot 包名为 `rootpxe-offline-identities`，编译命令使用 `TARGET_CC`、目标 CFLAGS、目标链接参数和 Buildroot 的 pkg-config。
- 包依赖 `json-c`、`libxml2` 与 `libhivex`，安装目标为 `/usr/sbin/rootpxe-offline-identities`。`hivex.pc` 与上游 minimal hive 是主机侧合成回归的构建和 fixture 依赖，不是 PXEOS 运行时发现路径。
- 已接入构建配置的 x86 为 `configs/fsx86.config`，目标架构为 i386。
- 已接入构建配置的 x86_64 为 `configs/fsx64.config`，目标架构为 x86_64。
- 已接入构建配置的 arm64 为 `configs/fsarm64.config`，目标架构为 aarch64。
- ARM32 没有接入该包配置。
- 上述配置项存在不等于三种架构已经完成 Buildroot 交叉构建，也不等于已在对应硬件上验证。特别是 Windows ARM64 没有实机部署或启动证据，不能据此声明受支持。

## 已知问题与验证边界

- Windows manifest 现将受控 Windows 目标根同时写入 `windowsRoot` 与 `stateRoot`，并由同一 manifest 驱动 Windows 与 EFI 三阶段。Windows EFI phase 已按原生阶段语义分别校验 apply 与 verify。
- 已有离线证据包括：Cygwin 原生 `-Werror` 联编和 selftest、合成 hivex 与 EFI fixture、生产 Windows manifest 生成函数结合真实 C EFI parser/stager 和临时模拟 `efivarfs` 的三阶段回归、PXEOS shell mock，以及真实 `ssh-keygen` 生成的公钥材料校验。
- 上述证据不包含完整 Buildroot 三架构交叉构建、真实 EFI 变量写入、Windows 或 Linux 克隆盘启动、BIOS/MBR、UEFI/GPT、LVM、恢复环境或盘符映射的实机验证。
- 既有捕获回归中有四项 POSIX 符号链接断言因宿主能力被跳过；这不是本轮运行结果，也不能补足实机验证。
- 对生产磁盘的任何直接调用都需要由正常部署任务提供已冻结 plan、受控挂载和可恢复备份；本说明不提供绕过该链路的写盘操作方法。
