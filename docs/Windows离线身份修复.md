# Windows 离线身份修复

`rootpxe-offline-identities windows-repair` 只在 PXEOS 中运行。它不使用
WinPE，不修改 `winre.wim`，也不写 EFI NVRAM；调用方负责在修复前更改目标
MBR 签名或 GPT 磁盘/分区 GUID，并负责 EFI 固件启动项。

调用方以 `0600` 普通文件传入 `--manifest`、`--plan` 与 `--result`。manifest
版本为 1，包含已挂载 Windows 卷内的 `windowsRoot`、`volumes`、实际 BCD hive
路径、`SYSTEM` hive 路径和 `ReAgent.xml` 路径。每个卷映射都必须提供
`diskBinding`、`partitionNumber`、旧/新盘标识、旧/新分区 GUID、旧/新偏移、大小和
逻辑扇区字节数。工具将每项映射逐一与 response wrapper 中的
`plan.topology.disks`（旧磁盘）和 `plan.disks`（新磁盘）按 target device、绑定、
分区号及标识精确核对；它拒绝卷外路径、规范化后不属于已许可卷的路径、非普通文件、
重复或无法精确匹配的映射。
GPT 新分区必须提供 `partitionGuid`；MBR 没有该标识，后端省略该字段时视为合法，
但提供非空值会被拒绝。新分区通过其 `targetDevice` 与旧拓扑中带分区号的
`targetDevice` 唯一关联；新分区自身不要求也不读取分区号。

`--plan` 是服务端响应的完整 wrapper：顶层必须有正整数 `attempt`、64 位小写十六
进制 `planHash`，以及含 `version: 1`、`planId`、`topology.disks` 和 `disks` 的
`plan` 对象。`attempt` 只描述本次任务重试，允许在同一计划的三个阶段之间变化。
`planId` 不能是 `.` 或 `..`；Windows 根目录、卷和输入文件先逐组件拒绝符号链接，再做
规范化解析；工具自己的阶段目录及其阶段标记同样拒绝符号链接。

三个阶段必须按顺序执行：

1. `preflight` 解析至少一个 BCD store、SYSTEM 和可选 XML，在 Windows 根目录下创建权限为 0700 的
   `.rootpxe-offline-identities/<planId>`，持久保存规范化的 manifest 及
   `{plan, planHash}` 输入、未改原件和候选副本；只有全部副本都已生成、可重新打开且可由原件和
   当前输入确定性重建后，才写入完整预检标记。发现 dirty hive、
   `.LOG1`/`.LOG2`、损坏 BCD 长度、未知 device record 或非空未支持恢复字段时拒绝。
2. `apply` 逐个将当前原件与保存备份逐字比较；有漂移即停止。若一次中断后文件已经等于
   同一规范输入的候选副本，会跳过该文件并继续后续安装。候选副本经 fsync 和
   同目录 rename 安装。跨 BCD/SYSTEM/XML 不是原子事务，阶段目录保留供同一计划
   排查；即使 `planId` 相同，改变 `planHash`、任何 plan 映射或 manifest 卷映射也
   不能复用或覆盖旧阶段。
3. `verify` 重新核对保存的 manifest 和 `{plan, planHash}`，再比较已安装文件和候选副本。其结果才可作为 BCD、MountedDevices
   与 WinRE 引用已安装的证据。

BCD 仅修改所有 `Objects/*/Elements/*/Element` 中附加对象 GUID 后的 device binary record：类型 6
按完整 GPT disk+partition GUID 或完整 MBR signature+offset 映射更新，类型 0 只递归
其内嵌 record，类型 5 保持。元素开头的 16-byte BCD 附加对象 GUID 保持不变。
SYSTEM 根键 `MountedDevices` 只更新完整匹配的 12-byte MBR 或 24-byte `DMIO:ID:` GPT
值；盘符/Volume 值名与 NTFS serial 不变。XML 禁止外部实体，`WinreLocation` 与
`ImageLocation` 的 `guid`、`id`、`offset` 属性仅按 disk GUID/id 加 offset 精确更新；
`WinreBCD` 的对象 GUID 属性不属于磁盘定位，不会被改写。未配置的全零位置保持。

未提供 `ReAgent.xml` 时，`winreApplicable` 和 `winre` 均为 `false`，表示无适用项，
不是 WinRE 已修复。`result.storage` 始终为 `false`，因为本程序没有写盘标识；它也不会报告 EFI 或 WIM
成功。调用方只能在自身完成磁盘标识和 EFI 工作后合成部署结果。

主机侧回归从 hivex 上游的合法 `images/minimal` hive 创建合成 BCD、SYSTEM 和
ReAgent XML fixture。它覆盖 `verify` 先于 `apply` 的拒绝、同 plan 的重复
`preflight`、同一 `planId` 但改变新 GUID、卷映射或 `planHash` 的拒绝、BCD 已安装后的
恢复式 `apply`、原件漂移拒绝，以及 BCD device record、未修改的 element、
MountedDevices 盘符值名和 ReAgent GUID/offset 的结果。
XML 输入使用大写且带花括号的 GUID；manifest 中的 GUID 保持 36 字符规范形式，
写回时保留花括号。运行时需要能发现 `hivex.pc`、`libhivex` 和上游 minimal hive：

```sh
ROOTPXE_WINDOWS_IDENTITY_TOOL=/usr/sbin/rootpxe-offline-identities \
ROOTPXE_HIVEX_MINIMAL=/path/to/hivex/images/minimal \
./tests/pxeos_windows_identity_regression.sh
```

合成 hive 回归和本工具的字节级 `selftest` 都不是 Windows 实机启动证明。仍须在
BIOS/MBR 和 UEFI/GPT Windows 克隆盘上做启动、恢复环境和盘符映射验证。
