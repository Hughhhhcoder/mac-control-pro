# 安装与运行

## 推荐：原生 PKG 安装器

从 [Releases](https://github.com/Hughhhhcoder/mac-control-pro/releases/latest) 下载 `Mac-Control-Pro-0.2.0-universal.pkg`，双击后按 macOS「安装器」完成管理员验证。它将应用固定安装到 `/Applications/Mac Control Pro.app`，并安装匹配版本的风扇控制助手。

安装器为**当前登录的控制台用户**配置助手。UID 从本机读取并验证，不固定为开发者账户；无需源码、终端命令或 `SUDO_UID` 环境变量。没有正常登录用户、选择其他启动卷或出现不安全的目标路径时，安装器会停止。完整安装器会要求先关闭运行中的应用。

安装完成后打开 Mac Control Pro，检查设备能力和助手状态。助手安装成功只说明服务可连接；固件是否接受手动调速由应用单独检测，不能从安装成功推断。

## DMG 与 ZIP

- **DMG**：内含应用、Applications 快捷方式和 `Install Mac Control Pro.pkg`。运行该 PKG 可一次安装应用与助手；仅拖动应用则先使用监控功能。
- **ZIP**：解压并移动应用后，在应用设置中打开辅助服务安装器。匹配的 `Install Fan Helper.pkg` 已包含在应用资源内，不需要另找源码或复制脚本。
- 普通监控无需管理员权限；安装助手才会调用 macOS 安装器请求管理员验证。

应用要求 macOS 14 或更新，通用包包含 arm64 与 x86_64。具体读写支持范围见 [兼容性](COMPATIBILITY.md)。安装器并不按 MacBook、Mac mini 或 Mac Studio 名称硬编码授权账户。

## 下载验证与签名

`.pkg`、`.dmg`、`.zip` 的 SHA-256 均列在同名 `.sha256` 文件中。把全部附件放在同一目录后可运行：

```bash
shasum -a 256 -c Mac-Control-Pro-0.2.0-universal.sha256
```

只下载一种包时，计算该附件的 SHA-256，与校验文件中对应行比较。默认开源构建的应用为 ad-hoc 签名，PKG 未带 Developer ID Installer 签名，均未 Apple 公证；首次打开可能需要系统设置「隐私与安全性」中的「仍要打开」。签名完整性不等于发布者认证。

## 助手权限与升级

助手由 root 拥有并通过 launchd 启动，仅允许安装时选定的用户和 root 连接。详细文件、协议及恢复边界见 [HELPER.md](HELPER.md)。升级助手时，安装器先等待旧服务恢复自动并退出，再验证、原子替换和启动新版本；失败时尝试还原旧版本。恢复日志不会因为升级而被清空。

管理员也可从仓库执行：

```bash
sudo ./scripts/install-helper.sh "/Applications/Mac Control Pro.app"
```

此方式默认使用 `SUDO_UID`，原生 PKG 使用当前控制台用户，两者都不固定账户 UID。无人值守管理可由管理员明确指定已有的人类账户：

```bash
sudo ./scripts/install-helper.sh "/Applications/Mac Control Pro.app" --uid USER_ID
```

## 删除

先在应用中恢复自动、退出控制会话，然后在设置中打开内置的 `Uninstall Fan Helper.pkg` 并完成管理员验证。应用和个人设置会保留。

管理员也可从源码仓库运行：

```bash
sudo ./scripts/uninstall-helper.sh
```

卸载脚本与安装器互斥，先停止服务并等待恢复。只有服务已卸载、进程结束且恢复日志为空时才删除已知助手文件；发现不安全路径或未恢复的控制记录时保留文件。它不删除个人设置或诊断导出。助手移除后可将应用移入废纸篓。

## 本地调试

```bash
swift run MacControlPro
swift run MacControlPro --demo
swift run MacControlPro --diagnose
```

直接通过 SwiftPM 运行没有完整应用资源，设置内的原生安装器以发布脚本生成的 `.app` 为准。
