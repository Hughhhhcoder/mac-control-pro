# 构建与发布

## 本地验证

```bash
swift test
VERSION=0.1.0 ./scripts/build-release.sh
"dist/Mac Control Pro.app/Contents/MacOS/MacControlPro" --diagnose
open "dist/Mac Control Pro.app"
```

脚本默认分别构建 arm64、x86_64，再用 `lipo` 合并两个可执行文件。输出包括 `.app`、ZIP、带 Applications 快捷方式的 DMG 和 SHA-256。检查归档后，可将 `dist/*.zip`、`dist/*.dmg` 与 `dist/*.sha256` 作为 Release 附件上传。`.app` 本身不作为散文件上传。

可用配置：

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `VERSION` | `0.1.0` | 数字版本 `major.minor.patch` |
| `ARCHS` | `arm64 x86_64` | 仅构建指定架构 |
| `OUTPUT_DIR` | 仓库下的 `dist` | 输出目录 |
| `CODE_SIGN_IDENTITY` | `-` | 默认 ad-hoc；可设为 Developer ID Application identity |
| `NOTARYTOOL_PROFILE` | 未设置 | 已在本机钥匙串配置的 notarytool 凭据名称 |

## 签名与公证

无 Apple Developer 账号也能构建完整可用的本地应用。默认临时签名只提供完整性，分发包仍可能触发 Gatekeeper。

有 Developer ID 时：

```bash
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARYTOOL_PROFILE='mac-control-notary' \
VERSION=0.1.0 ./scripts/build-release.sh
```

先自行用 `xcrun notarytool store-credentials` 把凭据安全存入钥匙串。脚本对助手和应用签名，使用 hardened runtime，提交 ZIP 公证、附加 app 票据，然后生成 DMG、提交并附加 DMG 票据，最后计算校验和。不要把证书、密码、API 私钥或公证凭据提交到仓库。

## GitHub Actions

`ci.yml` 对 main 的 push、PR 或手动运行执行 `swift test` 并生成通用开发包。`release.yml` 在 `v0.1.0` 形式的版本 tag push 时测试、构建并发布到 GitHub Releases。默认工作流不配置商业证书，附件为 ad-hoc 签名且未公证。

维护者发布前应更新 `CHANGELOG.md` 和 `docs/RELEASE_NOTES.md`，确认硬件验证的描述真实，再创建并推送版本 tag：

```bash
git tag v0.1.0
git push origin v0.1.0
```

Release 工作流会自动创建发布，因此本地手工发布时不要同时触发同一个 tag 的自动发布。可在手工上传后使用 `gh release upload <tag> ... --clobber` 更新附件；更新签名后的包必须重新生成校验和。
