# wtop 实施计划与当前状态

## 1. 定位

wtop（WaterRun's top）是 Linux-only 的现代 TUI 性能工作台。目标是把
“现在发生了什么”“为什么变慢”“哪个进程或设备相关”和“可以安全做什么”
放进同一个响应式界面。

当前版本是 `0.1.0-dev` development preview，不是已经完成的 0.1 release。
首条 CPU/内存/PSI → Snapshot → ViewModel → responsive TUI → luainstaller
纵向切片已经工作；后续重点是补齐功能、硬件后端和发布证据，而不是继续把
设计文档当作现状。

## 2. 状态定义

- **已实现**：存在运行时代码和自动测试，当前开发主机可执行。
- **部分实现**：基础路径可用，但 UI、provider、权限或平台矩阵不完整。
- **计划**：设计文档中存在，当前运行时尚未交付。

“已实现”不等于已经通过所有发行版、内核、终端或真实硬件验证。

## 3. 原始需求映射

| 原始要求 | 当前状态 | 下一阶段缺口 |
| --- | --- | --- |
| 美观的现代 TUI | 已实现自有 cell grid/diff、四种主题、颜色降级和响应式页面 | 视觉打磨、完整 overlay、更多终端矩阵 |
| 不同比例窗口适配 | 已覆盖 tiny、窄高、宽矮、宽高及四种 PTY 尺寸 | 连续 resize、tmux/SSH、更多极端尺寸 |
| 可自定义布局 | 固定 Widget 可四向移动、调整 split 比例、撤销/重做，并按 schema v2 持久化 | Widget 增删/替换、拖拽、导入/导出、恢复/备份 |
| 多选项卡 | Overview、Processes、Compute、Storage & I/O、Network、GPU、Workloads、Insights 八个固定标签可用 | 标签增删/重命名/排序和多工作区 |
| i18n | 安全 YAML、内置 plural rule、formatter、生成 registry、主 TUI 字符串、逐 key 回退和有界 XDG 用户 catalog 加载已实现 | 技术 reason 本地化、伪语言、RTL |
| 更强性能监控 | CPU、内存、PSI、磁盘、挂载点、网络/socket、进程、CPUFreq、hwmon、cgroup v2 和 DRM/sysfs GPU 已实现 | NUMA/RAPL、路由、systemd/容器语义、线程/PSS 与跨资源关联 |
| 深度查看 | 可选设备 SMART/NVMe、实验性 `perf stat` RAM PMU 采样、sshd Inspector 可用 | 统一资源导航、完整 session/event provider、PMU 平台映射和校验 |
| GPU | DRM 设备、AMD sysfs/DPM、Intel i915/xe 频率、DRM fdinfo 进程表与 hwmon 温度/功率关联已实现 | client/region 钻取、NVML、AMD SMI、Level Zero、MIG/tile |
| 性能释放/动作 | 诊断优先；TUI 只暴露带 PID 身份复验的 `SIGTERM` | 明确定义产品范围，再决定 STOP/CONT、renice 或调优协议 |
| Linux Only | rockspec、Make/bootstrap、C 编译期和统一 CLI 入口拒绝非 Linux，数据层只实现 Linux | 最低内核/发行版基线 |
| 使用 Lua | 业务、采集、UI、配置和 i18n 使用 PUC Lua | 保持 5.4 语法子集与 5.5 发布 ABI |
| LuaRocks 安装 | Linux-only `scm-1` rockspec、隔离安装与已安装 CLI smoke 已实现 | 发布版本化 rock |
| luainstaller | onedir/onefile、显式 locale include、锁定 payload 校验和 `make checksums` 已存在 | 多架构/libc、最终候选重建、SBOM/signing |

## 4. 当前实现基线

### 4.1 运行时

- PUC Lua 5.5.1 是发布 toolchain；LuaJIT 不受支持。
- 源码避免 5.5 独有语法，纯 Lua 单元测试同时跑 5.4。
- 项目内 `wtop_native.so` 使用 C17 和 Lua C API，当前承担：
  - raw terminal、poll、resize/退出信号与恢复；
  - monotonic/realtime clock；
  - 绝对 argv 子进程、最小环境、进程组清理、取消、timeout 和输出上限；
  - Linux 文件系统辅助、原子写入、pidfd identity signal、wcwidth 等窄接口；
  - nonblocking/no-follow 的有界 regular-file reader：默认 4 MiB、显式最大
    64 MiB，拒绝最终 symlink、设备、FIFO 和超限输入。
