# RootPXE 集成

以下为当前 PXEOS 运行时已实现的协议适配；服务端 Schema、任务快照、disk permit 以及管理端入口必须与此保持一致。它不代表已经完成真实磁盘环境验收。默认凭据和敏感信息边界见[安全配置](安全配置.md)，硬件构建边界见[硬件兼容性](硬件兼容性.md)。

## 存储协议

- 本次修复的根因是 JSON 中的 `storage` 字符串曾被按对象索引，导致 jq 报错后其返回码被吞掉，`protocol` 变为空并默认走 NFS，使 RootPXE 明确下发的 SMB 任务仍可能进入 NFS 挂载。SMB 仅接受当前 flat JSON 的顶层 `protocol`、`storageip`、`exportPath` 与 `smb*` 字段；顶层 `protocol` 优先，缺失时才保留 NFS 的嵌套兼容。普通 RootPXE 任务缺少或未知协议会拒绝，不根据 `storage` 字符串猜测协议；非 JSON legacy checkin 不接受 SMB。仅显式 `capone=1` 且缺少协议时保留既有 NFS 分支，仍要求 `storage_server` 与绝对 `storage_export`；不据此声明 USB 兼容性，Capone/USB 均未做真机验证。
- NFS export 使用绝对路径（例如 `/data/images`）。SMB `exportPath` 使用完整相对 `share[/subdir...]`（例如 `rootpxe/images`），并保持该值直到最终调用 `mount.cifs //server/share/subdir`；远程配置的 share/subdir 根必须已存在，PXEOS 不会在服务端回退挂载共享根。SMB 拒绝前导或尾随斜杠、空段、`.`/`..`、UNC、反斜杠、冒号、控制字符、空白和危险字符。SMB 仅使用凭据文件，checkin 明确协议并完成字段校验后才创建，明文不导出到子进程环境。
- SMB 不固定 `vers` 或 `sec`，由客户端和服务端自动协商。发布此运行时修改需要重新构建并替换相应 initramfs（如 `init.xz`）及同批次 PXEOS 产物；本次不修改或证明 `bzImage`/内核二进制已经重建。

## Schema、布局与 LVM

- `image_type=n` 捕获完成、镜像写入与最终目录移动成功后，PXEOS 从最终镜像目录的唯一正式分区表 `d1.partitions` 生成 `originalSchema`，并在同一次 `finish` 回调中提交 `sizeBytes` 与 Schema。捕获不收缩、移动或恢复源盘，不生成 minimum、original 或 shrunken 分区表副本；`minDeployBytes` 和所有分区的 `minSectors` 都等于捕获表中的原始值。v1 GPT/普通 MBR 行为不变；带 DOS extended/逻辑分区的 MBR 使用 v2：分区按数字排序，容器为 `kind=extended`、`role=extended_container`、`artifact=""`，携带 `logicalNumbers`、`ebrReservedSectors=2`，并保留其捕获的原始大小，即使尾部存在未分配扇区；逻辑分区为 `kind=logical`，只携带唯一 `parentNumber`。v2 MBR `typeGuid` 统一为小写 `0x...`。任务 Schema hash 使用 `jq -cS` 的紧凑排序 JSON 字节，明确不包含其输出末尾换行，以匹配服务端 canonical JSON。无 LVM 拓扑时省略 `lvm`，不伪造空 PV/VG/LV；容器和 swap 均不要求镜像 payload。
- 部署布局使用 `original`、`fixed`、`percentage`、`remaining`。所有真实物理分区默认 `original`，管理员可以选择任一模式，但固定值不得小于原始大小；`remaining` 向下按 256 KiB 对齐，避免越过目标盘边界。GPT/MBR 边界、最小容量、身份、重复分区和回读不一致均拒绝继续。MBR extended 容器是由逻辑分区推导的结构项，保持 `derived`，不作为独立大小策略。`original` 保持该分区的大小，不承诺在前序分区改变后仍保持相同起始位置。
- MBR v2 部署布局中，extended 容器（`5`/`f`/`85`，可带 `0x` 前缀）只能为 `derived`，其最终范围由逻辑分区解析结果与 EBR 预留推导；容器绝不捕获或恢复 payload，即使存储中遗留 `dNpN.img*` 也不得进入 `writeImage`。逻辑分区必须在唯一容器内、保留 EBR 间隔；多容器、无父容器、越界、重叠或 EBR 空间不足会在 disk permit/首次写盘前进入 attention。当前安全实现仅接受所有 primary 均位于 extended 之前的布局，其他顺序拒绝而不猜测重排。固定大小/原始磁盘等既有镜像路径不因此改变。已识别的 MBR `0xef`/`ef` 为 EFI、`0x27`/`27` 为 recovery，`bootable` 标记为 boot，`0x8e`/`8e` 为 LVM PV，均受上述保护。
- LVM v2 仅用于 `image_type=n` 的单目标盘 PV、单 VG、`linear` LV。捕获写入安全相对的 PV 元数据 sidecar、`vgcfgbackup` 配置和每个非 swap LV 的独立镜像；PV 不保存 raw payload。捕获不收缩或恢复任何源 LV/文件系统，PV 与 LV 的最小容量均为捕获时原始容量；swap 只记录 UUID 和容量。多 PV/跨盘 VG、thin、raid、mirror、cache、snapshot、LUKS、mdraid 或不可识别拓扑会在 permit 前进入 attention。
- LVM 部署先校验任务快照的 v2 Schema/布局、PV 原始容量及 extent 对齐，再申请绑定目标盘的 disk permit。目标盘不得小于捕获原盘，因此不再支持较小目标的 PV/VG/LV 重建路径；同尺寸或更大目标使用 `pvcreate --uuid --restorefile`、`vgcfgrestore`、`pvresize` 和已有 LV 的 `lvresize`。PV 可用容量按 `(PV 大小 - PE 起始 - 保留空闲)` 向下取完整 extent，允许末尾不足一个 extent 的未使用尾部。`ext2`/`ext3`/`ext4` 恢复后执行可接受返回码 0/1 的 `e2fsck` 与 `resize2fs`、再回读容量；XFS 仅可原始大小恢复。所有 `pvcreate`、`vgcfgrestore`、`writeImage` 前均须已有匹配 permit。

