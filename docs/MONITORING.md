# 监控范围与性能操作

> 本文分开记录 `0.1.0-dev` 已实现的持续 collector 和后续目标。未列在
> “当前实现”的 provider 不应从设计目标推断为已可用。

## 1. 数据源原则

- 持续采样优先使用 Linux procfs/sysfs/cgroup/DRM；外部 CLI 仅用于按需 Inspector。
- 所有 collector 先探测能力；不支持、无权或错误必须与数值 0 区分。
- 累积计数器只通过相邻单调时间样本计算 rate。首样本、reset、热拔插和
  样本间断不补零。
- 高基数扫描有明确上限，达到上限或部分路径拒绝时返回 partial/estimated。
- 外部 helper 通过绝对 argv、最小环境、超时、取消、输出上限和进程组清理
  运行，不经过 shell。

## 2. 当前 collector 矩阵

CLI 默认 `--interval 1000`。当前页面使用基本间隔与 collector floor 的较大值；
非当前页面仍会低频采样，以保留简短历史。

| 资源 | 当前数据 | 主要来源 | 默认前台 / 背景 |
| --- | --- | --- | ---: |
| CPU | 总体/每逻辑核利用率、load、context switch、interrupt、进程计数 | `/proc/stat`、`/proc/loadavg` | 1 s / 2 s |
| 内存 | total/available/used、cache/slab/anonymous/dirty、Swap、zswap 和部分 vmstat | `/proc/meminfo`、`/proc/vmstat` | 1 s / 5 s |
| PSI | CPU/memory/I/O `some`/`full` 的 avg/total | `/proc/pressure/*` | 1 s / 2 s |
| 块设备 | bytes/s、IOPS、busy、in-flight、队列大小、估算读/写延迟 | `/proc/diskstats`、block sysfs | 1 s / 3 s |
| 网络接口 | bytes/packet/error/drop rate、operstate、MTU、carrier/duplex、可用时的 speed | `/proc/net/dev`、`/sys/class/net` | 1 s / 3 s |
| socket | TCP/TCP6/UDP/UDP6/Unix endpoint、state、queue、UID、inode；可用时 PID/fd/name owner | `/proc/net/*`、`/proc/<pid>/fd` | 2 s / 10 s |
| 进程 | `(pid,starttime)`、PPID、state、CPU、RSS/VSZ、thread 数、priority/nice/CPU、UID | `/proc/<pid>/stat`、`status` | 1 s / 5 s |
| CPUFreq | policy/CPU 集、current/min/max、driver、governor、boost/EPP | cpufreq sysfs | 1 s / 5 s |
| hwmon | 温度、fan RPM、电压、电流、功率、能量与阈值/alarm/fault | `/sys/class/hwmon` | 1 s / 5 s |
| 挂载点 | mount 身份、文件系统/源/读只状态；安全时的容量和 inode | `/proc/self/mountinfo`、`statvfs` | 5 s / 30 s |
| cgroup v2 | CPU/max/weight、memory/Swap/events/limit、I/O rate、PID/events、PSI、cpuset | `/sys/fs/cgroup` | 2 s / 10 s |
| GPU | DRM 设备/节点身份、部分 AMD busy/VRAM、AMD/i915/xe 频率、DRM fdinfo 进程数据 | `/sys/class/drm`、`/proc/<pid>/fdinfo` | 1 s / 5 s |

`--interval` 可设为 100..10000 ms。交互 TUI 把初始值映射到最近的九个命名档位：
8s、5s、3s、2s、1s、0.75s、0.5s、0.3s、0.1s；右上角点击或 `f` 可在运行时
循环切换。它不会越过高开销采集器的 floor：GPU
500 ms，进程/CPUFreq/hwmon 1000 ms，socket/cgroup 2000 ms，挂载点 5000 ms。

历史按数据源实际完成的时间戳记录，不再在无关 collector 完成时复制旧值。
Sparkline 每个终端列固定覆盖 1 秒（总宽度最多 240 秒）：高频会增加每列参与平均的
真实点数，低频会产生稀疏节点，因而切换档位不会改变横轴时间比例。

