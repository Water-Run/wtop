# 监控范围与性能操作

> 本文档区分 `0.1.0` 中已实现的持续采集器与后续目标。对于“当前实现”中未列出的提供方,不得从设计目标推断其存在。

## 1. 数据源原则

- 持续采样优先使用 Linux 的 procfs、sysfs、cgroup 和 DRM。外部 CLI 仅保留给按需运行的 Inspector。
- 每个采集器先探测能力。不支持、权限不足和出错三种状态必须与数值零区分开。
- `--report` 只采集摘要展示的硬件来源，再从脱敏后的 Snapshot 字段生成英文 Markdown；来源状态和原因随报告保留，缺失读数不补零。Linux GPU 逐进程 fdinfo 扫描不属于该摘要。
- `--stream` 在建立速率基线后按请求间隔逐行输出 Snapshot JSON；各来源仍按自身采样周期刷新。`--count` 可限定行数，未到期的读数保留来源时间戳，每行的 `value_age_ms` 按输出时刻增长。
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
| NUMA | 节点 CPU 列表、总量/空闲/已用内存、相对距离、PCI 本地性；页分配位置累计计数与本地/跨节点页分配速率 | `/sys/devices/system/node` | 2 s / 10 s |
| 内存硬件 | SMBIOS 阵列、槽位/存储体、型号/制造商、容量、封装、数据位宽、Rank、速率、电压、纠错声明、映射地址范围及 Type 37 通道句柄关系；空槽与未知值分开 | Linux `/sys/firmware/dmi/tables`；Windows `GetSystemFirmwareTable` | 60 s / 300 s |
| 处理器固件 | SMBIOS Type 4 插槽状态、固件核心/线程数与速度，Type 7 缓存容量和明确的插槽引用 | Linux `/sys/firmware/dmi/tables`；Windows `GetSystemFirmwareTable` | 60 s / 300 s |
| 扩展槽 | SMBIOS Type 9 的槽位名称、类型、使用状态、宽度及固件 PCI 地址；在用且地址唯一时引用现有 PCI 节点，空槽仍单独列出 | Linux `/sys/firmware/dmi/tables`；Windows `GetSystemFirmwareTable` | 60 s / 300 s |
| 固件端口 | SMBIOS Type 8 的内部/外部标识、连接器类型与端口用途；不按名称猜测操作系统设备归属 | Linux `/sys/firmware/dmi/tables`；Windows `GetSystemFirmwareTable` | 60 s / 300 s |
| 板载设备 | SMBIOS Type 10/41 的名称、类型与固件启用状态；Type 41 的唯一 PCI 地址可引用当前功能 | Linux `/sys/firmware/dmi/tables`；Windows `GetSystemFirmwareTable` | 60 s / 300 s |
| 固件电池 | SMBIOS Type 22 的位置、名称、化学类型、设计容量/电压及报告误差；独立于实时电量 | Linux `/sys/firmware/dmi/tables`；Windows `GetSystemFirmwareTable` | 60 s / 300 s |
| 固件电源 | SMBIOS Type 39 的槽位、型号、额定持续输出、存在/插拔标志、冗余组和可选探针句柄；不是实时功耗 | Linux `/sys/firmware/dmi/tables`；Windows `GetSystemFirmwareTable` | 60 s / 300 s |
| BMC 接口 | SMBIOS Type 38 的 IPMI 接口类型、版本、目标地址及可选的寄存器布局和中断；不是实时 BMC 状态 | Linux `/sys/firmware/dmi/tables`；Windows `GetSystemFirmwareTable` | 60 s / 300 s |
| 固件 TPM | SMBIOS Type 43 的厂商 ID、规范与固件版本字段、描述及配置特征；不是当前 TPM 安全状态 | Linux `/sys/firmware/dmi/tables`；Windows `GetSystemFirmwareTable` | 60 s / 300 s |
| 固件组件 | SMBIOS Type 45 的组件、版本、发布日期、镜像大小、静态状态和明确的关联句柄；不测量实时健康或更新服务 | Linux `/sys/firmware/dmi/tables`；Windows `GetSystemFirmwareTable` | 60 s / 300 s |
| UEFI 固件资源 | ESRT 的固件类别 GUID、资源类型、已安装/最低支持版本、Capsule 标志和上次尝试代码；不是实时健康或可更新性检查 | Linux `/sys/firmware/efi/esrt` | 60 s / 300 s |
| Linux TPM | OS 注册的 TPM、规范主版本、驱动、可选状态位和 PCR 库目录/条目数；不读取 PCR 值或密钥 | `/sys/class/tpm` | 60 s / 300 s |
| Linux 看门狗 | 设备标识、活动状态、超时配置、可选原始状态位；只有 active 时显示距复位剩余时间 | `/sys/class/watchdog` | 5 s / 30 s |
| Linux 无线开关 | WLAN、蓝牙等 RF 开关的硬件/软件阻断、持久化标志和可信 PCI/USB 归属；仅只读，不改变开关 | `/sys/class/rfkill` | 2 s / 10 s |
| Linux 热区与冷却设备 | 热区温度、阈值、模式与策略，冷却设备当前/最大原始状态、转换次数及各状态累计驻留时间；按 `cdevN` 链接关联，不推断风扇转速或状态变化率 | `/sys/class/thermal` | 2 s / 10 s |
| 管理主机接口 | SMBIOS Type 42 的接口类别和 IPMI、MCTP、Redfish 等协议声明；不导出可能含网络配置的原始负载 | Linux `/sys/firmware/dmi/tables`；Windows `GetSystemFirmwareTable` | 60 s / 300 s |
| 内存纠错 | Linux EDAC 控制器及 DIMM/rank 的可纠正、不可纠正错误累计计数；逐字段保留读取失败 | `/sys/devices/system/edac/mc` | 5 s / 30 s |
| FPM/EDO/SDR/DDR/DDR2/DDR3/DDR4/DDR5 SPD | 模块属性、SPD 版本、可用时的最短周期与型号、校验状态；FPM/EDO 的模块 bank 数与容量，SDR/DDR/DDR2/DDR3/DDR4 的容量/位宽/Rank；按 I²C 地址关联 DDR3/DDR4/DDR5 温度 | `/sys/bus/i2c/devices/*/eeprom` | 60 s / 300 s |
| PSI | CPU/内存/I/O 的 `some`/`full` 平均值/总量 | `/proc/pressure/*` | 1 s / 2 s |
| 块设备 | 字节/秒、IOPS、繁忙度、在途请求、队列长度、估算的读/写延迟，以及整盘型号/厂商/固件、容量、介质、可移除标志、调度器、队列深度和预读；分区容量/起点、堆叠设备引用、DM 状态与 MD 阵列同步进度及成员位置/状态；Linux NVMe 命名空间/控制器诊断、多路径 ANA 清单与命名空间已分配量 | `/proc/diskstats`、block sysfs、NVMe subsystem sysfs | 1 s / 3 s；有稳定 `diskseq` 时 NUSE 读数最多复用 60 s |
| 网络接口 | 字节/包/错误/丢包速率,operstate,MTU,MAC,载波/双工,可用时的链路速率,默认路由族,带掩码/广播/对端的 IPv4/IPv6 地址,以及链路状态转换的累计与新增次数、RX/TX netdev 队列数、RPS/XPS 配置、TX 限速及逐 TX 队列超时累计数 | `/proc/net/dev`, `/sys/class/net`, `getifaddrs(3)` | 1 s / 3 s；队列每 30 s 重扫 |
| Linux procfs 路由 | 默认路由轻量扫描按接口刷新；按需清单给出 IPv4/IPv6 的目的前缀、可用时的源前缀与下一跳、接口、metric 和原始标志 | `/proc/net/route`、`/proc/net/ipv6_route` | 默认路由随网络接口采样，1 s / 3 s；浮层内完整清单每 10 s 或默认路由改变时刷新，Snapshot 按需读取 |
| Linux 网络接收栈 | 每 CPU 已处理/丢弃包和处理预算耗尽累计数；新内核的接收积压队列长度、CPU 身份及按实际间隔计算的速率 | `/proc/net/softnet_stat` | 随网络接口采样，1 s / 3 s |
| 套接字 | TCP/TCP6/UDP/UDP6/Unix 的端点、状态、队列、UID、inode;可用时的 PID/fd/名称属主,`owner_count` 只在真正执行了查找的地方发布,而不是填零 | `/proc/net/*`, `/proc/<pid>/fd` | 2 s / 10 s |
| 进程 | `(pid,starttime)`、PPID、状态、CPU、按系统 tick 频率换算的累计 CPU 时间、已运行时间、RSS/VSZ、线程数、优先级/nice/CPU、解析为本地用户名的 UID,以及完整命令行;针对选中线程:线程组、累计及每秒自愿/非自愿上下文切换、被抢占占比、I/O、cgroup 归属、运行队列等待、时间片与调度策略;所属进程的 PSS/USS 与按 NUMA 节点统计的映射页占用 | `/proc/<pid>/stat`, `/proc/uptime`, `status`, `cmdline`, `/proc/<pid>/task/<tid>/{stat,status,io,cgroup,schedstat,sched,wchan}`, `/proc/<pid>/schedstat`, `/proc/<pid>/{smaps_rollup,numa_maps,wchan}`, `/etc/passwd` | 1 s / 5 s;逐线程补充文件只读取选中 TID 的那一个,`/proc/<pid>/schedstat` 只读取视口正在显示的进程行;`numa_maps` 仅打开进程详情时读取,10 秒刷新 |
| CPUFreq | 策略/CPU 集合、硬件当前值或硬件反馈短时平均值、调频读数、最低/最高频率、来源与质量、驱动、governor、boost/EPP | cpufreq sysfs | 1 s / 5 s |
| CPU 热节流 | 每逻辑 CPU 的核心/封装热节流累计次数、相邻样本新增次数、累计与最长持续毫秒数 | `/sys/devices/system/cpu/cpu*/thermal_throttle` | 5 s / 30 s |
| CPU 空闲态 | 每逻辑 CPU、每状态的使用次数、内核报告时间、进入请求被拒次数、时长短于目标及可选更深状态次数；保留累计值和相邻样本增量、退出延迟与目标驻留时间 | `/sys/devices/system/cpu/cpu*/cpuidle/state*` | 5 s / 30 s |
| hwmon | 温度、风扇转速、电压、电流、功率、能耗、阈值/告警/故障;识别 `temp1_crit_alarm` 这类带限值的告警形式以及裸 `temp1_alarm` 形式;电压通道从 `in0` 起向上读取;过滤已知的无效哨兵值;恰好为零的阈值,或 u16 温度哨兵值,按“驱动未设置该属性”丢弃,而不是当作一条界限上报;设备的 `device_target` 供视图层把读数归属到 GPU 或磁盘(磁盘标注带型号与挂载点),表与浮层共用同一联接；直接读数记录本次会话最小/最大/采样平均 | `/sys/class/hwmon` | 1 s / 5 s |
| Powercap | 有界的 zone 层级、能量/直接功率、约束、防回绕/防复位的差值计算、独立的 CPU 封装与整机/`psys` 聚合;恰好为零的功率上限或界限,或驱动以 ENODATA 应答的属性,按“驱动未设置该属性”丢弃,而不是上报 | powercap sysfs | 1 s / 5 s |
| 挂载 | 挂载标识、文件系统/来源/只读状态,以及安全时的容量和 inode 数 | `/proc/self/mountinfo`, `statvfs` | 5 s / 30 s |
| 硬件清单 | PCI/USB 设备与 USB 接口、接口驱动/类别/端点数、PCI 链路、MSI/MSI-X 向量及观察到的中断计数、IOMMU 组成员及可见 PCI 同组引用、SR-IOV PF/VF 引用及可用时的 PCIe AER 错误计数；Linux 磁盘/分区、网卡父子树及按设备号关联的挂载；设备详情关联传感器，`inventory.topology` 导出同一关系。Windows/macOS 缺少路径时平面展示 | sysfs + `pci.ids` / SetupAPI / IOKit，复用磁盘/网络/挂载快照 | 总线 30 s / 120 s；其余按各采集器间隔 |
| cgroup v2 | CPU/max/weight、内存/Swap/事件/上限、I/O 速率、进程数；线程化子组的 TID 数、PID/事件、PSI、cpuset | `/sys/fs/cgroup` | 2 s / 10 s |
| 系统标识 | 主机名/域名/架构、内核类型/版本/构建/命令行(密钥与机器标识参数已脱敏)、来自 os-release 的发行版、运行时间与启动时间、虚拟化与容器检测、SELinux/AppArmor/lockdown 状态、DMI 机器/主板/固件白名单字段（占位字符串丢弃）、描述符/PID/线程上限、熵、内核全局计数器、Swap 设备、时区 | `/proc/sys/kernel`, `/proc/uptime`, `/proc/stat`, `/proc/swaps`, `/proc/vmstat`, `/etc/os-release`, `/sys/class/dmi/id` | 5 s / 30 s |
| 电源 | 电池与 UPS 的状态、电量和健康度、能量、功耗、电压、循环次数与剩余时间；外接电源在线状态，缺失读数保持未知 | `/sys/class/power_supply` | 5 s / 15 s |
| GPU | DRM 设备/节点标识、PCI 名称/链路元数据、选定的 AMD 繁忙度/显存、AMD/i915/xe 频率、DRM fdinfo 设备/进程数据 | `/sys/class/drm`, `/proc/<pid>/fdinfo`, 有界的本地 `pci.ids` | 1 s / 5 s |

