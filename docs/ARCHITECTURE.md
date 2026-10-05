# 当前架构

本文档描述的是 `0.1.0` 的实际结构。文中不会把规划中的插件、Insight Engine 或厂商 GPU 提供方当作已实现的能力来介绍。

## 1. 数据流

```text
/proc · /sys · cgroup v2 · DRM
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
      8-page Workspace + widgets
              │
              ▼
      virtual cell grid → diff renderer → terminal
```

默认的连续采集路径不依赖任何外部 CLI。`smartctl`、`perf`、`sleep` 和 `systemctl` 仅由按需运行的检查器（Inspector）使用，并通过受限的 Runner 启动。唯一的厂商 GPU 库是 NVML：`libnvidia-ml.so.1` 在运行时发现即加载，安全模式下则跳过。目前没有 AMD SMI 或 Level Zero 提供方。

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
  inspectors/           SMART, RAM bandwidth, and sshd on-demand Inspectors
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
  layout_store.lua       `layout.yml` schema v1-v3 reader, v4 layout-and-columns writer
  workspace.lua          tabs, the edit-mode tree, named workspaces, the edit banner
  actions.lua            process-identity revalidation and pidfd signal actions
native/wtop_native.c     libc-only Lua C module
locales/                 authoritative built-in `.yml` translation catalogs
tools/                   locale, toolchain, build, and checking tools
tests/                   unit/fixture and real-PTY smoke tests
```

十个固定页面按顺序为 `overview`、`processes`、`compute`、`memory`、`storage`、`network`、`gpu`、`workloads`、`system` 和 `insights`。目前页面和控件不能新增或删除。

## 3. 运行时

### 3.1 Lua 与原生模块

- 发布工具链以 PUC Lua 5.5.1 为目标，不使用 LuaJIT。纯 Lua 测试继续覆盖与 Lua 5.4 兼容的子集。
- `wtop_native.so` 必须与其加载的 Lua 运行时保持一致的 major.minor ABI。
- 交互式 TUI 需要 Linux、原生模块以及 TTY 标准输入/输出。没有 TTY 时，请使用 `--snapshot` 输出 JSON。

原生模块目前提供：原始/备用屏幕（alternate-screen）的终端生命周期管理、终端尺寸、`poll(2)`、信号与窗口尺寸变化处理、单调/实时时钟、睡眠、文件系统辅助函数、`statvfs`、`wcwidth`、原子写入、受限的 argv Runner、身份查询、`execve` 以及 pidfd 信号发送。原生 `readfile` 采用非阻塞、不跟随符号链接的打开方式，仅接受普通文件，默认上限 4 MiB、显式上限 64 MiB，并拒绝符号链接、设备文件、FIFO 和超大内容；以普通文件形式呈现的 procfs/sysfs 伪文件仍可读取。该模块不包含任何控件、布局、翻译、采集器或厂商 GPU 库。

### 3.2 事件循环

TUI 使用单线程调度器；Lua UI 状态与采集器都运行在主线程上。每次迭代中，事件循环最多等待 100 ms，以获取终端输入或到达下一个采样截止时刻。仅当发生输入、窗口尺寸变化、采样完成或显式失效时 UI 才会被标记为脏（dirty），此后渲染器只输出与上一帧相比发生变化的单元格序列。这里没有固定的“10–15 FPS”承诺。

同步的外部检查器可以在其超时预算内占用主线程。目前没有基于厂商 API 的工作线程池，也没有后台检查器队列。

## 4. 采集器与快照

引擎（Engine）按固定顺序注册采集器，包括：

```text
cpu, cpu_info, memory, pressure, disk, network, connections,
process, gpu, cpufreq, hwmon, powercap, mounts, cgroup
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

### 4.1 高基数扫描

