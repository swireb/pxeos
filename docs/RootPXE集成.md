## RootPXE 集成

- PXEOS 从认证通道获取任务冻结的计算机名称、系统初始化与部署脚本；管理员重新部署仍完整覆盖，不以目标已有系统作为跳过恢复的条件。
- 前置保持 PXEOS Bash；后置只对明确 Linux 类别离线安装，并由目标 systemd 每次正常开机运行，不即时执行正文。
- 全部 Windows、Apple Mac OS、Other、Chromium OS、未知及空类别无后置；Windows 系统内命令沿现有 Sysprep XML，平台只校验和写应答文件，不自动执行 Sysprep 或保证 Setup 触发。
- 捕获任何系统都无部署脚本，也不删除源系统的启动入口。
- Linux 部署的客户端能力必须在准入与写盘许可前校验，空后置也包含停用策略；未知能力、模式或错误散列拒绝，不从发布版本推断。
- 后置在恢复及可选系统初始化后处理；名称和初始化开关都关闭时仍可以安装，不进入 Windows 初始化逻辑。

```text
postDeployScriptCapability=linux-systemd-v1
postDeployScriptExecution=linux-systemd-v1
osTypeId=50
#目标Linux固定路径
/etc/rootpxe/startup.sh
/etc/rootpxe/startup-runner.sh
/etc/rootpxe/startup-result.sh
/etc/rootpxe/startup.manifest
/etc/rootpxe/startup.transaction
/etc/systemd/system/rootpxe-startup.service
/var/log/rootpxe/startup.log
```

## 挂载、归属与恢复

- 先探测所有已许可目标并证明唯一 Linux 根，纯数据盘可无根；零根、多根或真实探测失败停止，不先写某个根再发现歧义。
- 普通分区、LVM 与 Btrfs 根沿底层发现；只卸载自建挂载、停用自有激活，清理失败不能报告成功。
- 独立系统程序分区必须由挂载表、设备与卷组 UUID、全部物理卷证明属于选中许可盘；跨盘或未知关系不猜测。
- 无受管入口的空后置无写入返回；现有入口必须完整核验固定路径、权限、散列和清单，不能只凭文件名清理。
- 同名 foreign、写路径链接或同名单元附加配置停止；目标内能力链接有限解析，允许常见 usr-merge，不跟随到 PXEOS 根。
- 安装事务保留原 inode 与标签，最后才启用；未提交失败受控恢复，已提交清理另行核验重试，未知记录或 foreign 项保留证据待处理。
- 最后删除事务记录与删除本次新建空私有目录之间中断可能仅剩无入口空目录，不宣称断电跨文件原子性已验收。

## 运行时与日志

- 离线不执行目标二进制验证版本；目标运行器有限查询加载单元的真实身份、时限、重试、日志与来源属性，不满足则失败且不运行正文。
- 运行总时限为 300 秒，停止和收尾有短期限，受管子进程由 control-group 管理；不依赖用户登录，不把脚本成功设为关键启动依赖。
- 输出到目标 journal，收尾只保存当前 invocation 最近 200 条的有限样本，固定文件总上限 4 MiB；字节截断标志不承诺完整原始输出。
- 结果散列是收尾时当前文件散列，不是被执行字节的独立证明；主进程非零退出或超时不会被日志失败改成成功。
- 不改全局日志或 SELinux 策略，不增加全盘重新标记；按目标策略精确设置并回读受管标签，工具缺失拒绝非空安装。
- 当前三架构配置声明现有标签库依赖，但实际工具打包尚未构建验证，不能据此承诺当前 initrd 或 Rocky 实机可用。
- 配置、任务或正文不含真实部署凭据；平台不传 PXEOS 令牌或成像变量给目标正文，用户须避免在自己的输出中泄漏敏感信息。
- 本地 fixture、静态检查和服务端测试不等于已发布 PXEOS 或真实首次、第二次开机验收。完整契约见 [部署脚本设计](../../../docs/部署系统开机脚本设计.md)。
