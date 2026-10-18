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
| `signals`(array)| 阈值、数据质量和本轮新增 AER 报告产生的异常线索，按严重程度排序；这些并非自动给出的诊断结论 |
| `top`(object)| 进程、块设备、网络接口、工作负载、GPU 和最热有效传感器的有界摘要；线程化工作负载保留可见 TID 数、不可映射条目数与未知的进程数 |
| `data_quality`(array)| 每个采集器的资源、新鲜度、状态、原因，以及有已安装值时的 `value_timestamp_ns` 和 `value_age_ms`;解释缺失数值时应先查看此字段 |
| `unavailable_sources`(array)| 当前主机上不支持或不可访问的数据源 |
| `privacy`(object)| 报告中有意省略的信息类别 |
| `privilege`(object)| 实际身份,以及本次是普通调用、直接 sudo 调用还是显式提升权限调用 |

数值保留机器单位:容量和速率使用字节与字节每秒,延迟使用毫秒,功耗使用瓦特,利用率和 PSI 使用百分比。Linux 主机的 `metrics.cpu.thermal_throttle` 给出相邻样本中单个逻辑 CPU 报告的最大核心及封装热节流新增次数；封装次数不会跨 CPU 求和。`metrics.network` 还给出每 CPU 接收栈聚合后的积压包数、丢弃与处理预算耗尽次数的每秒速率，并携带独立的 `softnet_status`/`softnet_quality`；这些数值不归属到单个接口。Linux 的 `top.interfaces[]` 另带接口自身的 `link_changes_total`，有可比的前后样本时才带 `new_link_changes`；它与 softnet 计数不相加。`metrics.power.total_watts` 仅在选定的 CPU 封装/socket 后端完整时才输出;单独选定的平台/`psys` 代表值报告为 `platform_watts`。未知的根来源和存在歧义的 CPU 后端保持不聚合。缺失数据用字段缺省或 JSON `null` 表示;绝不能当作零处理。无效的硬件哨兵读数在导出前会被过滤,而不会作为极端物理量发出。

Linux 的 `top.wifi` 是独立的无线接口报告，遵循设备列表上限；
`metrics.network.wifi_interfaces_total` 与 `wifi_truncated` 说明可见范围。
它不与 `top.interfaces` 的流量按名称或 ifindex 推断同一个采样。PHY 速率
使用 `bits_per_second`（bit/s），信号使用 dBm，关联频率使用 MHz。信号为
驱动最后接收 PPDU 的值，PHY 速率为驱动报告的单播物理层速率；
`radio_sample_time_known=false` 表示硬件采样时间未知，`observed_at_ns` 只表示
查询捕获时间。MLO 顶层报告使用 `mld_station` 范围，不分摊到各物理链路。
没有 PHY 速率时不计算占比，也不据此判断连接拥塞。完整 Snapshot 的
`wifi.devices` 保留相同的字段、逐设备质量与关联频率列表；原始协议帧、
SSID 和 BSSID 不输出。

Linux RAPL 的 Snapshot `power.graphics_domains` 与 Agent
`metrics.power.graphics_domains` 独立描述 PP1 图形功耗域，使用相同的瓦数、
观察时间、采样窗口和质量。`scope=rapl_graphics_domain`、
`pci_device_known=false` 不建立与 `top.gpus` 的卡级对应关系；厂商整卡功耗
继续保留自己的来源和范围。多个后端分别列出，并以截断位说明列表范围。
`power.zones[].domain_kind` 按内核驱动语义区分 CPU 包、CPU 核心、图形、
内存和平台；未知来源不猜测类型。`energy_observed_at_ns` 为能量读取捕获
时间，功率差值按同一域相邻捕获时间计算；控制关闭不抹去有效读数，但不
据此生成正常的上限占比。

