# Agent / LLM 接口

`wtop --agent` 为自动化和 LLM Agent 输出一次有界的系统状态报告。它不要求 TTY，
不输出 ANSI，不混入日志；stdout 只有一行 UTF-8 JSON。

```bash
wtop --agent
```

顶层 schema 为 `dev.waterrun.wtop.agent/v1`。Agent 应先精确检查 `schema`，未知主版本
应拒绝解析；同一主版本增加未知字段时应忽略它们。
可机读的 JSON Schema 位于 [agent-v1.schema.json](agent-v1.schema.json)，采用
JSON Schema Draft 2020-12，并对向后兼容的新增字段保持开放。

## 数据结构

| 字段 | 含义 |
| --- | --- |
| `overall` | `ok`、`warning`、`critical` 或 `unknown`，以及 signal 数量 |
| `metrics`（object） | CPU、内存、PSI、存储、网络、GPU 和进程的紧凑原始数值 |
| `signals`（array） | 确定性阈值产生的异常线索，按严重度排序；不是自动诊断结论 |
| `top`（object） | 有界的进程、块设备、接口、workload 和 GPU 摘要 |
| `data_quality`（array） | 每个 collector 的 resource/freshness/status/reason；解释缺值时必须先看这里 |
| `unavailable_sources`（array） | 当前主机不支持或不可访问的数据源 |
| `privacy`（object） | 本报告主动省略的信息类别 |

数值保持机器单位：容量和速率使用 byte / byte per second，延迟使用 millisecond，
利用率与 PSI 使用 percent。缺失数据用字段缺失或 JSON `null` 表达，不应当按零处理。

`signals` 使用稳定的 `resource`、`code`、`severity`、`value` 和 `unit`；`message`
只供展示。当前阈值是保守的提示规则，例如 CPU 75/90%、内存 85/95%、设备 busy
80/95% 以及 PSI some avg10 5/20%。Agent 应结合持续时间、负载性质和
`data_quality` 再给出结论。

## 完整快照

需要原始明细时使用：

```bash
wtop --snapshot
```

它返回 `dev.waterrun.wtop.snapshot/v1`，包含更多 collector 字段和更长列表。
推荐先调用 `--agent`，只有异常需要钻取时再获取完整快照，避免无意义地占用上下文。

## 隐私与调用约定

- Agent 报告不包含进程命令行，只包含 PID、名称、状态、用户和资源使用。
- Agent 报告不包含 socket endpoint；完整 snapshot 默认也遮罩远端 IP。
- 输出中的 unavailable 不等于系统异常；可选硬件或权限缺失会单独列出。
- 进程、设备和 workload 列表有上限；未出现在 Top 列表中不代表对象不存在。
- 每次执行会进行两次采样以计算 rate，通常约 250 ms。持续监控应由调用方按需要轮询，
  并以 `captured_unix_ns` 和 `sequence` 标识样本，不应高频无界调用。
- 成功时退出码为 `0`，stdout 只有一个以换行结尾的 JSON document；诊断信息只写
  stderr。调用方必须同时检查退出码和 schema，不能解析半截输出。

示例调用：

```bash
context="$(wtop --agent)" || exit
printf '%s\n' "$context" | jq '.overall, .signals, .top.processes'
```