- 进程采集器默认最多枚举 8192 个 PID 的基本 `/proc` 字段。只有 TUI 中当前选中的进程才会触发更深入的读取，例如命令行、I/O 和 cgroup。进程模型最多保留 2048 行。
- 线程详情是第二个、更窄的选中项，随采样上下文携带，记为 `selected_thread_ids[pid] = tid`，与进程选中项并列。采集器随后读取该 TID 的 `status`、`cgroup`、`io`、`schedstat` 和 `sched`，共五个文件；读取量由选中项限定，而不受线程数量影响，因此一个拥有一千个线程的进程仍然只花五个文件的代价。该映射以 pid 而不是进程 id 作为键，因为 TID 只有与其所属进程放在一起才有意义，而已不存在的进程所对应的条目永远不会被匹配到。线程级的读取在选中后的下一个 tick 落地，因此浮层在此之前渲染为挂起（pending）状态。
- 运行队列相关数字读取 `schedstat` 而不是 `sched`，因为前者是固定的三个数字的 ABI，而后者是调试转储，其键随内核版本和编译配置变化；`sched` 仅按白名单解析调度策略，其余一概不用。每个已打开线程的上一次 `schedstat` 读数保存在采集器上而不是样本中，因此缓存量只取决于操作者实际检查过的线程数；其速率跨度是该线程自上次的真实间隔，而不是被重新缩放成单个 tick。
- 采样上下文在进程和线程选中项之外还携带 `visible_process_ids`，采集器恰好为这些 PID 读取 `/proc/<pid>/schedstat`。该集合在渲染阶段、滚动偏移稳定之后发布，因此测量到的就是绘制出的内容；其上限为 256 个条目，超出上限的集合会被拒绝而不是被采纳，这样畸形的上下文就无法把视口测量变回对整个 procfs 的扫描。进程级和线程级速率共用一份备忘录（memo）和同一个求差辅助函数，键是携带 pid 与 starttime 的身份标识，因此两种粒度不会互相矛盾，而一个被回收复用的 id 根本不会产生速率。
- 进程表的列集合是纯模型层的事务（`model/process_columns`）：一份目录、一个规范化器、两个操作。视图模型持有列的*定义*，并向模型询问顺序，因此一列不可能在一个文件里描述、却在另一个文件里排序。渲染器不受影响：`priority` 和 `full_only` 仍决定小面板丢弃哪些列，这与用户的决定是两回事。
- 仅当网络页上的连接表具有实际的可见位置（placement）时，连接属主扫描才会跟随进程 fd 链接。标准的 JSON 快照不执行属主扫描。
- 仅当 GPU 页上的 `gpu_process_table` 具有实际的可见位置时，GPU 采集器才会扫描标准 DRM fdinfo 以构建逐客户端/逐进程数据。仅仅打开 GPU 页或 Insights 页并不会触发它。概览页和后台采样只收集设备摘要。GPU 页最多显示 512 条进程级摘要，完整的客户端/区域细节仍保留在快照/JSON 模型中。非交互式快照会显式执行完整扫描。
- cgroup 采集器有深度和节点数限制。它暴露原始的 cgroup v2 层级结构和内核统计信息，不解读 systemd 单元或容器的语义。
- 它也是唯一一个必须在向下深入之前先知道*路径是什么*的采集器：cgroup 树内部的符号链接可能指回树内，而扫描是一次有界行走而不是遍历，因此回答为 `symlink` 的条目计为跳过，无法回答的条目则不下探。所以 `Cgroup.new` 会拒绝一个不能回答 `read`、`list`、`readlink` 和 `kind` 的文件系统，并指出缺的是哪一个。这里没有兜底回答。这个理由值得记录下来，因为兜底回答正是代码过去的行为：一个没有 `kind` 的对象会被当作“每个条目都是目录”来读取，而这恰好是唯一会让符号链接规避机制失效的答案；它过去只可能被一个不完整的测试替身触及——`FS.default` 总是全部回答。`test_cgroup_collector.lua` 中有两个替身依赖了这一点，于是节点和广度预算断言穿过的其实是产品代码写死的一个常量，而不是文件系统，而建立在其上的有界行走断言，实际断言的是那个常量。

