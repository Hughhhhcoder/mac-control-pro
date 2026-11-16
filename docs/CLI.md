# 命令行工具

应用包内包含 `Contents/MacOS/MacControlCLI`。它复用 GUI 的硬件读取、曲线计算和助手协议，便于记录逐次采样、复现控制结果和检查恢复自动。

CLI 本身无需 `sudo`，也不会直接写入 SMC。固定转速、温度曲线与恢复自动通过可选的 root 助手执行。助手安装仍需管理员认证，见 [安装与权限](HELPER.md)。

查看当前构建的完整参数：

```bash
"/Applications/Mac Control Pro.app/Contents/MacOS/MacControlCLI" --help
```

在仓库中也可运行：

```bash
swift run MacControlCLI --help
```

## 只读检查

```bash
"/Applications/Mac Control Pro.app/Contents/MacOS/MacControlCLI" read
"/Applications/Mac Control Pro.app/Contents/MacOS/MacControlCLI" status
```

`read` 输出真实硬件快照；没有可用读数时保留不可用状态，不填入演示数值。`status` 查询控制助手，区分未安装、未连接与服务响应。

## 固定转速与温度曲线

固定转速示例（风扇 ID `0`、目标 3000 RPM、持续 20 秒）：

```bash
"/Applications/Mac Control Pro.app/Contents/MacOS/MacControlCLI" \
  set --fan 0 --rpm 3000 --duration 20
```

按温度曲线运行示例：

```bash
"/Applications/Mac Control Pro.app/Contents/MacOS/MacControlCLI" \
  curve --fan 0 --sensor TCMb \
  --points '45:3000,65:4000,80:6000' --duration 20
```

将风扇 ID、传感器和 RPM 改为 `read` 实际报告的值。曲线节点格式为 `摄氏温度:RPM`，支持 2–12 个节点，温度严格递增、转速不下降；区间内使用线性插值，结果按各风扇硬件范围和额外的 1200 RPM 下限限幅。

`set`、`curve` 的默认持续时间为 20 秒，允许 `0 < duration <= 60` 秒，每约 2 秒续约并输出一次独立硬件读回。正常结束、操作失败、`Ctrl-C`（SIGINT）或 SIGTERM 都会尝试把本次风扇恢复为自动。CLI 不提供跳过恢复或关闭温度保护的参数。

立即恢复一个风扇或全部风扇：

```bash
"/Applications/Mac Control Pro.app/Contents/MacOS/MacControlCLI" auto --fan 0
"/Applications/Mac Control Pro.app/Contents/MacOS/MacControlCLI" auto
```

## 输出与退出码

`set`、`curve` 使用 JSONL，每行一个事件，便于保留原始证据：

| 字段 | 含义 |
| --- | --- |
| `event` | `sample`（请求与读回）、`restore`（恢复）或 `error` |
| `date` | ISO 8601 时间 |
| `command` / `fanID` | 命令与目标风扇 |
| `sensorID` / `sourceCelsius` | 曲线来源及本次计算时的摄氏读数 |
| `requestedRPM` | 本次请求目标；曲线输出已按硬件限幅 |
| `helper` | 助手返回的成功状态、消息和当前租约风扇 ID |
| `snapshot` | 独立硬件读取，包含实际 RPM、目标 RPM、手动标志和温度 |
| `error` | 本次失败原因 |

没有值的可选字段省略。`read` 输出快照 JSON；`status` 输出查询时间、`helper` 或 `helperError`，以及硬件快照。

| 退出码 | 含义 |
| --- | --- |
| `0` | 操作成功 |
| `1` | 操作或恢复失败 |
| `2` | `status` 未能确认助手可用 |
| `64` | 参数错误 |
| `130` / `143` | SIGINT / SIGTERM 后完成恢复尝试 |

解析器与曲线的离线自检不会访问或改变硬件：

```bash
"/Applications/Mac Control Pro.app/Contents/MacOS/MacControlCLI" --self-test
```

省略命令只打印帮助，不会写入硬件。SIGKILL 无法执行 CLI 清理，此时仍依靠独立助手的租约回退。

## 控制与验证

手动请求仍须通过风扇 ID、硬件范围、最低转速和温度保护检查。返回成功只代表控制请求已被接受；应观察后续快照中的实际 RPM、目标 RPM 和手动模式。风扇需要时间响应，温度曲线的计算值也会随传感器读数变化。

不要同时由 GUI、CLI 和其他风扇工具为同一个风扇持续发送不同目标。测试结束后确认恢复自动及助手租约为空。停止续约时，助手会在约 12 秒后尝试恢复自动，底层硬件读写失败仍可能导致恢复失败。

硬件验证应保留采样时间、请求转速、实际 RPM、温度与恢复结果。具体实测范围以 [测试记录](TESTING.md) 为准。
