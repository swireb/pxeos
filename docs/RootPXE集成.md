## RootPXE 集成

- Linux 镜像可保存原生 Cloud-init 配置，任务创建时冻结正文、散列、实例标识和主机名。部署前和部署后的平台脚本功能已移除。
- PXEOS 完成镜像恢复后仅离线安装 NoCloud seed；目标系统首次开机由预装的 Cloud-init 读取并执行原生配置。部署回执证明期望文件集合注入成功，不证明首次开机执行成功。
- 未配置 Cloud-init 的普通 Linux 部署和任何系统的捕获都不检查安装、不增加 seed、不清理目标缓存或已有内容、不离线修改 Linux 主机名。
- Windows 保留计算机名称与 Sysprep 应答文件两个独立开关：都关闭时不处理；只改名时写离线注册表；只启用 Sysprep 时保留自定义 XML 原字节；都启用时替换 XML 的计算机名称。平台不运行 Sysprep，也不保证 Windows Setup 已触发。

```text
#客户端能力
cloudInitCapability=linux-nocloud-v2
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
- 原生默认的每实例模块以冻结实例标识区分任务；需要每次开机行为时使用原生每次启动配置，平台不会强制循环执行。
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

## 可选网络配置

- 用户配置与网络配置可独立填写。网络配置使用原生 NoCloud 文件格式，不是写在外层网络键下的系统配置；后端检查单个映射和版本，完整发行版兼容性仍由镜像管理员验证。格式说明见 [NoCloud 网络配置](https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html#network-config)。
- 网络配置只在目标系统开机时交由原生 Cloud-init 处理；PXEOS 不解析原生网络 YAML、不执行配置，也不修改 PXEOS 当前网卡、DHCP 或管理连接。
- 配置任务要求新版客户端能力；旧版客户端能力不能继续配置部署，也不自动转换。私有响应始终携带两个网络字符串，未填写时正文和散列均为空，不创建第三个文件。
- 网络正文非空时最多为 65536 个 UTF-8 字节，不允许 NUL，按原字节核验 SHA-256。网络配置可能包含 Wi-Fi 凭据，按用户配置同等私密保护，不输出正文到日志、错误或命令参数。
- 只填写网络配置时，后端在冻结任务时生成下列最小用户配置及其散列；PXEOS 不补写或改写正文。

```yaml
#cloud-config
{}
```

```yaml
#network-config示例，网卡名称按目标镜像实际情况设置
version: 2
ethernets:
  enp1s0:
    dhcp4: true
```

## 目标发现与注入

- 配置任务先验证所有目标当前的硬件身份及写盘许可，只读发现唯一 Linux 根；纯数据盘可无根，零根、多根和探测失败都停止。
- 支持已许可普通分区及卷组中的扩展文件系统和 XFS。独立系统程序分区以只读方式检查预装程序，独立变量数据分区依据安全挂载表、设备身份和全部物理卷的当前许可关系挂载。
- 所有物理卷必须属于本任务明确许可的目标集合；设备可见不代表已授权。未知跨盘关系、重复挂载项、不支持的嵌套挂载和 Btrfs 根拒绝注入。
- 文件路径拒绝逃逸、不可信链接、硬链接及可被其他用户改写的组件。新增目录权限为 0700，两个文件为 root 属主、单链接的普通 0600 文件。
- 已有 NoCloud seed 只有恰好包含本任务期望的两个或三个文件、各文件字节与同一冻结任务完全匹配且安全属性和标签均通过时才只读接受；额外文件、缺失文件、篡改、不同任务、其他 seed 和未清理的 Cloud-init 缓存都明确拒绝。
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