连接、挂载、工作负载和 GPU 进程的视图模型行预算均为 512。达到上限的采集器会把资源标记为 `partial`/`truncated`；仅影响显示的限额不会改写采集器的质量。进程/GPU 进程和连接状态会提供总数线索，而挂载表和工作负载表目前没有单独的视图模型容量指示。因此，一个对象没有被显示，绝不能解读为它不存在。布局求解器把位置（placement）传给视图模型，因此隐藏的表不会构建高基数的行数组。

精确的限额和隐私边界见 [MONITORING.md](MONITORING.md)。

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

GPU 采集器只使用 DRM、sysfs、procfs 和有界的本地 `pci.ids` 查询：

- 它从 card/render 节点、PCI/sysfs、驱动链接和 PCI 名称构建设备身份。有 PCI BDF 时以 BDF 作为稳定 ID；否则使用估算的 DRM/sysfs 标识符。
- 它支持 AMD `gpu_busy_percent`、显存/可见显存/GTT、AMD DPM 频率，以及 Intel i915/xe 的 sysfs 频率路径。
- 它解析标准 DRM fdinfo 的引擎/周期/内存计数器，用于有界的逐客户端/逐进程聚合，并能在硬件没有忙计数器时推导出设备利用率兜底值。
- 在暴露时，它记录 PCI 类别、修订版、正确嵌套的 `pci.ids` 子系统名称、boot-VGA、NUMA、PCIe 链路、运行时电源管理（runtime-PM）和 modalias 元数据。
- 它发现关联的 hwmon 路径并存储 `hwmon_refs`，但不会在 GPU 采集器内部重复读取温度、功耗或风扇。

视图模型通过 `hwmon_refs`、hwmon `class` 和规范化后的 `device_target` 把全局 hwmon 快照连接进来。多个通道匹配时，它取最高温度和最高功耗，而不是把重叠的电源轨相加；原生 GPU 指标优先。GPU 页还有一个有界的进程表。没有匹配的传感器时，温度/功耗显示为 `—`，风扇目前也不在 GPU 表中显示。NVML 存在时按 PCI 地址连接：它填补 DRM 未提供的利用率、显存、时钟、温度、功耗、厂商 UUID 和逐进程 GPU 显存，并列出没有 DRM 节点的 NVIDIA GPU。目前仍然没有 AMD SMI/Level Zero 提供方、MIG、AMD `gpu_metrics` 或厂商操作。

## 7. 检查器

检查器只响应用户按键而运行，不参与连续采样。默认注册表恰好包含：

- `storage.smart`：选择一个 `/sys/class/block` 设备，然后调用 `smartctl`；结果缓存 60 秒；
- `memory.bandwidth`：枚举一组有限的 PMU 名称，并通过外部 `perf stat` 执行一次实验性的全系统采样；
- `service.sshd`：结合 `systemctl show`、进程快照和 `/proc/net/tcp*`。

当前检查器的输出是通用文本浮层，而不是完整的统一实体 UI。DIMM/EDAC、PCI/USB、RAID/LVM、服务日志/会话等类似来源没有注册为默认检查器。精确的能力与失败语义见 [DEEP_INSPECTION.md](DEEP_INSPECTION.md)。

## 8. 布局与状态

工作区（Workspace）为每个页面存储一棵二分分裂树。叶子引用一个固定控件；分裂节点有一个 `horizontal|vertical` 轴、一个比例、一个间隙，以及恰好两个子节点。编辑模式支持选中叶子、按方向移动它、调整最近的父分裂比例，以及每页最多 50 步撤销/重做。