- 当前没有 `luv`、第三方 `terminal.lua` 或其他运行时 LuaRock 依赖。
- native 默认以 `-O2 -g0` 构建，且 Makefile 是模块 target 的依赖，构建规则变化会
  触发重编译。
- Scheduler 使用单线程 deadline 调度；进程/CPUFreq/hwmon 采样下限
  1000 ms，socket/cgroup 下限 2000 ms，挂载点下限 5000 ms，GPU 下限
  500 ms，失败任务退避。非当前页面使用更慢的背景间隔。

### 4.2 UI

- 标签：Overview、Processes、Compute、Storage & I/O、Network、GPU、
  Workloads、Insights。
- Widget：metric、sparkline、table、text、panel、tab/status bar。
- 虚拟 cell grid 按显示列宽绘制，diff renderer 只输出变化 runs。
- 支持键盘、基础鼠标、bracketed paste 解码、resize 和终端能力降级。
- 当前布局编辑在同一页面内对固定 Widget 执行四向移动、split 比例
  调整和最多 50 步的每页撤销/重做。不能增删或替换 Widget。
- 响应式默认几何会按实际矩形选择信息最丰富的可用 form；紧凑窗口先换轴/重排，
  空间仍不足才保留焦点或高优先级分支。standard 最多两列、wide-short 最多四列、
  wide-tall 最多三列。实际 placement 同时驱动 ViewModel 和 collector
  可见性；隐藏表不建模，无其他可见 Widget 需要的 collector 转背景间隔。
- 进程页已提供文字搜索、固定排序循环、PPID 树、选中项详情和确认
  `SIGTERM`；它仍不是完整的 htop 式进程浏览器。

### 4.3 数据

- CPU：`/proc/stat`、`/proc/loadavg`。
- 内存：`/proc/meminfo`、`/proc/vmstat`。
- 压力：`/proc/pressure/{cpu,memory,io}`。
- 磁盘：`/proc/diskstats` 和 sysfs block size。
- 网络：`/proc/net/dev` 和 `/sys/class/net`。
- 连接：`/proc/net/{tcp,tcp6,udp,udp6,unix}`；只在 Network 页连接表实际
  placement 可见时执行有界 `/proc/<pid>/fd` owner 扫描。
- 进程：`/proc/<pid>/stat`、status；详情接口可读取 cmdline/io/cgroup。默认
  collector 上限 8192 个 PID，TUI 模型上限 2048 行。
- CPU 频率：cpufreq policy sysfs。
- 传感器：`/sys/class/hwmon`；挂载点：`/proc/self/mountinfo` 和 `statvfs`。
  网络文件系统、autofs、FUSE/`fuse.*`、fuseblk 与 virtiofs 默认跳过可能阻塞的
  statvfs，只保留 mountinfo 元数据并标 partial/estimated。其余默认原生调用共享
  50 ms 后续调用预算，但已进入的单次 statvfs 不可抢占。
- Workloads：`/sys/fs/cgroup` 下的 cgroup v2 文件，默认深度上限 16、节点
  上限 4096。
- GPU：`/sys/class/drm/card*`/render nodes、PCI identity、AMD busy/VRAM/DPM、
  Intel i915/xe 频率和 `/proc/<pid>/fdinfo` DRM client 计数。GPU 采集器只记录
  hwmon 关联键、不重复读取传感器；ViewModel 已按 hwmon `class`/`device_target`
  回填温度/功率并提供 GPU 进程表。交互 fdinfo 只在该进程表实际 placement 可见
  时扫描；snapshot 仍强制完整扫描。

进程模型之外，连接、挂载点、workload 和 GPU 进程表各最多建模 512 行。采集
预算命中使用 `partial`/`truncated`；单纯 UI 行上限不改写 collector quality。
进程/GPU 进程和连接状态提供总数线索，挂载点/workload 当前没有单独的 512-row
显示截断提示。Insights 没有前台 collector，不会为装饰性进程/GPU 数以 1 Hz
重新采样，只使用已有背景快照。

所有 collector 返回 status、quality、timestamp、duration、source 和 reason；
首个 counter 样本、reset、设备变化和缺失值不会伪装成零。

### 4.4 Inspector 与动作

