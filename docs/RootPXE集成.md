## RootPXE 集成

- Linux 镜像独立保存原生用户配置、手工元数据和可选网络配置，并有独立的 Cloud-init 启用开关；关闭时保留镜像草稿，但任务不下发私有正文。启用时任务冻结最终配置副本及散列，不自动生成实例标识；名称关闭时保留三份原文。部署前和部署后的平台脚本功能已移除。
- PXEOS 完成镜像恢复后仅离线安装 NoCloud seed；目标系统首次开机由预装的 Cloud-init 读取并执行原生配置。部署回执证明期望文件集合注入成功，不证明首次开机执行成功。
- Cloud-init 关闭时不检查安装、不增加 seed、不清理目标缓存或已有内容；是否离线修改 Linux 主机名由计算机名称开关决定。捕获不执行配置注入或改名。
- Windows 保留计算机名称与 Sysprep 应答文件两个独立开关：都关闭时不处理；只改名时写离线注册表；只启用 Sysprep 时保留自定义 XML 原字节；都启用时替换 XML 的计算机名称。平台不运行 Sysprep，也不保证 Windows Setup 已触发。

```text
#客户端能力
cloudInitCapability=linux-nocloud-v3
#Cloud-init关闭且计算机名称开启时，checkin与两种permit请求均声明
deploymentIdentityProtocolVersions=[1]
deploymentIdentityCapabilities=["hostname","linux-hostname-offline-v1"]
#仅配置的Linux部署使用
osTypeId=50
#目标系统始终注入的两个seed文件
/var/lib/cloud/seed/nocloud/user-data
/var/lib/cloud/seed/nocloud/meta-data
#仅网络配置非空时注入的第三个文件
/var/lib/cloud/seed/nocloud/network-config
```

## 准备 Linux 镜像

- 镜像管理员在制镜系统中安装、启用 Cloud-init，并确认 NoCloud 数据源及所需原生模块可用。使用发行版支持的配置和服务启用方法；PXEOS 不安装软件、不执行目标程序、不代替原生 YAML 合并或服务状态验证。
- 镜像管理员在源镜像系统中使用官方 schema 检查配置，完成试启动并确认发行版支持下列清理选项后再执行。清理后直接关机，通过 PXE 捕获干净镜像；不要再次正常启动源镜像，以免 Cloud-init 重新创建缓存。
- 清理缓存、seed 和准备 machine-id 属于镜像制作步骤；machine-id 不是平台 user-data 开关，PXEOS 不执行这些清理或修改。
- 每实例模块使用手工实例标识判断实例，并不自动按平台任务重新执行。应由管理员为使用场景管理标识；复用标识和缓存可能使原生模块不再执行。需要每次开机行为时使用原生每次启动配置，平台不会强制循环执行。
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

## 三份原生配置