`$XDG_CONFIG_HOME/wtop/layout.yml`（或 `~/.config/wtop/layout.yml`）可以读取旧版 schema v1 的有序列表、schema v2 的分裂树、schema v3——它在完整的逐页树集合之外新增了命名工作区，并带有 `active` 标记——以及 schema v4，它在文件已有的三种主体之旁新增顶层 `process_columns` 列表。布局本身没有改变：v4 是同样的三种形态只多了一个键，读取时按主体区分，因此页面是分裂树的 v4 文件按树读取，页面是扁平 id 的按 id 读取。v4 保持 v1、v2、v3 可读，且处在任一版本的文件都不报告列集合，因此进程表从默认列开始。一个从未打开过列编辑器的会话，会继续写入其主体一直写入的版本；版本号说明的是文件能装什么，而不是会话如何走到这一步。空的工作区集合不是损坏的集合：一个从未命名过工作区的会话仍写 v2，一旦列集合存在则写 v4。列集合属于会话而不属于某个工作区，因为用户关掉的一列不该在工作区切换时复活。列集合的读取是严格的——一串已知的稠密键，必须包含 `pid` 和 `name`——未知的键、重复的键、空洞或缺少标识列都会带着状态栏中的原因拒绝整个文件，而不是被修复，这样拼写错误就不会悄悄恢复用户已关闭的列。编码器则做规范化，因为它的契约是：它这次写入的，加载器必须能读回来，保存绝不能因为一个外观上的视图设置而失败。布局在 TUI 中被编辑后，通过 `q`、`Ctrl+C` 或被捕获的退出信号有序地退出事件循环时，会以 `0600` 模式原子保存。崩溃、`SIGKILL` 或断电没有恢复日志。校验限制包括 1 MiB、深度 32、511 个节点、间隙 0–16、`ratio_micros` 1–999999、已知的页面/控件、唯一的叶子，以及最多 16 个工作区，其名称长度 1–64 个字符，由字母、数字、空格、点、短横线和下划线组成。工作区名称写成**带引号**的 YAML 键，因为读取器的非引号键规则不接受空格：一个名为 `my setup` 的工作区曾被写成裸键，然后在下次启动时被同一个加载器拒绝，于是退出保存把一个好文件替换成了谁也读不了的文件，而单代备份里保存的同样是那段坏文本。命名规则写在两个文件中——`workspace.lua` 和这个存储模块——有一个测试断言两者一致，因为模型接受而存储拒绝的名称是一种静默丢失，而不是表面上的分歧。`rename_workspace` 移动一个名称并携带其存储的树，它刻意不用实时树覆盖目标重新保存——那正是“以新名称保存、再删除旧名称”会做的事——并且拒绝使用已占用的名称，而不是把两套布局合并到一个键下。每个版本都有精确的键集合，因此版本未定义的键会让整个文件被拒绝，而不是读了再忽略。缺失的固定控件会被追加，缺失的页面使用默认树。未知字段会拒绝整个文件——随后会先尝试 `layout.yml.bak`，其中保存着上一份可读的旧内容，每次成功加载后和每次保存前都会刷新它，然后才回退到默认布局；`config.yml` 遵循同样的备份与恢复契约，对应 `config.yml.bak`。恢复出的文件会在状态栏中报告，而不是静默切换到默认。这是单代的尽力备份，不是版本历史。

不要把布局版本与主配置混淆：`config.yml` 仍然使用 schema v1。模式定义与按键绑定见 [UI.md](UI.md)。

布局编辑模式下页脚的静止状态是 `LAYOUT` 横幅，它由工作区模型持有——但模型只持有横幅。瞬时消息的优先级高于它，而 TUI 其余的状态（布局保存错误、权限标记、进程过滤器、数据年龄）会照常透传，而不是被丢弃。横幅过去会替换整个状态表，而工作区管理器*只*在编辑模式下可达，于是该管理器产生的每一条确认——删除、切换、重命名——都发生在无处展示它的地方。替换掉横幅的消息会在编辑模式结束时离开，因此横幅不是一条单行道。

CLI/配置中的主题值只接受五个确切的内置名称。未知的 CLI 值立即报错；未知的配置值会拒绝整个配置、回退并报告错误。Locale 标签会做语法校验和规范化，但一个合法的未知标签可能在 TUI 加载 XDG 用户目录中的目录后成为当前语言。`--snapshot` 和 `--diagnose` 不创建翻译器，也不扫描用户目录。

