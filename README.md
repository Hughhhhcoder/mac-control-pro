<div align="center">

# Mac Control Pro

**用原生 macOS 界面，看清温度、风扇与系统状态。**

一款独立开发、完整开源的 Mac 监控与风扇管理工具。

[![Build](https://github.com/Hughhhhcoder/mac-control-pro/actions/workflows/ci.yml/badge.svg)](https://github.com/Hughhhhcoder/mac-control-pro/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Hughhhhcoder/mac-control-pro)](https://github.com/Hughhhhcoder/mac-control-pro/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black.svg)](docs/COMPATIBILITY.md)

[下载最新版](https://github.com/Hughhhhcoder/mac-control-pro/releases/latest) · [English](README.en.md) · [兼容性](docs/COMPATIBILITY.md) · [参与开发](CONTRIBUTING.md)

</div>

![Mac Control Pro native interface](docs/images/dashboard.png)

## 下载与运行

推荐从 [Releases](https://github.com/Hughhhhcoder/mac-control-pro/releases/latest) 下载 **通用 `.pkg`**。macOS 安装器会安装应用和匹配的控制助手，并为本机当前登录用户配置权限，无需源码或终端命令。

DMG 同时包含完整 PKG 与可拖动的应用；ZIP 用户也可在应用设置中安装或更新助手。应用自带原生安装、卸载包，普通监控无需管理员权限，安装助手时由 macOS 请求管理员验证。

要求 **macOS 14 或更新版本**，通用包包含 Apple Silicon 与 Intel 二进制。默认发行包的应用为 ad-hoc 签名、PKG 未带 Developer ID Installer 身份，尚未 Apple 公证；系统拦截时需使用系统提供的「仍要打开」流程。[安装说明](docs/INSTALLATION.md) 包含权限与校验信息。

## 功能

- **原生界面**：SwiftUI、系统侧边栏、工具栏、系统字体、深浅外观与键盘操作。
- **实时总览**：CPU 使用率、内存、电池、系统热状态、风扇与温度；当前会话图表帮助观察变化。
- **传感器浏览**：按名称、类别或 SMC 标识搜索，显示实际可读取的传感器；不可读的数据明确标注，正常模式不补入模拟值。
- **风扇管理**：按硬件识别每只风扇的数量、读数、范围和控制键；固定转速、温度曲线与自动模式均显示助手确认状态。
- **跨机型配置**：内置预设按每只风扇的转速范围百分比适配；自定义配置支持百分比或绝对 RPM，兼容旧 schema 1 配置。
- **明确的控制状态**：区分助手缺失、版本不匹配、读取失败、只读风扇、处理中和已应用。助手须在最终读回中同时确认手动模式与目标转速，才报告已应用；实际 RPM 是否稳定另看实时读数。
- **菜单栏入口**：快速查看关键读数并打开主窗口。
- **偏好设置**：中文 / English、温度单位、采样间隔与登录启动。
- **导入与导出**：配置预设可通过 JSON 分享；当前会话支持 CSV 导出，诊断快照支持 JSON，也可使用 `--diagnose` 输出实际读数。
- **命令行工具**：应用内置 `MacControlCLI`，支持真实读数、有限时长调速、温度曲线和 JSONL 采样记录；结束时尝试恢复自动。
- **离线运行**：核心功能无需账号、订阅或云端服务。

本项目受到风扇管理工具使用场景启发，是独立实现；与 CrystalIDEA、Macs Fan Control 或 Apple 无隶属关系。未复制、打包或重新分发 Macs Fan Control 的二进制文件、资源或商业代码。「更强」在此指开放的源码与曲线、图表、诊断和原生工作流；不能据此推断其硬件兼容性已经超过成熟商用产品。

## 兼容性与验证

0.2.0 面向 2022 年以来的 Mac 工作流，按接口能力探测，不以某台笔记本的风扇数量或固定 RPM 套用其他机器。实现覆盖 M4 Pro 等机型的双风扇独立控制、受保护模式解锁、Mac mini / Mac Studio 的各自转速范围，以及无风扇 Air 的监控状态。

**这些是已实现的代码路径，不是所有机型已实测的保证。** 物理调速证据来自 **Mac18,1 / Apple M6 / macOS 27.0**：0.1.1 记录包含固定转速、曲线、恢复自动和租约回退；0.2.0 早期候选还记录了 CLI 固定转速、曲线、租约到期与竞争会话拒绝。每次结论仅对应当时构建。M4 Pro、Mac mini、Mac Studio、其他 Mac 和 Intel 写入仍只有相应代码路径的模拟覆盖，尚无这些机型的实机通过记录。

[兼容性矩阵](docs/COMPATIBILITY.md) · [已有硬件记录](docs/HARDWARE_VALIDATION.md)

## 控制助手

设置中的安装、更新和卸载入口均打开应用内置的原生安装器。服务与应用协议不匹配时先升级助手；安装成功与固件调速能力分别判断。

助手维护有所有权的短租约。客户端只能续约或释放自己的会话，保护条件触发或租约失效后不会自动重放旧目标。SMC 接口未公开，读写或恢复仍可能被固件拒绝，具体边界见 [助手设计](docs/HELPER.md)。

## 从源码构建

需要包含 Swift 5.9 或更新版本的 Xcode / Command Line Tools，无第三方 Swift 包依赖。

```bash
git clone https://github.com/Hughhhhcoder/mac-control-pro.git
cd mac-control-pro
swift test
./scripts/build-release.sh
open "dist/Mac Control Pro.app"
```

构建产物位于 `dist/`：通用 `.app`、完整 `.pkg`、`.zip`、`.dmg` 和 `.sha256`。只为当前 Apple Silicon Mac 构建：

```bash
ARCHS=arm64 ./scripts/build-release.sh
```

诊断与演示：

```bash
"dist/Mac Control Pro.app/Contents/MacOS/MacControlPro" --diagnose
"dist/Mac Control Pro.app/Contents/MacOS/MacControlPro" --demo
```

演示模式会明确标注模拟数据，适合预览界面，不用于控制真实硬件。`--diagnose` 读取实际硬件。

## 工程结构

```text
Sources/
  CSMC/                  IOKit / SMC C 接口
  MacControlCore/        硬件读数、数据模型与风扇曲线
  MacControlHelper/      独立的特权风扇控制服务
  MacControlCLI/         有限时长调速与真实采样工具
  MacControlPro/         SwiftUI 应用与菜单栏
Tests/                   核心、助手和 CLI 参数测试
scripts/                 构建、打包与助手安装 / 卸载
docs/                    架构、安装、权限与兼容性
.github/                 CI、发布与协作模板
```

## 项目文档

- [架构](docs/ARCHITECTURE.md)：数据流、进程边界和故障处理。
- [兼容性](docs/COMPATIBILITY.md)：Apple Silicon / Intel、无风扇设备及未验证项。
- [构建与发布](docs/RELEASING.md)：通用包、签名、公证与 GitHub Release。
- [验证与测试](docs/TESTING.md)：自动化回归、模拟传输与实机验证范围。
- [硬件验证](docs/HARDWARE_VALIDATION.md)：M6 固定转速、曲线、保护与租约回退的实测记录。
- [命令行工具](docs/CLI.md)：调速时限、独立读回、恢复行为和 JSONL 字段。
- [路线图](docs/ROADMAP.md)：兼容性矩阵、签名发行与后续能力。
- [更新日志](CHANGELOG.md)、[安全政策](SECURITY.md)、[开源许可](LICENSE)。

欢迎提交包含机型、macOS 版本、实际读数和复现步骤的反馈。分享诊断文件前请检查其中的设备信息；不要上传用户名、序列号或其他隐私数据。
