# 当前架构

本文描述 `0.1.0-dev` 的实际结构，不把规划中的插件、Insight Engine 或厂商 GPU provider 当成已实现能力。

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

默认持续采集路径不需要外部 CLI。`smartctl`、`perf`、`sleep` 和 `systemctl` 只用于按需 Inspector，通过受限 Runner 启动；当前没有 NVML、AMD SMI、Level Zero 或其他厂商 GPU 库/provider。

UI 状态目前由 `tui.lua`、`workspace.lua` 和进程控制器直接协调，并没有完整的 Action→Reducer→单一 AppState 架构。仍然成立的边界是：collector 不绘制终端，widget 不直接读取 procfs/sysfs。

## 2. 主要目录

```text
src/wtop.lua             CLI 入口
src/wtop/
  application.lua       配置解析、snapshot/TUI 模式装配
  tui.lua               事件循环、按键、浮层和运行时状态
  workspace.lua         八个固定页面、widget 与布局编辑
  view_model.lua        Snapshot 到 widget model 的转换
  engine.lua            collector 调度、快照合并和历史
  core/                 时钟、scheduler、Runner、JSON 等基础设施
  linux/                procfs/sysfs 读取与 parser
  collectors/           12 个持续 collector
  inspectors/           SMART、RAM 带宽、sshd 三个按需 Inspector
  model/                Snapshot、ring 和布局树
  ui/
    backend/            原生终端接口适配
    input/              键盘、鼠标和转义序列解码
    renderer/           cell grid、Unicode 宽度、ANSI diff
    layout/              响应式求解
    widgets/             metric、text、table 等组件
    views/               页面框架
    theme/               语义主题与终端能力降级
  i18n/                  catalog、受限 YAML、格式与复数
  generated/locales/    构建期生成的内置 locale Lua 模块
  config.lua             `config.yml` schema v1
  layout_store.lua       `layout.yml` schema v1/v2 读取和 v2 保存
  actions.lua            进程身份复核和 pidfd 信号动作
native/wtop_native.c     libc-only Lua C 模块
locales/                 权威内置 `.yml` 翻译目录
tools/                   locale、toolchain、构建与检查工具
tests/                   单元/fixture 与真实 PTY smoke 测试
```

八个固定页面依次为 `overview`、`processes`、`compute`、`storage`、`network`、`gpu`、`workloads`、`insights`。当前不支持创建/删除页面或添加/删除 widget。

## 3. 运行时

### 3.1 Lua 与原生模块

- 发布 toolchain 目标是 PUC Lua 5.5.1，不使用 LuaJIT；纯 Lua 测试仍覆盖 5.4 兼容子集。
- `wtop_native.so` 必须与运行它的 Lua major.minor ABI 一致。
- 交互 TUI 需要 Linux、原生模块以及 stdin/stdout TTY；无 TTY 时使用 `--snapshot` 输出 JSON。

原生模块当前提供终端 raw/alternate-screen 生命周期、终端尺寸、`poll(2)`、信号/resize、单调/实时时钟、睡眠、文件系统辅助、`statvfs`、`wcwidth`、原子写入、受限 argv Runner、身份查询和 pidfd 信号。原生 `readfile` 使用 nonblocking/no-follow 打开，只接受 regular file，默认 4 MiB、显式最大 64 MiB，并拒绝 symlink、设备、FIFO 和超限内容；procfs/sysfs 中呈现为 regular file 的伪文件仍可读取。它不包含 widget、布局、翻译、collector 或厂商 GPU 库。

### 3.2 事件循环

TUI 使用单线程 scheduler；Lua UI 状态和 collector 都在主线程执行。事件循环每次最多以 100 ms 等待终端输入或下一个采样 deadline。只有输入、resize、采样完成或显式 invalidation 令界面 dirty 时才渲染，renderer 再输出相对上一帧发生变化的 cell runs；没有固定“10–15 FPS”承诺。

