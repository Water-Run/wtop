# 深度检查：当前实现与边界

本文只描述当前 `0.1.0-dev` 实现。wtop 的长期方向是把常用的只读诊断信息放进同一 TUI，但它目前并不等价于 `smartctl`、`perf`、`systemctl`、`ss` 或各厂商 GPU 工具的完整替代品。

## 1. 当前入口

当前默认 registry 只注册三个按需 Inspector：

| 按键 | Inspector | 当前来源 |
| --- | --- | --- |
| `s` | SMART / NVMe | `/sys/class/block` + 可选 `smartctl` |
| `b` | 系统 RAM 带宽 | PMU sysfs 描述 + 可选 `perf stat`/`sleep` |
| `d` | `sshd` 服务与监听端口 | 可选 `systemctl` + 进程快照 + `/proc/net/tcp*` |

检查结果显示在可滚动文本浮层中。浮层支持方向键、`PageUp`/`PageDown`、`Home`/`End` 和鼠标滚轮，使用 `Esc`、`Enter` 或 `q` 关闭。当前 renderer 只逐行显示 section 的标量值和 quality；table 值折叠成 `[N items]`，field unit/source/timestamp/reason 也没有完整展开。当前没有通用实体浏览器、详情层级导航、字段固定到仪表盘、Inspector 历史或插件 UI；这些仍是后续方向。

外部 helper 均通过无 shell 的 argv Runner 调用，并受超时、输出上限、固定环境和进程清理约束。`--safe-mode` 会关闭 Runner，因此三个 Inspector 中依赖外部命令的部分不可用；普通 procfs/sysfs collector 仍可工作。

## 2. SMART / NVMe

### 2.1 设备选择

按 `s` 后，wtop 先列出可选择的块设备，而不是默认检查“第一个磁盘”。选择器支持：

- `↑`/`↓`、`PageUp`/`PageDown`、`Home`/`End` 和鼠标滚轮移动选择；
- `Enter` 检查所选设备；
- `Esc` 或 `q` 关闭。

设备来自 `/sys/class/block`，当前上限为 256 个条目。分区以及名称匹配 `loop*`、`ram*`、`zram*`、`fd*` 的虚拟设备会被过滤；剩余设备按名称排序并映射为 `/dev/<name>`。

当前没有 `smartctl --scan-open`、USB/SAS bridge 的 `-d` 类型探测、手工输入设备路径或多路径去重。因此某些 USB enclosure、RAID、设备映射器或非标准块设备可能不会出现，或者需要 `smartctl` 参数但当前无法检查。

### 2.2 调用与数据

对选中设备执行：

```text
smartctl --json=c --nocheck=standby --all /dev/<device>
```

当前策略为 2 秒超时、4 MiB 输出上限和 60 秒结果缓存。`--nocheck=standby` 用于避免主动唤醒待机设备；wtop 不启动 SMART 自检，也不进行固件、修复或写操作。

当前解析并可在标量 section 中直接展示的字段包括：

- 型号、遮罩后的序列号、固件、容量、协议、旋转速度和推断设备种类；
- 总体 SMART 通过状态、温度、通电小时、开机次数和 `smartctl` exit bitmask；
- NVMe critical warning、available spare、percentage used、data units、media errors 和 unsafe shutdowns；
- ATA SMART attribute 的 ID、名称、规范值、阈值和原始值会进入 Inspector
  result，但当前通用浮层只把整张列表显示为 `[N items]`，不能浏览单项。

长度超过 4 的序列号默认只保留最后 4 个字符，其余以 `*` 替换；更短的序列号会全部遮罩。只有协议、rotation rate 或型号/产品中明确的 `SSHD` 标识才用于设备种类判断；wtop 不生成跨厂商“健康分数”。当前也不解析或呈现 SMART 自检历史的专用视图。

`smartctl` 缺失、设备权限不足、超时、输出被截断和 JSON 无效都会作为不可用/拒绝/错误返回，而不会被解释成设备健康。

## 3. RAM 带宽（实验性）

当前实现是一次性的系统级估算，不是连续 RAM 带宽监控，也不是内存 benchmark。按 `b` 后会：

1. 在 `/sys/bus/event_source/devices/` 中查找名称以 `uncore_imc`、`amd_df`、`amd_l3`、`hisi_sccl`、`arm_dmc` 或 `dmc` 开头的 PMU；
2. 从 PMU 的 `events/` 目录选择有限的读写事件；
3. 通过绝对路径执行一次约 250 ms 的 `perf stat -a -A`，以 `sleep` 作为计时 workload；
4. 按 `perf` CSV 中每个 CPU/uncore 控制实例自己的 runtime 换算速率，再把实例速率
   相加为系统总读/写 B/s。

采样时长内部限制为 50–2000 ms，TUI 使用默认 250 ms；Runner 超时为采样时长加 1250 ms，默认输出上限为 512 KiB。PMU 枚举最多处理 256 个设备、每个最多 512 个 sysfs event，单次 `perf` 最多使用其中 64 个受支持事件。默认运行还依赖可执行的 `perf` 和 `sleep`；可靠解析要求 `perf stat` CSV 提供 runtime（该字段从 perf 4.1 起可用），更旧格式会安全地返回不可用而不会用墙钟猜算。`perf_event_paranoid`、`CAP_PERFMON`、内核或平台事件支持也会影响结果。

当前仅识别这些事件名或模式：

- `data_read`、`data_write`；
- `cas_count_read`、`cas_count_write`；
- 名称包含 `rdcas`/`wrcas` 或 `cas_count_rd`/`cas_count_wr`。

