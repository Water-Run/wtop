# 监控范围与性能操作

> 本文档区分 `0.1.0` 中已实现的持续采集器与后续目标。对于“当前实现”中未列出的提供方,不得从设计目标推断其存在。

## 1. 数据源原则

- 持续采样优先使用 Linux 的 procfs、sysfs、cgroup 和 DRM。外部 CLI 仅保留给按需运行的 Inspector。
- 每个采集器先探测能力。不支持、权限不足和出错三种状态必须与数值零区分开。
- 累计计数器的速率只由相邻的单调时钟样本计算得出。首次采样、计数器复位、热插拔事件和采样缺口一律不用零填充。
- 高基数扫描设有显式上限,达到上限或部分路径被拒绝时返回部分/估算结果。
- 外部辅助进程以绝对路径 argv、精简的环境变量、超时、取消、输出上限和进程组清理运行,绝不经过 shell。

## 2. 当前采集器矩阵

CLI 默认 `--interval 1000`。活动页面使用基准间隔与采集器下限中的较大者。非活动页面以更低频率继续采样,以保留较短的历史记录。

| 资源 | 当前数据 | 主要来源 | 默认前台 / 后台 |
| --- | --- | --- | ---: |
| CPU | 整体/每逻辑 CPU 利用率、负载、上下文切换、中断、进程数 | `/proc/stat`, `/proc/loadavg` | 1 s / 2 s |
| CPU 身份信息 | 厂商/型号/架构、异构核心类型、算力/最高频率/SMT 宽度、封装/核心/线程数、online/present/isolated CPU、缓存清单 | `/proc/cpuinfo`、CPU 拓扑/缓存/cpufreq sysfs | 按需 / 低频 |
| 内存 | 总量/可用/已用,cache/slab/匿名页/脏页/回写页,共享内存,mapped,页表,内核栈,对照 commit limit 的已提交量,hugepages,Swap,zswap,选定的 vmstat 值,以及用于堆叠展示的不重叠的 已用/共享/缓冲/缓存/空闲 划分 | `/proc/meminfo`, `/proc/vmstat` | 1 s / 5 s |
| PSI | CPU/内存/I/O 的 `some`/`full` 平均值/总量 | `/proc/pressure/*` | 1 s / 2 s |
| 块设备 | 字节/秒、IOPS、繁忙度、在途请求、队列长度、估算的读/写延迟,以及每盘型号/厂商/固件、容量、是否 rotational、可移除标志、当前调度器、队列深度和预读 | `/proc/diskstats`、block sysfs | 1 s / 3 s |
| 网络接口 | 字节/包/错误/丢包速率,operstate,MTU,MAC,载波/双工,可用时的链路速率,默认路由族,以及带掩码、广播地址和对端地址的 IPv4/IPv6 地址 | `/proc/net/dev`, `/sys/class/net`, `getifaddrs(3)` | 1 s / 3 s |
| 套接字 | TCP/TCP6/UDP/UDP6/Unix 的端点、状态、队列、UID、inode;可用时的 PID/fd/名称属主,`owner_count` 只在真正执行了查找的地方发布,而不是填零 | `/proc/net/*`, `/proc/<pid>/fd` | 2 s / 10 s |
| 进程 | `(pid,starttime)`、PPID、状态、CPU、累计 CPU tick、RSS/VSZ、线程数、优先级/nice/CPU、解析为本地用户名的 UID,以及完整命令行;针对选中线程:线程组、累计及每秒自愿/非自愿上下文切换、被抢占占比、I/O、cgroup 归属、运行队列等待、时间片与调度策略;所属进程的 PSS/USS,标注为该进程自身的数据 | `/proc/<pid>/stat`, `status`, `cmdline`, `/proc/<pid>/task/<tid>/{stat,status,io,cgroup,schedstat,sched}`, `/proc/<pid>/schedstat`, `/proc/<pid>/smaps_rollup`, `/etc/passwd` | 1 s / 5 s;五个 per-thread 文件只读取选中 TID 的那一个,`/proc/<pid>/schedstat` 只读取视口正在显示的进程行 |
| CPUFreq | 策略/CPU 集合、当前/最低/最高频率、驱动、governor、boost/EPP | cpufreq sysfs | 1 s / 5 s |
| hwmon | 温度、风扇转速、电压、电流、功率、能耗、阈值/告警/故障;识别 `temp1_crit_alarm` 这类带限值的告警形式以及裸 `temp1_alarm` 形式;电压通道从 `in0` 起向上读取;过滤已知的无效哨兵值;恰好为零的阈值,或 u16 温度哨兵值,按“驱动未设置该属性”丢弃,而不是当作一条界限上报;设备的 `device_target` 供视图层把读数归属到 GPU 或磁盘(磁盘标注带型号与挂载点),表与浮层共用同一联接 | `/sys/class/hwmon` | 1 s / 5 s |
| Powercap | 有界的 zone 层级、能量/直接功率、约束、防回绕/防复位的差值计算、独立的 CPU 封装与整机/`psys` 聚合;恰好为零的功率上限或界限,或驱动以 ENODATA 应答的属性,按“驱动未设置该属性”丢弃,而不是上报 | powercap sysfs | 1 s / 5 s |
| 挂载 | 挂载标识、文件系统/来源/只读状态,以及安全时的容量和 inode 数 | `/proc/self/mountinfo`, `statvfs` | 5 s / 30 s |
| 硬件清单 | 带厂商/设备名称的 PCI 和 USB 设备列表;显示在 System 页面并导出在 `inventory` 下。Linux 读取 sysfs 和本地 `pci.ids`;Windows 使用 SetupAPI PCI/USB 枚举器(无类代码);macOS 使用 IOKit `IOPCIDevice`/`IOUSBHostDevice`(Apple Silicon 上无 `reg` 地址) | sysfs + `pci.ids` / SetupAPI / IOKit | 30 s / 120 s |
| cgroup v2 | CPU/max/weight、内存/Swap/事件/上限、I/O 速率、PID/事件、PSI、cpuset | `/sys/fs/cgroup` | 2 s / 10 s |
| 系统标识 | 主机名/域名/架构、内核类型/版本/构建/命令行(密钥与机器标识参数已脱敏)、来自 os-release 的发行版、运行时间与启动时间、虚拟化与容器检测、SELinux/AppArmor/lockdown 状态、DMI 机器/主板/固件(占位字符串丢弃;序列号、资产标签和产品 UUID 永不读取)、描述符/PID/线程上限、熵、内核全局计数器、Swap 设备、时区 | `/proc/sys/kernel`, `/proc/uptime`, `/proc/stat`, `/proc/swaps`, `/proc/vmstat`, `/etc/os-release`, `/sys/class/dmi/id` | 5 s / 30 s |
| 电源 | 电池状态、相对设计容量的电量与健康度、归一化为瓦时的能量或电量、功耗、电压、循环次数、剩余或充满所需时间、外接电源是否存在 | `/sys/class/power_supply` | 5 s / 15 s |
| GPU | DRM 设备/节点标识、PCI 名称/链路元数据、选定的 AMD 繁忙度/显存、AMD/i915/xe 频率、DRM fdinfo 设备/进程数据 | `/sys/class/drm`, `/proc/<pid>/fdinfo`, 有界的本地 `pci.ids` | 1 s / 5 s |