## Windows 与 Linux 主机名

- Windows 改名仅在 `deploy` 且 `changeHostname=true` 时运行。PXEOS 先从唯一含 `Windows/System32/config/SYSTEM` 的 NTFS 分区识别系统卷；没有或有多个候选都会进入 attention，绝不猜测第一块 NTFS。随后仅检查固定路径 `Windows/System32/Sysprep/unattend.xml`：存在时使用 `xmlstarlet` 修改或安全插入 `specialize/Microsoft-Windows-Shell-Setup/ComputerName`，XML 异常、非唯一或回读失败均进入 attention，不回退注册表；该文件不存在时才离线修改 `SYSTEM` 注册表。
- Linux 改名仅支持 `osid=50` 的 `deploy` 任务，和 Windows 共用 `rootpxe_apply_hostname_for_disk` 分派入口。PXEOS 只探测 `ext2`、`ext3`、`ext4`、`xfs`、`btrfs`、`f2fs` 白名单中的唯一本地根文件系统：普通目标盘分区，或全部 PV 均属于该目标盘且以 VG UUID 选择的 LVM LV；无根、多根、跨盘 VG、混合 LV 激活状态都会进入 attention，绝不按最大分区、首个 LV 或同名 VG 猜测。LUKS、mdraid、跨盘 VG 及其他未列文件系统当前不支持，均按无法安全识别根卷处理。XFS 只以 `nouuid` 挂载，探测和写入后均清理挂载；PXEOS 自行激活的目标 VG 会在探测后及最终写入卸载后停用，原本已激活的 VG 不会被停用。
- Linux 主机名仅允许 1–63 位字母、数字、连字符，且首尾不能是连字符。PXEOS 写入并回读 `/etc/hostname`；已有文件通过原 inode 覆盖以保留其权限和属主，缺失时新建为 `root:root`、`0644`。有旧主机名且存在 `/etc/hosts` 时，只替换非注释行中的完整字段，不替换子串，仍通过原 inode 覆盖。`/etc` 必须是真实目录，`hostname`、`hosts` 不能是符号链接，避免离线镜像的绝对/越界链接写入 PXEOS 自身；`os-release` 的相对内链（例如 `../usr/lib/os-release`）在解析后仍位于目标根内时允许。
- 部署认证 JSON 使用 `preDeployScript`/`preDeployScriptSha256` 和 `postDeployScript`/`postDeployScriptSha256` 两组字段；每组是独立脚本文本及其 SHA-256，单套上限为 64 KiB UTF-8 字节。前置脚本在目标盘身份确认并取得 `deploy_write` permit 后、任何 NVMe format、分区布局或镜像 restore 前执行；后置脚本在 restore、扩容和主机名定制后执行。每套脚本先独立复核 SHA-256，再写入独立的 `0700` 临时文件，并用 `env -i /bin/bash` 运行；临时文件不会写入镜像存储。
- 脚本进程只得到受控 `PATH`，以及 `ROOTPXE_TASK_ID`、`ROOTPXE_IMAGE_PATH`、`ROOTPXE_TARGET_DISK`、`ROOTPXE_HOSTNAME`、`ROOTPXE_OS_ID`。任务 token、SMB 凭据和其他父进程变量不会传入，调用方也不得依赖 `source` 或 `eval` 解释未受信任内容。捕获任务携带任一脚本或 hash 字段会被拒绝。
- 前置脚本的失败阶段为 `pre_deploy_script`，它不是安全恢复点，重试必须回到完整部署路径。安全续跑白名单只有 `customizing_hostname` 与 `post_deploy_script`：主机名失败以 `resumeStage=customizing_hostname` 恢复时仅重放 permit、定制主机名并执行后置脚本；后置脚本失败以 `resumeStage=post_deploy_script` 恢复时仅重放 permit 和后置脚本。两种恢复路径均不重新验证/应用布局、不计划 NVMe format，也不重新写镜像；任一脚本失败都不会报告任务成功。
- 重捕获时，PXEOS 仅接受 RootPXE 下发的安全 `captureBackupName`，将旧正式镜像原子移动到 `/storage/backup/<captureBackupName>`。该目录可见、不得覆盖同名目录，并且必须与正式镜像和捕获暂存目录处于同一文件系统；首次捕获没有旧正式镜像时不会创建备份。

