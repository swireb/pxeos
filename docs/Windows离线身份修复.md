# Windows 离线计算机名称

未启用 Sysprep 应答文件时，PXEOS 使用离线 SYSTEM 注册表更新并验证计算机名称。启用应答文件时，关闭名称开关会原样写入用户 XML；开启名称开关仅在 specialize 的 Shell-Setup ComputerName 元素写入平台名称并回读验证。

该流程不执行 sysprep.exe，不修改 SID、MachineGuid 或引导配置。