同步外部 Inspector 可能在其超时预算内占用主线程。当前不存在厂商 API worker pool 或后台 Inspector 队列。

## 4. Collector 与快照

Engine 按固定顺序注册 12 个 collector：

```text
cpu, memory, pressure, disk, network, connections,
process, gpu, cpufreq, hwmon, mounts, cgroup
```

collector 返回 `ok|unavailable|denied|error` 状态，以及 `fresh|stale|gap|estimated|unavailable|denied|error` 质量。Scheduler 捕获异常、记录耗时，并对失败指数退避，最长 30 秒。计数器 delta collector 负责把首次样本、回绕、重置或消失表达为 gap/不可用，不能制造速率尖峰。

Snapshot 当前资源形状为：

```lua
Snapshot = {
  sequence = 42,
  timestamp_ns = 0,
  cpu = {},
  memory = {},
  pressure = {},
  disks = {},
  network = {},
  connections = {},
  processes = {},
  gpus = {},
  cpu_frequency = {},
  sensors = {},
  mounts = {},
  workloads = {},
  quality = {},
  collectors = {},
}
```

成功结果替换对应资源；失败时保留上一份可用数据，但质量会变为 stale/denied/unavailable/gap，不继续宣称 fresh。

### 4.1 高基数扫描

- 进程 collector 枚举 `/proc` 的基础字段，默认最多 8192 个 PID；只有 TUI 当前
  选中进程会请求 cmdline、I/O 和 cgroup 等深读。进程模型最多保留 2048 行。
- connection owner 会扫描进程 fd 链接，只在 Network 页的连接表实际 placement
  可见时启用；标准 JSON snapshot 不做 owner 扫描。
- GPU collector 只在 GPU 页的 `gpu_process_table` 实际 placement 可见时扫描标准
  DRM fdinfo 以建立 per-client/per-process 数据；仅进入 GPU 页或 Insights 不会触发。
  Overview 与后台只采设备摘要。GPU 页显示最多 512 行进程级摘要，完整
  client/region 细节保留在 snapshot/JSON 模型中；非交互 snapshot 显式执行完整扫描。
- cgroup collector 有深度和节点上限，只提供 cgroup v2 原始层级与内核统计，不解释 systemd unit 或容器语义。

连接、挂载点、workload 和 GPU 进程表的 ViewModel 行预算均为 512。采集器上限
命中时资源使用 `partial`/`truncated`；单纯显示上限不改写 collector quality。
进程/GPU 进程和连接状态提供总数线索，挂载点/workload 当前没有单独的
ViewModel-cap 提示，所以不能把未显示对象视作不存在。布局求解得到的 placement
也传给 ViewModel，因此隐藏表不构建高基数行数组。

具体上限和隐私边界见 [MONITORING.md](MONITORING.md)。

## 5. 调度与历史

没有 `--interval` 覆盖时，CPU 默认 500 ms，mounts 默认 5000 ms，其余 collector 通常为 1000 ms；connections 默认 2000 ms。为避免快速刷新触发高成本扫描，Engine 还执行这些最小前台间隔：

| Collector | 最小前台间隔 |
| --- | ---: |
| GPU | 500 ms |
| process、cpufreq、hwmon | 1000 ms |
| connections、cgroup | 2000 ms |
| mounts | 5000 ms |

TUI 先用真实终端几何求解当前页 placement，再据 surviving Widget 计算前台
collector 集合；因此同一标签中被响应式布局隐藏的表不会仅因标签名而维持前台。
没有任何可见组件需要的 collector 继续低频采样：CPU/PSI 2 秒，disk/network 3 秒，
memory/process/GPU/cpufreq/hwmon 5 秒，connections/cgroup 10 秒，mounts 30 秒。
首次确定页面时，尚未运行且不可见的 collector 会直接延后到后台 deadline；首次与
手动刷新只强制实际可见组件所需 collector。不可见 collector 没有完全停止，目的是
保留有限整体趋势。GPU 设备摘要可继续前台或背景采样，但 fdinfo 进程扫描只由
GPU 进程表的实际 placement 启用。Insights 的前台 collector 集合为空，其计数只
读取有界背景快照，不为进程/GPU 建立 1 Hz 前台采样。

