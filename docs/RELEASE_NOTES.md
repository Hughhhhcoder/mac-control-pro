## Mac Control Pro 0.2.0

### 安装与跨机型处理

- 新增完整通用 PKG，一次安装应用与匹配助手；DMG 内也包含该安装器。
- 应用设置自带助手安装、更新与卸载入口，使用 macOS 原生安装器和本机登录账户，无固定 UID、源码或终端依赖。
- 按实际能力识别各只风扇，区分无风扇、读取失败、只读和可控制状态。补齐双风扇独立控制、受保护模式处理及桌面低转速范围路径。
- 内置预设改为风扇范围百分比，适配 MacBook Pro、Mac mini / Mac Studio 等不同转速范围；自定义配置保留绝对 RPM，并兼容 schema 1。

### 控制状态与恢复

- P2 协议绑定会话所有权，分离新控制、续约、会话释放与用户明确恢复自动；旧助手须升级后才能控制。
- 等待助手或固件时显示处理中；目标完成有期限回读后，核心与助手都在最终风扇快照中核对手动模式和目标转速，二者同时匹配才标记已应用。续约同样检查确认结果，失败不重放旧目标；已应用不等于实际 RPM 已稳定。
- 80 项 XCTest 通过，覆盖多风扇、延迟读回、受保护状态、失联、配置迁移和界面异步状态；助手与 CLI 自检、通用构建及安装包结构检查通过。

### 验证范围

新增跨机型路径由模拟传输和自动化测试覆盖，**不宣称所有 2022 年以来的 Mac 已实测通过**。物理证据限于 Mac18,1 / Apple M6 / macOS 27.0：0.1.1 的完整记录，以及 0.2.0 早期候选的 CLI 固定转速、曲线、租约到期和竞争会话拒绝记录。候选记录只说明当时构建，不能证明 M4 Pro、Mac mini、Mac Studio 或 Intel 已实测通过。

[兼容性矩阵](https://github.com/Hughhhhcoder/mac-control-pro/blob/v0.2.0/docs/COMPATIBILITY.md) · [已有硬件记录](https://github.com/Hughhhhcoder/mac-control-pro/blob/v0.2.0/docs/HARDWARE_VALIDATION.md) · [安装说明](https://github.com/Hughhhhcoder/mac-control-pro/blob/v0.2.0/docs/INSTALLATION.md)

要求 macOS 14 或更新，提供 arm64 + x86_64 通用 PKG、DMG、ZIP 与 SHA-256。默认构建尚未 Apple 公证；监控不需要管理员权限，助手安装由 macOS 请求管理员验证。SMC 兼容性仍取决于具体硬件及系统。
