# 当前架构

本文档描述当前开发树的实际结构。0.1.0 标签和 LuaRocks 包仅 Linux，macOS、Windows 是源码开发构建。已交付的 PCI/USB 拓扑与后续硬件扩展分别说明，产品方向见 [实现计划](PLAN.md)。

## 1. 数据流

```text
Linux /proc · /sys / macOS / Windows native APIs
              │
              ▼
        bounded collectors ──────────────┐
              │                         │
              ▼                         │
 Snapshot + quality/capability     on-demand inspectors
              │                         │
              ├──── fixed history ring  │
              ▼                         ▼
         ViewModel                  text overlay
              │
              ▼
      10-page Workspace + widgets
              │
              ▼
      virtual cell grid → diff renderer → terminal
```

默认连续采集不依赖外部 CLI。`smartctl`、`perf`、`sleep`、`systemctl`、`journalctl` 和 `loginctl` 由按需检查器通过受限 Runner 启动。Linux 的 NVML、AMD SMI、Level Zero 在各自独立的原生读取进程内动态加载；安全模式跳过这些厂商接口。macOS、Windows 使用各自的原生硬件后端。

Linux 显示连接器由独立的 `displays` 读取进程取得缓存 sysfs 属性与 EDID；
一次回复后释放进程。Windows 的 SetupAPI 显示清单也在独立读取器中获取；
父进程以私有 PnP 身份维护有界会话 ID，防止枚举重排或替换重定向设备详情。
共享 EDID 解析器只输出公开基础块声明，序列号原值与
原始块不进入 Snapshot、Agent 或界面。连接器与 PCI 的关系使用稳定读取的
内核设备链接，读取期间变化的状态不用于关联。

UI 状态目前由 `tui.lua`、`workspace.lua` 和进程控制器直接协调，尚未形成完整的 Action → Reducer → 单一 AppState 架构。既有的边界仍然成立：采集器不向终端绘制内容，控件（widget）也不直接读取 procfs 或 sysfs。

## 2. 主要目录

```text
src/wtop.lua             CLI entry point
src/wtop/
  application.lua       configuration parsing and snapshot/TUI assembly
  tui.lua               event loop, keys, overlays, and runtime state
  workspace.lua         ten fixed pages, widgets, and layout editing
  view_model.lua        Snapshot-to-widget-model conversion
  engine.lua            collector scheduling, snapshot merging, and history
  core/                 clocks, scheduler, Runner, JSON, and other infrastructure
  linux/                procfs/sysfs readers and parsers
  collectors/           bounded continuous collectors
  inspectors/           SMART, RAM bandwidth, systemd units, sshd, and logind Inspectors
  model/                Snapshot, rings, and layout tree
  ui/
    backend/            native terminal interface adapter
    input/              keyboard, mouse, and escape-sequence decoding
    renderer/           cell grid, Unicode width, and ANSI diff
    layout/              responsive solver
    widgets/             metric, text, table, and other components
    views/               page frames
    theme/               semantic themes and terminal-capability fallback
  i18n/                  catalogs, restricted YAML, formatting, and plurals
  generated/locales/    generated built-in locale Lua modules
  config.lua             `config.yml` schema v1
  layout_store.lua       `layout.yml` schema v1-v6 reader and content-based writer
  workspace.lua          tabs, the edit-mode tree, named workspaces, the edit banner
  actions.lua            process-identity revalidation and pidfd signal actions
native/wtop_native.c     libc-only Lua C module
locales/                 authoritative built-in `.yml` translation catalogs
tools/                   locale, toolchain, build, and checking tools
tests/                   unit/fixture and real-PTY smoke tests
```

十个固定页面按顺序为 `overview`、`processes`、`compute`、`memory`、`storage`、`network`、`gpu`、`workloads`、`system` 和 `insights`。页面集合固定；编辑模式可添加、移除或替换页面已定义的控件。

## 3. 运行时

### 3.1 Lua 与原生模块

- 发布工具链以 PUC Lua 5.5.1 为目标，不使用 LuaJIT。纯 Lua 测试继续覆盖与 Lua 5.4 兼容的子集。
- `wtop_native.so` 必须与其加载的 Lua 运行时保持一致的 major.minor ABI。
- 交互式 TUI 使用相应平台的原生模块，需要 TTY 或原生 Windows 控制台。非交互环境可使用 `--snapshot`、`--stream`、`--report`、`--agent` 或 `--diagnose`。

原生模块目前提供：原始/备用屏幕（alternate-screen）的终端生命周期管理、终端尺寸、`poll(2)`、信号与窗口尺寸变化处理、单调/实时时钟、睡眠、文件系统辅助函数、`statvfs`、`wcwidth`、原子写入、受限的 argv Runner、身份查询、`execve` 以及 pidfd 信号发送。原生 `readfile` 采用非阻塞、不跟随符号链接的打开方式，仅接受普通文件，默认上限 4 MiB、显式上限 64 MiB，并拒绝符号链接、设备文件、FIFO 和超大内容；以普通文件形式呈现的 procfs/sysfs 伪文件仍可读取。该模块不包含任何控件、布局、翻译、采集器或厂商 GPU 库。

### 3.2 事件循环

TUI 使用单线程调度器；Lua UI 状态与采集器都运行在主线程上。每次迭代中，事件循环最多等待 100 ms，以获取终端输入或到达下一个采样截止时刻。仅当发生输入、窗口尺寸变化、采样完成或显式失效时 UI 才会被标记为脏（dirty），此后渲染器只输出与上一帧相比发生变化的单元格序列。这里没有固定的“10–15 FPS”承诺。
页面切换先用现有快照画出新页，再运行刚转为前台的采集器；同轮取得的新读数由差分帧补上。这样一次慢的硬件读取不会挡在页面切换的首帧之前。

同步的外部检查器可以在其超时预算内占用主线程。目前没有基于厂商 API 的工作线程池，也没有后台检查器队列。

## 4. 采集器与快照

引擎（Engine）按固定顺序注册采集器，包括：

```text
cpu, cpu_info, thermal_throttle, thermal_zones, cpuidle, memory, numa, memory_devices, expansion_slots, port_connectors, onboard_devices, firmware_enclosures, firmware_batteries, firmware_power_supplies, firmware_bmcs, firmware_tpms, tpm, watchdog, rfkill, host_interfaces, processor_firmware, edac, spd, pressure, disk, network, connections,
process, gpu, cpufreq, hwmon, powercap, mounts, cgroup,
system_info, power_supply, inventory
```

采集器返回 `ok|unavailable|denied|error` 状态，以及 `fresh|stale|gap|estimated|unavailable|denied|error` 质量。调度器（Scheduler）捕获异常、记录耗时，并对失败按指数退避，最长 30 秒。基于计数器差值的采集器把首次采样、回绕、复位和消失都表示为 gap 或 unavailable 值，而不是产生速率尖峰。

当前快照的资源结构如下：

```lua
Snapshot = {
  sequence = 42,
  timestamp_ns = 0,
  cpu = {},
  cpu_info = {},
  memory = {},
  pressure = {},
  disks = {},
  network = {},
  connections = {},
  processes = {},
  gpus = {},
  cpu_frequency = {},
  sensors = {},
  power = {},
  mounts = {},
  workloads = {},
  quality = {},
  collectors = {},
}
```

一次成功的采集会替换对应的资源。失败时则保留上一份可用数据，但质量会变为 stale、denied、unavailable 或 gap，而不再宣称数据是新鲜的。

温度临界余量由 `model/thermal.lua` 统一计算，只使用同一摄氏温度通道的 `crit - input`。`max` 与 `emergency` 不替代 `crit`，负余量保持为负，也不合成限频位。来源、设备或通道不可用、输入故障、原观测超过 15 秒或时钟回退时不发布当前余量。Compute、传感器详情、Snapshot、Agent 和报告共用这一语义；详情前置至多三个最接近临界值的通道，Agent 的最小余量独立于最热列表的截断。温差转为华氏时只乘以 9/5，不加绝对温度的偏移。

### 4.1 高基数扫描

