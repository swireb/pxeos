# RootPXE 集成

PXEOS 从服务端获取任务冻结的 changeHostname 与 systemIdentity 配置。计算机名称在恢复完成后执行；任务重试复用冻结名称和初始化配置，不重放磁盘恢复。

Linux 系统初始化仅处理 machine-id、SSH 主机密钥、ROOT 登录公钥和密码。Windows 仅处理离线注册表计算机名称及可选 Sysprep 应答文件；不执行 Sysprep。