- SMART/NVMe 先从 `/sys/class/block` 枚举最多 256 个候选，由用户选择后调用
  `smartctl --json=c --nocheck=standby --all`；带 timeout、输出上限、60 秒缓存、
  serial mask 和设备路径校验。目前不使用 `smartctl --scan-open` 或 bridge 类型探测。
- RAM bandwidth Inspector 的 formula v4 会发现名称匹配的 PMU，并通过外部
  `perf stat -a -A`/`sleep` 对有限 data/CAS 事件作一次约 250 ms 系统级短采样。
  每个 PMU 控制实例用自己的 CSV runtime 计算后求和；Intel free-running/CAS
  替代族整族择一，相同 descriptor alias 去重。缺实例、单方向、部分事件或
  multiplex 标为 estimated。纯 EINVAL/event-open 失败返回 unavailable，并在
  `perf_event_paranoid` 提示可能相关时附 `permission_may_be_required`；只有明确
  权限诊断归 denied。启动 probe 不执行 `perf` 或验证权限。它没有 CPU family/model
  映射、multiplex 校正、socket/channel 拆分或连续图。理论值 API 只在调用方提供
  可信速率/通道/总线宽度时返回，默认 TUI 实体未提供这些数据。
- sshd Inspector 可组合 systemd、进程和 `/proc/net/tcp*` 证据。默认应用
  没有 session/journal provider 时，对应 section 明确 unavailable。
- TUI 进程动作只发送 `SIGTERM`；Lua 层复验 PID/starttime，原生层持有 pidfd
  再次核验并发信号，关闭 PID 重用窗口。

### 4.5 配置、i18n 与输出

- `config.yml` 使用 config schema v1；`layout.yml` 写入二叉 split 树的 layout
  schema v2，并兼容读取线性顺序的 v1。两者都使用受限 YAML profile，布局通过
  原生原子写入。
- CLI/config theme 严格限制为四个内置精确名称。locale tag 先做语法拒绝与
  规范化；合法未知 tag 可由 TUI 的 XDG 用户 catalog 提供，而不是强制属于内置表。
- 内置 locale 从 YAML 确定性生成 Lua modules，registry 使用字面量
  `require`。
- `en-US`、`zh-CN` 为 stable；其余首批八种语言为 preview 并逐 key 回退。
- CLI 提供 TUI、`--snapshot` JSON 和 `--diagnose`。
- TUI 启动时有界加载 XDG 自定义 locale 文件；`--snapshot`/`--diagnose`
  不创建 translator，也不扫描该目录。
- JSON snapshot 默认遮罩 socket 远程 IP，并以遮罩后的 endpoint 重建导出连接
  ID，防止内部 ID 泄露完整远端；它仍不遮罩远程端口、本地地址、Unix socket
  路径或网卡 MAC。TUI 网络页显示完整 endpoint，当前无遮罩开关。
- JSON snapshot 还导出不含 `path` 字段的 `configuration.state` 与可选
  `configuration.reason`，供脚本区分 loaded/default/error/unavailable。
- 严格 JSON decoder 默认限制 4 MiB、深度 64、100000 个 value node，并线性
  扫描数字；encoder 将字符串值和 object key 中的非法 UTF-8 替换为 U+FFFD。

### 4.6 当前验证入口

```bash
make check
make test
make test-54
make test-luarocks
make bundle-dir
make bundle-file
make test-bundle-dir
make checksums
```

`make test` 当前包含 36 个 Lua 5.5 单元/fixture 测试文件与响应式/色深真实 PTY matrix；
`make test-54` 验证纯 Lua 5.4 兼容子集。默认 luainstaller 1.3.0-1 payload 由
`tools/luainstaller-1.3.0.sha256` 锁定；相邻工作树不会自动使用，绝对路径
`WTOP_LUAINSTALLER_ROCKSPEC` 才是显式开发 opt-in。`make checksums` 只为两个
bundle 可执行入口生成 `dist/SHA256SUMS`。打包验证目前仍以 Fedora glibc x86_64
开发主机为主，不是正式发布，最低 glibc 尚未承诺。

## 5. 0.1 release 目标

以下标记描述相对“可发布 0.1”的完成度：

- [x] Linux-only Lua 5.5.1 toolchain 与原生终端恢复。
- [x] CPU、内存、PSI、磁盘、挂载点、网络/socket、基础进程、CPUFreq、
  hwmon、cgroup v2 和通用 DRM collectors。
