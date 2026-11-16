# 安装与运行

## 下载包

1. 从 [官方 Releases](https://github.com/Hughhhhcoder/mac-control-pro/releases/latest) 下载 `.dmg` 或 `.zip`，以及同名 `.sha256`。
2. 可在终端运行 `shasum -a 256 -c Mac-Control-Pro-0.1.0-universal.sha256`。两个包和校验文件需放在同一目录；只下载一种包时，可计算该包的 SHA-256 并与校验文件中对应行比较。
3. 打开 DMG，将应用拖入「应用程序」，再推出磁盘映像。ZIP 直接解压后移动应用。
4. 首次打开可能出现 Gatekeeper 提示。首发包仅有 ad-hoc 签名，没有 Apple Developer ID 和公证。可使用系统提供的「仍要打开」流程；请先确认下载来源及校验值。不要关闭整个系统的 Gatekeeper 或 SIP。

应用最低版本为 macOS 14。通用包包含 arm64 和 x86_64 两种架构。程序可启动不代表所有机型都支持风扇写入，详见 [兼容性](COMPATIBILITY.md)。

## 权限

日常监控无需 root，不安装系统扩展。登录启动由用户在偏好设置中选择；macOS 可能显示后台项目通知。

手动控制风扇时，在源码仓库目录运行：

```bash
sudo ./scripts/install-helper.sh "/Applications/Mac Control Pro.app"
```

脚本本身也完全开源。它会验证应用标识与签名完整性，复制并再次验证 root 拥有的助手副本，再注册系统 launchd 服务。ad-hoc 签名只能验证完整性，不证明发布者身份。安装只授权当前发起 sudo 的用户，管理员可以检查 [HELPER.md](HELPER.md) 中的文件路径。

## 删除

先在应用中恢复「Apple 自动」，再运行 `sudo ./scripts/uninstall-helper.sh`。随后退出应用并将其移入废纸篓。卸载助手脚本不删除个人设置或诊断导出文件。

## 本地调试

```bash
swift run MacControlPro
swift run MacControlPro --demo
swift run MacControlPro --diagnose
```

直接使用 SwiftPM 运行时没有完整的应用包元数据；发布脚本生成的 `.app` 更适合验证菜单、登录启动和系统集成。助手应从构建后的应用包安装，不能直接以 root 运行用户可写构建目录中的程序。