选中进程的 cmdline、`/proc/<pid>/io` 和 cgroup 列表才会按需读取。交互 TUI 的
GPU fdinfo 高基数扫描只在 GPU 页的 `gpu_process_table` 经响应式求解后实际拥有
placement 时启用；仅切到 GPU 页、GPU 摘要可见或停留在 Insights 都不足以触发。
Overview/后台 GPU 采样仍读取设备摘要，但不会枚举 `/proc/<pid>/fdinfo`。非交互
`--snapshot` 保持完整扫描。
默认 inventory 上限为 4096 个 DRM class 条目、32 张 card、64 个 render node，
每设备最多 16 个 hwmon ref 和 32 个频率域；进程扫描最多 4096 个进程、每进程
1024 个 fdinfo、总计 32768 个 fdinfo 文件、每文件 256 KiB 和 8192 个 client。
达到任一上限时会标记 partial/truncated，而不是把未扫描对象视为不存在。

进程 collector 默认最多扫描 8192 个 PID，原生目录枚举会在排序和逐 PID 读取前
以该预算加少量非 PID slack 截断；结果暴露 `process_candidates`、`process_limit`、
`truncated` 和 `partial`。进程 TUI 模型在已采集集合上搜索/排序，最多保留 2048
行。连接、挂载点、workload 和 GPU 进程 ViewModel 各最多建立 512 行；GPU 设备
inventory 另有上面的 32-card collector 上限。连接、挂载和 GPU 进程表选择有界的
优先子集，workload 表保留 collector 顺序的前 512 行。collector 截断会显式附加
`partial`/`truncated`，部分 collector 还会降为 estimated；只有 UI 行预算命中时
不会改写 collector quality。进程和 GPU 进程状态显示 visible/total，连接状态显示
collector 总 socket 数；挂载点与 workload 表目前没有单独的 512-row display-cap
提示。因此还必须结合可用的资源总数和扫描状态判断，不能把未显示行解释成对象不存在。

RAPL/energy、NUMA、路由/netlink、smaps/PSS、调度延迟和连续 RAM bandwidth 尚不在
当前 collector 集合中。SMART、RAM bandwidth 和 sshd 属于按需 Inspector，见
[深度检查](DEEP_INSPECTION.md)。

RAM bandwidth Inspector 不属于上表的 scheduler：它按键触发外部 `perf stat`/
`sleep` 做一次约 250 ms 系统级采样，只映射有限的 data/CAS 事件名。匹配 PMU 的
probe 不会实际运行 `perf` 或验证权限；部分方向、部分事件或 multiplex 结果会标为
estimated，默认 TUI 也没有足够拓扑参数计算理论利用率。

Insights 是静态能力/Inspector 入口摘要，只读取已有的有界背景样本来显示计数；
它没有前台 collector 集合，不会为了这些数字以 1 Hz 采集进程或 GPU。

## 3. socket 归属与隐私

- 只有 Network 页的连接表实际 placement 可见时，采集器才会扫描 owner；最多
  扫描 1024 个进程、每进程 512 个 fd、总计
  16384 个 symlink、每 socket 8 个 owner。权限拒绝、PID/fd 竞态或上限会让
  owner 质量降为 partial/estimated，不会猜测缺失 owner。
- 离开 Network 页后 owner 扫描关闭；低频 socket table 采样仍继续。标准
  `--snapshot` 也不启用 owner 扫描。
- TUI 显示完整 local/remote endpoint、Unix socket path、UID 和可见 owner。当前无
  TUI 遮罩开关，屏幕分享前需要人工评估。
- JSON snapshot 默认把 IPv4 远程地址的最后一段替换为 `x`，较长 IPv6
  只保留前两组。连接导出 ID 会由遮罩后的 remote endpoint、local endpoint 和
  状态等字段稳定重建，不会保留含完整远端地址的内部 ID。远程端口、local address、
  Unix path、interface MAC 和已存在的 owner 字段不会被这个遮罩器处理；CLI 当前
  没有导出完整远程 IP 的开关。内部 export API 只有显式
  `include_remote_addresses=true` 时才同时保留完整远端地址和原 ID。

collector 和 Snapshot 模型内部仍保留完整远程地址，遮罩发生在 JSON export 边界，
因此这不是“完整地址从未进入进程内存”的隐私模型。

## 4. GPU 当前能力

### 4.1 已实现

- 从 `/sys/class/drm` 枚举 `card*` 和 `renderD*`，优先以 PCI BDF 为稳定 ID，
  记录 vendor/device ID、driver、DRM node 和映射质量。
