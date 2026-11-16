## Mac Control Pro 0.1.1

原生 SwiftUI 监控与风扇管理，MIT 全开源。提供 Apple Silicon + Intel 通用 DMG、ZIP 和 SHA-256，源码归档由 GitHub Release 提供。

### 修复与新增

- 修复目标写入后立即读到旧 `F%dTg` 导致误判失败的问题：采用最多 0.8 秒的单调时钟确认，保留模式校验、温度保护及失败回滚。
- 助手结束控制租约后，客户端停止原会话，避免自动重新申请旧目标。
- 应用内置 `MacControlCLI`，支持真实读取、有时限固定转速、温度曲线、JSONL 采样与结束恢复。
- 自动化测试增至 28 项；增加本机硬件验证数据和时间图。

### 真实硬件验证

在 Mac18,1 / Apple M6 / macOS 27.0 上安装控制助手后：

- 固定 3000 RPM 实际达到 3001 RPM；5500 RPM 稳定后读数为 5490–5505 RPM。两次固定测试随后均触发 85°C 保护，不宣称完整 20 秒稳定性。
- 以 TCMb 为温度来源的曲线完整运行 12 秒，6 次请求均通过；目标随温度变化，正常结束后手动模式清除、租约为空。
- 强制结束控制客户端后，独立采样在 12.131 秒观察到自动模式。
- 原生应用实际操作：4500 RPM 固定运行约 20 秒，稳定实际 4492–4510 RPM；“持续负载”曲线观察约 24 秒，目标 4762–6500 RPM，最后均由界面恢复自动。

[硬件验证记录](https://github.com/Hughhhhcoder/mac-control-pro/blob/v0.1.1/docs/HARDWARE_VALIDATION.md) · [CLI 文档](https://github.com/Hughhhhcoder/mac-control-pro/blob/v0.1.1/docs/CLI.md)

### 安装与范围

监控无需管理员权限；风扇写入需要另行安装开源助手，见 [仓库说明](https://github.com/Hughhhhcoder/mac-control-pro/tree/v0.1.1#安装风扇控制助手可选)。发行包仍为 ad-hoc 签名、未 Apple 公证，首次启动可能需要在系统设置的「隐私与安全性」中选择「仍要打开」。

SMC 接口未公开，单台 M6 的实测不覆盖其他 Mac。Intel 和其他 Apple Silicon 机型的硬件写入、macOS 14 实机运行及未执行的异常恢复路径仍未验证。模拟界面数据不用于硬件能力结论。