`--interval` 接受 100..10000 ms。交互式 TUI 把初始值映射到九个命名档位中最近的一档:8s、5s、3s、2s、1s、0.75s、0.5s、0.3s 和 0.1s。点击右上角控件或按 `f` 可在运行时循环切换。这一操作不会绕过昂贵采集器的下限:GPU 500 ms;进程/CPUFreq/hwmon 1000 ms;套接字/cgroup 2000 ms;挂载/CPUIdle 5000 ms。

传感器本次会话统计纳入 Linux hwmon 直接读到的 `*_input`，以及
macOS/Windows 原生采集器、设备和通道均标为 fresh 的直接输入；按采样次数计算
最小、最大与算术平均，并保留首末采样时间。Linux 驱动给出的
`*_lowest`/`*_highest` 是另一套硬件历史值，不与会话范围混写；
`*_average` 等估算替代值不算直接采样，累计的 `energy_input` 也不计算
读数平均。通道读数缺失时保留旧统计但不增加次数；设备或通道身份
变化、完整采集失败后重新开始。没有可信设备身份时，每次只报告
当前直接样本，不跨扫描拼接历史。参见
[Linux hwmon 接口](https://docs.kernel.org/hwmon/sysfs-interface.html)。

网络队列数来自 `/sys/class/net/<iface>/queues` 的 `rx-N`、`tx-N`
条目，表示内核 netdev 队列，不等同于物理网卡的硬件通道数。
目录读取失败或截断时，队列小节单独标记状态，不影响接口计数器。
同一次队列重扫最多读取 512 条 TX 队列的 `tx_timeout` 累计计数；
只有队列目录完整且全部计数读到时才给出接口总数。缺失、拒绝、
畸形值和扫描上限各有状态，不会被填成零。相同接口、相同队列集合的
相邻扫描另给出新增报告数；首次扫描或身份变化为 `gap`，计数下降为
`reset`。RPS/XPS 掩码、RPS flow 数和 TX 限速同样按队列读取，
配置属性一次采样最多读取 512 个。`tx_maxrate=0` 表示限速关闭；
其他属性缺失时保持不可用，不推断硬件配置。参见
[Linux netdev 队列 ABI](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-class-net-queues)。

接口的 `carrier_changes`、`carrier_up_count`、`carrier_down_count` 来自各自的 netdev sysfs 属性。合计与上下行计数是独立读取的，采样时若刚好发生转换，不强求它们在同一瞬间相等；新增上下行分量与新增总数不一致时只保留总数，并把该小节标为 partial。最多为 256 个接口读取三项；超过预算的接口标记 `truncated`。新增次数只与同一 ifindex、名称、iflink 和设备路径的上次有效读数比较，首次读取、计数回退或身份变化不填零。这表示内核报告的链路状态转换，不能单凭次数判定物理线缆故障；见 [Linux 网络设备 sysfs 实现](https://github.com/torvalds/linux/blob/master/net/core/net-sysfs.c)。

`/proc/net/softnet_stat` 是每 CPU 的接收栈计数，不属于某一张网卡，也不等同于接口 `rx_drops`。前三列分别是已处理、丢弃和处理预算耗尽次数；提供明确 CPU 编号的内核还给出当前接收积压。速率只比较同一 CPU 的相邻读数；首次采样、CPU 集合变化、计数下降及旧格式缺少 CPU 编号时不填零。一次最多读取 1 MiB/4096 行，Snapshot 的逐 CPU 列表最多导出 256 行并保留总数与截断标记。来源文件缺失或损坏只影响这个独立小节，不抹掉接口速率。字段位置见 [Linux 内核的 `softnet_seq_show`](https://github.com/torvalds/linux/blob/master/net/core/net-procfs.c)。

上表中的每个速率都是 `Clock:now_ns()` 上的差值,时钟会标明取值的来源。来源名称是一个四元素封闭集合:`procfs_uptime` 表示读数取自 `/proc/uptime`;`process_clock_fallback` 表示读数由回退机制产生;`held` 表示因为新候选值比已有值更旧而返回旧值——这是单调时钟必须做的,但不是一次测量;`unavailable` 表示既无测量也无从测量。`--diagnose` 会打印它,并将其放入 JSON 报告的 `clock.source` 字段。

`held` 这种情况值得事先了解,而不是事后意外发现。默认回退是 `os.clock` ——进程自身的 CPU 时间,它与 `/proc/uptime` 是不同的量、不同的尺度,而不是它的第二份拷贝。因此,如果 `/proc/uptime` 在一次成功读取后停止应答,此后每个候选值都比手中的值更旧,单调钳制会拒绝它,**只要读取持续失败,时钟就停止推进**:所有速率都冻结在故障发生时刻的值上。这是安全行为——时钟倒退更糟——而它被命名而不是保持沉默的原因,是一条没有解释的冻结速率正是用户会当作 bug 报告的东西。

历史记录保存的是每个数据源实际完成采样的时间戳,而不是在其他无关采集器完成时重复旧值。每条 sparkline 的终端列覆盖固定的一秒,总计最多 240 秒。更高的速率向每一列贡献更多真实数据点,更低的速率则产生稀疏点,所以切换速率不会改变水平时间尺度。

`/proc/<pid>/cmdline` 在枚举期间读取,这样每一行都能显示真实的命令名;来自 `/proc/<pid>/stat` 的 `comm` 是十五字符截断,仅作回退。`/proc/<pid>/io` 通常只在详情打开时读取；明确按 I/O 排序、使用 I/O 数值过滤或调用 `--snapshot` 时，才对有界的进程集合批量读取。累计量排序和过滤使用 `read_bytes`/`write_bytes`，即存储层字节数，不是系统调用的全部字节。参见 [proc_pid_io(5)](https://man7.org/linux/man-pages/man5/proc_pid_io.5.html)。cgroup 列表只为详情或显式工作负载跳转读取；进程表按 `g` 时只访问所选 PID，并在读取前后核对启动时间。UID 到用户名的解析直接读取 `/etc/passwd` 而不是调用 `getpwuid(3)`,因为在配置了 LDAP 或 SSSD 的主机上,NSS 可能在渲染循环内阻塞数秒。交互式高基数 GPU fdinfo 扫描仅在 GPU 页面上的 `gpu_process_table` 经响应式布局求解获得实际位置时启用。仅仅切到 GPU 页面、显示 GPU 摘要或停留在 Insights 都不够。Overview/后台 GPU 采样仍只读取设备摘要,不枚举 `/proc/<pid>/fdinfo`。非交互式 `--snapshot` 保留完整扫描。

Linux 批量读取器对常规 `/proc/<pid>/stat` 行在原生模块中解析，解析不了的原文仍交给 Lua 解析器判定错误原因。旧原生模块与纯 Lua 5.4 路径继续使用字符串解析。

Linux 进程详情显示线程组首线程的允许 CPU 和内存节点列表；选中线程的详情显示该线程自己的列表，两者可能不同。读数来自各自的 `/proc/.../status` 中的 `Cpus_allowed_list` 和 `Mems_allowed_list`，表示内核报告的允许集合，不是当前运行的 CPU 或实际内存页位置。普通进程扫描复用上次状态读取的结果，JSON 同时给出 `observed_ns`；打开进程详情会重新读取。缺少字段时不推断为 CPU 0，单个列表损坏时保留另一个并标为 `partial`。参见 [proc_pid_status(5)](https://man7.org/linux/man-pages/man5/proc_pid_status.5.html) 和 [sched_setaffinity(2)](https://www.man7.org/linux/man-pages/man2/sched_setaffinity.2.html)。

所选进程详情还会有界枚举 `/proc/<pid>/fd`，给出首线程观察到的打开文件描述符数，并从 `/proc/<pid>/limits` 读取软/硬上限。线程可拥有不同的描述符表，因此这不是所有线程的合计。条目超过 4096 项时显示下界 `>=4096`；目录不可读和上限不可读各自报告状态，不填零。普通进程列表不做这次目录扫描，快照 JSON 也不附带只在详情模式采集的 FD 读数。参见 [proc_pid_fd(5)](https://www.man7.org/linux/man-pages/man5/proc_pid_fd.5.html)、[proc_pid_limits(5)](https://www.man7.org/linux/man-pages/man5/proc_pid_limits.5.html) 和 [unshare(2)](https://man7.org/linux/man-pages/man2/unshare.2.html)。

在进程详情按 `F` 才扫描最多 4096 个 FD 名字，按编号读取最多 128 条
符号链接目标；这与上面的
FD 数量采样分开。扫描前后都核对进程启动时间，身份变化时不显示已读的
路径。链接目标会净化控制字符并标明截断，单个 FD 消失或权限被拒时显示
状态。wtop 不打开这些目标，默认 Snapshot 和 Agent 不包含该列表。
在列表中选中 FD 并按 `Enter` 时，才读取对应 `fdinfo` 的最多 1024 字节前缀。
详情重新读取链接目标，保留文件偏移、八进制标志、挂载 ID 和 inode 的原始
数字拼写；旧内核未提供的字段留空。列表与详情是两个观察时点，FD 号可能
已被复用；详情展示选择时的目标，读取期间身份或目标变化就丢弃元数据。
不会打开 FD 指向的文件，也不导出 `fdinfo`。参见
[proc_pid_fdinfo(5)](https://man7.org/linux/man-pages/man5/proc_pid_fdinfo.5.html)。

打开进程详情时还读取 `/proc/<pid>/oom_score` 和 `oom_score_adj`，分别显示当前 OOM 选择分数与调整值。分数较高表示被选中的可能性较高，不是概率；调整值可为负数。两个文件各自报告缺失、拒绝或坏值，不降低普通进程表的质量，也不为未选中的进程读取。附加读取结束后仍复核 `(PID,starttime)`，避免把 PID 复用后的值附到旧进程。参见 [oom_score](https://man7.org/linux/man-pages/man5/proc_pid_oom_score.5.html) 与 [oom_score_adj](https://man7.org/linux/man-pages/man5/proc_pid_oom_adj.5.html)。

进程表的光标本身不触发详情读取；`smaps_rollup` 与 FD 目录只在详情打开时读取。I/O 排序和数值过滤显式请求最多 8192 个进程的 `/proc/<pid>/io`，原生读取器批量打开。累计计数五秒刷新；请求读写速率时改为两秒刷新。`--snapshot` 的两次采样都批量读取，第二次不等交互式刷新期限，以便导出实际速率。新进程仍立即读取。速率只由相同 `(pid,starttime)` 的两个实际读数和单调时间差计算；首读、未推进的时钟和计数回退不填零。中间复用的速率标为 held。缺失数据在排序中靠后，过滤时不当作零，状态行报告等待或部分覆盖。`schedstat` 只为实际画出 Queued 列的可见行及正在打开详情的进程读取；列被用户隐藏、响应式布局省略或表格被浮层遮住时，不为它做视口扫描。详情从 GPU 页打开时，进程采集器维持前台刷新；关闭浮层即撤销该请求。
线程选择器只刷新该进程的线程 `stat` 行；它不重读进程的 I/O、内存详情和 FD 目录。按 `Enter` 打开线程详情后，才读取该 TID 的 `status`、`io`、FD 目录等文件。选择绑定 TID 与 `stat` 的启动时间；线程消失或 TID 被复用时，不把新线程的详情放进旧浮层。字段来源见 [proc_pid_stat(5)](https://man7.org/linux/man-pages/man5/proc_pid_stat.5.html)。返回选择器会撤销逐线程请求。选择器与线程详情都不显示进程自身的排队速率，因此也不为它读取进程级 `schedstat`。

Linux 的 `wchan` 只在打开详情或实际绘制进程表的可选 `WCHAN` 列时读取：进程页读首线程，线程详情读选中 TID。视口行最多 256 个；列被隐藏、响应式布局省略或表格被浮层覆盖时，不做逐行读取。它是内核公布的休眠位置函数名，不是等待时长或故障原因；`0` 表示没有报告位置。读不到时展示字段状态，不把缺失当作零。进程和线程的补充读取都在末尾复核启动时间，避免 PID/TID 复用时混入另一个任务的数据。参见 [proc_pid_wchan(5)](https://man7.org/linux/man-pages/man5/proc_pid_wchan.5.html)。

线程详情的 `g` 使用该 TID 已核对启动时间的 cgroup v2 路径定位工作负载；线程读数未到、身份变化或 cgroup 文件不可读时，不退回所属进程的路径。[内核的 cgroup v2 文档](https://docs.kernel.org/admin-guide/cgroup-v2.html)说明线程模式可以让同一进程的线程分布在不同子组。

线程化 cgroup 的 `cgroup.procs` 读取会由内核拒绝；采集器核对 `cgroup.type` 后改读 `cgroup.threads`，把进程数保持未知，而不是显示零或报文件损坏。Workloads 页按 `Enter` 时最多复核 64 个 TID 的当前身份和 cgroup，再显示这些线程所属的进程；超过上限会报出已检查的范围。这项按需读取不增加常规刷新时的每节点 `/proc` 扫描。

Workloads 页按 `/` 搜索节点名称、完整路径和已识别的服务、容器或 Pod 身份；整段普通文本仍按一个字面短语匹配。可用 `cpu>20`、`mem>1G`、`read>10M`、`write>10M`、`procs>2`、`threads>2` 和 `pressure>1` 组合实测条件，字节后缀为二进制 K/M/G/T，I/O 值是字节每秒；缺失数值及其否定条件都不会当作零。命中的节点连同上级组在 512 行上限前筛选；已折叠的路径在搜索期间显示，但清除搜索后恢复原来的折叠状态。筛选期间 `c` 会提示先清除搜索。

PID 命名空间内还可能读到 `cgroup.procs` 或 `cgroup.threads` 的 `0` 条目。采集器保留可映射的 ID 数及 `0` 条目数；只要存在 `0`，总进程/线程数就保持未知。`0` 不作为成员 ID，也不会把可读控制文件误报为解析失败。

选中一个线程后，详情另外枚举该 TID 的 `/proc/<pid>/task/<tid>/fd`，并把它与首线程的数量并列显示；选中首线程时复用已有读数。两个数量相等并不能证明它们共用同一张表。逐线程扫描只针对当前选中项，沿用 4096 项上限及拒绝/截断状态。

默认清单上限为 4096 个 DRM 类条目、32 张卡、64 个 render 节点、16 个 hwmon 引用和每设备 32 个频率域。进程扫描上限为 4096 个进程、每进程 1024 个 fdinfo 条目、总计 32768 个 fdinfo 文件、每文件 256 KiB 和 8192 个 client。命中任一上限都会把结果标记为 partial/truncated,而不是把未扫描的对象当作不存在。

进程采集器默认最多扫描 8192 个 PID。原生目录枚举在排序和逐 PID 读取之前,先按该预算加少量非 PID 余量截断。结果暴露 `process_candidates`、`process_limit`、`truncated` 和 `partial`。进程搜索/排序在已采集集合上运行,TUI 模型最多保留 2048 行。连接、挂载、workload 和 GPU 进程 ViewModel 各自最多构建 512 行;GPU 清单另有 32 张卡的采集器上限。连接、挂载和 GPU 进程选择有界的优先级子集,workload 保留按采集器顺序排列的前 512 行。采集器截断会显式添加 `partial`/`truncated`,部分采集器还会把质量降级为 estimated;纯 UI 的行数上限不会改写采集器质量。当 512 行模型上限丢弃行时,进程、GPU 进程、挂载和 workload 状态行显示 visible/total,连接状态显示采集器的套接字总数。可用资源数量和扫描状态仍需被考虑;一行未显示并不能证明该对象不存在。

Storage 页的 `/` 可搜索挂载点、来源、文件系统类型及本地/网络/伪文件系统类别；`path:/mnt used>90`、`avail<10G` 和 `inodes>80` 可把文字与实测容量组合。K/M/G/T 按二进制字节计算，容量不可读的挂载点不会在数值条件及其否定条件中冒充零。伪文件系统先按 `v` 开关决定是否进入表格，同一挂载路径只保留最后可见的一项，然后才筛选并应用 512 行上限。筛选时状态行优先显示查询，`Esc` 清除。

完整路由/netlink、调度器延迟和连续的内存带宽尚不在持续采集器集合中。SMART、内存带宽和 sshd 是按需 Inspector;见 [Deep Inspection](DEEP_INSPECTION.md)。

内存带宽 Inspector 不在调度器矩阵之内。按一次键会启动一次约 250 ms 的全局外部 `perf stat`/`sleep` 采样,使用有限的 data/CAS 事件名映射。部分方向、部分事件或多路复用的结果标记为 estimated。

**该 Inspector 的“ready”意味着什么:测量得出,而非假设。** 匹配 PMU 的探测并不运行 `perf`,也不校验权限,所以 `available` 只意味着一件事:存在内存控制器 PMU,且有东西可以被要求读取它们。它并不意味着计数器能够被打开。这个区别不是学术性的——它来自一台真实主机的实际行为。这里的一台开发机发布了白名单查找的全部四个 PMU 名称(`uncore_imc_0`、`uncore_imc_1`、`uncore_imc_free_running_0`、`uncore_imc_free_running_1`),且 `perf list` 在 free-running 对上列出了 `data_read`、`data_write` 和 `data_total`——正是读取器匹配的事件名。然而它们每一个在 `sys_perf_event_open` 上都以 `EINVAL` 失败,因为 free-running 计数器不是计数型 PMU。探测找到了四个 PMU 并报告 ready;第一次真实测量返回 `memory_events_not_supported`。因此能力记录现在携带一条理由,说明计数器存在但尚未被读取,该理由已在全部十份目录中翻译,Insights 行把它显示在 `ready` 旁边,而不是留空。一行先说了 ready 然后什么也不说,与没有哈希的 SBOM 是同一种缺陷。

本节刻意**不作**两个声明。其一,不声明 `perf_event_paranoid` 阈值,因为这台主机无法演示任何阈值:这些事件在任何权限检查之前就以 `EINVAL` 失败,带不带 `-a` 都一样。把一条未经测量的内核规则写进能力记录,正是本项目一直在清除的缺陷,所以理由只陈述探测所确证的内容。其二,不声明该 Inspector 普遍精确:`theoretical_bandwidth` 数值由内存拓扑计算得出并标记为 `estimated`,因为它是一个公式,并且它是该 Inspector 在计数器无法打开的主机上始终能给出的唯一数值——这就是为什么由拓扑导出的结果报告 `provider: memory_topology_formula`,而不是点名一个什么也没产出的读取器。

在完全没有内存控制器 PMU 的主机上——也就是普通笔记本电脑——来源为 `unavailable`,原因是 `memory_controller_pmu_not_found`,它不会作为待补缺口出现在建议列表中。`tests/unit/test_ram_bandwidth_claim.lua` 把这一切全部钉住:探测的理由、探测不打开任何计数器、理由到达渲染行、存在来源时不列为缺口、普通的无 PMU 情形,以及公式导出的数值保持标注。

Insights 是一个静态的能力/Inspector 入口摘要。它读取已有的有界后台样本来获得计数,没有前台采集器集合,也不会为了这些数字而以 1 Hz 采样进程或 GPU 数据。

### 2.1 缺失内核数据源意味着什么

wtop 没有最低 Linux 内核版本要求。没有任何东西会把启动挂在某个内核接口上:`Scheduler:probe_all` 在每个探测外包一层 `pcall`,失败或抛错的探测会变成一条能力记录而不是致命错误,内核无法满足的能力恰好只损失它自己的那份资源。`Snapshot.merge` 只在结果为 `ok` 时安装采集器数据,并且无论结果如何都会写一条质量记录,所以缺失的来源产生一条 `quality[resource]` 记录,携带 `status`、`quality` 和采集器给出的 `reason`——不是一个数字,也不是零。`--diagnose` 会点明读不了的路径,JSON 导出复现同一条记录。

`quality[resource].reason` 说明本次结果为何降级或失败。内存、PSI、磁盘和网络采集器已经为各自的结果级降级提供原因，例如 `disk_data_partial` 与 `network_rate_unavailable`；更具体的失败仍保留在挂载点、设备或接口自身的状态与原因中。`Snapshot.merge` 将采集器的结果级原因送到 TUI、Snapshot 和 Agent。并非每个采集器的每种降级都已有可发布的原因；补齐时需按来源和事因逐项核对，不能从质量词推测一个原因。

`tests/unit/test_engine.lua` 在模拟内核上把这一点钉住:该内核没有 cgroup v2、没有 PSI、没有 hwmon、没有 DRM、没有 powercap、也没有 cpufreq——引擎仍然探测、仍然 tick、保留所有有数据源的采集器,把每个缺失的标记为 `unavailable` 并附理由,不为它安装数据,并记录图表缺口哨兵值而不是捏造的零。它还钉住:一个*抛错*的探测仍然只是一条能力记录,以及一个带着非 `ok` 状态返回数据的采集器,不能与它写入的快照相矛盾。

| 来源根 | 快照资源 | 内核不提供它时会失去什么 |
| --- | --- | --- |
| `/proc/stat`, `/proc/loadavg` | `cpu` | 利用率、负载、上下文切换、中断;资源不可用时核心概览卡片被隐藏 |
| `/proc/meminfo`, `/proc/vmstat` | `memory` | 内存卡片、其划分明细和内存历史 |
| `/proc/pressure/{cpu,memory,io}` | `pressure` | PSI 图表;Linux 4.20 加入,因此 4.20 之前的内核恰好只失去这一项 |
| `/proc/diskstats`, `/sys/block/*`, `/sys/class/nvme/*` | `disks` | 块设备表、速率及可用时的 NVMe 命名空间/控制器诊断计数 |
| `/proc/net/dev`, `/sys/class/net` | `network` | 接口速率与链路状态 |
| `/proc/net/*`, `/proc/<pid>/fd` | `connections` | 套接字表及其属主归属 |
| `/proc/<pid>/{stat,status,cmdline,task}` | `processes` | 进程表;隐藏其他用户进程的内核会把它收窄到调用者自己的进程 |
| `/sys/devices/system/cpu/cpufreq` | `cpu_frequency` | 频率卡片,隐藏而不是显示为 0 MHz |
| `/sys/devices/system/cpu/cpu*/thermal_throttle` | `thermal_throttle` | Compute 页的逐 CPU 热节流表及 System 页 CPU 设备详情；缺失时不显示伪造的零 |
| `/sys/devices/system/cpu/cpu*/cpuidle/state*` | `cpuidle` | Compute 页逐 CPU 空闲态表及 System 页逻辑 CPU 设备详情；首次采样及计数器回退时增量留空 |
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

- 属主扫描仅在 Network 页面的连接表获得实际可见位置时发生。上限为 1024 个进程、每进程 512 个 fd、总计 16384 个符号链接、每套接字 8 个不同进程。同一进程持有同一 socket 的多个 fd 合并为一个属主，并保留 fd 数与有界的内部 fd 列表。权限拒绝、PID/fd 竞态和上限会把属主质量降为 partial/estimated,而不是捏造缺失的属主。
- 离开 Network 页面后属主扫描停止;套接字表采样以更低频率继续。标准 `--snapshot` 同样保持属主扫描关闭。
- **`owner_count` 只在查找真正执行过的地方发布。** 由于除 Network 页面外扫描处处关闭,这意味着大多数时间不发布,非交互导出中处处不发布。在那里报告零计数等于说“没有进程持有这个套接字”,而同一条记录却说属主数据不可用——一行自相矛盾,在这台主机自己的 `--snapshot` 上让全部 256 个套接字(包括 sshd 的 22 端口)都读作无属主。因此,除非 `owners_quality` 为 `fresh` 或 `estimated`,否则该计数缺席;对被扫描且查找确实一无所获的套接字,计数会出现。`owners_quality` 与计数的缺席从两个方向说同一件事,所以只读其一的消费方仍然无法断定某个套接字没有属主。TUI 从不显示该计数——它按属主记录本身排序——所以这条保护针对的是导出及其下游,因为“这个套接字没有属主”正是有人会据以行动的陈述。同一规则也适用于 Windows 和 macOS 后端:无法归属套接字的平台(SP2 之前的 Windows XP 没有属主 PID)同样报告质量而不是零。
- TUI 默认显示完整的本地/远端端点、Unix 套接字路径、UID 和可见属主。在 Network 页面按 `m` 可遮蔽连接表中的远端地址以便屏幕共享;在 `config.yml` 中设置 `mask_remote_addresses: true` 可从启动起进入遮蔽状态。该开关只影响表格显示的内容。
- Network 页按 `/` 输入不区分 ASCII 大小写的字面文本；没有字段条件时，整段输入仍按一个字面短语匹配。可用 `proto:tcp state:listen`、`pid:42`、`local:127.0.0.1`、`remote:203.0.113.x`、`owner:sshd`、`uid:1000`、`lport:80`、`rport:443` 和 `queue>0` 等条件，以空格组合并用 `!` 排除。`tx`、`rx` 和 `queue` 可与 `=`、`>`、`>=`、`<`、`<=` 比较；缺失数值不会当作零。匹配在 512 行显示上限之前进行，状态行报告显示数与匹配数。`Esc` 清除筛选。开启远端地址遮蔽时，查询只使用遮蔽后的远端端点，并清除先前在完整地址模式输入的查询。
- Network 页按 `g` 才构建两份 procfs 路由文件的有界清单；最多保留 2048 条，浮层展示前 256 条，Snapshot 同样按需读取并导出条目及截断/解析状态。浮层内每 10 秒重读清单，默认路由改变或重新打开浮层时立即重读；两次之间继续轻量扫描默认路由。浮层关闭后保留的上次清单标为 stale。默认路由的选择会遍历全部有效行，并忽略未启用的 IPv6 回退记录。这是 procfs 的路由视图，不包含完整的策略路由表；见[内核 procfs 文档](https://github.com/torvalds/linux/blob/master/Documentation/filesystems/proc.rst)和[IPv4 路由文件实现](https://code.googlesource.com/linux/torvalds/linux/+/90f055df112162fd9e093c16be1c21f38c35b907/net/ipv4/fib_trie.c)。
- Linux Network 页用方向键选择连接，`Enter` 打开属主进程；多个不同进程持有同一 socket 时先选择属主。打开前重读该 PID 的 `/proc/<pid>/stat`、确认至少一个仍指向所选 inode 的 fd，再复核启动时间；详情只跟随相同 `(PID,starttime)` 的进程样本。当前样本尚未包含该进程时，只强制一次进程采集，并在详情中暂时显示读取状态。属主变化或无法核实时拒绝下钻，不按数字 PID 猜测。
- Linux 进程页或进程详情按 `n` 跳到 Network，只显示该进程当前映射的连接。连接采集会重新运行，并仅给在 fd 扫描前后仍有相同 `(PID,starttime)` 的属主标记身份；界面在本次采样完成前不显示旧结果。进程退出、PID 被复用或扫描未覆盖目标时不会按 PID 数字猜测连接。`/` 可继续缩小结果，`Esc` 先清文字查询，再清进程范围。标准 Snapshot 不请求这项身份检查。
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

Agent 与 TUI 顶栏共用核心/支撑来源的失败分级。可选硬件来源拒绝或
缺失仍显示在 Insights 的采集器行和 JSON 质量记录中，但不增加顶栏
`!N`，也不单独把 Agent `overall` 提升为严重。顶栏另外计入当前内存
与本地挂载的高占用；来源或挂载行已标为陈旧时不拿保留值重复报警。

设备清单有 256 个 PCI 设备、128 个 USB 设备和 256 个 USB 接口的上限,USB 目录扫描最多 1024 项,读自 `/sys/bus/pci/devices` 和 `/sys/bus/usb/devices`;电源列表是 `/sys/class/power_supply` 下的 16 个条目。条目数超过上限的主机一直发布的行数都少于它数到的,因为列表是有界的;它过去没有发布的是一个说明这一点的词,而且上限路径和缺失路径的结果都读作 `fresh`。逐资源的布尔量(`pci.truncated`、`usb.truncated`、`truncated`)一直存在且未变——它们是行级标记,而只看结果的消费方读不到行标记。两条总线到达电源或清单的上限报告同一个原因,因为一事因一代码:一次提前停止的枚举,没有任何读取失败。Insights 页上的 Collectors 表是用户看到采集器结果质量的唯一位置,这就是该表的采集器到槽位映射现在是受测属性而不是需要人工维护的字面量的原因。

Linux 电源类允许驱动省略属性。`online` 只有读到有效值才成为布尔量；
电池缺少 `present` 时按内核约定视为在场，外接适配器没有这个默认值。
USB 的 `online=2` 表示在线且供电可编程。缺少 `online` 的适配器
显示未知，采集器以 `power_supply_data_incomplete` 标记部分质量；若设备
目录存在但 `type` 不可读，也不误报为“没有电源”。UPS 按电池容量展示，
没有电池状态时不把摘要写成空闲；明确 `present=0` 的电池不显示残留电量。

Linux PCIe AER 读取每个设备自己的可纠正、非致命和致命报错文件，
只使用内核的 `TOTAL_ERR_*` 作为总量；一个错误消息可能带多个错误类，
类别数不能相加充当消息总数。根端口计数覆盖其下整个子树，单独展示，
不与设备总数相加。报错计数表示设备或链路**观察到**错误，
不能直接据此认定该设备是故障源。缺少 AER 文件是正常能力缺席；
个别文件权限或格式失败只标记该设备的 AER 状态，不影响 PCI 清单。
连续两次扫描的 PCI 地址、厂商/设备、类别、修订和父节点一致且时间前进时，
详情与 JSON 还给出各总数“自上次扫描新增”的消息数及实际间隔；
首次读取、缺失字段或身份变化标为 `gap`，计数下降标为 `reset`，
不当作负数或计数器回绕。相同型号的设备若在同一位置被替换，
这些可见标识未必能证明物理身份未变，因此增量只描述同一可见
PCI 身份下观察到的计数变化，不作为故障端点归属证据。
Agent 对本轮新增的致命和非致命报告各最多给出一条线索；
设备与根端口可能报告同一事件，因此不求和，亦不因自启动以来的旧计数
或首次/重置样本发信号。可纠正报告只保留在设备详情和完整快照中。
每个文件最多读取 16 KiB。参见
[Linux AER sysfs ABI](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-bus-pci-devices-aer_stats)。

Linux PCI MSI/MSI-X 清单只读每个设备的 `msi_irqs` 目录和向量模式，
再按数字 IRQ 与 `/proc/interrupts` 的各 CPU 累计计数相连；不靠驱动
标签推断设备。每设备最多保留 256 个向量，全次扫描最多 4096 个；
每个向量只保留累计计数最高的四个 CPU。它们是历史观察分布，
不是当前 IRQ 亲和性。向量缺行、重复归属或计数不可读时保留状态，
不把缺口当零；全向量齐全才给出设备总数。相邻同一 PCI 身份和向量
集合的扫描给出新增计数和实际间隔，首次或身份变化为 `gap`，
计数下降为 `reset`。参见 [PCI sysfs ABI](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-bus-pci)
和 [/proc/interrupts 文档](https://man7.org/linux/man-pages/man5/proc_interrupts.5.html)。
同一向量还只读 `/proc/irq/<N>/effective_affinity_list` 与
`smp_affinity_list`，分别保留内核报告的生效与允许 CPU 列表，
每次扫描合计最多读取 1024 个亲和性属性。某些托管 IRQ 关闭时，
生效列表也可能显示 `0`；因此这里不根据一个列表断言中断正在送往
CPU0，也不把历史累计最多的 CPU 当成当前亲和性。参见
[SMP IRQ affinity](https://www.kernel.org/doc/html/latest/core-api/irq/irq-affinity.html)
和 [托管 IRQ 文档](https://www.kernel.org/doc/html/next/core-api/irq/managed_irq.html)。

Linux SR-IOV 只读 `sriov_totalvfs`、`sriov_numvfs` 和 VF 的 `physfn`
符号链接。前两者分别是该 PF 当前公布的 VF 上限与已启用数量；
`physfn` 指向 VF 所属的 PF。共享设备树保留 PCI 桥接父节点，
另用 PF/VF 引用连接函数；已启用数和可见 VF 数不一致时标记关系不完整。
没有 `physfn` 的功能不会被推断成 VF，也不会修改 VF 启用配置。
这里没有枚举 `virtfnN`，因此不报告 VF 在 PF 下的索引。
参见 [Linux PCI sysfs ABI](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-bus-pci)。

Linux IOMMU 组只读 PCI 设备的 `iommu_group` 链接及对应的
`/sys/kernel/iommu_groups/<id>/devices` 目录。详情和 Snapshot 同时显示
内核报告的组成员名称，以及当前 PCI 清单中可见的同组功能引用；组成员
可能包含非 PCI 设备，因此可见 PCI 引用不代表完整组。目录缺失、拒绝、
截断或与设备链接矛盾时，关系标为部分数据。该视图不判断设备是否适合
交给 VFIO。参见 [Linux IOMMU group ABI](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-kernel-iommu_groups)
和 [VFIO 文档](https://kernel.org/doc/html/latest/driver-api/vfio.html)。

**词汇表是封闭的,表外的标签会被拒绝而不是被向上归整。**`Snapshot.merge` 做规范化,所以采集器无法把不可发布的词放进记录——而它规范化*到*哪个方向才是要紧的部分。测量下来,`ok` 结果上的未知质量过去会变成 **`fresh`**,而状态保持 `ok`、原因留在旁边,于是一条记录可以同时发布状态 ok、质量 fresh 和一个说部分资源不可读的原因;一个误拼成 `partail` 的真实降级被作为 fresh 数据发布,新数字就安装在它下面。未知的*状态*早已在另一个方向被拒绝,这让质量一行显得是例外而非选择。现在两者是同一步:不可发布的状态或质量会像彻底失败一样使记录失败。被拒绝的拼写不携带到任何地方——`quality[resource]` 没有容纳它的字段,而增加一个会改变已发布的 v1 文档。

有一个后果是陈述出来的而不是期望出来的。`stale` 意为"不再新鲜的保留值",而判断值是否被保留的测试是 `previous[resource] ~= nil`——但 `Snapshot.new` 用 `{}` 播种每个资源,所以从第一个快照起它就成立,首个失败样本会被标为 `stale`,身后却是一个空表。没有安装错误的东西,也没有显示数字,所以谎言不大;为播种的空表定义"保留"的含义是对数据模型的修改,不是一个补丁。

**质量记录上的 `timestamp_ns` 是上一次*尝试*的时间,不是该记录所限定的值的时间。**`value_timestamp_ns` 是当前所持数值的有效观测时间；失败后保留值或只更新提供方状态时不会续期。快照和 Agent 同时给出按捕获时间计算的 `value_age_ms`。从未安装过值，或旧快照没有可靠的值时间来源时，这两个字段缺席，不用最近一次失败尝试冒充值的时间。传感器详情的过期提示也按值时间计算。

Linux 多 GPU 采样按厂商保留独立观测。某一驱动等待或失败时，旧设备和读数
标为 `stale`，其他来源继续更新。过期读数不进入当前利用率汇总、曲线或
功耗占比；功耗详情显示读数年龄和原因。完整枚举确认移除、DRM 关联签名
变化或消失时会放弃对应保留值。部分枚举中尚未重新见到的设备保留为过期。
同一当前设备有有效 hwmon 通道时，过期厂商功耗不会遮住它的新读数；该通道
只与自己的上限比较，不沿用旧厂商上限或平均窗口。

## 10. 表格列序(历史断言)

进程表的列编辑器由两个决定约束,使其不会变成第二套自相矛盾的列系统。**默认值是历史的渲染顺序和历史的列集**,所以从不打开编辑器的用户看不到任何变化;在此功能之前断言表格形状的 73 个单元测试至今原样通过、未被改动。**用户的选择与渲染器的响应性是两个不同的决定**:`full_only` 和 `priority` 决定*小面板*丢弃什么,并且在用户已选的任何列集之上仍然适用;用户隐藏的列在模型中完全缺席。

### NUMA 与频率域

NUMA 距离是相对值，不是延迟纳秒数。距离列按[内核的在线节点顺序](https://github.com/torvalds/linux/blob/master/drivers/base/node.c)映射；
列表改变时丢弃本轮距离映射，保留其他可读数据并标为 partial。
节点已用内存按总量减空闲计算，包含缓存，不等同于主机的可用内存估计。
缺失的 CPU 列表或内存读数保留为未知，空 CPU 列表可表示仅有内存的节点。
`numastat` 的六项是自启动以来的页分配计数，不是内存访问次数。
`local_node` 与 `other_node` 分别按分配节点相对运行 CPU 的位置计数；
表格显示后者的页/秒变化，详情保留六项累计值与两项速率。
旧内核缺少 `numastat` 时不影响拓扑质量；读取错误或不完整则只标记
该节点 partial。计数器回退时本轮速率未知，不把负增量当作流量。

进程详情中的节点占用来自 `numa_maps`：逐映射按该行的内核页大小换算，
因此大页不会被当作普通页。数字包含共享映射，是进程当前映射到各节点的
页数换算值，不是 PSS、唯一物理内存或内存访问速率。读取最多 2 MiB、
8192 个映射和 128 个节点；超出界限或权限不足时仅该详情为空，
不降低进程表质量。详情不保留映射地址和文件名，Snapshot 不导出此按需数据。

CPUFreq 的 `related_cpus` 包含离线 CPU；缺少它时只使用已知的
`affected_cpus`。策略读数保持来源与 measured/estimated 区别，
不会改称独立测出的逐核心有效频率。参见
[NUMA 计数器说明](https://docs.kernel.org/admin-guide/numastat.html)、
[进程 NUMA 映射格式](https://github.com/torvalds/linux/blob/master/Documentation/filesystems/proc.rst)、
[NUMA sysfs ABI](https://www.kernel.org/doc/Documentation/ABI/stable/sysfs-devices-node)与
[CPUFreq 文档](https://docs.kernel.org/admin-guide/pm/cpufreq.html)。

Linux 另有独立的逐逻辑 CPU `cpu_clocks` 观测：读取只读的
`IA32_APERF` 与 `IA32_MPERF`，用 APERF 周期增量除以本 CPU 的实际单调
时间窗口得到有效频率，计入空闲时间。它会低于 CPU 活跃时的时钟，不能与
策略频率混为一谈。APERF/MPERF 只作为无量纲比值保留，不借用未知的
参考时钟推算忙时 MHz。这个区分与 [Linux turbostat 的 Avg_MHz 定义](https://github.com/torvalds/linux/blob/master/tools/power/x86/turbostat/turbostat.8)
一致；寄存器语义参见 [Intel 软件开发手册](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)。

当前支持带相应硬件反馈能力的部分 Intel Core 型号，包含本机的混合 P/E
核心；不把这个计数布局推广到 Atom、Phi、AMD、虚拟机或其他架构。
这些主机仍使用各自已有的 CPUFreq/原生频率来源。Linux 需要 `msr` 设备的
读取权限，普通权限不足时保持 denied，首次读取与计数复位保持预热或 gap，
不会填入零频率。真实的零只表示该有效窗口没有计到执行周期。

逻辑 CPU 表显示有效频率，CPU 设备详情保留窗口、窗口不确定度、
原始计数和样本年龄；Snapshot 还保留整个读取跨度。Snapshot 的 `cpu_clocks` 与 Agent 的
`metrics.cpu.effective_clocks` 保留来源与观测时间；Agent 摘要只使用当前
有效数据，并明确按逻辑 CPU 求平均，列表按输出上限截断。在线列表或
CPU 身份变化、读取失败、窗口过短或不可靠时，不发布新的有效频率。
采集运行在独立读取进程中，超时后重新预热计数基线。

当前值优先采用 `cpuinfo_cur_freq`，其次采用基于硬件反馈的
`cpuinfo_avg_freq`；只有两者都不可读时才用 `scaling_cur_freq` 并标为
估算。内核可能在 CPU 空闲时对硬件平均值返回 EAGAIN，此时不会把它
报成采集故障；零频率也不作为有效读数。Compute 表逐策略显示频率
来源与质量，System 策略详情保留硬件反馈和调频读数的区别。

Compute 的策略表和 System 策略详情还显示可信关联的 `coretemp` 温度。
策略成员全部落在同一实测核心时使用该核心温度；否则只有全部落在同一
实测封装时才显示封装温度，并明确标注层级。这是所关联核心或封装的
读数，不是策略自身的温度。成员缺失、跨封装、传感器归属有歧义或来源
不可用时留空。旧内核的 `Physical id N` 与当前主机的 `Package id N`
标签都可用于封装关联。参见[当前 coretemp 文档](https://docs.kernel.org/hwmon/coretemp.html)和[旧版内核文档](https://docs.kernel.org/6.2/hwmon/coretemp.html)。

热节流次数是启动以来的状态切换次数，新增列只比较相邻采样；首次读数和
计数器回退时留空。同一封装的计数会在多个逻辑 CPU 上重复，因而界面和
Agent 不把它们相加。累计次数不代表当前仍在热节流。参见
[Linux Intel 热节流计数器文档](https://docs.kernel.org/admin-guide/thermal/intel_thermal_throttle.html)。

CPU 空闲态的 `usage` 和 `time` 保留内核累计原值；Compute 表显示相邻样本
使用次数及报告时间的增量。首次读取和计数器回退时不推断增量。`time` 是
内核对该状态持续时间的估计，并不证明硬件实际进入了该状态；表格因此不将
它称为硬件驻留率。`latency` 是退出延迟，`residency` 是目标驻留时间，
单位均为微秒。可用时还读取 `rejected`、`above` 和 `below`：它们分别计数
被拒的进入请求、实际时长短于目标、以及更深状态本可匹配的次数。
三个计数独立求增量；首次读取或回退时不推断增量，旧内核未提供时留空。
这些次数是状态选择的诊断信息，不直接等于硬件故障。参见
[Linux CPUIdle 文档](https://docs.kernel.org/admin-guide/pm/cpuidle.html)。

### SMBIOS 内存信息

内存页的设备表和系统设备树使用相同的内存清单。SMBIOS 入口和内存字段
按 [DSP0134 3.8.0](https://www.dmtf.org/sites/default/files/standards/documents/DSP0134_3.8.0.pdf)
解码；表内扩展长度允许读取新字段，短记录保留可用的旧字段。
Linux 读取权限由内核控制；普通用户无法读取时显示 denied。
Windows 动态查找 [GetSystemFirmwareTable](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-getsystemfirmwaretable)，
没有该 API 的系统保持不可用；macOS 提供方尚未实现。

这些是固件报告的配置和能力。SMBIOS 纠错声明不作为 ECC 当前健康状态，
配置速率不作为实时测量时钟，槽位/存储体名称不用于猜测通道、NUMA 或
温度传感器归属。序列号、资产标签、UUID 与原始固件数据不进入导出。
Type 19/20 映射范围按固件句柄连接到阵列和设备。交错设备的地址范围
可能重叠，范围跨度不用于推算模块容量或操作系统可用内存。
Type 37 通道记录只按明确的 Type 17 句柄连接内存设备；负载总和超过
固件声明的最大值或引用不完整时保留记录而不建立关系。负载不是带宽测量。

Type 4 处理器插槽与 Type 7 缓存也是固件清单。设备树只按固件明确给出的
缓存句柄关联，未被引用的缓存仍单独显示。固件中的核心/线程数、启动
速率和缓存容量不替代操作系统实测拓扑、频率与缓存清单；不凭插槽名称
猜测它与 Linux CPU 包的对应关系。

扩展槽使用同一份 SMBIOS 表的 Type 9。固件 PCI BDF 可指向端点，也可能
在具体主机上指向上游端口，因此设备树只展示双向“固件槽位引用”，不把
PCI 设备放在槽位下面。使用状态为“可用”的槽位不引用当前 PCI 设备。
Type 10/41 板载设备保留为独立固件记录。旧式 Type 10 可在一个结构中声明
多个设备，以句柄和条目序号分别显示，不凭相同名称与 Type 41 合并。
Type 10 没有 PCI 地址；Type 41 启用、来源当前且地址唯一命中时，
设备树展示双向 PCI 引用，不把固件记录作为 PCI 父节点。
Type 22 电池留在固件树，容量按固件倍率换算为 mWh；它不凭名称与操作系统
电池相连，当前电量和健康状态仍由操作系统数据源负责。
Type 39 电源同样留在固件树。相同的非零组号说明固件声明冗余配置，
但不证明两台电源此刻都能供电；额定输出不作为实时功耗。固件表的
最大输出字段按表中瓦的说明显示，同时保留原始数值供核对。
Type 38 IPMI BMC 接口同样是固件声明。16 字节记录只显示已给出的字段；
较长记录可显示寄存器间距、地址最低位和中断。它不用于推断 BMC 当前健康。
Type 43 TPM 记录显示固件声明的厂商、规范版本和配置特征，不把它当作
操作系统中的可用性、密钥状态或安全健康检查。
Type 45 固件组件记录显示名称、版本、制造商、发布日期、镜像大小和固件
声明的状态。自由格式的 Firmware ID 可能包含资产标识，不进入公开模型；
只有符合标准格式的 GUID 才显示。关联句柄仅在当前 SMBIOS 设备树中唯一
对应已知节点时建立双向引用，不当作物理父子关系。组件的“可软件更新”位
不是 wtop 能执行更新、也不是更新服务当前可用的证据。
Linux ESRT 按目录条目采集，即使属性只允许 root 读取，也保留已发现的
条目数并将各字段标为拒绝；System 固件摘要显示条目数与拒绝数，不填入
猜测的 GUID 或版本。ESRT 的上次尝试
代码保留原始数值：`0` 也可能表示从未尝试更新，不能被当作成功更新的证据。
只有 Type 45 标准固件 GUID 与 ESRT 类别 GUID 在两份当前清单中各唯一时，
设备树才建立双向引用；这仍不是物理父子关系。参见
[Linux ESRT sysfs ABI](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-firmware-efi-esrt)
与 [UEFI ESRT 定义](https://uefi.org/specs/UEFI/2.10/23_Firmware_Update_and_Reporting.html#efi-system-resource-table)。
Type 42 管理主机接口可声明多个协议；固件表中的 IPMI、MCTP、Redfish
标签不代表当前控制器可访问。Type 38 与 Type 42 可能重复描述同一接口，
设备树没有可信身份键时不合并。

EDAC 的实时错误计数作为独立控制器树显示。两份列表未截断且标签各唯一时，
EDAC DIMM 和 SMBIOS 已填充槽位显示双向的同名引用。标签可被修改，因此
不把它当作可靠的物理身份键，也不合并两份计数。
System 页按 `/` 在完整共享设备图中搜索已展示的名称、ID、总线、类别，以及
设备详情中的驱动、厂商和型号。命中项连同图中已确认的父节点在 512 行上限前
筛选；未公开的序列号、资产标签和原始固件表不参与搜索。`Esc` 清除筛选。
没有 `mc*` 控制器的 Linux 主机报告不可用。`coretemp` 的包温度与核心温度
只在包号明确且目标唯一时归属到 CPU 树。
FPM/EDO/SDR/DDR/DDR2/DDR3/DDR4/DDR5 SPD 从内核公开的 EEPROM 属性分段只读。
FPM/EDO/SDR/DDR/DDR2 型号在首个 128 字节内，其余代际的型号需读到后续页才会出现；
前 128 字节可读而后续页失败时，基础字段仍显示为部分数据。原始 EEPROM
与序列号不进入快照。DDR5 的 `spd5118` 按同一 I²C 设备地址相连；DDR4
的 `jc42` 还需基础 SPD CRC 有效、温度存在位或 SPD 1.0 例外成立，
并与同总线的 EEPROM 地址对应。不凭容量或型号猜测 SMBIOS 槽位。
DDR3 的 `spd` EEPROM 只有 256 字节；`jc42` 关联还需 DDR3 类型字节、
基础 CRC 和温度存在位成立。DDR4 的容量公式只用于基础块校验有效的
非堆叠模块；3DS 模块不猜容量。
FPM/EDO/SDR/DDR/DDR2 使用前 63 字节的校验和；旧 `eeprom` 驱动只在头部符合
SPD 格式时纳入。校验失败时不发布容量、
位宽、Rank、模块 bank 数和最短周期，也不把同地址温度归属到该模块。只有前 64 字节
可读时，校验与基础字段仍能解码，采集质量标为 partial。
SDR 的两行混合密度可直接求和；超过两行且密度混合时容量保持未知。FPM/EDO 根据行/列地址数、模块 bank 数和有效数据位宽推导容量；其第 31 字节是保留字段，不使用 SDR 的密度位图。只在校验和与几何字段有效时发布容量。格式依据 [TI 的 FPM/EDO SPD 技术参考](https://www.ti.com/lit/pdf/smmu001)。