- 读取驱动暴露的 `gpu_busy_percent`、`mem_busy_percent`、VRAM/visible VRAM/GTT
  数值。这些路径主要见于 amdgpu；不存在时字段为 unavailable。
- AMD `pp_dpm_sclk`/`pp_dpm_mclk`、Intel i915 GT/legacy 和 xe tile/GT/freq sysfs 频率域。
- 解析标准 DRM fdinfo 的 client ID/name、engine ns/cycle/capacity、frequency 和
  memory total/shared/resident/active/purgeable；用 `(pid,starttime)` 复验后聚合到进程。
- GPU 页显示按利用率排序的有界进程表，包含 GPU、PID、名称、总利用率、内存、
  最多四个最忙引擎和质量；同一进程使用多张 GPU 时按设备分别成行，最多显示
  512 行并报告 visible/total 与扫描质量。
- ViewModel 以 GPU 的 `hwmon_refs`、hwmon `class` 和解析后的 `device_target`
  关联通用传感器，并把匹配 channel 的最高温度和最高功率填入 GPU 设备表。使用
  最大值是为避免把重叠的整卡/分 rail 功率相加；GPU 自身已有 metric 时优先使用。
- 输出 `dev.waterrun.wtop.gpu/v2` snapshot 模型，包含能力、质量、进程扫描状态
  和截断标记。

### 4.2 未实现或未接入

- GPU collector 枚举 `device/hwmon/hwmon*` 关联键，但不在 GPU collector 中重复读取
  temperature/power/fan；温度/功率由 ViewModel 从通用 hwmon snapshot 关联。没有
  匹配 `class`/`device_target`、缺相应 channel 或 hwmon 不可读时列仍为 `—`；fan
  尚未显示在 GPU 表中。
- TUI 只显示进程级摘要，尚未提供 DRM client、frequency domain、逐 memory region
  或 GPU↔主进程详情的交互钻取；完整模型仍可在 JSON 中读取。
- 没有 NVML、AMD SMI、Level Zero Sysman、`nvidia-smi`、`amd-smi` 或 `intel_gpu_top`
  provider；发行物也不链接这些库。
- 没有 NVIDIA 利用率/VRAM、MIG、AMD `gpu_metrics`、节流原因、ECC、
  PCIe/NVLink、功率上限或完整多 tile 语义。
- DRM fdinfo 能力依赖内核和驱动；不可见 fdinfo、缺少 client ID/BDF、计数器 reset
  或达到扫描上限时可能只得到 estimated/partial，不保证所有 GPU 提供同一指标。

## 5. 进程模型

进程唯一身份是 `(pid, /proc/<pid>/stat.starttime)`。采集器允许 PID 在任意两次
读取之间消失，并在读取 status/cmdline/io/cgroup 等补充字段后再读一次
`stat` 复验 generation；混合了重用 PID 的样本会被丢弃。

当前基础扫描每个进程读 `stat` 和 `status`。只对进程页当前选中项按需读
cmdline、I/O 和 cgroup；没有 smaps/PSS/USS、thread row、namespace、environment 或 fd
详情。环境变量默认不读取，避免无意显示密钥。

进程页的搜索是 PID/name/command/user/state 上的大小写不敏感子串；树仅基于
主机可见 PPID。I/O 排序键虽存在，但未选中进程通常没有 I/O 字段，不能视为
完整 `iotop` 替代。

## 6. 挂载点容量与阻塞边界

mount collector 始终解析 `/proc/self/mountinfo`。默认原生 provider 会跳过对网络
文件系统、`autofs`、`fuse`、`fuse.*`、`fuseblk` 和 `virtiofs` 挂载执行
`statvfs`，因为这些同步调用可能等待远端或 userspace daemon 并阻塞单线程 TUI。
被跳过的 mount 身份、源、类型、只读状态等元数据仍保留；capacity/inode 不可用，
mount 标为 partial，整体结果为 estimated，并记录
`statvfs_skipped_potentially_blocking_filesystem`。这不表示文件系统离线或容量为零。

其余默认原生 `statvfs` 调用共享 50 ms 累计 admission budget。collector 只会在
调用前以及前一次返回后检查时间；预算耗尽后不再进入后续 mount，并记录
`budget_exhausted`、`statvfs_budget_ms=50` 和
`statvfs_skipped_budget_exhausted`。这个预算不是线程或 syscall timeout，已经开始的
单次 `statvfs` 无法抢占，所以一次调用仍可能超过 50 ms 甚至阻塞。测试/嵌入方
注入 provider 时默认不套用该预算，只有显式提供 `statvfs_budget_ms` 才启用。

