## RootPXE 集成

以下为当前 PXEOS 运行时已实现的协议适配；服务端 Schema、任务快照、disk permit 以及管理端入口必须与此保持一致。它不代表已经完成真实磁盘环境验收。默认凭据和敏感信息边界见[安全配置](安全配置.md)，硬件构建边界见[硬件兼容性](硬件兼容性.md)。

## 存储协议

- 本次修复的根因是 JSON 中的 `storage` 字符串曾被按对象索引，导致 jq 报错后其返回码被吞掉，`protocol` 变为空并默认走 NFS，使 RootPXE 明确下发的 SMB 任务仍可能进入 NFS 挂载。SMB 仅接受当前 flat JSON 的顶层 `protocol`、`storageip`、`exportPath` 与 `smb*` 字段；顶层 `protocol` 优先，缺失时才保留 NFS 的嵌套兼容。普通 RootPXE 任务缺少或未知协议会拒绝，不根据 `storage` 字符串猜测协议；非 JSON legacy checkin 不接受 SMB。仅显式 `capone=1` 且缺少协议时保留既有 NFS 分支，仍要求 `storage_server` 与绝对 `storage_export`；不据此声明 USB 兼容性，Capone/USB 均未做真机验证。
- NFS export 使用绝对路径（例如 `/data/images`）。SMB `exportPath` 使用完整相对 `share[/subdir...]`（例如 `rootpxe/images`），并保持该值直到最终调用 `mount.cifs //server/share/subdir`；远程配置的 share/subdir 根必须已存在，PXEOS 不会在服务端回退挂载共享根。SMB 拒绝前导或尾随斜杠、空段、`.`/`..`、UNC、反斜杠、冒号、控制字符、空白和危险字符。SMB 仅使用凭据文件，checkin 明确协议并完成字段校验后才创建，明文不导出到子进程环境。
- SMB 不固定 `vers` 或 `sec`，由客户端和服务端自动协商。发布此运行时修改需要重新构建并替换相应 initramfs（如 `init.xz`）及同批次 PXEOS 产物；本次不修改或证明 `bzImage`/内核二进制已经重建。

## Schema、布局与 LVM

## 部署身份初始化 v1

- `rootpxe-offline-identities` 的 Windows 与 EFI 子命令职责、三阶段输入约束、结果解释、构建接入、架构验证边界和 Windows EFI 已知契约问题见 [离线身份修复工具](Windows离线身份修复.md)。

- PXEOS JSON checkin 读取服务端冻结的 deploymentIdentityPolicy。启用存储标识、Linux 系统唯一标识、SSH 服务器身份、SSH 登录公钥、root 密码或 Windows Sysprep 时，服务端会按对应 capability 门禁拒绝不支持的运行镜像。仅计算机名称保持既有 changeHostname 兼容流程，不需要身份计划。
- 需要计划的任务必须在任何部署脚本、分区表或镜像写入前取得磁盘许可和身份计划；重试携带当前 progressAttempt，计划响应必须回显完全相同的拓扑。运行时仅在对应工具链真实存在时声明 capability。

## 初始化系统与私密任务快照

- 部署策略可分别启用 Linux 系统唯一标识、SSH 服务器身份、计算机名称、SSH 登录公钥和 root 密码，或 Windows 计算机名称和 Sysprep 应答文件覆盖。
- PXEOS 只在策略启用私密初始化项时，从认证的私密任务接口读取裁剪后的任务快照。该接口响应禁止缓存，任务外或未启用私密项的请求会被拒绝。
- Linux SSH 登录公钥由 PXEOS 追加至 root 的现有已授权密钥文件并去重；它不改写 sshd 策略。root 密码以服务端提供的密码哈希替换 shadow 中 root 的第二字段，保留其余账户状态字段。
- Windows Sysprep 将完整 XML 写到固定的 unattend.xml 路径但不执行 Sysprep。xml 模式原样使用任务 XML；platform 模式只在任务副本的 specialize Shell-Setup ComputerName 安全唯一时替换为冻结名称。
- Windows 注册表改名不依赖 Sysprep 开关。PXEOS 使用只读原生 hostname inspect 找到 Current 和 Default ControlSet，交由 reged 写入四项主机名，再用只读 verify 核验。
- 部署 checkin 对需要名称的策略仅使用冻结 taskHostname。冻结名称缺失会返回冲突并要求重新创建任务，不读取实时主机名称。