`--interval` 接受 100..10000 ms。交互式 TUI 把初始值映射到九个命名档位中最近的一档:8s、5s、3s、2s、1s、0.75s、0.5s、0.3s 和 0.1s。点击右上角控件或按 `f` 可在运行时循环切换。这一操作不会绕过昂贵采集器的下限:GPU 500 ms;进程/CPUFreq/hwmon 1000 ms;套接字/cgroup 2000 ms;挂载 5000 ms。

上表中的每个速率都是 `Clock:now_ns()` 上的差值,时钟会标明取值的来源。来源名称是一个四元素封闭集合:`procfs_uptime` 表示读数取自 `/proc/uptime`;`process_clock_fallback` 表示读数由回退机制产生;`held` 表示因为新候选值比已有值更旧而返回旧值——这是单调时钟必须做的,但不是一次测量;`unavailable` 表示既无测量也无从测量。`--diagnose` 会打印它,并将其放入 JSON 报告的 `clock.source` 字段。

`held` 这种情况值得事先了解,而不是事后意外发现。默认回退是 `os.clock` ——进程自身的 CPU 时间,它与 `/proc/uptime` 是不同的量、不同的尺度,而不是它的第二份拷贝。因此,如果 `/proc/uptime` 在一次成功读取后停止应答,此后每个候选值都比手中的值更旧,单调钳制会拒绝它,**只要读取持续失败,时钟就停止推进**:所有速率都冻结在故障发生时刻的值上。这是安全行为——时钟倒退更糟——而它被命名而不是保持沉默的原因,是一条没有解释的冻结速率正是用户会当作 bug 报告的东西。