- 进程采集器默认最多枚举 8192 个 PID 的基本 `/proc` 字段。Linux 原生批量读取器直接解析常规 `stat` 行；非常规或畸形行保留原文交给 Lua 解析器，以维持同样的错误分类。旧原生模块没有解析能力时沿用字符串批量读取。命令行在枚举时按身份缓存；更深入的内存、线程、FD、OOM 分数、I/O 与 cgroup 读取按所选进程或明确的排序/过滤需求触发。进程模型最多保留 2048 行。
- 进程树的折叠状态绑定 `(PID, starttime)`，进程消失或 PID 复用后丢弃旧状态。搜索和 cgroup 过滤会临时展开命中项的祖先，清除条件后恢复折叠；折叠隐藏的行数单独计入状态，不冒充采集或视图上限截断。按 `]` 从折叠节点进入子进程时先展开该节点。
- 进程表按 `g` 时，`linux/process_cgroup.lua` 只读取所选进程的 cgroup，并在两侧核对 `(PID,starttime)`。归属无需预先打开详情，也不复用旧快照中的路径；失败时保留原页面。默认进程刷新不增加这项读取。
- 线程详情是第二个、更窄的选中项，随采样上下文携带，记为 `selected_thread_ids[pid] = tid`，与进程选中项并列。采集器随后读取该 TID 的 `status`、`cgroup`、`io`、`schedstat` 和 `sched`，共五个文件；读取量由选中项限定，而不受线程数量影响，因此一个拥有一千个线程的进程仍然只花五个文件的代价。该映射以 pid 而不是进程 id 作为键，因为 TID 只有与其所属进程放在一起才有意义，而已不存在的进程所对应的条目永远不会被匹配到。线程级的读取在选中后的下一个 tick 落地，因此浮层在此之前渲染为挂起（pending）状态。
- 运行队列相关数字读取 `schedstat` 而不是 `sched`，因为前者是固定的三个数字的 ABI，而后者是调试转储，其键随内核版本和编译配置变化；`sched` 仅按白名单解析调度策略，其余一概不用。每个已打开线程的上一次 `schedstat` 读数保存在采集器上而不是样本中，因此缓存量只取决于操作者实际检查过的线程数；其速率跨度是该线程自上次的真实间隔，而不是被重新缩放成单个 tick。
- 进程与线程的累计 `cpu_ticks` 在采集时按该平台的 `clock_ticks_per_second` 换算为 `cpu_time_seconds`。进程表时间列、详情、`time` 排序/比较和 JSON 使用同一秒数；旧快照缺少该字段时才用随快照提供的频率或兼容默认值换算。`schedstat` 的纳秒运行时间在选中线程详情中仍优先于 tick 换算。
- 进程已运行时间与累计 CPU 时间分开。Linux 每次采样读取一次 `/proc/uptime`，减去进程/线程 `starttime_ticks / clock_ticks_per_second`；Windows 的 FILETIME 与 macOS 的 Unix 微秒启动时间由可移植采集器用实时时钟换算。读取失败或时间来源缺失时 `elapsed_seconds` 保持未知，`elapsed`/`age` 比较不会把它当作零。进程表的 ETIME 列默认隐藏，可在列编辑器中开启。
- 采样上下文在进程和线程选中项之外还携带 `visible_process_ids`，采集器恰好为这些 PID 读取 `/proc/<pid>/schedstat`。该集合在渲染阶段、滚动偏移稳定之后发布，因此测量到的就是绘制出的内容；其上限为 256 个条目，超出上限的集合会被拒绝而不是被采纳，这样畸形的上下文就无法把视口测量变回对整个 procfs 的扫描。进程级和线程级速率共用一份备忘录（memo）和同一个求差辅助函数，键是携带 pid 与 starttime 的身份标识，因此两种粒度不会互相矛盾，而一个被回收复用的 id 根本不会产生速率。
- 进程表的列集合是纯模型层的事务（`model/process_columns`）：一份目录、一个规范化器、两个操作。视图模型持有列的*定义*，并向模型询问顺序，因此一列不可能在一个文件里描述、却在另一个文件里排序。渲染器不受影响：`priority` 和 `full_only` 仍决定小面板丢弃哪些列，这与用户的决定是两回事。
- 仅当网络页上的连接表具有实际的可见位置（placement）时，连接属主扫描才会跟随进程 fd 链接。相同 PID 的多个匹配 fd 合并成一个属主；打开其进程详情时按需复核 fd→socket inode 与两次进程启动时间，详情随后只跟随相同进程身份。反向从进程跳到连接时，目标携带 `(PID,starttime)` 与请求时间；采集器只给两次 stat 读取之间身份稳定的目标属主写入内部 id，ViewModel 等到本次连接样本安装后才按 id 筛选。标准的 JSON 快照不执行属主扫描。
- 进程详情的 `F` 下钻按需有界扫描至多 4096 个 `/proc/<pid>/fd` 名字，按数字排序后读取至多 128 个链接目标。选择一个 FD 后才读取其 `fdinfo` 前缀，显示原始偏移、八进制标志、挂载 ID 和 inode；进程身份或链接目标变化就丢弃该次详情。列表扫描前后也复核 `(PID,starttime)`，身份变化就丢弃整份路径列表。不打开链接所指文件，结果不进入 Snapshot 或 Agent。
- Network 查询由 `model/connection_filter.lua` 编译一次再筛选完整连接集合，之后才选最多 512 行。没有结构化条件的查询保留整句字面匹配；字段条件按 AND 组合。远端字段和普通文本都使用 ViewModel 已遮蔽的端点，缺失队列值不参加数值比较。
- 网络采集器平常只在两份 procfs 文件中轻量扫描最低 metric 的已启用默认路由，维持接口汇总的前台刷新；Network 页 `g` 浮层或一次性 Snapshot 显式请求时才解码完整的有界 IPv4/IPv6 路由清单。打开浮层会让 network 任务立即到期；保持打开时十秒重读一次，默认路由变化则立即重读；关闭后保留的清单标为 stale。收集上限与展示上限分开，超限时仍遍历剩余有效行以选择默认路由。此来源不代表全部策略路由表。
- 仅当 GPU 页上的 `gpu_process_table` 具有实际的可见位置时，GPU 采集器才会扫描标准 DRM fdinfo 以构建逐客户端/逐进程数据。仅仅打开 GPU 页或 Insights 页并不会触发它。概览页和后台采样只收集设备摘要。GPU 页最多显示 512 条进程级摘要，完整的客户端/区域细节仍保留在快照/JSON 模型中。非交互式快照会显式执行完整扫描。
- cgroup 采集器有深度和节点数限制。它保留原始的 cgroup v2 层级结构和内核统计信息，systemd/容器标签由独立的 `cgroup_semantics` 层补充。`cgroup.procs` 返回不支持时才检查 `cgroup.type`；确认是线程化子组后读取 `cgroup.threads`，不把未知进程数改写为零。PID 命名空间不能映射的成员以 `0` 出现在列表时，仅保存可见 ID 与零条目数，总数仍未知。用户按 `Enter` 时才有界核对 `/proc/<tid>` 并找出所属进程，常规采样不增加这项读取。
- 它也是唯一一个必须在向下深入之前先知道*路径是什么*的采集器：cgroup 树内部的符号链接可能指回树内，而扫描是一次有界行走而不是遍历，因此回答为 `symlink` 的条目计为跳过，无法回答的条目则不下探。所以 `Cgroup.new` 会拒绝一个不能回答 `read`、`list`、`readlink` 和 `kind` 的文件系统，并指出缺的是哪一个。这里没有兜底回答。这个理由值得记录下来，因为兜底回答正是代码过去的行为：一个没有 `kind` 的对象会被当作“每个条目都是目录”来读取，而这恰好是唯一会让符号链接规避机制失效的答案；它过去只可能被一个不完整的测试替身触及——`FS.default` 总是全部回答。`test_cgroup_collector.lua` 中有两个替身依赖了这一点，于是节点和广度预算断言穿过的其实是产品代码写死的一个常量，而不是文件系统，而建立在其上的有界行走断言，实际断言的是那个常量。

连接、挂载、工作负载、系统设备、CPU 空闲态和 GPU 进程的视图模型行预算均为 512。达到上限的采集器会把资源标记为 `partial`/`truncated`；仅影响显示的限额不会改写采集器的质量。表格状态报告视图模型截断，不把未显示的对象当作不存在。Storage 的 `model/mount_filter.lua` 在伪文件系统开关和重复路径归并之后、行数上限之前筛选挂载点；缺失容量不参加数值比较。Workloads 查询由 `model/workload_filter.lua` 编译一次，在完整节点集合中匹配文字和实测数值，再补祖先并应用显示上限；缺失数值不参与肯定或否定比较。System 的 `model/hardware_filter.lua` 在完整共享设备图中只检查白名单身份字段，补上已有父节点后再应用显示上限。折叠状态在工作负载搜索期间保留但暂不遮挡命中路径。布局求解器把位置（placement）传给视图模型，因此隐藏的表不会构建高基数的行数组。

精确的限额和隐私边界见 [MONITORING.md](MONITORING.md)。

### 4.2 共享硬件拓扑

`model/hardware.lua` 从快照建立有界的 PCI/USB 设备及 USB 接口、块设备和网卡树，
并关联挂载、GPU 和传感器。
Linux 采集器读取设备/驱动链接和可用链路元数据；模型自身不读取文件。
hwmon 同时保留设备链接与类链接的完整路径，后者用于解析 NVMe 等相对链接的归属。
系统设备表、设备详情和 `inventory.topology` 导出使用同一模型。
缺少父设备信息的平台仍显示清单；未知 USB 子设备和 I2C 传感器不归到
上层 PCI 控制器。模型对重复身份、循环与上限分别记录状态。
详情中的 `r` 从图里已解析的跨设备引用和子节点构建有界目的地列表；
不存在或身份有歧义的节点不会成为跳转目标。一个目标直接打开，多个目标
先选择，`b` 返回上一设备。列表上限为 256，超出时报告总数。