```text
POST /service/pxeos/deployment-initialization
rootpxe-offline-identities windows-hostname-inspect <SYSTEM>
rootpxe-offline-identities windows-hostname-verify <SYSTEM> <name>
```

- 服务端以 windows-hostname-registry-v1 和 windows-sysprep-v1 分别作为 Windows 注册表主机名和 Sysprep 的 capability 门禁名称。checkin 在 `jq`、`ntfs-3g`、`reged` 与 `rootpxe-offline-identities` 都存在时声明前者，在 `jq`、`ntfs-3g` 与 `xmlstarlet` 都存在时声明后者，避免把源码存在误报为运行镜像支持；完整 Buildroot 交叉构建仍待验证。
- 存储随机化不会从旧目标盘读取标识：`n` 镜像使用冻结 `originalSchema` 和 `schemaHash`；固定、多盘和 dd 镜像使用冻结 `partitionInventory` 和 `partitionInventoryHash`，每个磁盘都有许可的 `targetBinding`、`sourceDiskNumber` 及对应 `dN.partitions` 中的旧磁盘标识。缺少或不一致的冻结元数据在写盘前拒绝。当前固定/多盘 inventory 无法证明 LVM 逻辑卷的文件系统映射时同样拒绝；LVM PV/VG UUID 从不修改。
- Linux 在恢复后按计划修改 GPT/MBR 磁盘与分区标识以及 ext2/3/4、XFS、swap UUID，精确更新 `fstab`、`crypttab`、GRUB 和 BLS 的 `UUID=`/`PARTUUID=` 引用，以及 GRUB `search --fs-uuid`。MBR 的 `签名:分区号` 冻结标识会转换为启动配置使用的 `签名-两位十六进制分区号`。存在 `grubenv` 时，PXEOS 仅通过目标系统的 `grub2-editenv` 或 `grub-editenv` 更新并读回 `kernelopts`，缺少目标工具或出现不安全 grubenv 会失败，不直接改写固定长度文件；受计划设备约束挂载独立 `/boot`、`/boot/efi`，并使用目标系统的 dracut、update-initramfs 或 mkinitcpio 重建 initramfs。缺少支持的工具失败，不会带着旧引用启动。冻结 schema 或 inventory 识别为 EFI 的分区只有在受控挂载中确有 EFI 可执行文件时才进入 EFI 修复；首次改 UUID 前，PXEOS 将所有计划分区的源、目标几何（目标几何取自 `sfdisk --json` 的实际逻辑扇区）和新旧标识写入目标根目录 `.rootpxe-offline-identities/<planId>/efi/manifest.json`，随后执行 native `efi-repair preflight`。改 UUID 并以同一路径重挂目标根后，才执行 `apply` 和 `verify`。未访问到 efivarfs 或 native 未匹配 NVRAM HD() 节点时，受控 ESP 必须包含当前架构的标准 `EFI/BOOT/BOOTX64.EFI`、`BOOTAA64.EFI` 或 `BOOTIA32.EFI` fallback；仅存在 GRUB 或 Windows loader 不能证明成功。纯 BIOS 镜像不调用 EFI 修复。
- Windows 在唯一受控 NTFS 系统卷生成 manifest，并将该稳定挂载根同时写入 `windowsRoot` 与 EFI `stateRoot`。含真实受控 ESP loader 的 UEFI 路径以此 manifest 执行 native EFI `preflight`、写盘后的 `apply` 和 `verify`；apply 只确认原生写入结果可用，只有 verify 的 `verified:true` 才是 EFI 变量读回证明。Windows EFI 缺少 `efivarfs` 或未匹配 NVRAM HD() 节点时，同样只接受受控 ESP 中当前架构的标准 fallback。
- `machine-id` 和 SSH 主机密钥仅写入已挂载的目标根目录。SSH 按实际 `HostKey` 配置使用 staging 生成、私钥公钥匹配验证和同计划 marker 复用，不触碰 `authorized_keys`；不支持的自定义 HostKey 路径或不安全链接拒绝。每次完成只上报本次实际成功的步骤。

