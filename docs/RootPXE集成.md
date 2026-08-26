# RootPXE 集成

以下为当前 PXEOS 运行时已实现的协议适配；服务端 Schema、任务快照、disk permit 以及管理端入口必须与此保持一致。它不代表已经完成真实磁盘环境验收。默认凭据和敏感信息边界见[安全配置](安全配置.md)，硬件构建边界见[硬件兼容性](硬件兼容性.md)。

## Schema、布局与 LVM

- `image_type=n` 捕获完成、镜像写入与最终目录移动成功后，PXEOS 从最终镜像目录的 `d1.partitions` 生成 `originalSchema`，并在同一次 `finish` 回调中提交 `sizeBytes` 与 Schema。v1 GPT/普通 MBR 行为不变；带 DOS extended/逻辑分区的 MBR 使用 v2：分区按数字排序，容器为 `kind=extended`、`role=extended_container`、`artifact=""`，携带 `logicalNumbers`、`ebrReservedSectors=2`，并以每个逻辑分区的 `startSectors + minSectors` 推导容器 `minSectors`；逻辑分区为 `kind=logical`，只携带唯一 `parentNumber`。v2 MBR `typeGuid` 统一为小写 `0x...`。任务 Schema hash 使用 `jq -cS` 的紧凑排序 JSON 字节，明确不包含其输出末尾换行，以匹配服务端 canonical JSON。无 LVM 拓扑时省略 `lvm`，不伪造空 PV/VG/LV；容器和 swap 均不要求镜像 payload。
- 部署布局使用 `original`、`fixed`、`percentage`、`remaining`。`remaining` 向下按 256 KiB 对齐，避免越过目标盘边界；GPT/MBR 边界、最小容量、身份、重复分区和回读不一致均拒绝继续。EFI、MSR、boot、recovery、swap、LVM PV 及任何 `resizable=false` 分区只能使用 `original` 大小。`original` 保持该分区的大小，不承诺在前序可调整数据分区改变后仍保持相同起始位置。
- MBR v2 部署布局中，extended 容器（`5`/`f`/`85`，可带 `0x` 前缀）只能为 `derived`，其最终范围由逻辑分区解析结果与 EBR 预留推导；容器绝不捕获或恢复 payload，即使存储中遗留 `dNpN.img*` 也不得进入 `writeImage`。逻辑分区必须在唯一容器内、保留 EBR 间隔；多容器、无父容器、越界、重叠或 EBR 空间不足会在 disk permit/首次写盘前进入 attention。当前安全实现仅接受所有 primary 均位于 extended 之前的布局，其他顺序拒绝而不猜测重排。固定大小/原始磁盘等既有镜像路径不因此改变。已识别的 MBR `0xef`/`ef` 为 EFI、`0x27`/`27` 为 recovery，`bootable` 标记为 boot，`0x8e`/`8e` 为 LVM PV，均受上述保护。
- LVM v2 仅用于 `image_type=n` 的单目标盘 PV、单 VG、`linear` LV。捕获写入安全相对的 PV 元数据 sidecar、`vgcfgbackup` 配置和每个非 swap LV 的独立镜像；PV 不保存 raw payload。`ext2`/`ext3`/`ext4` 先按最小文件系统大小加 5%（至少一个 extent）余量收缩并捕获，随后无论捕获 writer/产物处理成功或失败都尽力恢复源 LV 与文件系统；`xfs`、swap 保持原大小，swap 只记录 UUID 和容量。多 PV/跨盘 VG、thin、raid、mirror、cache、snapshot、LUKS、mdraid 或不可识别拓扑会在 permit 前进入 attention。
- LVM 部署先校验任务快照的 v2 Schema/布局、PV 最小容量及 extent 对齐，再申请绑定目标盘的 disk permit。PV 可用容量按 `(PV 大小 - PE 起始 - 保留空闲)` 向下取完整 extent，允许末尾不足一个 extent 的未使用尾部。同尺寸或更大目标使用 `pvcreate --uuid --restorefile`、`vgcfgrestore`、`pvresize` 和已有 LV 的 `lvresize`；较小但不低于最小容量的目标不回放原 allocation map，而以 `pvcreate --norestorefile --uuid`、`vgcreate`、`lvcreate` 安全重建后逐 LV 恢复。后一路径会生成新的 VG/LV UUID，捕获 UUID 仅作身份与完整性校验；启动仍依赖保留的 VG/LV 名称和文件系统 UUID。`ext2`/`ext3`/`ext4` 恢复后执行可接受返回码 0/1 的 `e2fsck` 与 `resize2fs`、再回读容量；XFS 仅可原始大小恢复。所有 `pvcreate`、`vgcfgrestore`、`vgcreate`、`lvcreate`、`writeImage` 前均须已有匹配 permit。