历史记录保存的是每个数据源实际完成采样的时间戳,而不是在其他无关采集器完成时重复旧值。每条 sparkline 的终端列覆盖固定的一秒,总计最多 240 秒。更高的速率向每一列贡献更多真实数据点,更低的速率则产生稀疏点,所以切换速率不会改变水平时间尺度。

`/proc/<pid>/cmdline` 在枚举期间读取,这样每一行都能显示真实的命令名;来自 `/proc/<pid>/stat` 的 `comm` 是十五字符截断,仅作回退。`/proc/<pid>/io` 和 cgroup 列表仍只对选中的进程按需读取,因此 I/O 列标注为累计总量而非速率。UID 到用户名的解析直接读取 `/etc/passwd` 而不是调用 `getpwuid(3)`,因为在配置了 LDAP 或 SSSD 的主机上,NSS 可能在渲染循环内阻塞数秒。交互式高基数 GPU fdinfo 扫描仅在 GPU 页面上的 `gpu_process_table` 经响应式布局求解获得实际位置时启用。仅仅切到 GPU 页面、显示 GPU 摘要或停留在 Insights 都不够。Overview/后台 GPU 采样仍只读取设备摘要,不枚举 `/proc/<pid>/fdinfo`。非交互式 `--snapshot` 保留完整扫描。

默认清单上限为 4096 个 DRM 类条目、32 张卡、64 个 render 节点、16 个 hwmon 引用和每设备 32 个频率域。进程扫描上限为 4096 个进程、每进程 1024 个 fdinfo 条目、总计 32768 个 fdinfo 文件、每文件 256 KiB 和 8192 个 client。命中任一上限都会把结果标记为 partial/truncated,而不是把未扫描的对象当作不存在。

进程采集器默认最多扫描 8192 个 PID。原生目录枚举在排序和逐 PID 读取之前,先按该预算加少量非 PID 余量截断。结果暴露 `process_candidates`、`process_limit`、`truncated` 和 `partial`。进程搜索/排序在已采集集合上运行,TUI 模型最多保留 2048 行。连接、挂载、workload 和 GPU 进程 ViewModel 各自最多构建 512 行;GPU 清单另有 32 张卡的采集器上限。连接、挂载和 GPU 进程选择有界的优先级子集,workload 保留按采集器顺序排列的前 512 行。采集器截断会显式添加 `partial`/`truncated`,部分采集器还会把质量降级为 estimated;纯 UI 的行数上限不会改写采集器质量。当 512 行模型上限丢弃行时,进程、GPU 进程、挂载和 workload 状态行显示 visible/total,连接状态显示采集器的套接字总数。可用资源数量和扫描状态仍需被考虑;一行未显示并不能证明该对象不存在。

NUMA、路由/netlink、smaps/PSS、调度器延迟和连续的内存带宽尚不在持续采集器集合中。SMART、内存带宽和 sshd 是按需 Inspector;见 [Deep Inspection](DEEP_INSPECTION.md)。

内存带宽 Inspector 不在调度器矩阵之内。按一次键会启动一次约 250 ms 的全局外部 `perf stat`/`sleep` 采样,使用有限的 data/CAS 事件名映射。部分方向、部分事件或多路复用的结果标记为 estimated。