Snapshot 的 `power.zones[].power_session` 与 Agent 的
`metrics.power.zones[].power_session` 描述当前读取器会话接受的读数，
不表示硬件启动以来的历史。`minimum_watts`、`maximum_watts` 和
`average_watts` 使用瓦特，`samples` 为接受的读数或完整窗口数。
`average_kind=time_weighted` 按能量差值窗口的时长加权，
`covered_time_ns` 和 `energy_joules` 只累计这些完整窗口，缺失时段不插值；
此时最小值、最大值也是窗口平均功耗的极值。
`average_kind=samples` 为直接功率读数的算术平均，不估算覆盖时间或能量。
`first_timestamp_ns`、`last_timestamp_ns` 标明统计范围；失效输入可保留已接受
的历史统计，但不会增加样本数或刷新最后时间。身份、读取源纪元、测量方式
改变或计数器重置后重新统计。重复与重叠窗口不会重复计入，读取器重启也
建立新会话。缺少有效统计时省略该对象。

`metrics.cpu.frequency` 按各策略已知的在线 CPU 数加权给出平均 Hz；缺少成员列表的策略按一个读数计。它携带来源与 measured/estimated/partial 质量，混用来源时标为 `mixed`。CPUFreq 采集失败或数据过期时不把保留值作为当前频率输出。

`data_quality.value_timestamp_ns` 是该资源当前所持值的单调时钟时间；
`value_age_ms` 是它距本次捕获的毫秒数。采集失败而保留旧值时，两者继续
指向旧值；从未成功采到值或来源时间不明时，这两个字段缺席。
完整快照的 `quality[resource].timestamp_ns` 仍是最近一次采集尝试的时间，
不能用它计算保留值的年龄。

Linux GPU 的 `top.gpus[].observations` 按来源记录观测时间、接收时间和
是否保留；`metric_observations` 将这些信息关联到具体指标。
提供方等待、失败或枚举不完整时，保留的旧指标明确标为 `stale`。
`metrics.gpu.maximum_utilization_percent` 汇总当前可用读数，过期设备不会
挤掉 `top.gpus` 中有当前利用率或其他当前读数的设备，也不生成当前功耗百分比。
完整 Snapshot 的设备携带同样的元数据；整体只有旧 GPU 观测时，资源的
`value_timestamp_ns` 保留原观测时间。
界面可优先使用同一当前设备的有效 hwmon 功耗通道；厂商原始观测及其质量
仍在导出中保留，通道读数和上限可在 `sensors` 中核对。

温度条目的 `critical_celsius` 来自同一通道的 `crit`，`headroom_celsius` 为临界值减去当前温度；完整 Snapshot、硬件报告与 `top.sensors` 使用同一计算。`max` 和 `emergency` 分别保留，不作为缺失 `crit` 的替代。`metrics.sensors.minimum_headroom_celsius` 与 `closest_to_critical` 保留全部有效温度通道中的最小余量及对应设备，独立于最热列表的数量限制。余量不表示限频位；过期、故障或不可用的读数没有当前余量，也不产生新的温度阈值信号。

Windows GPU 的 `providers.levelzero`、设备 `sysman` 和 `observations.levelzero`
保留独立 Sysman 观测。当前功率是同一功耗域的能量增量除以 SDK 微秒窗口，
`power_interval_ns` 给出换算窗口；`power_limit_watts` 使用同一选中域的有效瓦数
上限，电流上限、禁用项和有歧义的多个上限不成为功耗墙。原始功耗域与限频
原因仍可下钻。过期功率没有当前百分比，厂商来源之间不借用时间或设备身份。

Windows 的 Snapshot `disk_health` 保留磁盘自己的温度通道、标准 NVMe 健康字段和
按需读取的 ATA 原始属性。已核对身份的磁盘在 `disks.devices[].temperature` 和
Agent `top.disks[].temperature` 携带当前温度、临界值、余量、来源、质量和观测时间。
I/O 与健康有独立的数据质量；不要用 I/O 停滞推断盘温也已停止，或把缓存值当作新样本。
私有身份比较字段不导出，身份不足或不匹配时不建立关联。