## NVMe、permit 与验证边界

普通部署在写盘前绑定 `taskId`、token、MAC、目标盘稳定标识和计划操作的 disk permit；NVMe 扇区不匹配时仅在匹配 namespace、metadata-free LBAF、许可和倒计时确认后允许格式化。格式化开始即视为磁盘操作已开始；失败、重枚举异常或扇区回读不一致均应进入 attention。

稳定标识保留已符合服务端 `targetId` 规则的 1–128 位原值；空白值、缺失属性或哈希失败会拒绝继续。含空格、斜杠、额外等号、非 ASCII 或超长的原值使用 `sha256:<64 位小写 hex>`，并完整参与散列；原值即使看似已在 `sha256:` 命名空间内也会再次散列，避免冒充编码标识。

disk permit 的 HTTP `4xx`、`granted:false`、非 JSON 响应以及 targetId/operation 回显不匹配均不等同于任务取消。对于 HTTP `4xx` 或布尔 `granted:false` 的明确拒绝，PXEOS 会以同一 task 上下文查询 `task-status`，仅接受 `2xx` JSON 的 `cancelled`、`superseded`、`deleted`，或 `404` JSON 的 `deleted` 作为取消终态；HTML 404、401、状态查询失败和其他状态都会保留许可围栏，不执行 hook 或磁盘操作。非 JSON、字段类型错误和 targetId/operation 回显不匹配按协议错误直接上报，不查询取消状态。服务端 `5xx` 与传输失败安全重试；明确拒绝或协议错误会上报 `PXEOS_DISK_PERMIT_DENIED` 并进入既有 attention/Retry 等待，上报被确认后才开始超时计时。控制台只显示 HTTP 状态和已知 permit code，任务 token、目标盘标识及原始响应正文不会回显。

上述运行时与三个 filesystem 配置均有改动。发布或真机验证时必须重新构建并替换同一批次的三架构产物；准确产物名称和硬件联调清单见[硬件兼容性](硬件兼容性.md#构建与回退边界)。capture/restore 失败传播与 `finish` 回调见[故障处理](故障处理.md)。
