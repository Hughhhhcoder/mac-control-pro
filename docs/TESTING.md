# 验证与测试

## 自动化测试

```bash
swift test
swift run MacControlHelper --self-test
```

核心测试覆盖数值解码、曲线验证与插值、命令参数、温度保护和租约超时等纯逻辑。`--self-test` 只验证协议和策略，不访问或写入硬件，不要求 root。

这些检查不会证明某台 Mac 支持 SMC 写入。CI 的通用构建证明两个架构能编译，不代表两种硬件均经过实机控制测试。

## 只读检查

```bash
./scripts/build-release.sh
"dist/Mac Control Pro.app/Contents/MacOS/MacControlPro" --diagnose
codesign --verify --deep --strict "dist/Mac Control Pro.app"
lipo -archs "dist/Mac Control Pro.app/Contents/MacOS/MacControlPro"
lipo -archs "dist/Mac Control Pro.app/Contents/Library/LaunchServices/MacControlHelper"
```

确认诊断值来自真实系统：没有电池的设备不显示虚构电量，没有风扇的设备不显示模拟风扇，读取失败时清晰说明不可用。CPU 需要两次采样后才可计算差值。

## 界面检查

启动构建后的 `.app`，检查总览、传感器搜索、图表时间范围、配置导入与导出、偏好设置、中英文和菜单栏。`--demo` 可预览有读数的界面，但演示值不能用来声称真实硬件能力。

暂停监控和进入演示模式应放弃当前手动控制；睡眠与唤醒后应重新采样。关闭窗口不应意外退出菜单栏应用。诊断与 CSV 导出使用系统保存对话框，用户决定位置。

## 硬件控制验证

只有主动安装助手后才能验证实际写入。测试报告应记录机型、系统版本、观察到的 RPM、控制模式和恢复结果；不要把纯单元测试或 mock 结果标成硬件验证。优先验证恢复 Apple 自动、连接丢失的租约到期，以及不接受超范围 RPM 或不可信温度。

本仓库默认构建与 CI 不自动安装 root 助手，不自动改变风扇状态。提交中涉及写入的改动需要说明哪些硬件实际验证过，哪些仍未知。

## 0.1.0 本次验证记录（2026-11-16）

| 项目 | 结果 |
| --- | --- |
| 自动化测试 | 17 项 XCTest 通过，包含解码、曲线、参数校验、租约和套接字超时 |
| 界面交互 | 总览、风扇模式与曲线表单、传感器页面、配置名称输入、设置窗口和演示标识已在本机检查 |
| 设备 | Mac18,1 / Apple M6 / macOS 27.0 |
| 实际读取 | 本次采样读取 145 个温度 key、1 个风扇，含当前 RPM、最小 / 最大 RPM、目标 RPM 与模式 |
| 通用构建 | 应用与助手均含 arm64、x86_64；Mach-O 最低系统版本均为 14.0 |
| 归档完整性 | ZIP 解压后的完整代码签名验证与 SHA-256 校验通过 |
| 助手自检 | 协议与策略 `--self-test` 通过，未访问或修改硬件 |
| 特权硬件控制 | 未安装助手，未进行风扇写入测试；不宣称此项已验证 |
| 其他机型 | Intel 与其他 Apple Silicon 实机仍待验证 |

传感器数量和转速是本次采样结果，不能当作其他机器或未来系统版本的保证。macOS 14 是构建目标；在 macOS 14 实机运行仍需补充验证。