未知事件不会被猜测为带宽事件。同一主机同时暴露 Intel free-running data 与 CAS
替代事件族时会整族择一，优先完整的 free-running 读写族，同时保留所选族所有
PMU/socket 实例，避免把同一 DRAM 流量重复相加。同一 PMU、同一方向内编码
descriptor 相同的 sysfs event alias 也只计一次。若 `perf` 返回字节单位则按其 CSV unit 换算；
无单位的已识别 CAS/DRAM 事件按每计数 64 字节处理。每个被采用的计数行都必须带有
有效的正 runtime；缺失或畸形 runtime 的行会被拒绝，而不会退回到采样时长估算。
若仍有有效子集，结果可成功但会标为 `estimated`；若没有有效受支持计数，则检查
不可用。缺少读或写方向、只得到部分受支持事件或实例、事件列表触及上限、
multiplexing 或缺少 running-percent 也会将成功结果标记为 `estimated`。存在匹配
PMU 只说明候选硬件接口存在，并不保证有受支持事件或当前用户有读取权限；启动时
的 capability probe 不运行 `perf`，最终状态以按 `b` 后的检查结果为准。只有输出
明确包含权限诊断时结果才归为 `denied`；纯 EINVAL/event-open failure 不能区分
不支持事件与权限问题，因此归为 `unavailable`，并只在 `perf_event_paranoid` 等证据
支持时附 `permission_may_be_required` hint。默认 TUI
成功结果的 provider 为 `perf_stat`，formula version 为
`perf-stat-csv-no-aggr-v4`；当前实现调用外部 `perf stat`，不是直接使用
`perf_event_open`。result 中的带宽字段单位是 bytes/s，但当前通用浮层只显示原始
数值和 quality，不格式化或附加 unit。

理论带宽只会在调用者明确提供有效的 MT/s、整数通道数和整数总线位宽时计算：

```text
MT/s × 1,000,000 × (bus_width_bits / 8) × channels
```

默认 TUI 不提供这些拓扑参数，因此通常不会显示理论上限或利用率。实现不会自动猜测通道数，也没有 CPU family/model 白名单、按 socket/controller/channel 拆分、长期历史或厂商参考工具级别的平台覆盖。`perf` CSV 和事件语义也可能随内核/平台变化，所以该功能保持实验性。

## 4. `sshd` 服务

按 `d`（或在 Insights 页按 `Enter`）检查固定的 `sshd.service`。当前可组合的数据为：

- `systemctl show sshd.service` 的白名单字段，例如 ActiveState、MainPID、重启数、退出状态、内存、CPU 时间和 cgroup；
- 已采集进程快照中名称为 `sshd` 或 `sshd:*` 的进程；
- `/proc/net/tcp` 和 `/proc/net/tcp6` 中的监听 socket，默认以端口 22 作为没有配置 provider 时的有限回退。

当前 TUI 没有注入有效 sshd 配置、登录会话、socket owner 或 journal/recent-events provider。因此默认运行不会展示有效配置、活动登录来源、认证失败或近期日志；“unavailable”不表示没有会话或事件。非 systemd 系统只能依赖进程和 procfs 监听信息降级。

进程、listener、session、event 和 configuration 都是 table-valued section；当前通用浮层只显示各表的 item 数量，尚不能逐项查看监听地址/端口或进程明细。标量 systemd service 字段可以直接显示。

Inspector 模型支持在调用者提供会话时遮罩远端地址，默认 TUI 上下文启用遮罩：IPv4 只保留前两段，IPv6 只保留短前缀。此处的遮罩策略只适用于 sshd Inspector；Network 页和 JSON 导出的隐私边界见 [MONITORING.md](MONITORING.md)。

## 5. 能力、权限与失败语义

- `available` 只表示探测到基础来源，不保证随后的设备、权限和事件组合可用。
- `denied` 表示权限阻止读取；wtop 不因此把整个 TUI 以 root 重启。
- `unavailable` 表示 helper、PMU、设备、事件或可选 provider 不存在。
- `error` 表示超时、截断、无效结构化输出或其他运行错误。
- SMART 有 60 秒缓存；RAM PMU 和 sshd 结果当前不缓存，也不会在关闭浮层后持续采样。

主程序不要求 root。当前没有特权 helper、权限提升流程或修改系统状态的 Inspector 动作。

## 6. 发布验证与剩余工作

发布验证至少应覆盖：

- SMART：多盘选择、无盘、列表截断、standby、权限不足、helper 缺失、ATA/NVMe fixture；
- RAM PMU：无 PMU、无受支持事件、`perf`/`sleep` 缺失、权限拒绝、multiplex/单方向结果和数值边界；
- sshd：systemd 与非 systemd、默认端口与自定义端口、没有进程/监听、日志和会话 provider 缺失；
- 四种 PTY 尺寸中的选择、滚动和关闭路径；
- `--safe-mode` 下外部命令确实不可执行。

尚未实现的长期方向包括通用 Resource Inspector、更多实体/provider、SMART bridge 参数与自检历史、可信的平台 PMU 映射、服务会话/日志来源，以及按字段显示更完整的证据和权限说明。

## 7. 参考

- [smartctl JSON/YAML output option](https://www.smartmontools.org/static/doxygen/smartctl_8cpp_source.html)
- [Linux perf events security](https://docs.kernel.org/admin-guide/perf-security.html)
- [perf-stat manual](https://man7.org/linux/man-pages/man1/perf-stat.1.html)