- 用户配置可以为空；空文件仍必须有真实空字节 SHA-256，PXEOS 保留空文件，不生成最小用户配置。元数据必须非空并由管理员填写合法实例标识；后端验证 YAML 和字段，PXEOS 只核对认证任务原字节与散列，不引入原生 YAML 解析器。
- 手工实例标识为一至一百二十八个 ASCII 字母、数字、点、下划线、冒号或连字符，不能只有点；平台不自动生成或改写。下例标识仅作占位，实际部署由管理员选择。
- 网络配置使用原生 NoCloud 文件格式，不是写在外层网络键下的系统配置；后端检查单个映射和版本，完整发行版兼容性仍由镜像管理员验证。格式说明见 [NoCloud 网络配置](https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html#network-config)。
- 网络配置只在目标系统开机时交由原生 Cloud-init 处理；PXEOS 不解析原生网络 YAML、不执行配置，也不修改 PXEOS 当前网卡、DHCP 或管理连接。
- 启用的 Linux 部署私有响应始终携带六个字符串，旧版能力、旧自动元数据字段、部分字段或散列错误均拒绝，不兼容降级。网络未填写时正文和散列都为空，不创建第三个文件；其他两项即使用户正文为空也携带真实散列。
- 每项最多为 65536 个 UTF-8 字节，不允许 NUL，按原字节核验 SHA-256，包括原有 CRLF。三份正文同等私密，可能包含 Wi-Fi 凭据等秘密，不输出到日志、错误或命令参数。

```text
cloudInitUserData
cloudInitUserDataSha256
cloudInitMetaData
cloudInitMetaDataSha256
cloudInitNetworkConfig
cloudInitNetworkConfigSha256
```

```yaml
#meta-data示例，必须手工提供instance-id
instance-id: operator-chosen-instance
local-hostname: image-default
```

```yaml
#network-config示例，网卡名称按目标镜像实际情况设置
version: 2
ethernets:
  enp1s0:
    dhcp4: true
```

## Linux 计算机名称四态

- Cloud-init 关闭、名称关闭：不修改主机名，不检查或修改 Cloud-init 内容。
- Cloud-init 关闭、名称开启：PXEOS 按任务冻结的管理端名称离线更新主机名和必要的本机回环映射，不要求预装 Cloud-init。
- Cloud-init 开启、名称关闭：三份配置保持原文，包括管理员手写的元数据主机名；不套用管理端名称校验，也不离线修改主机名。
- Cloud-init 开启、名称开启：服务端只在任务副本中渲染冻结管理名称，镜像原文不变，重试复用相同快照。PXEOS 不离线改名，只验证并注入已渲染副本；下发的任务用户配置必须非空，镜像用户配置可留空，由服务端生成最小命名副本。
- 管理名称沿用单标签一至六十三个 ASCII 字母、数字或连字符、首尾非连字符的规则，不扩展为管理端 FQDN。手工配置且名称关闭时的原生主机名由后端按元数据格式验证。
- 只有全部期望文件注入、读回和本次清理均成功且名称开启，才提交名称回执；该回执表示平台名称配置已注入，不表示客户机首启后已采用名称。

```yaml
#meta-data任务副本：保留手工instance-id，只渲染local-hostname
instance-id: operator-chosen-instance
local-hostname: managed-node
```

```yaml
#cloud-config
#user-data任务副本中的平台名称字段
hostname: managed-node
fqdn: managed-node
preserve_hostname: false
create_hostname_file: true
```

## Linux 离线改名边界

- 离线名称分支先验证完整许可目标集合并只读查找唯一根，再读写处理一次；同一多物理卷根去重，全部物理卷都必须属于已许可集合。纯数据盘不猜为根，多个系统根拒绝。
- 只更新下面两个固定配置文件；已有文件保留 inode、属主、模式和 SELinux 标签。只替换本机回环行的完整旧名称 token，保留本地主机默认别名、注释、空白和远端行，不推断域名后缀。没有可替换自身条目时追加本机映射，已有新名称映射不重复追加。
- 配置文件缺失时可创建受控普通文件；危险链接、硬链接、属主、模式、额外挂载或标签无法验证均拒绝。系统配置目录的额外挂载不在支持范围。
- 受控失败只回滚本次文件，外来替换不覆盖；回滚或清理无法证明成功时保留事务证据并报告失败，不承诺多文件断电原子性。不执行目标程序或旧初始化功能。

```text
/etc/hostname
/etc/hosts
#需人工核对的受控失败证据，不由后续任务盲删
/etc/.rootpxe-hostname.*
```

## 目标发现与注入

- 配置任务先验证所有目标当前的硬件身份及写盘许可，只读发现唯一 Linux 根；纯数据盘可无根，零根、多根和探测失败都停止。
- 支持已许可普通分区及卷组中的扩展文件系统和 XFS。独立系统程序分区以只读方式检查预装程序，独立变量数据分区依据安全挂载表、设备身份和全部物理卷的当前许可关系挂载。
- 所有物理卷必须属于本任务明确许可的目标集合；设备可见不代表已授权。未知跨盘关系、重复挂载项、不支持的嵌套挂载和 Btrfs 根拒绝注入。
- 文件路径拒绝逃逸、不可信链接、硬链接及可被其他用户改写的组件。新增目录权限为 0700，期望集合中的所有文件为 root 属主、单链接的普通 0600 文件。
- 已有 NoCloud seed 只有恰好包含期望的两个或三个文件、各文件字节与当前冻结内容完全匹配且安全属性和标签均通过时才只读接受；额外文件、缺失文件、篡改、内容不同、其他 seed 和未清理缓存都拒绝。手工实例标识下，散列相等只能证明内容一致，不能证明历史归属同一任务，不新增任务归属标记文件。
- 清空平台网络配置不会删除镜像中的网络文件。任务网络为空但目标已有第三文件时视为外来冲突并拒绝，不覆盖或静默清理已有内容。
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