- `image_type=n` 捕获完成、镜像写入与最终目录移动成功后，PXEOS 从最终镜像目录的唯一正式分区表 `d1.partitions` 生成 `originalSchema`，并在同一次 `finish` 回调中提交 `sizeBytes` 与 Schema。捕获不收缩、移动或恢复源盘，不生成 minimum、original 或 shrunken 分区表副本；`minDeployBytes` 和所有分区的 `minSectors` 都等于捕获表中的原始值。v1 GPT/普通 MBR 行为不变；带 DOS extended/逻辑分区的 MBR 使用 v2：分区按数字排序，容器为 `kind=extended`、`role=extended_container`、`artifact=""`，携带 `logicalNumbers`、`ebrReservedSectors=2`，并保留其捕获的原始大小，即使尾部存在未分配扇区；逻辑分区为 `kind=logical`，只携带唯一 `parentNumber`。v2 MBR `typeGuid` 统一为小写 `0x...`。任务 Schema hash 使用 `jq -cS` 的紧凑排序 JSON 字节，明确不包含其输出末尾换行，以匹配服务端 canonical JSON。无 LVM 拓扑时省略 `lvm`，不伪造空 PV/VG/LV；容器和 swap 均不要求镜像 payload。
- 部署布局使用 `original`、`fixed`、`percentage`、`remaining`。所有真实物理分区默认 `original`，管理员可以选择任一模式，但固定值不得小于原始大小；`remaining` 向下按 256 KiB 对齐，避免越过目标盘边界。GPT/MBR 边界、最小容量、身份、重复分区和回读不一致均拒绝继续。MBR extended 容器是由逻辑分区推导的结构项，保持 `derived`，不作为独立大小策略。`original` 保持该分区的大小，不承诺在前序分区改变后仍保持相同起始位置。
- MBR v2 部署布局中，extended 容器（`5`/`f`/`85`，可带 `0x` 前缀）只能为 `derived`，其最终范围由逻辑分区解析结果与 EBR 预留推导；容器绝不捕获或恢复 payload，即使存储中遗留 `dNpN.img*` 也不得进入 `writeImage`。逻辑分区必须在唯一容器内、保留 EBR 间隔；多容器、无父容器、越界、重叠或 EBR 空间不足会在 disk permit/首次写盘前进入 attention。当前安全实现仅接受所有 primary 均位于 extended 之前的布局，其他顺序拒绝而不猜测重排。固定大小/原始磁盘等既有镜像路径不因此改变。已识别的 MBR `0xef`/`ef` 为 EFI、`0x27`/`27` 为 recovery，`bootable` 标记为 boot，`0x8e`/`8e` 为 LVM PV，均受上述保护。
- LVM 仅用于 `image_type=n` 的单目标盘 PV、单 VG、`linear` LV。其唯一协议是 `lvm.version=1`、`captureMode=per_lv`、`resizePolicy=grow_only`：`LVM2_member` 在分区捕获分发时直接进入逐 LV 流程，保存 `d1p<分区号>.lvm.pv.meta` PV 元数据 sidecar、`d1p<分区号>.lvm.vg.cfg` 的 `vgcfgbackup` 配置和 `d1p<分区号>.lvm.lv.<LV名>.img` 的每个非 swap LV 镜像；LV artifact 必须是单个 Windows 安全文件名（允许 LVM 的 `+`，拒绝目录分隔符、冒号和管道），部署只按 schema 中的 artifact 字段读取，不扫描或猜测旧 UUID 文件名。PV 不保存 raw payload，也不提供 raw 回退。捕获不收缩、移动或恢复源 LV/文件系统，PV 与 LV 的最小容量均为捕获时原始容量；swap 保留 `swapUuid`，ext2/3/4 与 XFS LV 仅在取得真实 `filesystemUuid` 时写入该可选字段。存储随机化会按冻结计划修改 LV 的文件系统 UUID，但绝不修改 PV/VG/LV 自身 UUID；历史 LV 缺该字段时仅在开启随机化前拒绝并要求重新捕获，普通部署和仅系统身份初始化不受影响。多 PV/跨盘 VG、thin、raid、mirror、cache、snapshot、LUKS、mdraid、未知 LV 文件系统或不可识别拓扑会失败，不会最终化 Schema。
- LVM 的 schema、逐卷捕获以及部署阶段分层思路参考 [Toems](https://github.com/jdolny/Toems)、[Toec](https://github.com/jdolny/Toec) 与 [TheOpenEM 镜像文档](https://docs.theopenem.com/latest/ui/images/images.html)。这不表示照搬其实现：PXEOS 不沿用 TheOpenEM 的 LVM 缩容选项，也不采用 raw 回退或全局设备清理；本协议仍只允许目标 PV/VG/LV 作用域内的 grow-only 操作。
- LVM 部署在申请绑定目标盘的 disk permit 前校验唯一协议、PV 原始容量及 extent 对齐。目标 PV 和每个 LV 均不得小于捕获容量；不支持较小目标的 PV/VG/LV 重建。相同或更大目标使用 `pvcreate --uuid --restorefile`、`vgcfgrestore`，仅在 PV 更大时运行 `pvresize`，LV 仅使用 `lvextend`。`ext2`/`ext3`/`ext4` 恢复后执行可接受返回码 0/1 的 `e2fsck` 与 `resize2fs`；XFS 在 LV 扩大后临时挂载并执行 `xfs_growfs`；swap 保持原容量并以记录的 UUID 重建。恢复结束后核对容量、卸载临时 XFS 挂载并停用 VG。旧 LVM raw 或不符合该协议的镜像只可查看，不能创建或执行部署。
- 镜像类型与范围固定为：`n=all`、`dd=all`、`mps/mpa=all|mbr|1..10`。`dd` 是管理员显式选择的整盘逐扇区 raw 例外，可以包含 LVM，但不提供 LVM 的逐 LV 扩容能力；`mps/mpa` 捕获到 `LVM2_member` 会失败。部署 `mps/mpa` 时必须有可信的捕获分区清单且其中不含 LVM PV；缺少清单的历史 fixed 镜像会失败关闭，应改用 `dd` 明确整盘恢复，或重新以 `n` 逐 LV 流程捕获。
- 新建或重新捕获不支持 Partimage（format `1`）；PXEOS 仍保留其只读恢复解码器，以部署未改变捕获身份的历史 Partimage 镜像。物理 XFS 对已解析的目标分区临时挂载并对挂载点执行 `xfs_growfs`，不会再用 `resizepart … 100%` 覆盖布局解析结果或再次改变分区边界。

## Windows 与 Linux 主机名

- Windows 改名仅在 `deploy` 且 `changeHostname=true` 时运行。PXEOS 先从唯一含 `Windows/System32/config/SYSTEM` 的 NTFS 分区识别系统卷；没有或有多个候选都会进入 attention，绝不猜测第一块 NTFS。随后仅检查固定路径 `Windows/System32/Sysprep/unattend.xml`：存在时使用 `xmlstarlet` 修改或安全插入 `specialize/Microsoft-Windows-Shell-Setup/ComputerName`，XML 异常、非唯一或回读失败均进入 attention，不回退注册表；该文件不存在时才离线修改 `SYSTEM` 注册表。
- Linux 改名仅支持 `osid=50` 的 `deploy` 任务，和 Windows 共用 `rootpxe_apply_hostname_for_disk` 分派入口。PXEOS 只探测 `ext2`、`ext3`、`ext4`、`xfs`、`btrfs`、`f2fs` 白名单中的唯一本地根文件系统：普通目标盘分区，或全部 PV 均属于该目标盘且以 VG UUID 选择的 LVM LV；无根、多根、跨盘 VG、混合 LV 激活状态都会进入 attention，绝不按最大分区、首个 LV 或同名 VG 猜测。LUKS、mdraid、跨盘 VG 及其他未列文件系统当前不支持，均按无法安全识别根卷处理。XFS 只以 `nouuid` 挂载，探测和写入后均清理挂载；PXEOS 自行激活的目标 VG 会在探测后及最终写入卸载后停用，原本已激活的 VG 不会被停用。
- Linux 主机名仅允许 1–63 位字母、数字、连字符，且首尾不能是连字符。PXEOS 写入并回读 `/etc/hostname`；已有文件通过原 inode 覆盖以保留其权限和属主，缺失时新建为 `root:root`、`0644`。有旧主机名且存在 `/etc/hosts` 时，只替换非注释行中的完整字段，不替换子串，仍通过原 inode 覆盖。`/etc` 必须是真实目录，`hostname`、`hosts` 不能是符号链接，避免离线镜像的绝对/越界链接写入 PXEOS 自身；`os-release` 的相对内链（例如 `../usr/lib/os-release`）在解析后仍位于目标根内时允许。
- 部署认证 JSON 使用 `preDeployScript`/`preDeployScriptSha256` 和 `postDeployScript`/`postDeployScriptSha256` 两组字段；每组是独立脚本文本及其 SHA-256，单套上限为 64 KiB UTF-8 字节。前置脚本在目标盘身份确认并取得 `deploy_write` permit 后、任何 NVMe format、分区布局或镜像 restore 前执行；后置脚本在 restore、扩容和主机名定制后执行。每套脚本先独立复核 SHA-256，再写入独立的 `0700` 临时文件，并用 `env -i /bin/bash` 运行；临时文件不会写入镜像存储。
- 脚本进程只得到受控 `PATH`，以及 `ROOTPXE_TASK_ID`、`ROOTPXE_IMAGE_PATH`、`ROOTPXE_TARGET_DISK`、`ROOTPXE_HOSTNAME`、`ROOTPXE_OS_ID`。任务 token、SMB 凭据和其他父进程变量不会传入，调用方也不得依赖 `source` 或 `eval` 解释未受信任内容。捕获任务携带任一脚本或 hash 字段会被拒绝。
- 前置脚本的失败阶段为 `pre_deploy_script`，它不是安全恢复点，重试必须回到完整部署路径。安全续跑白名单只有 `customizing_hostname` 与 `post_deploy_script`：主机名失败以 `resumeStage=customizing_hostname` 恢复时仅重放 permit、定制主机名并执行后置脚本；后置脚本失败以 `resumeStage=post_deploy_script` 恢复时仅重放 permit 和后置脚本。两种恢复路径均不重新验证/应用布局、不计划 NVMe format，也不重新写镜像；任一脚本失败都不会报告任务成功。
- 启用随机化存储标识的任务不使用上述续跑路径。若在 customizing_hostname 或 post_deploy_script 中断，PXEOS 会在目标写入前以 `STORAGE_IDENTITY_RESUME_REQUIRES_REDEPLOY` 明确失败，并要求重新创建部署任务；只有不含存储标识随机化的初始化系统任务可按冻结配置续跑。
- 重捕获时，PXEOS 仅接受 RootPXE 下发的安全 `captureBackupName`，将旧正式镜像原子移动到 `/storage/backup/<captureBackupName>`。该目录可见、不得覆盖同名目录，并且必须与正式镜像和捕获暂存目录处于同一文件系统；首次捕获没有旧正式镜像时不会创建备份。

## 磁盘健康上报

- PXEOS 在部署和捕获任务完成认证 checkin、任务上下文和镜像路径校验后、实际选盘及写盘前，使用任务的原始 MAC 向既有 inventory 接口单独发送一次 diskHealth 表单字段；它不复用部署阶段旧硬件 inventory 临时改写 MAC 的流程。数据格式为 version=1 与最多 64 个主机物理磁盘条目。lsblk 使用其原始输出顺序枚举整盘 TYPE=disk 且 SIZE 大于零的设备，按设备路径去重；虚拟机中的 SATA、SCSI、NVMe 和 virtio 整盘均保留，TRAN 缺失不排除。NBD、loop、ram、zram、md、device-mapper、光驱、mmc boot 分区、普通分区及零容量设备不进入报告。镜像类型和任务选中的源盘或目标盘不会缩小该主机快照。
- SATA/SAS 使用 `smartctl -a -j`；NVMe 还使用 `nvme smart-log -o json`。只上传归一化后的型号、序列号、SMART 结论、温度、通电时长、寿命、备用空间、关键告警和错误计数，不上传原始 SMART JSON。计数为十进制字符串，整个 JSON 不超过 128 KiB；型号/序列号、设备名和诊断消息分别有 256、128、512 字符上限。
- 只有明确成功的 SMART/NVMe 健康证据才标记 `healthy`。SMART 失败或 NVMe `critical_warning` 非零为 `failed`；坏扇区、介质错误或 `percentage_used >= 100` 为 `warning`。工具缺失、超时、读取错误或畸形 JSON 会按现有优先级影响结论；缺少足以判定状态的健康证据时保留 `unknown`。有效 SMART JSON 未给出健康结论也会附上具体原因，但不覆盖已从其他来源取得的健康、告警或异常证据。虚拟 ATA/SATA 磁盘可能属于前一类，仍按 lsblk 的接口类型采集，不按型号或 smartctl 协议字段推断能力，也不强制指定 ATA 设备类型。`percentage_used` 是 NVMe 已使用寿命百分比，可超过 100，不是健康评分。
- 采集和上报均是有时限的 best-effort 行为：单次工具读取采用 3 秒软超时和 1 秒强制终止，总采集预算约 30 秒，网络请求也有连接和总超时。SMART、NVMe、解析或 HTTP 上报失败只记录本地告警并继续原有部署/捕获流程。lsblk 缺失、命令失败、JSON 结构或设备字段异常、或已枚举设备的逐盘记录无法完整生成，均不当作无盘，不上传空报告，后续仍由既有选盘、容量、许可和 I/O 规则决定结果。
- 只有 lsblk 成功枚举且确认没有有效物理磁盘时，PXEOS 才上报 version=1、disks=[] 快照，随后通过既有错误回调进入待处理并可重试的失败流程，捕获或部署不会开始；即使该空快照上传失败，仍按无盘失败。主机的已有健康度只在后续任务成功提交新快照后替换。已发布捕获载荷的 finish 续跑仍在 checkin 后采集主机快照，但不会重新选盘或重做捕获写入；确认无盘同样进入错误流程。

## NVMe、permit 与验证边界

普通部署在写盘前绑定 `taskId`、token、MAC、目标盘稳定标识和计划操作的 disk permit；NVMe 扇区不匹配时仅在匹配 namespace、metadata-free LBAF、许可和倒计时确认后允许格式化。格式化开始即视为磁盘操作已开始；失败、重枚举异常或扇区回读不一致均应进入 attention。

稳定标识保留已符合服务端 `targetId` 规则的 1–128 位原值；空白值、缺失属性或哈希失败会拒绝继续。含空格、斜杠、额外等号、非 ASCII 或超长的原值使用 `sha256:<64 位小写 hex>`，并完整参与散列；原值即使看似已在 `sha256:` 命名空间内也会再次散列，避免冒充编码标识。

disk permit 的 HTTP `4xx`、`granted:false`、非 JSON 响应以及 targetId/operation 回显不匹配均不等同于任务取消。对于 HTTP `4xx` 或布尔 `granted:false` 的明确拒绝，PXEOS 会以同一 task 上下文查询 `task-status`，仅接受 `2xx` JSON 的 `cancelled`、`superseded`、`deleted`，或 `404` JSON 的 `deleted` 作为取消终态；HTML 404、401、状态查询失败和其他状态都会保留许可围栏，不执行 hook 或磁盘操作。非 JSON、字段类型错误和 targetId/operation 回显不匹配按协议错误直接上报，不查询取消状态。服务端 `5xx` 与传输失败安全重试；明确拒绝或协议错误会上报 `PXEOS_DISK_PERMIT_DENIED` 并进入既有 attention/Retry 等待，上报被确认后才开始超时计时。控制台只显示 HTTP 状态和已知 permit code，任务 token、目标盘标识及原始响应正文不会回显。

上述运行时与三个 filesystem 配置均有改动。发布或真机验证时必须重新构建并替换同一批次的三架构产物；准确产物名称和硬件联调清单见[硬件兼容性](硬件兼容性.md#构建与回退边界)。capture/restore 失败传播与 `finish` 回调见[故障处理](故障处理.md)。
