# 架构

Mac Control Pro 使用 SwiftPM 管理源码，最低 macOS 14，以 Apple 系统框架完成 UI、图表、系统读取和硬件通信。核心模块可独立测试，应用和特权助手是两个不同的可执行文件。

```text
SwiftUI app (normal user)
  ├─ HardwareMonitor → host statistics / battery / thermal state
  ├─ SMCConnection → CSMC → IOKit AppleSMC (reads)
  ├─ session history / preferences / diagnostics
  └─ local Unix socket → privileged helper (root)
                           ├─ peer-user validation
                           ├─ command validation / leases / thermal guard
                           └─ SMCConnection → CSMC → IOKit (fan writes)
```

## 数据与 UI

硬件层产出带时间戳的 `SystemSnapshot`。温度只保留通过数值检查的真实读数；风扇发现合并硬件报告数量与索引键证据，保留部分或全部读数缺失的风扇记录。CPU、RPM 和范围等暂时无法读取的项目使用可选值。Apple 系统的热状态与温度传感器是不同来源，UI 不把它们混为同一指标。

图表记录当前运行会话中的样本。诊断导出是采样快照，不是无限期历史记录。演示数据需要显式 `--demo`，用于预览，不能作为实际硬件读数使用。

## 写入边界

应用本身不提权。用户明确安装助手后，应用可以发送固定转速、自动恢复等受限请求；助手使用内核报告的对端身份验证授权用户。协议不接受任意 shell 命令、文件路径或任意 SMC key 写入。

协议 2 为每个客户端维护稳定的会话 ID；续约必须属于尚未过期的原会话，不能自动重新申请。客户端释放仅影响自己的租约，用户明确恢复自动可结束目标风扇的全部会话。助手在独立进程维护租约与热保护。正常退出、断联和超时触发自动恢复尝试。写入前持久化风扇 ID，助手崩溃重启后读取所有权日志并重试恢复；成功前保留记录。恢复失败后阻止新目标与续约，持续重试恢复；固件交还自动模式时也确认释放全局解锁，再清除日志。系统睡眠、固件差异、底层调用阻塞和硬件故障仍是实际边界，不能仅靠 UI 保证物理散热行为。

## 打包与分发

发布脚本分别构建 arm64 和 x86_64，使用 `lipo` 合并应用、助手及 CLI。完整 PKG 安装应用与助手，按本机控制台用户配置权限；应用内置单独的助手安装与卸载 PKG。构建输出包含 PKG、DMG、ZIP 和 SHA-256；CI 运行核心、CLI 与应用状态测试，并以只解包方式检查安装器，版本 tag 触发正式 Release。

详见 [助手与权限](HELPER.md)、[兼容性](COMPATIBILITY.md) 和 [发布](RELEASING.md)。