Linux 的 NVMe 健康数据也可由隔离的原生读取器提供，无需 smartctl。它只读取
标准 SMART/Health 页，并以设备号和 diskseq 核对同一设备。Snapshot 的
`disk_health` 与 Agent 的 `top.disks[].nvme_health` 保留寿命使用量、备用空间、
累计读写与介质错误；Linux 的 `scope=controller` 表示控制器健康，不能作为
某个分区或命名空间独占的计数。权限不足、旧内核无法核对 diskseq 或设备
变化时不发布新的健康值；陈旧记录保留质量和原观测时间。
支持逐设备时间戳的来源按每个设备自己的 `observed_at_ns` 计龄；同批其他
设备的慢速查询不会更新早先读数的时间。缺少逐设备时间的旧来源继续使用
来源时间。Snapshot、Agent、盘温和健康详情使用相同的新鲜度判断。Windows 按需详情的
缓存也保留其自身读取时间；缓存老化时显示陈旧状态，不为更新标签而增加查询。

NVMe 的 128 位计数使用十进制字符串，避免浮点或有符号整数截断。
`data_unit_bytes=512000` 和 `data_units_rounded_up` 说明累计读写的单位与取整；
`percentage_used_lower_bound` 在 255 时表示下界，不把使用率超过 100 当作接口错误。
ATA 原始属性没有通用温度单位，也不据此合成健康通过/失败结论。

每条 `signals` 条目使用稳定的 `resource`、`code`、`severity` 字段；
有数值时再提供 `value` 和 `unit`，`message` 仅供展示。当前阈值为
保守提示，例如 CPU 75/90%、内存 85/95%、设备忙 80/95%、PSI
`some avg10` 5/20%。智能体在下结论前应考虑持续时间、工作负载特征
和 `data_quality`。

阈值信号只使用当前可用的来源读数。采集失败后保留的旧值仍会出现在
`metrics` 或 `top` 中供对照，但不会再次生成利用率、压力、设备繁忙或
温度阈值信号。CPU、内存和进程这三项核心来源无法读取时给出严重的
`data_unavailable`；磁盘、网络、挂载和系统来源失败时给出警告。
读取失败即使保留旧值也给出 `data_unavailable`；状态仍为 `ok` 但
质量为 `stale` 时给出 `data_stale`。核心来源的速率缺口与部分数据
分别标为 `data_gap` 和 `data_incomplete`。可选硬件来源缺失、权限不足或只有估算值时，
状态保留在 `data_quality`；能力不可用时另列 `unavailable_sources`，
不把健康主机判作故障。
同一来源的局部故障不会阻止其他当前读数生成阈值信号。

`pcie_aer_fatal` 和 `pcie_aer_nonfatal` 只在本轮 PCIe AER 计数增加时
分别给出严重和警告线索。设备与根端口可能报告同一事件，因此每种严重度
最多一条信号，不把计数相加，也不把报告错误的链路认定为故障端点。
可纠正错误、启动以来的累计计数和具体 PCI 地址请查看完整 Snapshot 的
`inventory.pci.devices[].aer`。调用期间没有新增报告时不会凭历史非零
计数生成这两种信号。