- [x] 响应式八标签框架、cell diff、主题和基础鼠标。
- [x] 配置、layout schema v2 树持久化（兼容 v1）、JSON snapshot 和 diagnose。
- [x] YAML i18n 编译、stable/preview 目录与逐 key 回退。
- [x] onedir/onefile build target。
- [x] 默认 luainstaller payload hash 校验，以及两个 bundle 入口的 checksum target。
- [x] Linux-only LuaRocks 安装、隔离 tree smoke test 与 MPL-2.0 仓库许可证。
- [~] 进程页：已有文字搜索、固定排序循环、PPID 树、详情 overlay 与确认
  SIGTERM；线程、PSS/USS、组合过滤、列管理和跨资源跳转未完成。
- [~] 布局编辑：已有方向树移动、比例、撤销/重做；Widget 增删/替换、拖拽、
  导入/导出、备份/恢复未完成。
- [~] Inspector：三个原型可用；导航、provider 和真实主机覆盖不足。
- [~] GPU：DRM/sysfs/fdinfo、进程摘要表与 hwmon 温度/功率回填可用；三家
  vendor API、fan 展示和 client/frequency-domain/memory-region 钻取尚未实现。
- [~] 完整 i18n：主 TUI、表头、帮助和 Inspector 标签已接入；provider 原始
  字段 ID/reason、preview 翻译完整度、伪语言与 RTL 尚未完成。
- [x] Workloads/cgroup v2 页面与 collector 基础路径。
- [x] CPUFreq、通用 hwmon 与挂载点容量基础路径。
- [~] GPU 的 class/device_target 传感器关联已实现；更通用的设备拓扑关联、
  systemd/容器语义与更完整进程数据仍未完成。
- [ ] 性能预算实测与回归门禁。
- [ ] glibc aarch64、最低 glibc/kernel 和计划中的 musl 发行证据。
- [ ] 真实 NVIDIA/AMD/Intel 与无 GPU 硬件矩阵。

### 5.1 安全边界

0.1 保持普通用户、默认只读，不引入常驻 root daemon。任何进程动作必须：

1. 保存 `(pid, starttime)` 身份；
2. 执行前重新读取 `/proc/<pid>/stat`；
3. 通过 `pidfd_open` 固定原进程，再核验 starttime，并使用
   `pidfd_send_signal`；
4. 拒绝 PID 1、wtop 自身和身份变化；
5. 显示目标并要求明确确认；
6. 返回逐目标错误，不把无权限伪装成成功。

是否在 0.1 继续开放 SIGKILL、STOP/CONT 或 renice，需要单独的 UI、安全和
测试评审；底层存在能力不代表产品已经承诺暴露。

## 6. 非目标

- macOS、Windows、BSD。
- 集群、远程 agent 和长期指标数据库。
- 自动清理缓存、自动杀进程或“一键加速”。
- 固件更新、分区/文件系统修复等破坏性设备管理。
- 必须存在的特权 helper。
- 稳定第三方插件 ABI。
- Kubernetes 编排级视图。
- 保证所有 GPU/驱动暴露同一组指标。

## 7. 后续路线

### 阶段 A：development preview 稳定化

- 本地化 provider 技术 reason，加入伪语言和 locale layout tests。
- 将 onefile PTY、clean-env、locale `--check` 加入标准 CI。
- 增加 crash/signal/continuous-resize、tmux 和 SSH 场景。
- 建立可重复性能 benchmark，校准 CPU、RSS、首屏和输入延迟预算。
- 为配置/布局增加显式迁移工具、备份和更清晰的错误恢复；当前只是
  layout v1 兼容读取和 v2 重写。
- 为 TUI 连接表增加隐私遮罩/导出策略，并为 JSON 中的端口、本地地址、
  Unix socket 路径与 MAC 建立明确契约。

### 阶段 B：0.1 功能补齐

- 进程组合过滤、可选排序方向、线程/PSS/USS、namespace 和完整详情导航。
- Widget 增删/替换、拖拽、布局导入/导出与标签/工作区管理。
- 为 cgroup v2/Workloads 增加展开/折叠、详情、systemd unit 和容器语义。
- 将现有 GPU hwmon `class`/`device_target` 关联扩展为更通用的 CPUFreq、传感器、
  挂载点与设备拓扑关联，并定义 fan/rail/board-power 语义。
- NVML、AMD SMI、Level Zero 动态 provider 与 fake library tests。
- 将现有 GPU 进程摘要扩展为 client/引擎/memory-region 钻取和主进程详情反向跳转。
- 为 RAM PMU 建立 CPU family/model 事件白名单、multiplex 校正、分 socket/controller
  聚合和真实硬件误差门禁；在此之前继续标为实验性。