## 7. Workloads / cgroup v2

当前 collector 从 `/sys/fs/cgroup` 广度遍历目录，默认最深 16 层、最多 4096
node，跳过 symlink、dot/unsafe 名称和非目录项。每 node 读取固定 cgroup v2
文件，并对 CPU、I/O、memory/pids event 和 PSI total 计数计算 delta。

无权子树可以作为 partial node 保留；缺失 controller 文件作为 node issue，不将值
伪装为 0。页面按路径缩进显示平铺行，尚无展开/折叠、选中详情、systemd unit、
容器/runtime 标识或 namespace 视图。

## 8. PSI、洞察与动作

PSI 已作为指标显示，但当前 Insights 页没有自动规则引擎、瓶颈推理、异常时间线
或“高利用率与实际压力”的自动解释。它目前只显示 collector/Inspector 能力摘要，
进程/GPU 数来自背景快照，不注册前台 1 Hz 进程或 GPU 采样。

当前唯一可见系统动作是对选中进程的确认 `SIGTERM`：Lua 先复验
`(pid,starttime)`，原生层再使用 pidfd 绑定目标、复验身份并发送信号。它拒绝
PID 1、wtop 自身和重用 PID。没有 SIGKILL、STOP/CONT、renice、affinity、governor、
power limit、`drop_caches` 或自动调优。

## 9. 数据质量

| 状态 | 含义 |
| --- | --- |
| `fresh` | 当前样本可用 |
| `stale` | 保留的值已超过新鲜度期限 |
| `gap` | 首样本、时间间断、累积计数 reset 或无法计算 delta；具体 reset 原因可在资源字段中记录 |
| `estimated` | 使用估算或不完整映射 |
| `unavailable` | 平台/驱动没有该能力 |
| `denied` | 能力可能存在，但当前权限不足 |
| `error` | 读取或解析失败 |

`partial`/`truncated` 当前通常是资源或扫描报告上的布尔标记，而不是 Engine
顶层 quality 枚举。并非所有 collector 使用完全相同的 quality 子集；UI/JSON 需要
同时保留 quality、这些标记和 reason。当前 TUI 可见的技术 reason 仍有未本地化部分。

## 10. 后续监控能力

- NVML、AMD SMI、Level Zero 和真实硬件能力矩阵；更完整 GPU 传感器语义与
  client/region 钻取。
- systemd unit/容器语义、Workloads 展开/详情和跨 cgroup/进程关联。
- NUMA、RAPL、调度延迟、频率驻留、节流、PSS/USS、thread/namespace 详情。
- 路由、地址和连接筛选；TUI/JSON 可配置且经评审的隐私遮罩。
- 指标录制/回放、带证据的洞察规则和可选 perf/eBPF backend。

## 11. JSON 与原生读取安全预算

- 严格 JSON decoder 默认输入上限 4 MiB、最大深度 64、最多 100000 个 value
  node；array、object 和 scalar 都占一个 node。数字只复制当前 token，解析工作量
  随输入线性增长；非法 `max_nodes` 选项会拒绝，超限返回
  `maximum_nodes_exceeded`。
- JSON encoder 在字符串值与 object key 中发现非法 UTF-8 时，逐个非法字节稳定
  替换为 U+FFFD，再进行 JSON escaping，避免输出无效 UTF-8 JSON。
- 原生 `readfile` 默认最多读取 4 MiB，显式预算只接受 1..64 MiB。它使用
  `O_NONBLOCK|O_NOFOLLOW` 打开、`fstat` 确认 regular file，并多读一个字节检测
  超限；最终 symlink、device、FIFO 和超预算输入会拒绝。procfs/sysfs 中呈现为
  regular file 的伪文件仍在允许范围内。无原生模块的纯 Lua 数据层保留测试/降级
  fallback，但交互 TUI 本身要求原生模块。

## 12. 参考接口

- [Linux procfs](https://docs.kernel.org/filesystems/proc.html)
- [Pressure Stall Information](https://docs.kernel.org/accounting/psi.html)
- [DRM client usage stats](https://docs.kernel.org/gpu/drm-usage-stats.html)
- [AMDGPU sysfs](https://docs.kernel.org/gpu/amdgpu/thermal.html)
