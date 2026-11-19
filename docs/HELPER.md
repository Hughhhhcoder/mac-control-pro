# 特权控制助手

## 原生安装入口

完整的通用 `.pkg` 同时安装应用和助手。DMG 内也提供该安装器；ZIP 或仅拖动应用的用户可在设置中打开应用自带的 `Install Fan Helper.pkg`。助手包内含与应用匹配的签名二进制和完整安装脚本，不依赖开发者机器上的文件。

macOS 安装器负责管理员验证，安装脚本读取 `/dev/console` 当前用户 UID，确认该 UID 对应真实非系统账户、数值至少为 501，再将其写入服务参数。没有固定 UID，也不要求 PKG 环境存在 `SUDO_UID`。服务授权单个账户；在另一账户使用时，应由管理员为该账户重新安装。

普通监控不需要助手。安装成功与硬件调速能力分开显示：root 权限不能使不支持的固件接口生效。

## 系统文件

| 路径 | 用途 |
| --- | --- |
| `/Library/PrivilegedHelperTools/io.github.hughhhhcoder.MacControlPro.helper` | root:wheel、0755 的助手 |
| `/Library/LaunchDaemons/io.github.hughhhhcoder.MacControlPro.helper.plist` | root:wheel 的系统服务配置 |
| `/var/run/mac-control-pro/control.sock` | 仅安装时选定用户可访问的本地 socket |
| `/var/run/mac-control-pro/leases.json` | root 拥有、0600 的控制恢复日志，仅含风扇 ID |
| `/var/run/io.github.hughhhhcoder.MacControlPro.install.lock` | 安装与卸载的互斥锁；操作结束后移除 |

安装脚本拒绝不安全的符号链接、所有者和可写目录。助手先复制到 root 拥有的临时文件，再验证签名完整性；root 不直接执行应用或用户构建目录里的程序。替换前停止旧助手并等待退出，保留恢复日志；新服务未就绪时尝试还原旧文件并恢复原服务。过期 socket 只在受保护的运行目录中、旧进程结束后处理。

默认构建没有 Developer ID Installer 身份和 Apple 公证。ad-hoc 代码签名仅检查完整性，不证明发布者身份；应从可信源码或官方仓库下载。

## 协议边界

助手通过内核提供的对端 UID 验证客户端，不信任请求内声称的身份。授权账户及 root 可连接；同一账户的其他进程也可使用该接口，未做逐客户端的代码签名身份验证。接口只接受定义好的风扇状态、目标与恢复操作，不执行任意 shell、文件路径或 SMC key。

P2 协议将控制与会话所有权绑定：新控制、续约、会话释放和用户明确恢复自动是不同操作。客户端只能续约或释放自己持有的会话；旧版助手需先升级，应用不会把过期协议当作可用控制通道。控制请求须通过风扇能力、转速范围和租约检查。0.2.1 起取消 85°C 固定拦截。macOS 报告严重或危急热压力，或缺少有效温度读数时，助手阻止手动控制并尝试恢复自动。被助手终止后不应自动重放旧目标。各机型的控制路径和实测记录见 [兼容性](COMPATIBILITY.md) 与 [硬件验证](HARDWARE_VALIDATION.md)。

## 管理员脚本接口

```bash
sudo ./scripts/install-helper.sh "/Applications/Mac Control Pro.app"
sudo ./scripts/install-helper.sh "/Applications/Mac Control Pro.app" --uid USER_ID
```

未给 `--uid` 时，显式 sudo 方式使用调用账户；没有 sudo 环境时才读取当前控制台账户。原生包传入已验证的控制台 UID。

安装器内部使用 `install-helper.sh --helper ABSOLUTE_HELPER_PATH --uid USER_ID`，源文件先复制到 root 拥有的位置并验证，才替换系统助手。该接口仅供已获管理员授权的安装过程使用。

## 恢复与卸载

设置中的卸载入口打开应用内置 `Uninstall Fan Helper.pkg`，由 macOS 安装器请求管理员验证。它只移除服务及助手系统文件，保留应用和个人设置。

助手在写入前原子保存所持有的风扇 ID。launchd 重启助手后，它验证日志的类型、所有者、大小和 ID，再尝试恢复遗留控制；失败项保留以便重试。

```bash
sudo ./scripts/uninstall-helper.sh
```

卸载与安装共用互斥锁，验证已知系统路径后停止服务，等待进程结束，并确认恢复日志为空。未完成恢复时不会删除文件，并尝试重新启动保留的服务。脚本不递归删除系统目录，不清除用户设置。

所有恢复最终取决于 SMC / 固件接受写入。单台机器的成功结果不代表睡眠、内核阻塞、强制结束助手等所有路径都已验证。安全问题见 [SECURITY.md](../SECURITY.md)。