**该 Inspector 的“ready”意味着什么:测量得出,而非假设。** 匹配 PMU 的探测并不运行 `perf`,也不校验权限,所以 `available` 只意味着一件事:存在内存控制器 PMU,且有东西可以被要求读取它们。它并不意味着计数器能够被打开。这个区别不是学术性的——它来自一台真实主机的实际行为。这里的一台开发机发布了白名单查找的全部四个 PMU 名称(`uncore_imc_0`、`uncore_imc_1`、`uncore_imc_free_running_0`、`uncore_imc_free_running_1`),且 `perf list` 在 free-running 对上列出了 `data_read`、`data_write` 和 `data_total`——正是读取器匹配的事件名。然而它们每一个在 `sys_perf_event_open` 上都以 `EINVAL` 失败,因为 free-running 计数器不是计数型 PMU。探测找到了四个 PMU 并报告 ready;第一次真实测量返回 `memory_events_not_supported`。因此能力记录现在携带一条理由,说明计数器存在但尚未被读取,该理由已在全部十份目录中翻译,Insights 行把它显示在 `ready` 旁边,而不是留空。一行先说了 ready 然后什么也不说,与没有哈希的 SBOM 是同一种缺陷。

本节刻意**不作**两个声明。其一,不声明 `perf_event_paranoid` 阈值,因为这台主机无法演示任何阈值:这些事件在任何权限检查之前就以 `EINVAL` 失败,带不带 `-a` 都一样。把一条未经测量的内核规则写进能力记录,正是本项目一直在清除的缺陷,所以理由只陈述探测所确证的内容。其二,不声明该 Inspector 普遍精确:`theoretical_bandwidth` 数值由内存拓扑计算得出并标记为 `estimated`,因为它是一个公式,并且它是该 Inspector 在计数器无法打开的主机上始终能给出的唯一数值——这就是为什么由拓扑导出的结果报告 `provider: memory_topology_formula`,而不是点名一个什么也没产出的读取器。

在完全没有内存控制器 PMU 的主机上——也就是普通笔记本电脑——来源为 `unavailable`,原因是 `memory_controller_pmu_not_found`,它不会作为待补缺口出现在建议列表中。`tests/unit/test_ram_bandwidth_claim.lua` 把这一切全部钉住:探测的理由、探测不打开任何计数器、理由到达渲染行、存在来源时不列为缺口、普通的无 PMU 情形,以及公式导出的数值保持标注。

Insights 是一个静态的能力/Inspector 入口摘要。它读取已有的有界后台样本来获得计数,没有前台采集器集合,也不会为了这些数字而以 1 Hz 采样进程或 GPU 数据。

### 2.1 缺失内核数据源意味着什么

wtop 没有最低 Linux 内核版本要求。没有任何东西会把启动挂在某个内核接口上:`Scheduler:probe_all` 在每个探测外包一层 `pcall`,失败或抛错的探测会变成一条能力记录而不是致命错误,内核无法满足的能力恰好只损失它自己的那份资源。`Snapshot.merge` 只在结果为 `ok` 时安装采集器数据,并且无论结果如何都会写一条质量记录,所以缺失的来源产生一条 `quality[resource]` 记录,携带 `status`、`quality` 和采集器给出的 `reason`——不是一个数字,也不是零。`--diagnose` 会点明读不了的路径,JSON 导出复现同一条记录。

`reason` 槽位在很长一段时间里只由*缺失*路径携带:彻底失败的采集器走 `Common.error_result`,而它一直会填写该槽。一个带着 `partial`、`gap` 或 `estimated` 质量持续运行的采集器则把它留空,所以一条降级但仍在运行的读数只说“partial”,给不出别的解释——这是唯一一种无法自我说明的降级读数。如今所有能想到的原因都已补上(一份无法解析的和一份无法读取的 `/proc/vmstat` 报告的是不同的理由,而不是同一个常量),并由 `tests/unit/test_core_collectors.lua` 在两端钉住:理由必须能穿过 `Snapshot.merge`,`Common.error_result` 必须继续说明原因,因为降级路径正是以它为基准来衡量的。**Pressure 是第二个补上这一点的采集器**,它是一个很好的第二个案例,因为它的事因确实是单一的:唯一会让 PSI 样本降级的情况是某个资源无法读取,所以聚合理由与 `data.errors` 中按资源给出的理由不可能在“是哪种原因”上相互矛盾。丢失了部分资源的样本报告 `not_all_pressure_resources_readable`;丢失了全部资源的样本保留自己的 status 与理由 `no_pressure_resources_readable`,因为一条不能指明原因的理由告诉快照读取者的,并不超过它从 status 已经得到的信息。**仍有十四个采集器完全不带理由**——cpu、disk、network、process、hwmon、gpu、cpufreq、powercap、cgroup、cpu_info、inventory、portable、power_supply 和 system_info。它们并不计算理由,所以补齐它们需要按采集器按事因逐个测量,而不是打个补丁;该事项作为未决项记录在 `docs/PLAN.md` 中,而不是用一个推导出的字符串敷衍。
这些采集器*确实*知道原因的地方,理由是数据内部的逐项信息(`mount.partial_reason`、`device.reset_reason`、`nvml_reason`),那是另一个通道、另一种粒度。