## Windows 与 Linux 主机名

- Windows 改名仅在 `deploy` 且 `changeHostname=true` 时运行。PXEOS 先从唯一含 `Windows/System32/config/SYSTEM` 的 NTFS 分区识别系统卷；没有或有多个候选都会进入 attention，绝不猜测第一块 NTFS。随后仅检查固定路径 `Windows/System32/Sysprep/unattend.xml`：存在时使用 `xmlstarlet` 修改或安全插入 `specialize/Microsoft-Windows-Shell-Setup/ComputerName`，XML 异常、非唯一或回读失败均进入 attention，不回退注册表；该文件不存在时才离线修改 `SYSTEM` 注册表。
- Linux 改名仅支持 `osid=50` 的 `deploy` 任务，和 Windows 共用 `rootpxe_apply_hostname_for_disk` 分派入口。PXEOS 只探测 `ext2`、`ext3`、`ext4`、`xfs`、`btrfs`、`f2fs` 白名单中的唯一本地根文件系统：普通目标盘分区，或全部 PV 均属于该目标盘且以 VG UUID 选择的 LVM LV；无根、多根、跨盘 VG、混合 LV 激活状态都会进入 attention，绝不按最大分区、首个 LV 或同名 VG 猜测。LUKS、mdraid、跨盘 VG 及其他未列文件系统当前不支持，均按无法安全识别根卷处理。XFS 只以 `nouuid` 挂载，探测和写入后均清理挂载；PXEOS 自行激活的目标 VG 会在探测后及最终写入卸载后停用，原本已激活的 VG 不会被停用。
- Linux 主机名仅允许 1–63 位字母、数字、连字符，且首尾不能是连字符。PXEOS 写入并回读 `/etc/hostname`；已有文件通过原 inode 覆盖以保留其权限和属主，缺失时新建为 `root:root`、`0644`。有旧主机名且存在 `/etc/hosts` 时，只替换非注释行中的完整字段，不替换子串，仍通过原 inode 覆盖。`/etc` 必须是真实目录，`hostname`、`hosts` 不能是符号链接，避免离线镜像的绝对/越界链接写入 PXEOS 自身；`os-release` 的相对内链（例如 `../usr/lib/os-release`）在解析后仍位于目标根内时允许。
- 主机名定制失败后重试使用 `resumeStage=customizing_hostname`：PXEOS 为同一稳定目标盘重放 `operation=deploy_write` 的 disk permit，随后只执行系统卷识别、改名和 `postdeployscripts/hook.sh`，不运行 postinit、不重新验证/应用布局、不计划 NVMe format，也不重新写镜像。

## NVMe、permit 与验证边界

普通部署在写盘前绑定 `taskId`、token、MAC、目标盘稳定标识和计划操作的 disk permit；NVMe 扇区不匹配时仅在匹配 namespace、metadata-free LBAF、许可和倒计时确认后允许格式化。格式化开始即视为磁盘操作已开始；失败、重枚举异常或扇区回读不一致均应进入 attention。

上述运行时与三个 filesystem 配置均有改动。发布或真机验证时必须重新构建并替换同一批次的三架构产物；准确产物名称和硬件联调清单见[硬件兼容性](硬件兼容性.md#构建与回退边界)。capture/restore 失败传播与 `finish` 回调见[故障处理](故障处理.md)。