Windows 的 `collect_cpu_info` 保留 OS 身份与缓存报告，独立的 `collect_cpuid`
在后台运行模块内嵌的 x86/x64 读取器。亲和性仅在子进程内改变；父端按 Lua VM
保存有界任务、缓存和模块引用。`model/cpuid.lua` 解码原始包，区分硬件能力、
OS 扩展状态与实际可用性，按观察到的 APIC/计算单元关系去重缓存。
完整且一致的视图才提升为首选拓扑，并保留 `os_topology` 和 `os_caches`；
AMD 共享计算单元是独立节点。额外读数 pending 时，调度器短间隔补采，
已有 OS 读数仍保持自己的状态。该进程隔离目前用于 CPUID，不代表其他
厂商 SDK 已全部迁移到相同执行方式。

Linux 磁盘和网络采集器将类链接解析为 `/sys/devices` 下的路径；
磁盘/网卡关联到路径中的 PCI/USB 设备；已列出的 USB 接口优先作为
具体函数的父节点，分区关联到祖先块设备。接口级驱动、类别与端点数
来自 USB sysfs，不把未列出的接口误归到上层 PCI 控制器。
虚拟设备或没有路径的平台保留独立节点，不按设备名称猜测父设备。
挂载通过 `device_id`（major:minor）关联具体块设备，因此别名和 bind
mount 均可保留。节点的 `resource`/`resource_id` 指向原始快照资源；
块设备节点优先使用含 `diskseq` 的身份，网卡使用 ifindex。
分区从 `/sys/dev/block/<major>:<minor>/{size,start}` 读取 512 字节扇区数，
换算成容量与相对父盘起点；缺失、非整数及溢出值保持未知。分区仍不计入
整盘 I/O 合计，也不借父盘容量补自己的缺失值。
堆叠块设备从 `slaves` 链接读取每个底层设备的 major:minor，再与本轮
唯一的块设备清单核对；整组引用完整时建立双向 `slave_ids`/`holder_ids`。
这是一条依赖关系，不改变 PCI/USB/分区的物理父节点。缺失、歧义、截断
或来源陈旧时不建立未经证实的引用。
`linux/stacked_block.lua` 在存在时读取 device-mapper 的名称/暂停位，以及
MD 的级别、阵列状态、预期与缺失设备数、同步动作和扇区进度。同步进度
读取前后复核动作，变化时不发布不对应的分数。它不读取映射器 UUID、MD UUID、
设备映射表或元数据镜像。缺失的可选字段保持未知，解析/权限错误标为部分
数据；卷名仅是可读标签，不作为跨采样身份键。
MD 的 `dev-*` 成员目录另以 `block/dev` 核对设备号，读取 `slot` 位置和
`state` 标志。成员清单最多 64 项；无效设备号、重复设备号与截断各有
独立状态，不据名称推断物理身份。成员清单质量与阵列级告警分开。
Linux 块设备采集器仅对 NVMe 命名空间读取 `/sys/block/*/diag` 的可选
计数与 ANA 状态，不读取序列号或 WWID；单轮最多 128 个。累计值与样本差值
分开保存，只有相同 `diskseq` 的相邻样本能产生差值。缺少可选文件不
影响普通磁盘 I/O 质量，解析/权限错误和上限则显式标记部分数据。
命名空间的真实 sysfs 路径若落在已核对的控制器类链接
之下，还读取该控制器的状态、传输方式及命令错误、重置、重连计数。
同一轮的多个命名空间共享一次控制器读取，各自保留独立的计数差值和
质量；多路径聚合命名空间不猜测单一控制器。序列号、NQN 和传输地址
不进入结果。
多路径聚合命名空间的真实路径还要与 NVMe subsystem 类链接核对；其
目录里的路径命名空间链接逐条指向真实控制器，再读取各路径的 ANA 状态、
控制器状态和传输方式。单个聚合设备最多扫描 256 个目录项、保留 32 条
路径；链接缺失、控制器不符及截断各自有质量状态，不从名称推断关系。
`nuse` 读取会触发 Identify Namespace。具有相同 `diskseq` 的命名空间在
60 秒内复用该读数，保留首次读取时间和 `cached` 标志；身份不足时不借用
上一设备的值。逻辑块数只在块大小有效且换算不溢出时转为字节，
这表示命名空间已分配量，不是文件系统已用空间。
USB 设备最多 128 个、接口最多 256 个，目录扫描最多 1024 项。
磁盘最多 256 个、网卡最多 128 个、挂载关联最多 512 条；系统表最多
512 行，各自触及上限时报告截断。父设备驱动仍显示在父设备详情中，
路径处理依据 [Linux sysfs 规则](https://docs.kernel.org/admin-guide/sysfs-rules.html)。

CPU 节点按实测插槽和核心分组；采集器以 `package_id_known` 和
`core_id_known` 区分实测 ID 与兼容旧模型的推断值，`online_known`
区分已知与推断的在线状态。插槽/核心是由 CPU 清单分组得到的节点，
逻辑 CPU、NUMA 和策略节点的 `resource_id` 对应各自原始记录。NUMA 节点和频率策略
通过 `cpu_ids`、`numa_node_ids`、`cpufreq_ids` 关联，保留它们跨插槽的情况。
只有成员完整且都属于同一实测插槽时，频率策略才放在该插槽下。
CPU 最多 512 个、频率策略最多 128 个；NUMA 采集最多 128 个节点，
每节点 CPU 列表默认最多 4096 项。共享图中的 CPU 关联列表最多 512 项。
CPUFreq 读数依次选硬件当前值、硬件反馈短时平均值和调频读数；最后一种
保留估算质量。策略详情同时显示来源与备用读数，不把策略读数宣称为
独立测出的每个物理核心瞬时频率。
NUMA 独立采集器使用 2 秒前台下限和 10 秒后台间隔，内存页或设备详情
可见时启用；没有原生提供方的平台报告 unavailable。
每节点的 `numastat` 按内核页分配计数解析；本地/跨节点速率只在连续样本
均有效时计算，计数器回退记为 reset。缺失该可选接口不抹掉节点拓扑。
`coretemp` 的温度通道仅按驱动发布的包号归属；核心编号还需在该包内
唯一。重复的包传感器或没有明确标签的通道保持未归属。
CPUFreq 策略从这些已归属的通道取得温度引用：全部成员在同一核心时
关联核心通道，否则只有全部成员在同一封装时关联封装通道。引用包含
传感器、通道和归属节点，Compute 表与 System 策略详情共用设备图的
判断；传感器、CPU 身份或频率策略来源过期时不建立新关联。
热节流读数只按逻辑 CPU ID 连接对应线程节点，并沿已知父子关系列出
核心和封装的 `thermal_throttle_cpu_ids`；重复 ID 不归属。封装上的列表
仍是逐 CPU 引用，不把重复公布的封装计数相加。设备详情逐 CPU 显示
累计与相邻采样新增次数，快照拓扑导出相同引用。
CPUIdle 状态同样按逻辑 CPU ID 连接线程节点；核心和封装上的
`cpuidle_cpu_ids` 只表示哪些 CPU 有报告，不汇总各状态的内核报告时间。
使用、时间及可选的拒绝/过短/可更深状态计数各自计算增量，留在逻辑 CPU
详情与 Snapshot；失败采样的旧报告不进入当前设备图。

`collectors/smbios_source.lua` 从 Linux 固件 sysfs 或 Windows 动态解析的
`GetSystemFirmwareTable` 读取 SMBIOS，供内存、扩展槽、端口连接器、板载设备、固件电池、固件电源和处理器固件采集器共用。
同一轮调度中，来源、基路径和读取后端相同的采集器共用一次成功读取与
解码；各采集器取得独立的记录副本，下一轮重新读取。直接调用采集器时
不保留缓存。
`format/smbios.lua` 校验入口校验和、记录长度和字符串终止符，解码
Type 2/3/4/7/9/16/17/19/20/22/37/39/41，使用句柄关联内存阵列、设备、固件地址范围
及内存通道。
读取上限 4 MiB，遍历最多 4096 条结构，输出最多 128 个处理器插槽、
512 条缓存、128 个扩展槽、128 个端口连接器、64 块固件电池、64 台固件电源、64 个内存阵列、256 个内存设备、64 个内存通道、
256 条阵列地址范围和 512 条设备地址范围。
旧记录的缺失字段保持未知，空槽与未知容量分开；速率使用 MT/s。
内存设备采集的前台下限为 60 秒，后台间隔为 5 分钟。
Type 19/20 的旧地址以 KiB 为单位，扩展地址以字节为单位；解析器转换为
精确的闭区间，并拒绝倒置、混用哨兵值或超出整数范围的地址。
设备树以 Type 19 → Type 16、Type 20 → Type 19 的句柄为父子关系，
再以 Type 20 → Type 17 的句柄作反向引用；不把交错设备的重叠范围
相加推断容量。
Type 37 只按其声明的 Type 17 句柄建立通道与内存设备的双向引用；
设备仍以 Type 16 阵列为父节点。计数、负载和句柄任一处不完整时，
保留固件记录但不建立该通道的引用。通道负载不是带宽读数。

`collectors/expansion_slots.lua` 从同一 SMBIOS 表独立采集 Type 9 物理
槽位，保留旧版短记录与空槽。`format/smbios.lua` 对 Peer 组按声明长度和
数量设界；共享图仅在固件说“在用”、BDF 唯一命中当前 PCI 清单且记录
无歧义时建立双向引用。引用不成为父子关系，因为固件报告的地址在真机
上可能指向上游端口而非插入卡。前台下限与后台间隔为 60 秒 / 5 分钟。

`collectors/onboard_devices.lua` 独立采集 Type 10/41 板载功能。Type 10 的
设备条目使用结构句柄和条目序号区分，保留声明的类型、启用状态与公开名称；
没有 PCI 地址，不按名称与 Type 41 或操作系统设备合并。两类来源共用 128 条上限。
Type 45 的句柄引用只有在 Type 10 结构恰含一个设备、记录完整且清单未截断时
才能解析到该设备。Type 41 启用的固件记录
只有在 PCI 地址唯一命中当前清单时才与 PCI 节点互相引用；禁用、缺少地址、
截断及歧义记录仍可单独查看，但不建立引用。固件引用不改变 PCI 父子树。
`collectors/port_connectors.lua` 采集 Type 8 的内部/外部标识、连接器类型和
端口用途。固件没有给出当前操作系统设备的身份，因此端口保留独立节点，
不按名称猜测 PCI、USB 或网络接口的关系。
前台下限与后台间隔为 60 秒 / 5 分钟。

`collectors/platform_firmware.lua` 使用同一共享输入采集 Type 0 平台固件和
Type 1 系统公开声明，每类最多 16 条。ROM 的旧编码以 64 KiB 为单位，
扩展编码区分 MiB/GiB；旧 FF 哨兵缺少可用扩展时只给出 16 MiB 下限。
传统运行时 BIOS 区域与 ROM 容量分开，起始段为零时不推算运行时区域。
功能位与修订号按记录长度读取，厂商保留的高 32 位只给存在性；Type 1
序列号与 UUID 值不进入结果。UEFI 支持不推断当前启动方式或安全启动，
未设置虚拟机标志也不推断物理机。Type 2/45 的明确句柄可以关联这些节点，
不按厂商或名称猜测归属，静态声明不产生实时健康告警。

`collectors/firmware_enclosures.lua` 共用固件输入，采集 Type 2 主板与 Type 3
机箱各最多 64 条记录。按 [DMTF SMBIOS 3.9](https://www.dmtf.org/sites/default/files/standards/documents/DSP0134_3.9.0.pdf)
保留公开型号、功能位、机箱位置、机架 U/OU 高度、供电线数量及可变长度部件声明；
序列号、资产标签与 OEM 数据只保留存在性，不导出值。
主板的机箱句柄只有在当前清单中唯一命中有效机箱记录时才建立父子关系；
内含设备句柄和 Type 45 关联保持可双向导航的引用，不改变 CPU 或 PCI 的父子树。
Type 3 部件类型与数量范围不生成设备，启动、供电、温度及安全状态注明为
上次启动时的记录，不进入实时健康告警。前台下限与后台间隔为 60 秒 / 5 分钟。

`collectors/firmware_batteries.lua` 独立采集 Type 22 便携电池设计值。
旧结构的容量倍率默认为 1，新结构按固件倍率换算 mWh；未知容量、电压和
误差不编造数值。日期、序列号及 OEM 字段不进入解析结果，固件电池不凭名称
猜测操作系统实时电池的归属。前台下限与后台间隔为 60 秒 / 5 分钟。

`collectors/firmware_power_supplies.lua` 独立采集 Type 39 电源配置。
非零电源组只有在清单完整、记录无歧义且同组至少两台时建立同伴引用。
额定容量和固件状态保持静态声明，不参与实时功耗或主机健康告警；
序列号与资产标签不出解析器。前台下限与后台间隔为 60 秒 / 5 分钟。

`collectors/firmware_bmcs.lua` 独立采集 Type 38 IPMI BMC 接口声明。
解码接口类型、规范版本、I²C 目标地址及可选的寄存器地址、间距和中断；
16 字节旧记录不猜测缺失的地址修饰位。记录在硬件图中保持独立，
不据此判断 BMC 当前可用性。前台下限与后台间隔为 60 秒 / 5 分钟。

`collectors/firmware_tpms.lua` 独立采集 Type 43 TPM 固件声明。
读取厂商 ID、规范版本、固件版本字段、描述和公开特征位；OEM 字段不进入
解析结果。TPM 记录保持独立，不据此推断操作系统中的可用性或安全状态。
前台下限与后台间隔为 60 秒 / 5 分钟。

`collectors/firmware_components.lua` 独立采集 Type 45 固件组件清单。
解析器按记录中的关联数量读取有界句柄列表，不用记录总长度推测数量；
只公开标准格式的 GUID，不输出可能含资产标识的自由格式 Firmware ID。
共享设备图把无歧义的关联句柄建为双向导航引用，不变成父子关系；
未建模的句柄保留在固件记录中；重复句柄标记部分质量，不猜测设备。
前台下限与后台间隔为
60 秒 / 5 分钟。

`collectors/firmware_esrt.lua` 在 Linux 上只读 UEFI ESRT sysfs。
目录发现与字段读取分开：属性为 root-only 时保留可见条目及权限状态，
不为缺失的 GUID 建设备节点。已读取的版本和上次尝试状态保留 UEFI
原始数值；状态 `0` 也可能表示没有尝试。共享图只在 Type 45 的标准
Firmware ID GUID 与 ESRT 类别 GUID 各自唯一时建立双向引用，既不猜测
固件更新服务的可用性，也不建立物理父子关系。前台下限与后台间隔为
60 秒 / 5 分钟。
Snapshot 的设备拓扑仅在实际建立引用的节点上导出 `associated_ids`、
`firmware_component_ids` 与 `esrt_ids`，与 TUI 的 `r` 导航使用同一份图。

`collectors/tpm.lua` 读取 Linux `/sys/class/tpm` 的 OS 注册设备、规范主版本、
驱动及可选的状态位。PCR 库只列目录名与条目数，不打开 PCR 值文件；
密钥和安全姿态不在采集范围内。该节点与 Type 43 固件声明分别保留，
没有可信身份键时不建立同一设备引用。前台下限与后台间隔为 60 秒 / 5 分钟。

`collectors/watchdog.lua` 只读 Linux `/sys/class/watchdog`，显示设备标识、
活动状态、配置超时及可选状态位。仅在 active 时读取剩余倒计时；设备的
sysfs 链接明确经过当前 PCI 功能时才建立父子关系。采集器不打开
`/dev/watchdog`，不启动或保活硬件。前台下限与后台间隔为 5 秒 / 30 秒。

`collectors/rfkill.lua` 只读 Linux `/sys/class/rfkill`。优先使用可分别表示
硬件、软件阻断的 `hard`/`soft` 字段，旧内核两者均缺席时才回退到
信息较少的 `state`。设备路径明确归属当前 PCI/USB 节点时才建立父子
关系；未阻断不代表网络已连接。前台下限与后台间隔为 2 秒 / 10 秒。

`collectors/thermal_zones.lua` 只读 Linux `/sys/class/thermal`，采集热区温度、
模式、策略、阈值及冷却设备原始状态。可用时读取冷却状态转换累计次数和
各状态累计驻留毫秒数，不读取 `stats/reset`，也不推断变化速率。低于绝对
零度的阈值占位值留空；
`cdevN` 链接明确命中当前冷却设备时才建立双向引用。冷却状态不换算成
风扇转速或百分比，阈值不推断关机倒计时。前台下限与后台间隔为
2 秒 / 10 秒。

`collectors/host_interfaces.lua` 独立采集 Type 42 管理控制器主机接口。
按固件结构长度逐条解析接口与协议类别；SMBIOS 3.2 之前的 OEM 结构按
入口版本使用旧布局。接口和协议专属负载可能包含管理网络配置，只保留
类别、长度与 OEM 企业编号，不导出原始负载。Type 42 与 Type 38 可能
描述同一硬件，但缺少可靠身份键时保留独立节点。前台下限与后台间隔为
60 秒 / 5 分钟。

`collectors/processor_firmware.lua` 独立采集 Type 4 插槽和 Type 7 缓存。
共享图只按 Type 4 明确给出的 L1/L2/L3 句柄关联级别匹配、无歧义的
Type 7 记录；未被引用或被多个插槽引用的缓存保持独立。固件插槽不按
名称或数量映射 Linux 实测 CPU 包，固件缓存也不替代 sysfs 缓存清单。
前台下限与后台间隔为 60 秒 / 5 分钟。

解析结果和 JSON 只保留白名单字段，不包含序列号、资产标签、UUID 或原始
固件表。Linux 普通用户读表受限时报告 denied；Windows API 缺席时报告
unavailable，不访问物理内存或调用外部工具。固件记录不用于推断实际
ECC 健康、当前内存时钟、NUMA 归属或通道绑定。

Linux EDAC 独立采集器读取 `mc*` 控制器和 `dimm*`/`rank*` 的累计纠错
计数；目录与数值均有上限，字段读取失败保留来源和问题记录。它以 5 秒
前台下限、30 秒后台间隔运行。共享图中 EDAC 模块只挂在自己的控制器下。
两份列表未截断、来源当前可用，且非占位标签在两侧各唯一时，SMBIOS 已
填充槽位与 EDAC DIMM 模块建立双向标签引用。重复标签、rank 或空槽不参与
匹配；引用不改变父子关系，也不证明物理身份。

SPD 采集器读取 `spd`(SDR/DDR/DDR2/DDR3)、`ee1004`(DDR4)和
`spd5118`(DDR5) I²C 设备的 EEPROM。旧内核的通用 `eeprom` 驱动还可
暴露 SDR/DDR/DDR2：采集器先检查有界的 SPD 头部，再把符合条件的设备
纳入，避免把同地址的普通 EEPROM 当作内存。每次至多 64 个设备，按
128 字节分段读取至 128/256/512/1024 字节。
内核属性有时只让前 128 字节可读；分段接口保留该页的类型、修订版、
封装和最短周期，后续页失败则报告 partial。DDR4 基础块 CRC 可在
128 字节时核验，第二块在 256 字节时核验；DDR3 配置 CRC 也可在
128 字节时核验，SDR/DDR/DDR2 校验和只覆盖前 63 字节，DDR5 主 CRC 需 512 字节。
SDR/DDR/DDR2 的容量、位宽、Rank 和最短周期在校验和有效时解码；仅前
64 字节可读时仍保留这些基础字段并报告 partial。
SDR 的混合大小双行模块按两个密度位求和；更多行的混合密度不猜容量。
DDR4 非堆叠模块在基础块 CRC 有效时按颗粒密度、位宽和 Rank 推出
标称容量；3DS 编码留作未知。
共享图按 I²C 地址把 `spd5118` 连到同一 DDR5 SPD 设备；DDR4 的 `jc42`
使用 `ee1004` 驱动声明的同总线地址关系，并要求基础块 CRC 与温度
存在位有效(SPD 1.0 的驱动例外亦可)。该地址不映射 SMBIOS 插槽名。
DDR3 的 `jc42` 使用 `at24` 驱动的同总线地址规则，并要求基础 CRC
与温度存在位有效。
原始 EEPROM 和序列号不会复制到快照或 JSON。

EDO/更早代 SPD、SMBIOS 插槽与 SPD 的可信归属、更多固件结构和复杂
存储栈仍待扩展。

静态身份低频发现，实时遥测按独立预算采样，昂贵的硬件检查按需执行。
平台公开接口与厂商提供方分别扩展；新增字段需要同时验证旧系统降级、
热插拔身份和采样开销。现有 Snapshot/Agent 导出契约继续作为兼容边界。

## 5. 调度与历史

在没有 `--interval` 覆盖的情况下，CPU 默认为 500 ms，挂载默认为 5000 ms，大多数其他采集器为 1000 ms；连接默认为 2000 ms。为防止快速刷新触发开销巨大的扫描，引擎还强制下列前台最小间隔：

| 采集器 | 前台最小间隔 |
| --- | ---: |
| GPU | 500 ms |
| process、cpufreq、hwmon | 1000 ms |
| connections、cgroup | 2000 ms |
| mounts | 5000 ms |

TUI 先用真实终端尺寸求解当前页面，再根据存活下来的控件计算前台采集器集合。因此，一张被响应式布局隐藏的表，并不会仅仅因为它的标签页处于激活状态就保持前台。任何可见控件都不需要的采集器会以更低频率继续运行：CPU/PSI 为 2 秒，磁盘/网络为 3 秒，内存/进程/GPU/cpufreq/hwmon 为 5 秒，连接/cgroup 为 10 秒，挂载为 30 秒。当某个页面首次被选中时，从未运行过且不可见的采集器会被直接推迟到其后台截止时刻。初始刷新和手动刷新只强制运行可见控件所需的采集器。不可见的采集器不会完全停止，从而保留有限的整体趋势。GPU 设备摘要可以继续前台或后台采样，但 fdinfo 进程扫描仅由 GPU 进程表的实际可见位置启用。Insights 没有前台采集器集合；它的计数器读取有界的后台快照，不会产生 1 Hz 的前台进程/GPU 采样。

历史并非存储在“15 分钟/5 分钟”这样的分级中。引擎为 CPU、内存、PSI、磁盘读/写、网络收/发、第一块 GPU 利用率、平均 CPU 频率、最高温度、CPU 功耗和根 cgroup CPU 等聚合指标保留有界的、时间戳单调递增的数据点。只有当对应的数据源真正完成时，才会追加一个数值或 gap，避免无关采集器重复填充旧数据点。渲染器把窗口固定为每列一秒、最长 240 秒。更高的更新速率只会提高列内的采样密度，而不会缩短横向时间跨度。目前没有按核心、按设备或按进程的历史订阅。

## 6. GPU 数据边界

Linux GPU 采集器以 DRM、sysfs、procfs 和有界的本地 `pci.ids` 查询为基础：

- 它从 card/render 节点、PCI/sysfs、驱动链接和 PCI 名称构建设备身份。有 PCI BDF 时以 BDF 作为稳定 ID；否则使用估算的 DRM/sysfs 标识符。
- 它支持 AMD `gpu_busy_percent`、显存/可见显存/GTT、AMD DPM 频率，以及 Intel i915/xe 的 sysfs 频率路径。
- 它解析标准 DRM fdinfo 的引擎/周期/内存计数器，用于有界的逐客户端/逐进程聚合，并能在硬件没有忙计数器时推导出设备利用率兜底值。
- 在暴露时，它记录 PCI 类别、修订版、正确嵌套的 `pci.ids` 子系统名称、boot-VGA、NUMA、PCIe 链路、运行时电源管理（runtime-PM）和 modalias 元数据。
- 它发现关联的 hwmon 路径并存储 `hwmon_refs`，但不会在 GPU 采集器内部重复读取温度、功耗或风扇。

视图模型通过 `hwmon_refs`、hwmon `class` 和规范化的 `device_target`
联接传感器。GPU 表和传感器浮层共用关联函数；温度取最热通道，
功率取来源明确的最大通道，风扇取最快通道，避免重叠功率域求和。
设备、客户端、引擎、显存区域和频率域可下钻，GPU 进程可跳转到主机进程详情。

Windows 磁盘 I/O 与健康查询分别使用 `disk` 和 `disk_health` 原生读取进程。
来源编号固定为 0/1/2 的频率、GPU、热区，3 的 NVML，4 的磁盘健康、5 的
磁盘 I/O、6 的 Level Zero；NVML 的协议类型 6 保持不变，Level Zero 使用类型 9。每来源两个读取名额，超时、关闭和
父进程退出沿用同一守护和实际回收路径。健康查询不会在界面线程执行。

两类读取在同一接口句柄上核对设备号、描述符及 PnP 身份；ATA 深查询重开所选
接口后再次核对。两个进程用规范化私有身份字段匹配，字段不进入公开 JSON。
I/O 计数失败时，健康来源仍可凭当前响应核对同一强身份；不同或重复身份不配对。
默认使用标准 NVMe 温度属性和健康日志，ATA/桥接设备只在用户选择后进行深查询。
温度描述符的设备临界值仅配给 Composite，独立传感器保留自己的 over/under
设置。NVMe 的 128 位累计计数导出为十进制字符串；读写数据单位为 512000 B，
原值按协议向上取整；寿命使用率允许超过 100，255 标为下界。ATA 属性只保留
校验通过的编号、规范化值和六字节原始值，不按属性编号推算摄氏温度。

Windows 的 `collectors/windows_gpu.lua` 组合隔离的设备枚举/PDH、NVML 和
Level Zero 读取器。Intel Sysman 复用 Linux 的只读能量/功耗域、上限和频率实现，
平台层只改变动态加载与调用约定；SDK 的完整结构在 Win32/Win64 对照独立上游
声明验证。Level Zero 只从原生位数 System32 加载 `ze_loader.dll`。独立 Sysman
不可用时，先回收旧进程，再用新进程及其私有的 CRT/Win32 环境尝试旧初始化；
两种初始化状态不在同一进程混用。缓存可执行文件按来源、位数和摘要命名，读取
期间固定字节，构建清单也将各类读取器绑定到独立摘要。功耗域按明确的 card/
package 关系选择，重叠域不相加；能量差值使用 SDK 自己的计数窗口。

两个 Windows 厂商来源分别保留接收与观测时间、等待宽限和失败缓存。PCI 厂商/
设备身份冲突时，当前与后续保留数据均不能附着到冲突的宿主设备；有效的其他
来源继续更新。安全模式取消全部厂商读取器，缺失 SDK 不回退到界面进程内调用。

主程序保持 PE32；原生模块内嵌两种位数的 SDK 读取器，按
主机架构选择，读取器自身不链接 Lua。NVML 从系统目录和标准 NVSMI
目录加载，缺失接口保留不可用状态。读取器使用独立管道、取消和父进程
句柄，原生控制线程负责超时与实际回收；每个来源有两个名额。
Vista 及以后动态配置显式继承白名单，限制每个子进程获得的句柄；CPUID
使用同一启动封装。XP 缺少对应 API 时沿用兼容启动，子端清除继承标志。
读取器在加载 SDK 或创建采集器前等待父进程守护线程的就绪事件，避免
驱动构造函数先占加载器锁，使守护线程无法完成 DLL 线程初始化。

SDK 可执行文件缓存于应用数据目录，执行前逐字节核验，并在子进程存活
期间持有禁止改写的读取句柄。缓存文件有意保留，不能把它们当作退出时
应删除的临时文件。Windows 与 Linux 共用 NVML 查询、数据操作协议、功耗
语义及设备模型；合并时核对 PCI 身份，故障保留原时间，安全模式不查询
SDK，进程扫描标志分别传入 PDH 和 NVML。

Linux 厂商提供方按设备身份补充通用 DRM 信息：NVML 提供 NVIDIA
遥测与进程显存，AMD SMI 补充 AMD 遥测，Level Zero 补充 Intel
温度、时钟和功率。后两项已有假库测试，真机覆盖仍待补齐。
MIG、多 tile、完整厂商健康信息和厂商控制操作仍是规划项。

默认三个 SDK 共用内嵌在原生模块中的读取器 ELF，各自运行在独立进程，
不依赖辅助 Lua 或外部命令。后台控制线程负责启动、两秒查询截止与回收；
默认前台查询只检查已有响应。每个提供方拥有自己的会话，每个 SDK 最多
两个控制器，全进程最多六个；一个厂商挂住不会占满另一个厂商的名额。
停止时分别取消会话，关闭 Lua VM 不等待驱动。标准输出与错误输出不会混入
协议、界面或 JSON。原 NVML 隔离 API 保留最多 50 ms 的兼容等待。

读取进程保留 NVML 会话和进程采样游标，以及 Sysman 的能量基线。
响应有长度、深度、操作数、来源和序号边界，完整校验后才解码；Lua 内存
不足时保留同一帧供重试。真实采样起止时间随响应传递，交付时重新核对
NVML 功耗时间戳。没有 DRM 节点的设备可以在异步发现完成后更新 GPU 能力。
一次性导出在常规两次采样后，最多额外等待 2250 ms，让 SDK 启动和能量差值
完成；交互采样不做这段等待。同步 sysfs 读取仍不在进程隔离范围内。

GPU 采集器另按来源保存规范化观测，每源最多 64 个设备；设备副本的字段与
标量拷贝预算为 65,536 项，字符串预算为 1 MiB。观测不携带进程行；等待、失败及部分枚举中遗漏的设备只补充
当前来源未提供的字段，标为 stale，并保留原始时间。新读数优先，完整枚举
可移除旧设备，成功响应缺失的字段不会从更早响应补回。已知 DRM 关联签名
变化或消失时放弃对应观测；停止、安全模式、文件系统或单调时钟纪元变化
会清空缓存。`observations` 与 `metric_observations` 随 Snapshot/Agent 导出，
当前利用率汇总、曲线和告警跳过旧观测。只有保留值时，快照模型接受有界的
`result.value_timestamp_ns`，不把本次状态更新当作一次新测量。

Level Zero 使用完整、经 SDK 校验的 Sysman 结构与调用签名。优先独立 Sysman
初始化；旧运行时需要 core 初始化时重新执行读取器，再设置兼容环境，避免
混用两类句柄。设备按 PCI 地址关联，未知关系保留独立设备；不按枚举位置
猜测。频率的实际值和请求值分开，功率按同一域的能量/时间差计算，窗口为
100 ms–5 s；板卡、封装、子设备和显存域不会相加。只有明确选定域的已启用
功率上限才参与百分比计算，电流限制和未确认供电来源的限制保留原语义。

## 7. 检查器

检查器只响应用户按键而运行，不参与连续采样。默认注册表恰好包含：

- `storage.smart`：选择一个 `/sys/class/block` 设备，然后调用 `smartctl`；结果缓存 60 秒；
- `memory.bandwidth`：枚举一组有限的 PMU 名称，并通过外部 `perf stat` 执行一次实验性的全系统采样；
- `service.sshd`：结合 `systemctl show`、进程快照和 `/proc/net/tcp*`。
- `session.logind`：按需查询登录会话的公开属性，以启动 ID、会话 ID、UID 与创建单调时间区分身份；sshd 的登记会话以 PAM 服务字段精确筛选。
- `service.systemd`：只在按键时枚举/查询系统与当前有效用户的 unit；名称、管理器和 UID 共同标识实体。unit 选择器在完整有界集合上搜索，详情可核对进程身份与当前 cgroup 后下钻，或跳到 Workloads。枚举只有一个实体时仍使用原检查器和标题。

Linux argv 执行器默认只给子进程固定 PATH 和 C locale。systemd 用户查询可显式
传入绝对路径 `XDG_RUNTIME_DIR`，取值由有效 UID 推导；它不会继承父进程的
用户总线地址、HOME 或加载器变量。缺失、无穷上限与读取失败分别保留自己的含义。

检查器使用文本浮层；systemd unit 与登录会话有专门的字段标签、样本年龄和跨资源导航，其他来源沿用通用显示。DIMM/EDAC、PCI/USB、RAID/LVM 等来源没有注册为默认检查器。精确的能力与失败语义见 [DEEP_INSPECTION.md](DEEP_INSPECTION.md)。

`inspectors/journal.lua` 是 unit 详情按 `l` 打开的子视图，不新增后台采集器。
每次显式读取或刷新都先重新核对 unit，再以当前启动 ID、管理器和 canonical
名称调用有界的 `journalctl`。只保留消息、时间、优先级和发送者等公开字段，
区分 unit 发出、slice 成员和引用消息；原始 journal 对象、主机/机器 ID 与命令行
不进入共享模型。记录中的 PID 保持历史意义，不反向绑定当前进程。

`inspectors/journal_stats.lua` 汇总已经有界的查询，显示优先级与来源关系。
sshd 另按 unit 直接记录的 OpenSSH 文本格式分类，使用系统管理器确认的
canonical 名称/别名；保留未知格式与查询覆盖状态。分类样本只含种类、已知
方法、时间和优先级，用户名、地址、指纹和原始消息不进入结果，也不加入
默认 Snapshot/Agent。它不推算独立连接数、全启动总量或速率。

`inspectors/sshd_config.lua` 按需让 OpenSSH 解析当前配置，优先使用 `-G`，
只在模式不受支持时改用 `-T`；连接范围保留 `-C` 参数。单次命令限
500 ms、128 KiB，输出还有行数、单行长度和重复值上限。结果仅保留配置
白名单与查询范围，不保存密钥、命令、原始输出或连接参数。
查询不能证明守护进程采用了同样的文件内容和启动选项，因此配置为估算
质量；失败配置保持 nil。默认快照和报告不执行该查询。

## 8. 布局与状态

工作区为每个页面存储一棵二分分裂树。叶子引用页面定义的控件，
分裂节点包含方向、比例和两个子节点。编辑模式支持移动、比例调整、
添加/移除/替换、指定目标与侧边的键盘拖放，以及每页最多 50 步撤销/重做。
命名工作区支持保存、切换、重命名和删除。

`layout.yml` 支持 v1 有序列表、v2 树布局、v3 命名工作区、v4 进程列和 v5 可见标签顺序及用户移除的控件。v5 只列出标签栏可见的内置页面；所有页面的布局树仍保存，因此隐藏后重新显示不会丢掉控件安排。移除控件的名单让加载器区分用户选择与新版本添加的默认控件，命名工作区各有自己的名单。标签集合是全局选择，各命名工作区继续保存自己的页面树。导出、导入和迁移都保留这些信息。
v6 另存最多八个自定义页面的 ID、名称和初始控件。每个页面的布局树可放入不同内置页的控件，也可从现有页面完整复制；副本与源页独立，各命名工作区按自己的源树复制。控件 ID 在全局唯一，ViewModel 按当前可见控件构建模型，Engine 以同一集合决定前台采集器。页面聚焦控件决定详情和键盘操作的语义，已存在的内置页逻辑不因标签顺序改变。新建、复制、重命名和删除的定义与布局一并经过 CLI 导入、导出和迁移。
编码器按实际内容选择版本；旧布局兼容读取。进程列选择是整份布局的设置，
切换工作区时保留。列集合必须包含 PID 和 Command，未知、重复或缺失身份列
会拒绝该文件并报告原因。

布局在有序退出时原子保存，权限为 `0600`。文件损坏时先尝试单代
`.bak`，恢复结果显示在状态栏；无可用备份时回退默认布局。
`--export-layout`、`--import-layout` 和 `--migrate-layout`
提供无需启动 TUI 的布局操作。

命名工作区最多 16 个；名称最多 64 字节，允许合式 UTF-8，
拒绝控制字符和结构性 ASCII。写出时使用带引号的 YAML 键，
模型和存储共同使用名称校验函数。重命名保留已存的树并拒绝重名。
其余限额和按键见 [UI.md](UI.md)。

不要把布局版本与主配置混淆：`config.yml` 仍然使用 schema v1。模式定义与按键绑定见 [UI.md](UI.md)。

布局编辑模式下页脚的静止状态是 `LAYOUT` 横幅，它由工作区模型持有——但模型只持有横幅。瞬时消息的优先级高于它，而 TUI 其余的状态（布局保存错误、权限标记、进程过滤器、数据年龄）会照常透传，而不是被丢弃。横幅过去会替换整个状态表，而工作区管理器*只*在编辑模式下可达，于是该管理器产生的每一条确认——删除、切换、重命名——都发生在无处展示它的地方。替换掉横幅的消息会在编辑模式结束时离开，因此横幅不是一条单行道。

CLI/配置中的主题值只接受五个确切的内置名称。未知的 CLI 值立即报错；未知的配置值会拒绝整个配置、回退并报告错误。Locale 标签会做语法校验和规范化，但一个合法的未知标签可能在 TUI 加载 XDG 用户目录中的目录后成为当前语言。`--snapshot` 和 `--diagnose` 不创建翻译器，也不扫描用户目录。

## 9. 身份、安全与隐私

- 进程操作使用 `(pid, starttime_ticks)` 身份。Lua 层重新校验 `/proc/<pid>/stat`；原生层随后持有 pidfd，再次校验，并且只发送白名单内的信号。TUI 的 `k` 菜单提供 TERM、HUP、INT、KILL、STOP 和 CONT，发送前需要确认。
- GPU 优先使用 PCI BDF。没有 BDF 时身份质量记为 estimated。目前没有厂商 UUID。
- 外部程序必须使用绝对可执行路径，argv 不得经过 shell 拼接。Runner 控制文件描述符、环境变量、进程组、超时和输出大小。
- `--sudo`/`--elevate` 通过固定的系统 `sudo` 路径、以精简消毒后的环境变量重新执行当前调用；直接使用 `sudo wtop` 也会被识别。不存在常驻的特权守护进程，也没有可变的 shell 命令辅助函数。
- 布局以 `0600` 模式原子保存；主配置是只读的。
- 网络页默认显示完整的端点、Unix 路径、UID 和已发现的属主；`m` 在连接表中切换远程地址遮蔽（启动时可用 `mask_remote_addresses` 配置）。JSON 快照默认遮蔽远程 IP 地址，但不遮蔽本地地址、端口、Unix 路径、MAC 地址或属主。两个界面共用同一份遮蔽实现。见 [MONITORING.md](MONITORING.md)。
- 默认的 JSON 导出于遮蔽后的远程端点重建稳定的连接 ID，使完整地址无法经由内部 ID 泄露。只有显式的内部选项 `include_remote_addresses=true` 才保留原始 ID。
- 严格 JSON 解码器默认 4 MiB、深度 64、100000 个值节点，并以线性方式扫描数字 token。编码器会把字符串值和对象键中无效的 UTF-8 替换为 U+FFFD。该节点预算独立于布局/YAML 各自的节点限制。
- 快照导出包含一个 `configuration` 对象，其中只有配置 `state` 和可选的 `reason`；内部的配置状态 `path` 不导出。
- `--report` 复用快照的脱敏白名单，以 Markdown 汇总硬件身份、当前读数、设备关系及所用来源质量。报告只调度其实际展示的硬件采集器，Linux GPU 不做逐进程 fdinfo 扫描；生成器不读取原始采集器表或文件。缺失来源保留状态与原因，不以零填充。当前报告标签为英文。
- `--stream` 先建立一次速率基线，之后逐行输出与 `--snapshot` 同模式的 JSON。持续采样遵守采集器各自的刷新间隔，不反复强制低频固件来源；每行写完即刷新 stdout。输出时刻更新每行的 `captured_monotonic_ns` 与来源年龄，未到期的来源保留自己的采样时间和序列。下游关闭管道的 EPIPE 正常结束并清理引擎，其他写入错误仍失败。`--count` 可限定输出行数。
- `--safe-mode` 用一个不执行任何命令的 Runner 替代默认实现，防止被注入的执行器绕过策略。它不会禁用普通的 procfs/sysfs 读取。

挂载采集器默认不会对网络文件系统、autofs、FUSE/`fuse.*`、`fuseblk` 或 `virtiofs` 调用同步的 `statvfs`，以避免远程或用户态守护进程停滞拖垮单线程事件循环。其他原生 statvfs 调用共享 50 ms 的准入预算。每次返回后和下一次调用前都会检查已耗时间；预算耗尽后，剩余的挂载会被跳过。这不是系统调用超时，进行中的调用无法被抢占，因此它仍可能超过 50 ms 或发生阻塞。被跳过的挂载保留身份，但容量/inode 变为 unavailable 或 partial，整体质量变为 estimated。这不能作为容量为零或挂载离线的证据。

程序默认以非特权身份运行，也从不安装常驻的特权辅助程序。提权是显式的，且只作用于当前这次进程调用。

## 10. 当前测试边界

- 现有的 162 个 Lua 单元/夹具测试文件覆盖：平台门控、procfs、sysfs、连接、cgroup v2、DRM fdinfo、GPU 频率/hwmon 连接、磁盘/挂载与 hwmon 的设备拓扑联接、异构 CPU 清单、powercap、SMART、PMU、布局、i18n、输入、渲染器、Runner 隔离、资源预检、权限处理、pidfd 操作、JSON 边界、导出隐私、无硬件环境下的驱动树、离线检查器重放、进程采集的规模限制、sudo 文件访问策略、主机或显卡必须提供的最小 GPU 能力、Lua 代码树内的版本收敛、原生模块与 SBOM、内存带宽能力声明、Insights 的 Collectors 表中采集器与槽位的对应关系、`truncated` 结果质量及其原因，以及发布证据——glibc 基线、内嵌 ELF 下限、构建身份和发布 SBOM。
- PTY 冒烟测试覆盖 `40×10`、`60×20`、`80×24/25`、`80×50`、`160×24`、`200×22`、`180×45`、窗口缩放、CJK、按键路径、备用屏幕恢复和布局持久化。
- onedir/onefile 构建后有针对 CLI、快照和 PTY 的目标。
- `tests/support/` 下三个共享测试辅助模块各有自己的测试，因为一个被十几个调用方使用、自身却没有测试的辅助模块，其正确性只是碰巧由哪些调用方使用它而决定的意外。`test_makefile_readers.lua` 在一个合成本地 Makefile 上固定了 Makefile 读取器的行为，该 Makefile 带有本项目并不使用的形态——本项目的 Makefile 正是那些它所钉住的缺陷处于蛰伏状态的原因。`test_fixture_fs.lua` 钉住的是“合并不得改变夹具所声明的内容”这一性质，而不是声明种类的清单，因为清单会成为同一事实的第三份副本；`merge` 曾经把 `errors` 整个丢掉，于是一个回答 `ENODATA` 的驱动被变成了一份“文件不存在”的记录。`test_hardware_fixtures.lua` 是第三个，它那里的缺口更糟：另外两个模块是在构建东西，而这个模块本身*就是*证据——每个需要本项目没有的硬件的采集器测试都从它那里取一棵树并采信它，因此一个自相矛盾的夹具不会让测试失败，反而会让读到它的测试通过。它按性质审计全部十二个夹具，并且不点名任何路径。
- 夹具文件系统必须像产品回答的那样回答，否则它断言的就是一个不存在的文件系统。`path_type` 曾经做不到，具体表现在两个以 `native.path_type` 为度量的方面（除非另有说明否则用 `lstat`，且 `S_ISREG` → `regular`）：它先问 `directories` 再问 `links`，于是类设备目录——每个 `/sys/class` 设备都是，而夹具恰恰因此把它声明为符号链接——返回的是 `directory`，而产品回答的是 `symlink`；它在产品回答 `regular` 的地方回答 `file`。前者不是表面问题。`collectors/cgroup.lua` 把符号链接计为跳过的条目以避免走入环，而覆盖该分支的那个测试传入的是一个*私有*文件系统，它回答 `symlink`——于是共享的那个文件系统便可以在唯一真正要紧的方向上错下去，而对于任何使用它的测试，那个分支都不可达。那个私有文件系统本身就是同一事实的第二份副本，两份副本还曾互相矛盾；现在与产品一致的是共享的那份。
- `FS.new` 会为每一个未显式提供的访问器替换为真实实现，这正是它能在生产环境使用的原因——`FS.default` 就是 `FS.new()`——但它也是自以为密闭的测试的陷阱。它过去还会忽略自己不认识的选项键，而代价是在测试而不是在报告中度量的：两个替身把自己的 readlink 实现拼成了 `readlink`，而真正的名字是 `read_link`，于是这个键被接受、被保留、却从未被读取，真实的 readlink 取而代之。两个测试中的一个所测的采集器从不询问符号链接，所以什么都没变；另一个测的是 `system_info`，它通过 `readlink("/etc/localtime")` 解析时区，因此那个测试一直在**把本主机的时区读进自己的样本，并且对它没有任何断言**——即使在一台根本没有 `/etc/localtime` 的主机上，它也会继续通过。`FS.new` 现在会拒绝它不认识的选项键，并同时报出键名和它接受的键集合，两半都被钉住了：拒绝必须能说清是哪个键，而它接受的每个键必须仍然被接受，否则“拒绝你无法解释的东西”就会变成“拒绝一切”。这个拼写错误现在在构建树的当场就是一个硬性失败。
- 质量与状态词汇表位于 `src/wtop/model/quality.lua`，由快照模型、调度器和检查器模型读取。它们过去被书写了三遍，而且副本已经互相漂移——快照的那份有十一个条目，另外两份各十个，缺的那个正是 `truncated`——对于三个发布方谁都不会发布的一个标签，它们还各执一词：检查器拒绝它并点名它，调度器在状态为 `ok` 时把它向上取整为 `fresh`，快照做过同样的事，直到这份宽容的重写被移除。这个项目知道正确的形态，却有三份副本，其中只有一份是对的。`core/runner.lua` 的状态列表则刻意*不*共享：它是子进程执行器的词汇表，共六个条目，包含 `timeout` 和 `cancelled`，而一个资源读数绝不可能是这两者，把它合并进来会是反方向的同一个错误。`tests/unit/test_core_primitives.lua` 把收敛性作为性质钉住——每个门都必须接受每个已发布的标签、拒绝同样的标签——因为一份清单会以同样的方式漂移，而且调度器的门是通过 `tick` 询问的，而不是通过一个为测试导出的规范化器。
- 采集器的 id 是它自报的名字，快照槽位是消费者读取的名字，因此 `Snapshot.merge` 通过 `ID_TO_RESOURCE` 把前者解析到后者，并且只有当解析出的名字是已知槽位时才写入数据。实测全部十七个已注册采集器都能到达槽位——九个经由映射，八个因为自己的 id 本来就是槽位名——因此一个加了映射项之外的新采集器会每个周期都被采集却永远不显示，而且没有任何提示。这就是静默丢弃的方向，而映射是手写在与拥有这个事实的注册表旁边的，所以它是一个副本。它已经漂移过一次：`psi` 的条目指向一个不存在的采集器，这无害，因此是个陷阱而不是笔误——一个取了那个名字的采集器会被解析到真正的 `pressure` 槽位。`Snapshot.RESOURCE_IDS` 导出了这份映射，使副本可以被检查而不是被采信，因为 `resource_for_collector` 只回答一个 id 去哪里。`tests/unit/test_core_primitives.lua` 中的三个子句把这一关系作为性质钉住：每个已注册 id 都到达一个槽位，没有两个 id 到达同一个槽位，没有条目指向不存在的采集器。
- Insights 的 “Collectors” 表通过自己的手写 `COLLECTOR_RESOURCE`，从采集器写入的快照槽位中读出该采集器的状态、质量和原因。它是上面那套关系在另一个文件里、为另一个消费者准备的第二份副本，而且它同样漂移过：十七个已注册采集器只有十六条，缺的是 `inventory`。缺一个条目不等于跳过了一行——`collector_rows` 读到 nil 槽位，会在一个可能正在发布 `truncated` 或失败原因的采集器旁边打印出 `ready` 和两个破折号，于是这一行看起来仍是一行。`tests/unit/test_view_model_collectors.lua` 把这一关系作为一个性质钉住，并且向注册表发问而不是复述它：每个已注册采集器的行必须显示该采集器所写入槽位的原因，其中每个槽位都被赋予一个点名自身的原因。单这一条子句对“缺条目”和“条目指向邻居的槽位”两种错误都会失败，而后一种恰恰能骗过“它是不是真实槽位名”的检查。
- 一种产品测量到却不发布的降级。设备清单把列表约束在 256 条 PCI 和 128 条 USB，电源列表约束在 16 条，因此设备多于这些上限的主机发布的行数从来就少于它数到的——而结果读作 `fresh`，带一个按资源的布尔值，**完全没有原因**；电源列表却因同样的原因发布了 `truncated` 作为结果质量，同样没有说明为什么。两者现在都携带 `device_enumeration_truncated`：一个成因，一个代码，原因列已经在采集器自己的行内。标签用 `truncated` 而不是 `partial`，因为现存的数据是当下且精确的，缺的只是有界列表的尾部，这正是 `docs/MONITORING.md` §4 所述。`test_inventory_collector.lua` 和 `test_system_collectors.lua` 各构造一个超出上限一条的夹具——257 和 129——因为一个断言采集器从未产生的截断结果的守卫，断言的是夹具本身；它们还钉住了边界本身：恰好*在*上限处的一条是 `fresh` 且无原因。
- 一个不可能失败的夹具等于什么都没测。`test_no_data_absence.lua` 是针对 `ENODATA` 的测试，它的 powercap 断言无论夹具的 errno 声明存在与否都成立：驱动拒绝声明的属性和根本不存在属性，采集器得到的样本一模一样，因此断言必须移到文件系统边界上——那是唯一能让两者区分的层。它的四个子句不点名任何路径——已声明的 errno 必须是文件系统实际提供的，至少三条路径必须回答 `unavailable` 以覆盖全部三种采集器形态，以及清除声明必须改变夹具报告的内容。
- 上一条论断是一次比较，而比较只有在可能失败时才算证据。成就它的那个子句——两条路径产生相同样本——用到了三件工具才做对，前两件各自都会发布一个自信的错误答案。最初的序列化器按字符串化后的键查值，于是数字键得到 `nil`，整个数组从未进入比较。下一件在整个遍历中共用同一个 `seen` 集合，而样本从两处同时到达它的三张区域表，于是区域拿到哪种渲染由 `pairs` 顺序决定：一个固定样本有 19 种不同的文本，断言在 200 次运行中有 3–10 次失败。第三个缺陷在样本而不是工具里——`timestamp_ns`、每个区域的 `observed_at_ns` 和 `duration_ns` 都是墙钟读数，而本主机的时钟是以 10 ms 为步进的 `/proc/uptime`，因此相隔不到一毫秒采到的两个样本只要落在同一个 tick 内就彼此相等，这正是该断言最初能通过的原因。序列化器现在是其所接受值的纯函数（循环守卫限定在被遍历的路径内，数组条目包含在内），采样时则通过 `context.now_ns` 钉住时钟，也就是 `Common.now_ns` 早已提供的注入点。两半各有自己的对照，缺少它便会失败；而一次从未被人看着失败过的比较所得到的空结果，不是测量。

部分选定的构建与测试入口使用非并行的资源预检，检查可用内存、交换空间余量、内存 PSI 和每 CPU 负载。主机不健康时，拒绝执行校验而不是加大压力。该预检与硬件夹具覆盖相互独立。

这些测试不是真实的硬件矩阵。发布证据仍缺少多种架构/libc/较旧内核、真实 NVIDIA/AMD/Intel/无 GPU 主机、USB/SAS SMART 桥接以及跨平台 PMU 对比。也没有固定硬件的长期性能回归基线。