历史不是按“15 分钟/5 分钟”分层存储。当前 Engine 为 11 个聚合指标保留带单调
时间戳的有界点：CPU、内存、PSI、磁盘读写、网络收发、第一块 GPU 利用率、平均
CPU 频率、最高温度和根 cgroup CPU。只有对应数据源实际完成时才写值或 gap，避免
无关 collector 制造重复点。renderer 以固定每列 1 秒、最多 240 秒的时间窗分桶；
提高更新频率只增加每列样本密度，不缩短横轴。当前没有 per-core、per-device 或
per-process 历史订阅。

## 6. GPU 数据边界

GPU collector 只使用 DRM/sysfs/procfs：

- 从 card/render node、PCI/sysfs 和 driver 链接建立设备身份；PCI BDF 可用时作为稳定 ID，否则使用估算的 DRM/sysfs 标识。
- 支持 AMD `gpu_busy_percent`、VRAM/visible VRAM/GTT，AMD DPM 频率，以及 Intel i915/xe sysfs 频率路径。
- 解析标准 DRM fdinfo 的引擎/cycle/memory 计数并做有界 per-client/per-process 聚合。
- 发现相关 hwmon 路径并保存 `hwmon_refs`，但 GPU collector 不重复读取温度、功耗或风扇值。

ViewModel 已用 `hwmon_refs`、hwmon `class` 和规范化 `device_target` 关联全局 hwmon
snapshot：匹配多个 channel 时取最高温度与最高功率，避免把重叠 rail 相加；GPU
原生 metric 存在时优先。GPU 页同时有有界进程表。未匹配传感器时 Temp/Power
仍为 `—`，风扇尚未进入 GPU 表。也没有 vendor UUID、NVML/AMD SMI/Level Zero、
NVIDIA proprietary metrics、MIG、AMD `gpu_metrics` 或厂商动作。

## 7. Inspector

Inspector 只在用户按键时运行，不参与持续采样。默认 registry 恰好有：

- `storage.smart`：选择 `/sys/class/block` 设备后调用 `smartctl`，60 秒缓存；
- `memory.bandwidth`：枚举有限 PMU 名称并通过外部 `perf stat` 做一次系统级实验性采样；
- `service.sshd`：组合 `systemctl show`、进程快照和 `/proc/net/tcp*`。

当前 TUI 的 Inspector 输出是通用文本浮层，而不是完整的统一实体 UI。DIMM/EDAC、PCI/USB、RAID/LVM、服务日志/会话等没有注册为默认 Inspector。准确能力和失败语义见 [DEEP_INSPECTION.md](DEEP_INSPECTION.md)。

## 8. 布局与状态

Workspace 为每个页面保存一棵二叉 split tree。leaf 引用固定 widget；split 有 `horizontal|vertical` 轴、比例、gap 和恰好两个 children。编辑模式支持选择 leaf、按方向移动、调整直接父 split 的比例，以及每页最多 50 步 undo/redo。

`$XDG_CONFIG_HOME/wtop/layout.yml`（或 `~/.config/wtop/layout.yml`）可读取旧 schema v1 顺序列表和 schema v2 split tree；只要在 TUI 内修改过布局，事件循环通过 `q`、`Ctrl+C` 或已捕获的退出信号有序结束时就以 schema v2 原子保存并使用 `0600`。崩溃、`SIGKILL` 或掉电没有恢复日志。校验限制包括 1 MiB、深度 32、节点 511、gap 0–16、`ratio_micros` 1–999999、已知页面/widget 和无重复 leaf。缺少的固定 widget 会追加，缺少的页面使用默认树；未知字段会拒绝整个文件并回退默认布局。

