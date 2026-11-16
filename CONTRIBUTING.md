# 参与贡献

感谢你帮助改进 Mac Control Pro。小问题可直接提 PR；较大的控制协议、硬件或数据存储变更请先开 issue 说明目标与兼容性影响。

## 开发环境

macOS 14+，Xcode / Command Line Tools，Swift 5.9+。无第三方 Swift 包依赖。

```bash
swift test
swift run MacControlPro --demo
./scripts/build-release.sh
```

提交前运行相关测试与完整构建。不要在没有硬件证据时写「支持所有 Mac」。UI 变更附上深色 / 浅色截图；底层变更说明所测机型、macOS 和失败路径。

## 控制代码

- 保持助手协议小而明确，不接受 shell、任意文件路径或任意 SMC 写入。
- 输入验证、RPM 范围、对端身份验证、租约和自动恢复均需考虑。
- 测试使用纯逻辑或模拟接口，不在 CI 修改实际风扇模式。
- UI 不得把演示值作为实际硬件数据显示。
- 不引入要求关闭 SIP、全局 Gatekeeper 或系统防护的流程。

## 提交与许可

用清晰的提交信息说明具体改动；PR 描述包括问题、最终行为和验证结果。提交的原创贡献按仓库 MIT License 授权。引入第三方实现时保留原有许可，在 `THIRD_PARTY_NOTICES.md` 记录来源；不要提交商业软件、反编译结果、私有签名材料或含个人信息的诊断文件。

发现安全问题请按 [SECURITY.md](SECURITY.md) 处理。