`tests/unit/test_engine.lua` 在模拟内核上把这一点钉住:该内核没有 cgroup v2、没有 PSI、没有 hwmon、没有 DRM、没有 powercap、也没有 cpufreq——引擎仍然探测、仍然 tick、保留所有有数据源的采集器,把每个缺失的标记为 `unavailable` 并附理由,不为它安装数据,并记录图表缺口哨兵值而不是捏造的零。它还钉住:一个*抛错*的探测仍然只是一条能力记录,以及一个带着非 `ok` 状态返回数据的采集器,不能与它写入的快照相矛盾。

| 来源根 | 快照资源 | 内核不提供它时会失去什么 |
| --- | --- | --- |
| `/proc/stat`, `/proc/loadavg` | `cpu` | 利用率、负载、上下文切换、中断;资源不可用时核心概览卡片被隐藏 |
| `/proc/meminfo`, `/proc/vmstat` | `memory` | 内存卡片、其划分明细和内存历史 |
| `/proc/pressure/{cpu,memory,io}` | `pressure` | PSI 图表;Linux 4.20 加入,因此 4.20 之前的内核恰好只失去这一项 |
| `/proc/diskstats`, `/sys/block/*` | `disks` | 块设备表及其速率 |
| `/proc/net/dev`, `/sys/class/net` | `network` | 接口速率与链路状态 |
| `/proc/net/*`, `/proc/<pid>/fd` | `connections` | 套接字表及其属主归属 |
| `/proc/<pid>/{stat,status,cmdline,task}` | `processes` | 进程表;隐藏其他用户进程的内核会把它收窄到调用者自己的进程 |
| `/sys/devices/system/cpu/cpufreq` | `cpu_frequency` | 频率卡片,隐藏而不是显示为 0 MHz |
| `/sys/class/hwmon` | `sensors` | 温度卡片,隐藏;由内核硬件监控子系统发布 |
| `/sys/class/powercap` | `power` | 功耗卡片,隐藏;RAPL 驱动仅 Intel 平台暴露 |
| `/sys/class/power_supply` | `power_supplies` | 电池条,无电池的机器上隐藏 |
| `/sys/class/drm` | `gpus` | GPU 卡片和每设备频率,无 DRM 驱动的机器上隐藏 |
| `/sys/fs/cgroup` | `workloads` | Workloads 页面;仅支持 cgroup v1 的主机没有按 workload 的记账 |
| `/sys/bus/pci/devices` 加本地 `pci.ids` | `inventory` | 设备列表;没有 `pci.ids` 时条目保留,但厂商和设备名称无法解析 |
| `/proc/self/mountinfo` | `mounts` | 挂载表,经由每个挂载点的 `statvfs(3)` |
| `/sys/class/dmi/id` | `system` | 仅 DMI 机器、主板和固件行;身份记录的其余部分相互独立 |

那五张被*隐藏*而不是留占位符的卡片,是若不隐藏就会被误读为真实测量的卡片:显示 0 MHz 的频率卡片、显示 0 W 的功耗卡片、显示 0 °C 的温度卡片,都是对机器的断言,而内核从未发布该属性的机器并没有作出这种断言。其余所有面板就地降级,保留应答了的采集器。

PSI 内部有一条内核版本边界值得点明,因为它看起来像缺陷,其实不是。内核文档说明:系统级 `cpu` PSI 的 `full` 未定义;内核从 5.13 起报告它;更早的版本为了向后兼容将其置零——所以 5.13 之前不带 `full` 行的 `/proc/pressure/cpu` 是预期形态,不是截断读取。wtop 从不显示系统级 `full`:每个消费方都读 `some`,JSON 导出仅在文件确实带有 `full` 行时才复制它。解析器接受只有 `some` 行的文件,拒绝两者皆无的文件,所以 5.13 之前的形态可以解析,而真正空的文件仍会失败。

