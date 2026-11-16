# 更新日志

采用 [Semantic Versioning](https://semver.org/)；未发布变更列于 Unreleased。

## Unreleased

暂无。

## 0.1.0 — 2026-11-16

### Added

- SwiftUI 原生应用框架、实时总览、会话图表和传感器浏览。
- 真实系统统计与 SMC 读数，明确标记不可用数据和演示模式。
- 风扇自动、固定 RPM、曲线与预设工作流。
- 独立的可选特权助手、对端 UID 验证、短租约、温度保护与崩溃恢复日志。
- 菜单栏、偏好设置、中英文与诊断导出。
- 通用 macOS 构建、DMG / ZIP / 校验和、核心测试与 GitHub 工作流。

### Known limitations

- 首发 ad-hoc 签名，未公证；硬件读写兼容性未覆盖全部 Mac。
- 风扇与传感器依赖未公开的 SMC 接口；保护与自动恢复为尽力执行。