不要把布局版本与主配置混淆：`config.yml` 当前仍是 schema v1。schema 和按键详见 [UI.md](UI.md)。

CLI/config theme 只接受四个内置精确名称；CLI 未知值直接报错，配置未知值使
整份配置回退并报告 error。locale tag 会做语法校验与规范化，但合法未知 tag
可在 TUI 随后加载 XDG 用户 catalog 后成为 active locale。`--snapshot` 与
`--diagnose` 不创建 translator，也不扫描用户 catalog 目录。

## 9. 身份、安全与隐私

- 进程动作使用 `(pid, starttime_ticks)` 身份；Lua 先复核 `/proc/<pid>/stat`，原生层再持有 pidfd 复核并只发送白名单信号。当前 TUI 的 `k` 只发 SIGTERM，并要求确认。
- GPU 优先使用 PCI BDF；无 BDF 时身份质量会标为 estimated。当前没有 vendor UUID。
- 外部程序必须使用绝对 executable path 和 argv，不通过 shell 拼接；Runner 控制 fd、环境、进程组、超时和输出大小。
- 布局以原子写入和 `0600` 保存；主配置是只读加载。
- Network 页显示完整 endpoint、Unix path、UID 和已发现 owner；JSON snapshot 默认只遮罩远端 IP，不遮罩本地地址、端口、Unix path、MAC 或 owner。详见 [MONITORING.md](MONITORING.md)。
- 默认 JSON export 会用遮罩后的远端 endpoint 重建稳定连接 ID，避免完整地址从
  内部 ID 旁路泄露；显式内部 `include_remote_addresses=true` 才保留原 ID。
- 严格 JSON decoder 默认限制 4 MiB、深度 64 和 100000 个 value node，并线性
  扫描数字 token；JSON encoder 将字符串值和 object key 的非法 UTF-8 替换为
  U+FFFD。这里的 node 预算独立于 layout/YAML 各自的节点限制。
- snapshot export 包含 `configuration` object，只复制配置状态 `state` 与可选
  `reason`；内部 config status 的 `path` 字段不会进入机器输出。
- `--safe-mode` 替换为不可执行的 Runner，不会让注入的 executor 绕过策略；它不关闭普通 procfs/sysfs 读取。

mount collector 默认不对网络文件系统、autofs、FUSE/`fuse.*`、`fuseblk` 或
`virtiofs` 调用同步 `statvfs`，避免远端/userspace daemon 阻塞单线程事件循环。
其他默认原生 statvfs 调用共享 50 ms admission budget：每次返回后和下一次进入前
检查累计时间，耗尽后跳过剩余 mount。它不是 syscall timeout，已经进入的单次
`statvfs` 无法抢占，仍可能超过 50 ms 或阻塞。被跳过 mount 的身份仍保留，
容量/inode 标为 unavailable/partial，整体质量为 estimated；这不是容量为零或挂载
离线的结论。

主程序不要求或自动获取 root。当前没有特权 helper。

## 10. 当前测试边界

- 当前 36 个 Lua 单元/fixture 测试文件覆盖平台门禁、procfs、sysfs、connections、cgroup v2、DRM fdinfo、GPU 频率/hwmon join、SMART、PMU、布局、i18n、输入、renderer、Runner、pidfd 动作、JSON 边界和 export 隐私。
- PTY smoke 覆盖 `40×10`、`60×20`、`80×24/25`、`80×50`、`160×24`、
  `200×22`、`180×45`、resize、CJK、按键路径、alternate-screen 恢复和布局持久化。
- onedir/onefile 有构建后 CLI、snapshot 和 PTY target。

这些测试不构成真实硬件矩阵。当前仍缺多架构/libc/旧内核、真实 NVIDIA/AMD/Intel/无 GPU、USB/SAS SMART bridge，以及跨平台 PMU 对照的发布证据；也没有固定硬件的长期性能回归基线。