- 属主扫描仅在 Network 页面的连接表获得实际可见位置时发生。上限为 1024 个进程、每进程 512 个 fd、总计 16384 个符号链接、每套接字 8 个属主。权限拒绝、PID/fd 竞态和上限会把属主质量降为 partial/estimated,而不是捏造缺失的属主。
- 离开 Network 页面后属主扫描停止;套接字表采样以更低频率继续。标准 `--snapshot` 同样保持属主扫描关闭。
- **`owner_count` 只在查找真正执行过的地方发布。** 由于除 Network 页面外扫描处处关闭,这意味着大多数时间不发布,非交互导出中处处不发布。在那里报告零计数等于说“没有进程持有这个套接字”,而同一条记录却说属主数据不可用——一行自相矛盾,在这台主机自己的 `--snapshot` 上让全部 256 个套接字(包括 sshd 的 22 端口)都读作无属主。因此,除非 `owners_quality` 为 `fresh` 或 `estimated`,否则该计数缺席;对被扫描且查找确实一无所获的套接字,计数会出现。`owners_quality` 与计数的缺席从两个方向说同一件事,所以只读其一的消费方仍然无法断定某个套接字没有属主。TUI 从不显示该计数——它按属主记录本身排序——所以这条保护针对的是导出及其下游,因为“这个套接字没有属主”正是有人会据以行动的陈述。同一规则也适用于 Windows 和 macOS 后端:无法归属套接字的平台(SP2 之前的 Windows XP 没有属主 PID)同样报告质量而不是零。
- TUI 默认显示完整的本地/远端端点、Unix 套接字路径、UID 和可见属主。在 Network 页面按 `m` 可遮蔽连接表中的远端地址以便屏幕共享;在 `config.yml` 中设置 `mask_remote_addresses: true` 可从启动起进入遮蔽状态。该开关只影响表格显示的内容。
- JSON 快照默认把远端 IPv4 地址的最后一组替换为 `x`,较长的 IPv6 地址只保留前两组。导出的连接 ID 由遮蔽后的远端端点、本地端点、状态及相关字段稳定重建,因此不会保留包含完整远端地址的内部 ID。该遮蔽器不改远端端口、本地地址、Unix 路径、接口 MAC 地址或已有的属主字段。`--snapshot --unmask-remote-addresses` 是获得完整远端地址的唯一 CLI 路径;它同时保留完整远端地址和原始 ID。配置文件的 `mask_remote_addresses` 只管辖交互式表格,绝不会解除导出的遮蔽。

遮蔽契约,逐字段说明:远端 IPv4 地址保留为 `a.b.c.x`;超过两组的远端 IPv6 地址保留为 `a:b:…`;远端端口、本地地址与端口、Unix 套接字路径、接口 MAC 地址和属主身份永不遮蔽。TUI 开关和 JSON 导出器使用同一段遮蔽代码,所以两个界面对遮蔽端点的形态不会不一致。采集器和 Snapshot 模型在内部保留完整远端地址;遮蔽发生在显示边界和 JSON 导出边界。这不是一种“完整地址从不进入进程内存”的隐私模型。

## 9. 数据质量

| 状态 | 含义 |
| --- | --- |
| `fresh` | 当前样本可用 |
| `stale` | 上一次样本没有安装,正在显示保留值。这**不是**期限:保留了一个采样间隔的值就已经是 `stale`——快照路径完全不查阅任何新鲜度期限,它是在第一个无法安装的结果上重新标注的 |
| `gap` | 首个样本、时间间隙、累计计数器复位或不可计算的差值;具体的复位原因可以记录在资源上 |
| `estimated` | 使用了估计值或不完整的映射 |
| `unavailable` | 平台/驱动缺少该能力 |
| `denied` | 能力可能存在,但当前权限不足 |
| `error` | 读取或解析失败 |
| `truncated` | 有界的枚举在上限处停止,列表比总数短且没有任何东西失败;在场的数字是当前且精确的,缺少的是列表的尾部,这也是它不是 `partial` 的原因。两个采集器把它作为结果质量发布——设备清单和电源列表——并都携带原因 `device_enumeration_truncated`,因为事因是同一个,而原因列已经写明该行属于哪个采集器 |

