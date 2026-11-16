# 构建与发布

## 产物

```bash
swift test
./scripts/test-installer.sh
VERSION=0.2.0 ./scripts/build-release.sh
./scripts/test-installer.sh dist/Mac-Control-Pro-0.2.0-universal.pkg dist/Mac-Control-Pro-0.2.0-universal.zip
```

`dist/` 输出：

- `Mac Control Pro.app`：应用、CLI、助手，以及设置可打开的 `Install Fan Helper.pkg`、`Uninstall Fan Helper.pkg`。
- `Mac-Control-Pro-VERSION-universal.pkg`：推荐的完整原生安装器，固定安装应用到 `/Applications`，为当前控制台用户配置助手。
- 通用 ZIP、DMG 与包含三种附件的 SHA-256；DMG 同时含应用、Applications 链接和完整 PKG。

打包顺序为：编译并合并各架构，签名助手和 CLI，创建匹配的助手包并嵌入应用，签名应用，再创建完整安装器和磁盘映像。完整 PKG 不允许应用重定位，要求关闭正在运行的应用。所有安装器均声明 macOS 14 和真实二进制架构；Apple Silicon 不依赖 Rosetta 执行安装脚本。

## 配置

| 环境变量 | 默认值 | 含义 |
| --- | --- | --- |
| `VERSION` | `0.2.0` | 数字版本 `major.minor.patch` |
| `ARCHS` | `arm64 x86_64` | 编译并合并的架构 |
| `OUTPUT_DIR` | `dist` | 产物目录 |
| `CODE_SIGN_IDENTITY` | `-` | ad-hoc；发行签名使用 Developer ID Application |
| `INSTALLER_SIGN_IDENTITY` | 未设置 | 原生 PKG 的 Developer ID Installer 身份 |
| `NOTARYTOOL_PROFILE` | 未设置 | 已在钥匙串配置的 notarytool 凭据 |

有发行证书时：

```bash
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
INSTALLER_SIGN_IDENTITY='Developer ID Installer: Your Name (TEAMID)' \
NOTARYTOOL_PROFILE='mac-control-notary' \
VERSION=0.2.0 ./scripts/build-release.sh
```

启用公证必须同时提供应用与 Installer 签名身份。脚本依次公证并附加助手安装 / 卸载 PKG、应用、完整 PKG 和 DMG，最终重新计算校验和。默认无证书构建仍可创建通用包，但应用仅为临时签名、PKG 未签署发行身份且未公证。不要把证书或公证凭据提交到仓库。

## 无安装检查

`scripts/test-installer.sh` 验证 UID 身份边界，包括正常 501 / 502 及目录账户 ID、系统账户拒绝和身份不匹配。给定 PKG 与 ZIP 时，它只展开归档并读取 Installer 选择信息，检查本机架构声明、固定 Applications 目标、匹配的助手及通用用户设置脚本，不执行任何安装脚本、sudo 或硬件写入。

这些检查验证安装器结构，不等于在所有 macOS、账户或 Mac 型号上完成真实安装。管理员认证与升级回退还需用具体候选包实测并记录。

## GitHub Actions

`ci.yml` 在 main push、PR 或手动触发时测试、构建通用包，检查安装器结构并上传开发附件。`release.yml` 在 `v0.2.0` 形式的 tag push 时测试、打包并发布 PKG、ZIP、DMG 与校验文件。

发布前更新应用版本、更新日志、发布说明和真实验证记录，再创建版本 tag。不要同时手工创建相同 tag 的 Release；工作流会自动发布。

```bash
git tag v0.2.0
git push origin v0.2.0
```