- SMART、RAM bandwidth、服务 Inspector 的统一资源导航。

### 阶段 C：0.2

- 多 GPU/MIG/tile 的 vendor 语义与更完整的 GPU 进程关联。
- systemd unit、容器、线程、PSS/USS 和进程 I/O 深化。
- RAPL、节流原因、传感器与洞察规则。
- 第二批语言和布局导入导出。
- glibc x86_64/aarch64 的稳定发行矩阵。

### 阶段 D：0.3 及以后

- 指标录制与回放。
- 可选 perf/eBPF 后端、热点调用栈和火焰图。
- 跨资源时间线关联和告警规则。
- EDAC/ECC、DIMM/NUMA、RAID/LVM/ZFS、PCI/USB 等扩展 Inspector。
- 只有在明确用户需求和权限模型后，才评估独立最小权限调优 helper。

## 8. 性能目标

以下仍是待实测和校准的 release 目标，不是当前结果：

| 场景 | 目标 |
| --- | --- |
| 1000 进程、默认 1 秒采样 | 平均 CPU 小于一个核心的 2% |
| 空闲仪表盘 | RSS 小于 60 MiB |
| 输入到画面 | p95 小于 50 ms |
| 首屏 | 冷启动小于 500 ms |
| 无数据变化 | 不执行全屏重绘 |
| 历史数据 | 定长，不能随运行时间无限增长 |
| 采集失败 | 单个 collector 退避，不阻塞其他 collector |

当前实现已经具备定长 ring、diff output、collector duration、scheduler backoff、
首屏隐藏源延后和 GPU fdinfo 按实际进程表 placement 启停。在当前 x86_64 开发主机的一次
safe-mode 实测中，Overview 的 probe+当前页首次采样约 91 ms，切到 GPU 后完整
fdinfo 首次采样约 104 ms；这些单机数值不是跨机器 release 证明，仍需可重复的
CPU/RSS/输入延迟 benchmark。

## 9. 0.1 发布门禁

- 单元、fixture、PTY、clean-env、onedir 和 onefile 测试通过。
- `/proc` 竞态、PID 消失、counter reset、设备热拔插和权限错误不终止应用。
- stable locale 覆盖与占位符一致；preview 状态不被误报为稳定翻译。
- 所有核心可见字符串完成 i18n；CJK 和伪语言不破坏布局。
- 无 GPU、无 PSI、无 hwmon、无 systemd 和无外部 helper 均可降级启动。
- TUI/导出的 socket、session、设备标识和进程字段经过隐私评审；遮罩契约
  和完整值的显式选择已文档化并测试。
- 实验性 RAM PMU 结果不被冒充为通用精确测量；对声明支持的每个平台
  有事件公式、权限、multiplex 和实机对照证据。
- 原生模块 ABI、架构、`ldd` 和最低 glibc/kernel 基线有可复验证据。
- glibc x86_64 与 aarch64 目标分别完成原生构建和 PTY smoke。
- 真实性能预算在声明支持的最低/典型主机上通过。
- 发行物包含 checksum、SBOM、第三方通知和可追溯构建信息。

## 10. 已固化与待决策

已固化：

- Linux-only、PUC Lua 5.5.1 发布 ABI、Lua 5.4 语法子集。
- 自有 cell grid/diff renderer 和窄 C 原生终端 backend。
- 单线程 deadline scheduler；当前不引入 luv。
- YAML 权威 locale → deterministic Lua modules → literal registry。
- luainstaller 先 onedir、再 onefile；每个 arch/libc 原生构建。

仍待决策或证据：

- 最低 Linux kernel、glibc 和发行版基线。
- 正式 release 的 SBOM、签名与二进制再分发记录。
- 0.1 GPU 的精确能力下限（通用 DRM 是否足够，还是必须包含 vendor API）
  与真实硬件池。
- “性能释放”最终包含哪些 profiling、进程管理或调优能力。
- 0.1 是否接受当前只有原始 cgroup v2 语义的 Workloads 页，还是必须先加入
  systemd/容器标识、展开/折叠和详情。
- 0.1 是否保留实验性 `perf stat` RAM bandwidth Inspector，以及它的平台支持
  声明和默认开关。
- stable 翻译的维护者、人工评审和终端截图流程。