`partial` 通常是资源或扫描报告上的布尔标记,同时也是结果质量;`truncated` *也*是结果质量——对上表中点名的两个采集器而言,所以区别不在"标记对结果",而在具体采集器选用了两者中的哪一个。并非每个采集器都使用完全相同的质量子集。UI/JSON 消费方必须把质量、这些标记和原因放在一起保留。TUI 中可见的部分技术性原因仍不翻译。

设备清单的两个上限是 256 个 PCI 设备和 128 个 USB 设备,读自 `/sys/bus/pci/devices` 和 `/sys/bus/usb/devices`;电源列表是 `/sys/class/power_supply` 下的 16 个条目。条目数超过上限的主机一直发布的行数都少于它数到的,因为列表是有界的;它过去没有发布的是一个说明这一点的词,而且上限路径和缺失路径的结果都读作 `fresh`。逐资源的布尔量(`pci.truncated`、`usb.truncated`、`truncated`)一直存在且未变——它们是行级标记,而只看结果的消费方读不到行标记。两条总线到达电源或清单的上限报告同一个原因,因为一事因一代码:一次提前停止的枚举,没有任何读取失败。Insights 页上的 Collectors 表是用户看到采集器结果质量的唯一位置,这就是该表的采集器到槽位映射现在是受测属性而不是需要人工维护的字面量的原因。

**词汇表是封闭的,表外的标签会被拒绝而不是被向上归整。**`Snapshot.merge` 做规范化,所以采集器无法把不可发布的词放进记录——而它规范化*到*哪个方向才是要紧的部分。测量下来,`ok` 结果上的未知质量过去会变成 **`fresh`**,而状态保持 `ok`、原因留在旁边,于是一条记录可以同时发布状态 ok、质量 fresh 和一个说部分资源不可读的原因;一个误拼成 `partail` 的真实降级被作为 fresh 数据发布,新数字就安装在它下面。未知的*状态*早已在另一个方向被拒绝,这让质量一行显得是例外而非选择。现在两者是同一步:不可发布的状态或质量会像彻底失败一样使记录失败。被拒绝的拼写不携带到任何地方——`quality[resource]` 没有容纳它的字段,而增加一个会改变已发布的 v1 文档。

有一个后果是陈述出来的而不是期望出来的。`stale` 意为"不再新鲜的保留值",而判断值是否被保留的测试是 `previous[resource] ~= nil`——但 `Snapshot.new` 用 `{}` 播种每个资源,所以从第一个快照起它就成立,首个失败样本会被标为 `stale`,身后却是一个空表。没有安装错误的东西,也没有显示数字,所以谎言不大;为播种的空表定义"保留"的含义是对数据模型的修改,不是一个补丁。

**质量记录上的 `timestamp_ns` 是上一次*尝试*的时间,不是该记录所限定的值的时间。**保留值可以任意老,而旁边的记录携带当前时间,所以 `now - quality[resource].timestamp_ns` 度量的是上一次读取是在多久以前尝试的——测量:一个 99 秒老的值刚刚重试过,在 `quality: "stale"` 旁边报告年龄 0 秒。记录中没有任何东西说值本身多老,这一点作为未决项记录在 `docs/PLAN.md` 中,而不是在这里猜测。`tests/unit/test_core_primitives.lua` 把两半钉在一起——保留了一个采样间隔的值就已经是 `stale`,而这段话必须这么说——因为行为在一个测试里、措辞在一份文档里,而在它们说法不同的时候没有任何东西把它们连起来。

## 10. 表格列序(历史断言)

进程表的列编辑器由两个决定约束,使其不会变成第二套自相矛盾的列系统。**默认值是历史的渲染顺序和历史的列集**,所以从不打开编辑器的用户看不到任何变化;在此功能之前断言表格形状的 73 个单元测试至今原样通过、未被改动。**用户的选择与渲染器的响应性是两个不同的决定**:`full_only` 和 `priority` 决定*小面板*丢弃什么,并且在用户已选的任何列集之上仍然适用;用户隐藏的列在模型中完全缺席。
