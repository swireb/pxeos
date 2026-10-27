## RootPXE 集成

- Linux 镜像保存手工编辑的用户、元数据、可选供应方和可选网络四份模板，并有独立的 Cloud-init 启用开关；关闭时保留镜像草稿，但任务不下发私有正文。服务端只替换显式宏，在任务创建时渲染一次并冻结最终字节与散列；重试复用同一快照，PXEOS 不渲染模板。部署前和部署后的平台脚本功能已移除。
- PXEOS 完成镜像恢复后仅离线安装 NoCloud seed；目标系统首次开机由预装的 Cloud-init 读取并执行原生配置。部署回执证明期望文件集合注入成功，不证明首次开机执行成功。
- Cloud-init 关闭时不检查安装、不增加 seed、不清理目标缓存或已有内容；是否离线修改 Linux 主机名由计算机名称开关决定。捕获不执行配置注入或改名。
- Windows 启用 Sysprep 应答模板时，PXEOS 仅校验并原字节注入服务端冻结 XML，不插入或覆盖固定计算机名称，也不另写离线注册表。未启用模板且名称开关开启时，保留离线注册表改名。平台不运行 Sysprep，也不保证 Windows Setup 已触发。

```text
#客户端能力
cloudInitCapability=linux-nocloud-v5
#Windows应答模板能力，替换旧Sysprep v1能力
windows-sysprep-template-v2
#Cloud-init关闭且计算机名称开启时，checkin与两种permit请求均声明
deploymentIdentityProtocolVersions=[1]
deploymentIdentityCapabilities=["hostname","linux-hostname-offline-v1"]
#仅配置的Linux部署使用
osTypeId=50
#目标系统始终注入的两个seed文件
/var/lib/cloud/seed/nocloud/user-data
/var/lib/cloud/seed/nocloud/meta-data
#仅对应配置非空时分别增加文件，seed共两个、三个或四个文件
/var/lib/cloud/seed/nocloud/network-config
/var/lib/cloud/seed/nocloud/vendor-data
```

## 手动多播会话

- 手动多播需要第二版会话能力和匹配的服务端；旧版客户端必须重新构建并发布PXEOS后升级，不会静默改为单播。普通单播仍沿用原执行身份合同。
- 首次认证JSON报到取得公开编号与不可复用实例键，后续专用控制、许可、阶段、进度、异常、初始化、库存、状态和完成请求共同携带二者及当前尝试号。编号始终为严格正十进制文本，最大为9223372036854775807，不经过shell整数或JSON数值转换。
- 私有请求上下文冻结任务、执行令牌、MAC、尝试号和会话身份；任一不一致时不发专用请求，错实例响应不保存为当前状态。同一进程改为单播时清除旧会话环境与私有上下文，不把旧身份附在单播请求中。
- 队列或连带清理任务的主机清理允许公开编号重新从1分配，历史和旧回调依靠不可复用实例键隔离；取消、单删和清理事件不复位。字段、迁移与跨进程限制统一见根项目[通信消息规范](../../../docs/RootPXE与PXEOS通信消息规范.md)。

```text
deploymentIdentityCapabilities=["manual-multicast-session-v2"]
multicastSessionId="1"
multicastSessionKey="mc-0123456789abcdef0123456789abcdef0123456789abcdef"
```

## 准备 Linux 镜像

- 镜像管理员在制镜系统中安装、启用 Cloud-init，并确认 NoCloud 数据源及所需原生模块可用。使用发行版支持的配置和服务启用方法；PXEOS 不安装软件、不执行目标程序、不代替原生 YAML 合并或服务状态验证。
- 镜像管理员在源镜像系统中使用官方 schema 检查配置，完成试启动并确认发行版支持下列清理选项后再执行。清理后直接关机，通过 PXE 捕获干净镜像；不要再次正常启动源镜像，以免 Cloud-init 重新创建缓存。
- 清理缓存、seed 和准备 machine-id 属于镜像制作步骤；machine-id 不是平台 user-data 开关，PXEOS 不执行这些清理或修改。
- 每实例模块依据元数据实例标识判断实例；元数据可填写固定标识，也可显式使用实例标识宏，让新任务生成随机值并在重试时复用。仍需准备干净缓存，不能用新标识替代镜像清理。需要每次开机行为时使用原生每次启动配置，平台不会强制循环执行。
- 配置会原字节保存，不能把真实密码、私钥、访问令牌放入共享文档或诊断输出。

