# Agent / LLM 接口

`wtop --agent` 为自动化脚本和 LLM 智能体输出一份有界系统状态报告。它不需要 TTY,不输出 ANSI 转义序列,也不会混入日志;stdout 恰好只有一行 UTF-8 JSON。

```bash
wtop --agent
```

顶层模式(schema)为 `dev.waterrun.wtop.agent/v1`。智能体应先检查 `schema` 是否精确匹配,并拒绝未知的 major 版本。同一大版本内新增的未知字段应当忽略。
机器可读的 JSON Schema 见 [agent-v1.schema.json](agent-v1.schema.json)。它基于 JSON Schema Draft 2020-12,并保持向后兼容的字段可扩展性。

该模式是被实际执行的,而不只是发布在那里。`make check` 会在构建宿主机上运行 `--agent`,并依据该模式校验结果,因此报告与契约的两处改动若不一致,构建就会报错。校验器实现了该模式所用到的 Draft 2020-12 子集,并且**拒绝使用其未实现关键字的模式**,同时会指出该关键字——因为校验器若忽略自己不理解的内容,就会在只检查了部分契约的情况下报告文档有效,而这正是本检查要防止的失败。如需自行校验一份捕获文件:

```bash
.tools/lua-5.5.1/bin/lua tools/check_agent_schema.lua --document path/to/capture.json
```

一个已知的限制,明说而不隐瞒:空的 JSON 容器同时满足 `"type": "object"` 和 `"type": "array"`。解码器为两种 JSON 类型返回同一种 Lua 类型,因此要么接受真实的违例,要么拒绝合法的空调表——两者取其一。所有非空容器均按常规方式校验。

## 数据结构

| 字段 | 含义 |
| --- | --- |
| `overall` | `ok`、`warning`、`critical` 或 `unknown`,以及信号计数 |
| `metrics`(object)| CPU 标识/核心类型/拓扑、内存、PSI、存储、网络、GPU、分离的 CPU/平台功耗、传感器和进程的紧凑原始值 |
| `signals`(array)| 由确定性阈值产生的异常线索,按严重程度排序;这些并非自动给出的诊断结论 |
| `top`(object)| 进程、块设备、网络接口、工作负载、GPU 和最热有效传感器的有界摘要 |
| `data_quality`(array)| 每个采集器的资源、新鲜度、状态和原因;解释缺失数值时应始终先查看此字段 |
| `unavailable_sources`(array)| 当前主机上不支持或不可访问的数据源 |
| `privacy`(object)| 报告中有意省略的信息类别 |
| `privilege`(object)| 实际身份,以及本次是普通调用、直接 sudo 调用还是显式提升权限调用 |

数值保留机器单位:容量和速率使用字节与字节每秒,延迟使用毫秒,功耗使用瓦特,利用率和 PSI 使用百分比。`metrics.power.total_watts` 仅在选定的 CPU 封装/socket 后端完整时才输出;单独选定的平台/`psys` 代表值报告为 `platform_watts`。未知的根来源和存在歧义的 CPU 后端保持不聚合。缺失数据用字段缺省或 JSON `null` 表示;绝不能当作零处理。无效的硬件哨兵读数在导出前会被过滤,而不会作为极端物理量发出。

每条 `signals` 条目使用稳定的 `resource`、`code`、`severity`、`value` 和 `unit` 字段;`message` 仅供展示。当前阈值为保守提示,例如 CPU 75/90%、内存 85/95%、设备忙 80/95%、PSI `some avg10` 5/20%。智能体在下结论前应考虑持续时间、工作负载特征和 `data_quality`。

## 完整快照

需要原始细节时使用以下命令:

```bash
wtop --snapshot
```