## 9. 身份、安全与隐私

- 进程操作使用 `(pid, starttime_ticks)` 身份。Lua 层重新校验 `/proc/<pid>/stat`；原生层随后持有 pidfd，再次校验，并且只发送白名单内的信号。TUI 当前的 `k` 操作只发送 SIGTERM，且需要确认。
- GPU 优先使用 PCI BDF。没有 BDF 时身份质量记为 estimated。目前没有厂商 UUID。
- 外部程序必须使用绝对可执行路径，argv 不得经过 shell 拼接。Runner 控制文件描述符、环境变量、进程组、超时和输出大小。
- `--sudo`/`--elevate` 通过固定的系统 `sudo` 路径、以精简消毒后的环境变量重新执行当前调用；直接使用 `sudo wtop` 也会被识别。不存在常驻的特权守护进程，也没有可变的 shell 命令辅助函数。
- 布局以 `0600` 模式原子保存；主配置是只读的。
- 网络页默认显示完整的端点、Unix 路径、UID 和已发现的属主；`m` 在连接表中切换远程地址遮蔽（启动时可用 `mask_remote_addresses` 配置）。JSON 快照默认遮蔽远程 IP 地址，但不遮蔽本地地址、端口、Unix 路径、MAC 地址或属主。两个界面共用同一份遮蔽实现。见 [MONITORING.md](MONITORING.md)。
- 默认的 JSON 导出于遮蔽后的远程端点重建稳定的连接 ID，使完整地址无法经由内部 ID 泄露。只有显式的内部选项 `include_remote_addresses=true` 才保留原始 ID。
- 严格 JSON 解码器默认 4 MiB、深度 64、100000 个值节点，并以线性方式扫描数字 token。编码器会把字符串值和对象键中无效的 UTF-8 替换为 U+FFFD。该节点预算独立于布局/YAML 各自的节点限制。
- 快照导出包含一个 `configuration` 对象，其中只有配置 `state` 和可选的 `reason`；内部的配置状态 `path` 不导出。
- `--safe-mode` 用一个不执行任何命令的 Runner 替代默认实现，防止被注入的执行器绕过策略。它不会禁用普通的 procfs/sysfs 读取。

挂载采集器默认不会对网络文件系统、autofs、FUSE/`fuse.*`、`fuseblk` 或 `virtiofs` 调用同步的 `statvfs`，以避免远程或用户态守护进程停滞拖垮单线程事件循环。其他原生 statvfs 调用共享 50 ms 的准入预算。每次返回后和下一次调用前都会检查已耗时间；预算耗尽后，剩余的挂载会被跳过。这不是系统调用超时，进行中的调用无法被抢占，因此它仍可能超过 50 ms 或发生阻塞。被跳过的挂载保留身份，但容量/inode 变为 unavailable 或 partial，整体质量变为 estimated。这不能作为容量为零或挂载离线的证据。

程序默认以非特权身份运行，也从不安装常驻的特权辅助程序。提权是显式的，且只作用于当前这次进程调用。

## 10. 当前测试边界

- 现有的 120 个 Lua 单元/夹具测试文件覆盖：平台门控、procfs、sysfs、连接、cgroup v2、DRM fdinfo、GPU 频率/hwmon 连接、磁盘/挂载与 hwmon 的设备拓扑联接、异构 CPU 清单、powercap、SMART、PMU、布局、i18n、输入、渲染器、Runner 隔离、资源预检、权限处理、pidfd 操作、JSON 边界、导出隐私、无硬件环境下的驱动树、离线检查器重放、进程采集的规模限制、sudo 文件访问策略、主机或显卡必须提供的最小 GPU 能力、Lua 代码树内的版本收敛、原生模块与 SBOM、内存带宽能力声明、Insights 的 Collectors 表中采集器与槽位的对应关系、`truncated` 结果质量及其原因，以及发布证据——glibc 基线、内嵌 ELF 下限、构建身份和发布 SBOM。
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