`nvme_critical_warning` 只在当前、身份与时间均可核对的 NVMe 健康页报告
已知关键警告位时发出严重线索；`nvme_unknown_warning_bits` 对未识别位给出
警告，不猜测其物理含义。位定义来自 [libnvme 的标准健康页说明](https://github.com/linux-nvme/libnvme/blob/master/src/nvme/types.h)。
两种线索各最多一条，多个命名空间可能共享控制器，不把它们当作故障盘数
或合并成某一控制器的位掩码。寿命使用量达到 100、介质错误或非正常关机
累计非零不会单独触发当前警告。陈旧、拒绝、缺少身份或观察时间的值不发出
新的当前警告。TUI 的提示计数使用相同判定，按 `!` 查看当前原因。

`nvme_no_path_io_failure` 仅在本轮 NVMe 无可用路径 I/O 失败计数
增加时给出一条警告线索。首次样本、计数器回退、盘符身份无法以
`diskseq` 核对或磁盘来源陈旧时不报警；多个设备同时报告也不把累计计数
相加。内核允许管理员改写这些计数器，增加量是观察到的差值，不单凭它
断言发生了多少次真实故障。完整 Snapshot 的 `disks.devices[].nvme` 保留
各计数器状态和来源。

`md_array_degraded` 只在当前磁盘样本中看到活动 MD 阵列明确报告缺失设备
时给出一条警告。来源陈旧、阵列未激活或 MD 字段部分损坏时不报警；多个
阵列也不合并成一个缺失设备数。具体级别、状态和计数保留在完整快照的
`disks.devices[].stack`。

## 完整快照

需要原始细节时使用以下命令:

```bash
wtop --snapshot
```

它返回 `dev.waterrun.wtop.snapshot/v1`,包含额外的采集器字段和更长的列表。除 `--agent` 所汇总的资源外,快照还携带 `system`(主机名、内核、发行版、固件、虚拟化、安全模块、内核限制与计数器、Swap 设备、时区)和 `power_supplies`(电池的电量、相对设计容量的健康度与剩余续航,以及市电适配器)。网络接口额外携带其 IPv4/IPv6 `addresses` 和原始 `counters`。

Linux 快照会对进程集合额外读取两次 `/proc/<pid>/io`。`processes.top[].io` 给出累计计数，`io_rate` 给出按实际两次读取间隔计算的存储层读写字节每秒速率及 `quality`；首读后消失、权限不足或计数回退的进程不会被填成零速率。`processes.io_scan` 报告整个有界扫描的覆盖数，而 `top` 只保留最多 50 行。`--agent` 不请求这项全进程 I/O 扫描。

`system.kernel.command_line` 会对命名了密钥或标识主机的参数——如 `root`、`resume`、`cryptdevice`、`rd.luks.key`、`systemd.machine_id`、`ip`、`nfsroot` 等——做脱敏:仅将值替换为 `<redacted>`,普通参数和裸开关保持原样。`/proc/cmdline` 本身是世界可读的,所以这并非访问控制;它只是避免磁盘加密密钥或根文件系统 UUID 出现在被粘贴进工单的导出内容里。

`system.firmware` 有意省略序列号、资产标签和产品 UUID:采集器从不读取它们,因此粘贴进缺陷报告的快照不会泄露超出操作者预期的主机身份信息。

请先调用 `--agent`,仅在发现异常需要深入排查时再获取完整快照,以免不必要地消耗上下文。

## 隐私与调用约定

- Agent 报告省略进程命令行;仅包含 PID、名称、状态、用户和资源用量。
- Agent 报告省略套接字端点;完整快照默认同样对远端 IP 地址打码。
- `unavailable` 条目不意味着系统故障。可选硬件和缺失权限是分开报告的。
- 进程、设备和工作负载列表均有界。未出现在 Top 列表中的对象,不一定不存在于主机。
- 运行 `sudo wtop --agent` 或使用显式的 `--sudo`/`--elevate` 可能暴露需要权限的数据源。消费方应检查 `privilege` 并继续使用 `data_quality`;提升权限执行并不保证每个数据源都存在或成功。
- `--agent` 与 `--snapshot` 每次调用都采样两次以计算速率，两次采样之间等待 `min(--interval, 250 ms)`。250 ms 是该延迟的上限,而不是整个调用的耗时。在 16 核 Fedora 44 共享开发主机上，`--agent` 的 **n=16** 次调用耗时 1.16–1.38 s，中位数约 1.23 s；这些数字是共享的、负载波动宿主机的特性，不构成其他机器的性能预算。`--snapshot` 使用相同的双采样路径，并在第二次采样时重读 Linux 进程 I/O。持续监控可用 `--stream` 接收逐行 Snapshot/v1 JSON；它先建立速率基线，此后遵守各采集器的刷新周期，不是 Agent/v1 格式。消费方通过 `captured_unix_ns`、`sequence` 和各来源的 `value_age_ms` 标识样本与保留的旧读数。间隔速率来自两次读数的差值，而非缓存值。
- 成功时退出码为 `0`,stdout 恰好包含一个以换行结尾的 JSON 文档。诊断信息只写入 stderr。调用方必须同时检查退出码和模式,且不得解析被截断的输出。
- GPU SDK 启动或能量差值仍未完成时，一次性导出最多额外等待 2250 ms。
  达到截止时间后仍保留未就绪或缺失状态；交互和流模式继续按调度器采样。

示例:

```bash
context="$(wtop --agent)" || exit
printf '%s\n' "$context" | jq '.overall, .signals, .top.processes'
```