```shell
#仅镜像管理员在源镜像系统内执行，先确认发行版支持这些选项
cloud-init schema --system
#验证待使用的user-data配置，可按实际文件位置调整
cloud-init schema --config-file /root/user-data
#完成清理后直接关机，不再正常启动源镜像
cloud-init clean --logs --machine-id --seed
```

- 数据源、清理和模块频率以 [NoCloud 官方说明](https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html)、[clean 官方说明](https://docs.cloud-init.io/en/latest/reference/cli.html#clean) 和 [原生模块说明](https://docs.cloud-init.io/en/latest/reference/modules.html) 为准。

## 四份原生配置

- 用户配置可以为空；空文件仍必须有真实空字节 SHA-256，PXEOS 保留空文件，不强制写入平台名称字段。元数据必须非空，支持手工实例标识及原生合法其他键；PXEOS 只核对认证任务原字节与散列，不引入原生 YAML 解析器。
- 供应方配置非空时必须为原生 Cloud-config，后端验证格式；PXEOS 不解析或执行正文，只校验完整性并离线写入固定种子路径。供应方配置与用户配置的原生合并和模块行为由目标系统 Cloud-init 决定。
- 网络配置使用原生 NoCloud 文件格式，不是写在外层网络键下的系统配置；后端检查单个映射和版本，完整发行版兼容性仍由镜像管理员验证。格式说明见 [NoCloud 网络配置](https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html#network-config)。
- 网络配置只在目标系统开机时交由原生 Cloud-init 处理；PXEOS 不解析原生网络 YAML、不执行配置，也不修改 PXEOS 当前网卡、DHCP 或管理连接。
- 启用的 Linux 部署私有响应始终携带八个字符串，旧版能力、旧自动元数据字段、部分字段或散列错误均拒绝，不兼容降级。网络和供应方配置分别未填写时，对应正文与散列都为空，不创建对应文件或私有句柄；用户正文即使为空也携带真实散列。
- 每项最多为 65536 个 UTF-8 字节，不允许 NUL，按原字节核验 SHA-256，包括原有 CRLF。四份正文同等私密，可能包含 Wi-Fi 凭据等秘密，不输出到日志、错误或外部进程命令参数；解析通过标准输入传递完整响应。

```text
cloudInitUserData
cloudInitUserDataSha256
cloudInitMetaData
cloudInitMetaDataSha256
cloudInitNetworkConfig
cloudInitNetworkConfigSha256
cloudInitVendorData
cloudInitVendorDataSha256
```

```yaml
#meta-data固定标识模板示例
instance-id: operator-fixed-instance
local-hostname: fixed.example
```

```yaml
#meta-data显式宏模板示例，任务创建时由服务端替换
instance-id: "{{ROOTPXE_INSTANCE_ID}}"
```

```yaml
#cloud-config
#vendor-data示例，不在PXEOS中执行
timezone: Asia/Shanghai
```

```yaml
#network-config示例，网卡名称按目标镜像实际情况设置
version: 2
ethernets:
  enp1s0:
    dhcp4: true
```

## 计算机名称策略入口

- 名称开关、Windows 与 Linux 规则、四态路由和任务冻结语义统一见根项目 [主机名称策略](../../../docs/主机名称策略.md)；本页只说明客户端 NoCloud 注入边界。
- 宏模板字段与编辑约定见根项目 [Cloud-init 配置](../../../docs/Cloud-init配置.md)。服务端只替换显式宏，固定名称保留；名称宏仅在名称开关开启时可用。ROOTPXE_MAC_COLON 固定输出小写冒号，ROOTPXE_MAC_HYPHEN 固定输出大写横线，两者均可在Linux和Windows模板中使用，客户端不作二次转换。
- 平台掩码宏使用点分十进制，前缀长度宏由掩码派生为纯数字；客户端不再次推导或替换宏。
- Cloud-init 或 Windows 应答模板启用时，PXEOS 验证并注入已冻结副本，不校验固定名称是否等于管理端名称，不另行离线改名。
- 只有全部期望文件注入、读回和本次清理均成功，才提交对应模板注入回执；模板启用时名称回执始终为 false。未启用模板时独立离线改名的名称回执保持原语义。回执都不证明目标首次开机已执行或采用名称。

```text
{{ROOTPXE_INSTANCE_ID}}
{{ROOTPXE_HOSTNAME}}
{{ROOTPXE_MAC_COLON}}
{{ROOTPXE_MAC_HYPHEN}}
{{ROOTPXE_IP}}
{{ROOTPXE_NETMASK}}
{{ROOTPXE_PREFIX}}
{{ROOTPXE_GATEWAY}}
{{ROOTPXE_DNS1}}
{{ROOTPXE_DNS2}}
{{ROOTPXE_DNS_SUFFIX}}
{{ROOTPXE_FQDN}}
{{ROOTPXE_TIMEZONE_IANA}}
{{ROOTPXE_TIMEZONE_WINDOWS}}
```

## 目标发现与注入

- 配置任务先验证所有目标当前的硬件身份及写盘许可，只读发现唯一 Linux 根；纯数据盘可无根，零根、多根和探测失败都停止。
- 支持已许可普通分区及卷组中的扩展文件系统和 XFS。独立系统程序分区以只读方式检查预装程序，独立变量数据分区依据安全挂载表、设备身份和全部物理卷的当前许可关系挂载。
- 所有物理卷必须属于本任务明确许可的目标集合；设备可见不代表已授权。未知跨盘关系、重复挂载项、不支持的嵌套挂载和 Btrfs 根拒绝注入。
- 文件路径拒绝逃逸、不可信链接、硬链接及可被其他用户改写的组件。新增目录权限为 0700，期望集合中的所有文件为 root 属主、单链接的普通 0600 文件。
- 已有 NoCloud seed 只有恰好包含期望的两个、三个或四个文件、各文件字节与当前冻结内容完全匹配且安全属性和标签均通过时才只读接受；额外文件、缺失文件、篡改、内容不同、其他 seed 和未清理缓存都拒绝。散列相等只证明内容一致，不能单独证明历史归属同一任务，不新增任务归属标记文件。
- 清空平台网络或供应方配置不会删除镜像中的对应文件。任务配置为空但目标已有对应种子文件时视为外来冲突并拒绝，不覆盖或静默清理已有内容。
- 同一文件系统暂存完整期望文件集合，核对散列与目标 SELinux 标签后发布并读回。已有空目录保留原 inode 和扩展属性；受控失败仅回滚本次新建对象，清理失败保留证据并报告失败。
- 只卸载本次挂载、停用本次激活的卷组，借用挂载不卸载。关机断电或 SIGKILL 可能留下半份 seed，后续部署会拒绝；不宣称文件集合发布具备断电原子性。
- 沿目标 SELinux 策略核对固定路径标签，不关闭安全策略或触发全盘重新标记。三架构配置已声明标签库及扩展属性工具依赖，实际工具打包和 initrd 尚未构建验证。

## 原生日志与验证边界

- 目标首次开机后的状态和执行结果在目标系统检查，使用发行版提供的 Cloud-init 状态命令与日志。
- 本地 shell fixture 使用普通临时文件和设备命令替身；Windows 上 Unix 属主、模式及原生符号链接存在验证限制。通过 fixture 不代表真实 Linux 权限、挂载、Cloud-init 首启或已发布 PXEOS 验证通过。

```shell
#目标系统
cloud-init status --long
```

```text
#目标系统原生日志
/var/log/cloud-init.log
/var/log/cloud-init-output.log
```

## 修改记录

- 2026-10-15：退役平台部署脚本与 Linux 自制初始化，改用原生 NoCloud 两文件离线注入；保留 Windows 计算机名称与 Sysprep 应答文件四态。
- 2026-10-15：升级 NoCloud 能力并支持可选网络配置；未配置网络仍保持两文件，非空网络增加第三文件并纳入私密校验、只读幂等与回滚。
- 2026-10-15：升级为三份原文私有链及手工元数据，允许空用户文件；恢复独立 Linux 离线改名并按四态路由，名称回执只证明配置注入或离线文件更新，不代表首启执行。
- 2026-10-16：增加可选供应方配置，四文件集合完整纳入私有句柄、只读预检、标签、暂存发布和回滚；升级为 v5 冻结模板及 Windows 应答模板 v2，保留手工元数据和固定名称，客户端停止强制名称覆盖，模板只报告注入结果。

## 网络存储与抓取发布

当前源码增加存储协议v1和固定C/json-c/OpenSSL helper，x64/x86/arm64 profile同步接入；必须重新构建并成对发布服务端与PXEOS。源码存在不等于三架构产物或真实NAS已验证，本轮未执行编译、测试、挂载或设备操作。

```json
{
  "storageProtocolVersions": [1],
  "storageCapabilities": {
    "helper": true,
    "numericIdentity": true,
    "durablePublish": true
  },
  "storageBootId": "12345678-1234-4234-8234-123456789abc"
}
```

上述为checkin能力示例，boot_id必须读取本次Linux启动事实，不能复用示例值。NFS和SMB都在任务准入推进前检查能力；旧端缺能力时拒绝，不回退root直接NAS I/O。受任务认证JSON的`storageAccess`包含version、execution owner、协议、server/exportPath/imagePath、版本策略及NFS身份；SMB凭据继续走私有认证响应和临时0600凭据文件，不写启动参数、普通日志或恢复副本。实际执行还绑定attempt、storageNonce、workerNonce和storageBootId。

| 协议 | 配置策略 | 执行要求 |
| --- | --- | --- |
| NFS | auto、3、4.0、4.1、4.2 | AUTH_SYS；UID/GID双必填，0..4294967294，显式0合法。auto只在明确版本拒绝时按4.2→4.1→4.0→3回退 |
| SMB | auto、2.1、3.0、3.0.2、3.1.1 | 只允许四方言，拒SMB1/2.0.2和guest/null；空域不补WORKGROUP，固定版本必须精确匹配 |

服务端与PXEOS分别核验`configuredVersion/actualVersion`，两端auto结果可以不同；本执行、重连和恢复固定原实际版本，不再次auto。PXEOS从精确受控挂载的mountinfo核对来源、根与版本，不从普通mount退出码推测版本拒绝，不因权限/路径/认证/网络失败降级。

NAS访问根预先存在。写任务才按需创建根下`dev/taskId/attempt`、`.imports/taskId/attempt`、`.locks/canonicalTargetKey`。部署、导出和多播读取不做写探针、不创建dev或写锁；路径逐分量核对，不跟随链接，不认领陌生对象。NAS管理员或独立客户端的外部修改仍会导致任务拒绝，公共锁不提供跨控制面或物理别名检测。

```text
/storage/dev/<任务编号>/<执行批次>/       # 捕获暂存
/storage/.imports/<任务编号>/<执行批次>/  # 导入控制树
/storage/.locks/<canonicalTargetKey>/owner
/storage/<image.path>/                   # 正式镜像
```

公开镜像路径拒绝顶层保留命名空间、绝对路径、点分量和越界，普通分量 `build..old` 合法。重复及父子目标拒绝；目标只读权限不能被根写探针阻断。旧固定 MAC 暂存、旧 `.imports/.locks`、旧 claim 或陌生目录不能自动认领、迁移、删除，也不能通过使用新锁位置绕开原保护。已运行旧 PXEOS 不会自动获得新合同，须结束旧会话后成对发布。

抓取必须完整写入当前任务/批次暂存，全部 writer 与元数据成功并封存后才发布。发布、回滚及清理仅依原 owner、持久对象身份和逐阶段 ACK 授权；本执行的旧树仅用于恢复，不提供永久备份。只清理身份明确属于原批次的对象，未知内容或丢回执保留并等待安全恢复；不能仅按任务编号、marker 或最后一个管道退出码判定成功。finish 与后台收尾分离，工作者及 helper 真正退出、清理得到确认后才 release。

helper固定入口为`rootpxe-storage-io --context-fd 3 --request-fd 4 --data-fd 5 --result-fd 6`。FD3来自root所有0600本地上下文；请求/ACK、数据和结果管道分离、有界。NFS普通存储进程先组→GID→UID→能力收敛→NoNewPrivs，之后才打开NAS；root块设备与压缩进程只通过本地FIFO交换数据，不把root已打开的NAS FD交给helper。NFS挂载使用单独固定入口，仅保留CAP_SYS_ADMIN和配置身份，不给挂载添加uid/gid参数。

五回调位于`/pxe/v1/storage/preflight`、`publish-begin`、`publish-checkpoint`、`publish-complete`、`release`。preflight返回分页原目标清单、两端实际版本、rootFileId和原执行恢复信息；helper intent→created→result逐阶段经服务端持久后才ACK。全部producer成功退出后seal，publish-begin依据锁定任务所绑定镜像类型检查原捕获事实：n型必须提供originalSchema并通过结构及默认部署布局前置校验，其他类型可省略，客户端不能自行选择绑定类型；随后冻结原捕获事实和时间，再正式rename、finish、cleanup/helper join，最后release；不能以最后一个管道退出码代替整条流水结果。

服务重启或PXEOS重启仅沿原owner/attempt恢复。必须确认原worker停止，或原token/MAC、同一非克隆可信宿主的稳定UUID、不同Linux boot_id和新认证checkin一致；这不是硬件远程证明。普通同boot任务不要求可靠DMI，无可靠DMI不能跨boot接管。storage-only只允许原代际发布/回滚/清理，禁止新磁盘许可和重复电源动作。未知证据保留内部保护，不按心跳或TTL抢占，不改变已完成历史。

本页保留独立子仓所需的客户端合同；RootPXE 配置及完整待验矩阵另见根项目[存储系统](../../../docs/存储系统.md)。四版本NFS、四SMB方言、Windows共享宿主参考、恢复和吞吐尚未实测，不以版本选项或离线夹具声称兼容通过。

### 多播与普通 checkin

七条 `/pxe/v1/multicast/{join,prepare,ready,report,status,end,cancel}` 请求统一携带 `storageNonce`、`workerNonce`、`attempt`、`storageBootId`，并可选携带 `sysuuid` 作为稳定硬件见证。前四项必填；`attempt` 必须是严格正整数且等于 `progressAttempt`，小数、带后缀字符串、0 和负数均拒绝。旧 `worker` 或不匹配的 `boot/nonce` 值拒绝；body 继续拒绝未知字段。多播控制不承担跨 boot 接管，跨 boot 仅通过 storage preflight 的原执行恢复条件进入 storage-only；普通同 boot 任务没有可靠 DMI 时仍可工作。

多播先取得域首锁和 task 锁，完成 storage 认证并持久提交后才进入 service/NAS；`end`、`cancel` 写入最终状态前再次封口。`ready` 仅允许 `pxeos` scope。普通首次 checkin 若尚未发放 storage reservation，可沿原 reservation 独立准入；一旦已执行 preflight，恢复只允许原代际 storage-only 路径，不发放新的磁盘许可。服务端 owner/目标占用返回409，协调不可用返回503，真实数据库错误返回500；checkin 只接受当前 JSON，不提供旧键值载荷兼容。

本页记录源码合同和客户端边界，不代表构建或运行通过。shell/C 离线入口见本仓[测试说明](../tests/README.md)；仍须构建三架构产物并验收真实 NAS 权限、版本、原工作者未停保护、跨 boot 恢复和吞吐。RootPXE 数据库只支持匹配当前完整初始化目标的新空库，不提供旧库迁移。