它返回 `dev.waterrun.wtop.snapshot/v1`,包含额外的采集器字段和更长的列表。除 `--agent` 所汇总的资源外,快照还携带 `system`(主机名、内核、发行版、固件、虚拟化、安全模块、内核限制与计数器、Swap 设备、时区)和 `power_supplies`(电池的电量、相对设计容量的健康度与剩余续航,以及市电适配器)。网络接口额外携带其 IPv4/IPv6 `addresses` 和原始 `counters`。

`system.kernel.command_line` 会对命名了密钥或标识主机的参数——如 `root`、`resume`、`cryptdevice`、`rd.luks.key`、`systemd.machine_id`、`ip`、`nfsroot` 等——做脱敏:仅将值替换为 `<redacted>`,普通参数和裸开关保持原样。`/proc/cmdline` 本身是世界可读的,所以这并非访问控制;它只是避免磁盘加密密钥或根文件系统 UUID 出现在被粘贴进工单的导出内容里。

`system.firmware` 有意省略序列号、资产标签和产品 UUID:采集器从不读取它们,因此粘贴进缺陷报告的快照不会泄露超出操作者预期的主机身份信息。

请先调用 `--agent`,仅在发现异常需要深入排查时再获取完整快照,以免不必要地消耗上下文。

## 隐私与调用约定

- Agent 报告省略进程命令行;仅包含 PID、名称、状态、用户和资源用量。
- Agent 报告省略套接字端点;完整快照默认同样对远端 IP 地址打码。
- `unavailable` 条目不意味着系统故障。可选硬件和缺失权限是分开报告的。
- 进程、设备和工作负载列表均有界。未出现在 Top 列表中的对象,不一定不存在于主机。
- 运行 `sudo wtop --agent` 或使用显式的 `--sudo`/`--elevate` 可能暴露需要权限的数据源。消费方应检查 `privilege` 并继续使用 `data_quality`;提升权限执行并不保证每个数据源都存在或成功。
- 每次调用采样两次以计算速率。两次采样之间等待 `min(--interval, 250 ms)`——250 ms 是**该延迟的上限,而不是整个调用的耗时**。在开发主机上实测(16 核 Fedora 44 容器,wtop 0.1.0,**n=16** 次调用、跨两个负载水平,1.16–1.38 s,中位数 ≈1.23 s):`wtop --agent` 在默认 interval 下耗时约 **1.2 s**,在 `--interval 100` 下约少 150 ms,这正是 250→100 ms 的延迟缩减,仅此而已。其余时间是一次完整采样轮,`wtop --snapshot` 同样要付出这一轮——1.26–1.33 s——尽管它完全不等待。上述绝对数值是共享的、负载波动宿主机的特性,此处引用是为了说明比例,不供复现:站得住脚的结论是调用耗时约为 250 ms 上限的五倍,而区间较宽是因为宿主机如此,并非因为代码不清楚。这句话过去写的是整个调用"normally takes about 250 ms",那是把上限当成了总量,误差约五倍;中间某版改成了 1.22–1.25 s 的区间,宽度只有 30 ms,排除了十六个样本中的两个,会让照着复现的读者误以为行为发生了变化。该上限现在位于 `src/wtop/application.lua` 的 `AGENT_SAMPLE_DELAY_CAP_MS`,`tests/unit/test_agent_schema.lua` 会将本文档与它比对,并且要求此处引用的实测耗时必须带样本数——一个来自共享机器却不带样本数的数字不是任何人可以核验的测量。需要持续监控的调用方应只在必要时轮询,通过 `captured_unix_ns` 和 `sequence` 标识样本,并避免无界的高频调用——这里的速率是真实的差值,而非缓存值,这正是两次采样所换来的。
- 成功时退出码为 `0`,stdout 恰好包含一个以换行结尾的 JSON 文档。诊断信息只写入 stderr。调用方必须同时检查退出码和模式,且不得解析被截断的输出。

示例:

```bash
context="$(wtop --agent)" || exit
printf '%s\n' "$context" | jq '.overall, .signals, .top.processes'
```
