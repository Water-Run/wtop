# wtop

**WaterRun's top** — 面向 Linux 的响应式 TUI 性能工作台。

> 当前版本：`0.1.0-dev` development preview。首条可运行纵向切片已经完成，
> 但尚不是稳定发行版，也没有覆盖路线图中的全部监控与管理能力。

> **Linux-only：** wtop 不支持 macOS、Windows、BSD 或 Android/Termux。
> LuaRocks、Makefile、bootstrap、C 编译期和运行入口都会拒绝非 Linux 平台。

wtop 目前可以在普通 Linux 用户权限下显示 CPU、内存、PSI、磁盘、挂载点、
网络接口与 socket、进程、CPU 频率、hwmon、cgroup v2 和通用 DRM GPU
数据，并提供自适应八标签界面、CJK/i18n、差分渲染、JSON snapshot、
能力诊断和少量按需 Inspector。项目只支持 Linux，使用 PUC Lua 5.5.1
和一个小型 C17 原生模块，不使用 LuaJIT。

## 当前已实现

### TUI 与交互

- 八个固定标签：概览、进程、计算、存储与 I/O、网络、GPU、工作负载、洞察。
- 根据终端宽度、高度和组件实际最小尺寸切换响应式布局：紧凑窗口优先重排并保留
  尽可能多的可用组件，空间不足时才按焦点/优先级隐藏；wide-short 最多四列，
  wide-tall 最多三列。
- 自有 virtual cell grid 与 diff renderer；无变化的帧不会重复整屏输出。
- Water Dark、Water Light、高对比度和色觉友好主题。
- truecolor、256 色、16 色和无颜色模式；支持 `NO_COLOR`。
- UTF-8、CJK、组合字符、emoji 宽度处理；非 Unicode 终端自动使用 ASCII 框线、
  图表和安全占位；并支持 resize、鼠标标签/更新频率点击和进程滚轮选择。
- raw terminal、alternate screen、SIGWINCH/SIGINT/SIGTERM/SIGHUP 与退出恢复由原生模块处理。
- 布局编辑模式可在当前标签内按四个方向移动 Widget、调整最近的 split
  比例并撤销/重做；事件循环有序退出时以 layout schema v2 原子保存到 XDG 配置目录。

### 采集与输出

- CPU 总体/每逻辑核利用率、负载、上下文切换、中断和进程计数。
- 内存、缓存、Swap、zswap/zswapped、部分 vmstat 字段。
- CPU、内存和 I/O PSI。
- 块设备吞吐、IOPS、忙碌度、队列中请求数和估算平均延迟。
- 网络接口吞吐、包、错误、丢弃、链路状态、MTU 和可用时的链路速度。
- 进程 PID/父 PID、名称、状态、CPU、RSS、线程数、调度字段和用户；
  进程页支持文字搜索、树形切换、固定顺序的排序循环和选中项详情。
- CPUFreq policy、通用 hwmon 传感器、mountinfo/statvfs 容量与 cgroup v2
  CPU/memory/I/O/PID/PSI/limit 概要。为避免阻塞主线程，网络文件系统、autofs、
  FUSE/`fuse.*`、`fuseblk` 和 `virtiofs` 默认只显示 mountinfo 元数据，不调用可能
  阻塞的 `statvfs`；其余同步容量查询共享默认 50 ms 的后续调用预算。预算只能
  阻止进入后续 mount，已经开始的单次 `statvfs` 不可抢占，仍可能超过 50 ms 或阻塞。
- `/proc/net/{tcp,tcp6,udp,udp6,unix}` socket 表；只在网络页连接表实际 placement
  可见时尝试扫描 `/proc/<pid>/fd` 进行有界的进程归属关联。权限或扫描上限会
  标记 partial。
- `/sys/class/drm` GPU 卡/渲染节点、PCI/驱动身份，AMD sysfs
  busy/VRAM、AMD DPM 与 Intel i915/xe 频率，以及驱动支持时的 DRM
  fdinfo 每进程/引擎/内存统计。GPU 页有进程表；设备表通过 hwmon
  `class`/`device_target` 关联通用传感器的温度和功率。
- 定长历史、暂停/继续、counter reset/gap 与 unavailable/denied/error 数据质量。
- `--snapshot` 输出带 schema 标识的完整 JSON 快照；`--agent` 输出面向 LLM/自动化的
  紧凑上下文（关键指标、异常信号、Top 列表、质量与不可用数据源）。两者都包含配置加载的 `state` 与可选
  `reason`，但不导出配置路径；`--diagnose` 输出平台、数据源和可选工具能力。

响应式求解完成后，只有实际 placement 中的高基数表才会建立 ViewModel。未放置
的表保持空模型；不再被任何可见组件需要的 collector 转到背景间隔。GPU fdinfo
进程扫描还要求 GPU 页的进程表实际可见；非交互 `--snapshot` 则仍强制完整扫描。
Insights 只使用已有的有界背景快照，不会为了装饰性计数把进程或 GPU collector
提升到前台 1 Hz。进程 collector 默认最多
枚举 8192 个 PID，进程 TUI 模型最多保留 2048 行；连接、挂载点、workload 与
GPU 进程表各最多建模 512 行。达到采集或显示上限时，状态、`partial`/`truncated`
或 visible/total 计数必须与“确实没有更多对象”区分；挂载点和 workload 表当前
尚未单独显示仅由 512 行 ViewModel 上限造成的截断提示。

### 按需 Inspector 与安全动作

- `smartctl` 存在时，`s` 先打开有界的块设备选择器，再读取选中设备的
  SMART/NVMe JSON 摘要；使用 `--nocheck=standby`，不会主动唤醒待机磁盘。
- RAM bandwidth Inspector 枚举有限名称的内存相关 PMU，并通过可选 `perf stat`
  与 `sleep` helper 进行一次约 250 ms 的系统级读/写计数采样。它只接受若干
  data/CAS 事件名；缺方向、部分事件或 multiplex 会标为 estimated。这不是连续
  带宽监控，也不保证支持所有 CPU/PMU。
- `systemctl` 可用时检查 sshd 服务，并从 `/proc/net/tcp*` 读取候选监听；
  默认应用尚未注入 session/journal provider，对应 section 会显示 unavailable。
- 进程页可对选中进程请求 `SIGTERM`。执行前重新核对
  `(pid, /proc/<pid>/stat.starttime)`，原生层再通过 `pidfd` 绑定原进程，拒绝
  PID 1、wtop 自身和 PID 重用目标，并要求 `y/N` 确认。
- `--safe-mode` 禁止运行所有可选外部 helper，包括 `smartctl`、`systemctl`
  和 RAM bandwidth 使用的 `perf`/`sleep`。

外部 helper 使用绝对 argv、最小环境、独立进程组、超时/取消与输出上限；
不会经过 shell，超时会清理同一进程组内的后代。

所有外部工具都是可选项；缺失或无权限不会阻止核心监控启动。

### 连接数据与隐私

- 交互式网络页会显示内核 socket 表中的完整本地/远程 endpoint；屏幕分享或
  截图可能暴露远程 IP、端口、Unix socket 路径、UID 和可归属的 PID/进程名。
- `--snapshot` 默认遮罩连接的远程 IP：IPv4 最后一段变为 `x`，较长 IPv6
  只保留前两组；远程端口、本地地址、Unix socket 路径和已有 owner 字段不会
  因此自动遮罩。导出的连接 `id` 也会用遮罩后的 endpoint 重建，不能借原始 ID
  取回完整远端地址。标准 `--snapshot` 路径不启用 owner fd 扫描，当前 CLI 也没有
  导出完整远程 IP 的开关。
- 采集器内存中仍保留内核提供的完整 endpoint，TUI 也没有隐私遮罩开关。
  sshd Inspector 若未来注入 session provider，默认会遮罩 session 的远程地址；当前默认
  应用并未提供 session/journal provider。

### 结构化输入与文件读取边界

- 内部严格 JSON decoder 默认限制 4 MiB、深度 64 和 100000 个 value node；
  array、object 与 scalar 都计数，数字 token 线性扫描，非法预算会拒绝，超限返回
  `maximum_nodes_exceeded`。JSON encoder 会把字符串值和 object key 中的非法
  UTF-8 字节确定性替换为 U+FFFD，保证输出仍是合法 UTF-8 JSON。
- 原生文件读取默认上限 4 MiB（显式上限最多 64 MiB），以 nonblocking、
  no-follow 方式打开并在读取前确认最终对象是 regular file；symlink、设备、FIFO
  和超过预算的内容会拒绝。procfs/sysfs 中内核呈现为 regular file 的条目仍可读取。

## 构建要求

- Linux 与可用的 `/proc`、`/sys`。
- POSIX shell、`make`、支持 C17 的 C 编译器。
- 首次 bootstrap 需要 `curl` 或 `wget`、`tar`、`sha256sum` 和网络连接。
- PTY 测试需要 Python 3。
- LuaRocks 源码安装和 luainstaller 打包需要系统 LuaRocks 3.13 或更新版本。

标准构建会下载官方 Lua 5.5.1 源码、校验固定 SHA-256，并安装到项目内的
`.tools/`；不会替换系统 Lua。

## LuaRocks 安装

仓库提供 `wtop-scm-1.rockspec`。它只接受 Linux 和 PUC Lua `>= 5.5, < 5.6`，
会通过 LuaRocks 构建 C17 原生模块，并安装全部 Lua module、`wtop` 命令、许可证、
README 和配置示例；没有第三方运行时 LuaRock 依赖，也不支持 LuaJIT。

从源码树安装到 LuaRocks 当前配置的 tree：

```bash
git clone https://github.com/Water-Run/wtop.git
cd wtop

luarocks --lua-version=5.5 make wtop-scm-1.rockspec
wtop --diagnose
```

如果 LuaRocks 尚未配置 Lua 5.5 的位置，传入对应 PUC Lua prefix，例如
`--lua-dir=/usr/local`。仓库也提供完全位于项目目录内、不写系统 tree 的开发安装：

```bash
make luarocks-install
.tools/wtop-rocks-5.5/bin/wtop --diagnose
make test-luarocks
```

该 target 会先 bootstrap 固定的 PUC Lua 5.5.1，再把 wtop 安装到
`.tools/wtop-rocks-5.5`。LuaRocks 负责生成绑定正确解释器与 module path 的命令
wrapper；卸载时使用同一 `--lua-version`、`--lua-dir` 和 `--tree` 参数执行
`luarocks remove wtop`。

## 快速运行

```bash
make run
```

首次运行会自动完成 Lua toolchain、`wtop_native.so` 和 locale 生成。诊断与
非交互 JSON 快照可直接运行：

```bash
make diagnose
make snapshot
```

Agent 可直接获取单行 JSON，无需启动 TUI 或解析 ANSI：

```bash
wtop --agent
```

接口 schema 为 `dev.waterrun.wtop.agent/v1`；完整字段、隐私边界与可机读的
[JSON Schema](docs/agent-v1.schema.json) 见 [docs/AGENT.md](docs/AGENT.md)。

需要传递 CLI 参数时，先构建，再直接使用项目 Lua：

```bash
make all

LUA_PATH="$PWD/src/?.lua;$PWD/src/?/init.lua;;" \
LUA_CPATH="$PWD/build/native/?.so;;" \
.tools/lua-5.5.1/bin/lua src/wtop.lua \
  --lang zh-CN --theme water-dark --interval 1000
```

交互模式要求 stdin 和 stdout 都是 TTY；管道或脚本采集请使用
`--snapshot`。

### CLI

| 选项 | 当前行为 |
| --- | --- |
| `-h`, `--help` | 显示帮助 |
| `-V`, `--version` | 显示版本 |
| `--diagnose` | 输出能力诊断后退出 |
| `--snapshot` | 采样并输出一个 JSON snapshot 后退出 |
| `--agent` | 输出一个有界、适合 LLM/Agent 上下文的 JSON 报告后退出 |
| `--lang LOCALE` | 校验并规范化 locale tag，如 `zh_CN.UTF-8` → `zh-CN`；畸形 tag 拒绝 |
| `--theme NAME` | 只接受精确的 `water-dark`、`water-light`、`high-contrast` 或 `colorblind`，未知值拒绝 |
| `--interval MS` | 基础采样间隔，范围 100–10000 ms；交互 TUI 映射到最近的下列九档，GPU/进程/CPUFreq/hwmon/socket/cgroup/mounts 仍有采集 floor |
| `--safe-mode` | 禁止可选外部命令 |
| `--no-color` | 禁用颜色 |

## 快捷键

| 按键 | 行为 |
| --- | --- |
| `1`–`8` | 选择标签 |
| `←` / `→` | 前后切换标签；编辑模式中移动 Widget |
| `Tab` / `Shift+Tab` | 前后移动 Widget 焦点 |
| `↑` / `↓` | 在进程页移动选择；编辑模式中向上/下移动 Widget |
| `[` / `]` | 编辑模式中缩小/扩大焦点 Widget 所在的最近 split |
| `u` / `U` | 编辑模式中撤销/重做（每标签最多 50 步） |
| `Space` | 暂停或继续采样 |
| `f` | 按“非常低”到“非常高”的顺序循环更新频率 |
| `e` | 进入/退出布局重排模式 |
| `r` / `Ctrl+L` | 立即刷新实际可见组件所需 collector，并强制重绘 |
| `?` / `F1` | 打开帮助 |
| `/` | 在进程页编辑大小写不敏感的文字搜索；`Esc` 清除已确认搜索 |
| `o` | 在进程页循环 CPU、内存、PID、名称、I/O 读、I/O 写排序 |
| `t` | 在进程页切换父子树显示 |
| `Enter` | 在进程页打开选中项详情；在洞察页打开 sshd Inspector |
| `k` | 在进程页请求向选中进程发送 `SIGTERM` |
| `s` | 打开 SMART/NVMe 设备选择器 |
| `b` | 打开 RAM bandwidth Inspector |
| `d` | 打开 sshd Inspector |
| `Esc` / `Enter` | 关闭一般 overlay；SMART 选择器中 `Enter` 检查选中设备 |
| `q` | 主界面退出；普通 overlay/SMART 选择器中只关闭浮层 |
| `Ctrl+C` | 在主界面、搜索、确认或任何 overlay 中始终退出 |

一般详情 overlay 支持方向键、`PgUp`/`PgDn`、`Home`/`End` 和滚轮滚动。
右上角“更新频率”也是按钮，左键点击与 `f` 相同。九档依次为：非常低 `8s`、
低 `5s`、较低 `3s`、中低 `2s`、中 `1s`、中高 `0.75s`、较高 `0.5s`、
高 `0.3s`、非常高 `0.1s`。切换只影响运行中的会话，不写回配置。

鼠标当前只覆盖标签/更新频率点击、进程列表滚动和 overlay 滚动；不支持行点击选择或
拖拽布局。

Sparkline 的时间比例不会随档位伸缩：每个终端列始终代表 1 秒，高频档会把同一列
内更多真实样本取平均，低频档则显示更稀疏的节点；最多保留 240 秒。高成本
collector 仍受各自 floor 保护，因此“非常高”不会把全进程或挂载点扫描提升到 10 Hz。

## 配置

配置文件路径为：

```text
$XDG_CONFIG_HOME/wtop/config.yml
```

如果未设置 `XDG_CONFIG_HOME`，则使用 `~/.config/wtop/config.yml`。可从
[config.example.yml](config.example.yml) 复制起步。主配置和布局是两个独立 schema；
`config.yml` 当前仍使用 schema v1：

```yaml
schema_version: 1
locale: "zh-CN"
theme: "water-dark"
interval_ms: 1000
safe_mode: false
color: true
mouse: true
active_tab: "overview"
```

`active_tab` 可为 `overview`、`processes`、`compute`、`storage`、`network`、
`gpu`、`workloads` 或 `insights`。命令行显式选项优先于配置文件。配置损坏时
wtop 使用安全默认值，并在 TUI 状态区显示错误。配置中的 theme 也只接受上述四个
精确名称；未知 theme 会使该配置进入 error 状态，而不是悄悄换成相近名称。
locale 会先规范化并拒绝语法错误，但不会仅因未列入内置目录而拒绝。

Widget 布局单独保存在 `$XDG_CONFIG_HOME/wtop/layout.yml`。当前写入格式是
schema v2 的二叉 split 树：

```yaml
schema_version: 2
pages:
  processes:
    type: leaf
    widget_id: "process_table"
  gpu:
    type: split
    axis: horizontal
    ratio_micros: 500000
    gap: 1
    children:
      - type: leaf
        widget_id: "gpu_summary"
      - type: leaf
        widget_id: "gpu_table"
```

`axis` 只允许 `horizontal`/`vertical`，`ratio_micros` 是 `1..999999` 的整数，
split 必须有两个 child，且每个页面只允许自己的固定 Widget ID。读取器仍接受
schema v1 的线性顺序文件；下次布局发生变化并有序退出后会保存为 v2。
新版新增的默认 Widget 会附加到已保存树中；非法或未知 page/Widget 会使整个
布局回退到默认值并在状态区报错。只有布局发生变化且事件循环通过 `q`、
`Ctrl+C` 或已捕获的退出信号有序结束时才写入；崩溃、`SIGKILL` 或掉电不会保存当次编辑。

## 国际化

`locales/*.yml` 是权威翻译源，运行时使用
`src/wtop/generated/locales/*.lua`。`en-US` 与 `zh-CN` 标记为 stable；
`zh-TW`、`ja-JP`、`ko-KR`、`es-ES`、`fr-FR`、`de-DE`、`pt-BR` 和
`ru-RU` 当前为 preview，并对缺失 message 逐 key 回退。

语言选择优先级为 CLI、配置、`LC_ALL`、`LC_MESSAGES`、`LANG`、`en-US`。
CLI/配置校验 locale tag 的结构并保存规范形式，而不是要求它已经内置；因此合法但
未知的 locale（例如自定义区域 tag）可由 TUI 随后从 XDG 用户 `.yml` catalog 提供。
如果没有匹配 catalog，则按已加载 alias/父级和默认 `en-US` 回退。用户 catalog 的
`_meta.locale` 自身必须写成规范形式。`--snapshot`/`--diagnose` 不加载用户 catalog。
编译器会检查 YAML profile、重复 key、schema、占位符和内置 plural rule：

```bash
make locales

.tools/lua-5.5.1/bin/lua tools/compile_locales.lua \
  --source locales \
  --output src/wtop/generated/locales \
  --check
```

TUI 启动时会有界扫描 `$XDG_CONFIG_HOME/wtop/locales/*.yml`（回退到
`~/.config/wtop/locales`）并通过同一受限 YAML profile 加载用户 catalog。默认最多
64 个文件、每个 1 MiB；单个文件失败时继续加载其他文件并在状态区报告。
主 TUI、表头、帮助和 Inspector 标签已经接入 i18n；内核/provider 的原始
字段 ID、质量代码和错误 reason 仍按技术标识显示。

## 测试

```bash
make check       # Lua 语法检查
make test        # 36 个 Lua 5.5 单元/fixture 文件 + 响应式/色深 PTY matrix
make test-54     # 使用系统 lua 验证纯 Lua 的 5.4 兼容子集
make test-luarocks  # 隔离 tree 的 LuaRocks 安装与 CLI smoke test
```

PTY 测试覆盖 `40×10`、`60×20`、`80×24/25`、`80×50`、`160×24`、
`200×22`、`180×45`，检查中文渲染、
交互路径、alternate-screen 恢复，以及隔离 XDG 目录中的布局重排、原子保存
和 `0600` 权限；另有 truecolor、256 色、16 色和无色 ASCII profile，且 2–8 页
分别作为最终终屏验证完整绘制。测试通过只代表当前 fixture 和主机矩阵，不代表
所有内核、驱动、GPU 或终端已经兼容。

## luainstaller 打包

```bash
make luainstaller
make bundle-dir
make test-bundle-dir
make bundle-file
make test-bundle-file
make checksums
```

输出：

```text
dist/wtop/wtop
dist/wtop-onefile
dist/SHA256SUMS
```

`bundle-dir` 是诊断和发行版再打包的基线；onefile 是自解包程序，不是完全
静态 ELF。`make checksums` 要求两种 bundle 已存在，只为两个可执行入口写
`dist/SHA256SUMS`，不等于签名、SBOM 或完整 onedir 清单。原生模块默认使用
`-O2 -g0`，且 Makefile 变化会触发重编译。产物绑定构建机的 CPU 架构、libc 和
Lua 5.5 ABI；当前 Fedora `dist/` 只是开发验证，最低 glibc 尚未承诺，也没有
可发布的 aarch64、musl 或旧 glibc 矩阵。完整约束见
[打包文档](docs/PACKAGING.md)。

默认 luainstaller `1.3.0-1` 安装会按
`tools/luainstaller-1.3.0.sha256` 核验 payload，不会自动采用相邻工作树。本地开发
替换必须通过绝对路径 `WTOP_LUAINSTALLER_ROCKSPEC` 显式选择，不能把该 opt-in
构建冒充默认锁定依赖的发布证据。

## 已知边界

- 当前只有八个固定标签；标签增删、重命名、排序和多工作区管理尚未实现。
- 布局编辑限于固定 Widget 的方向移动、比例调整和内存中撤销/重做；没有
  Widget 添加/删除/替换、独立的 split 工具、拖拽、导入/导出或崩溃恢复。
- 进程搜索只是 PID/名称/命令/用户/状态的文本子串匹配；排序键和方向由
  固定循环决定。树仅基于主机 PPID，详情是可滚动 overlay，没有线程行、PSS/USS、
  namespace、列配置或 GPU 反向跳转。
- Workloads 页是 cgroup v2 文件系统树摘要；它不识别 systemd unit/容器语义，
  没有树展开/折叠或选中项详情。
- GPU TUI 展示设备摘要和 DRM fdinfo 映射的进程级利用率、内存与最忙引擎，
  但尚无 client/frequency-domain/memory-region 钻取。GPU collector 只保留 hwmon
  关联键且不重复读传感器；ViewModel 已按 `class`/`device_target` 合并匹配 hwmon
  的温度和功率，未匹配或驱动未暴露时仍显示 `—`，风扇尚未在 GPU 表中显示。没有
  NVML、AMD SMI、Level Zero、MIG 或完整 tile 能力。`--diagnose` 即使发现
  `nvidia-smi`、`rocm-smi` 或 `intel_gpu_top`，也只表示可执行文件存在，不表示
  当前 collector 会调用它。
- RAM bandwidth 是实验性按需诊断：formula v4 通过外部 `perf stat -a -A`/`sleep`，
  按每个 PMU 控制实例的 CSV runtime 计算并求系统总和。Intel free-running/CAS
  替代事件族整族择一，相同 descriptor alias 去重；缺实例、部分事件或 multiplex
  会标为 estimated。纯事件 open/EINVAL 失败是 `unavailable`（可附带权限提示），
  只有明确权限诊断才是 `denied`。启动 probe 不执行 `perf`，所以发现 PMU 不等于
  事件、权限和 helper 已验证。它没有 CPU family/model 事件表、multiplex 校正、
  socket/channel 拆分或连续历史；结果不应视为已校验的跨平台带宽数据。
- SMART 设备发现依赖 `/sys/class/block`，过滤分区和常见虚拟设备，但不会
  运行 `smartctl --scan-open`、自动选择 USB bridge `-d` 类型或接受手工设备路径。
  SMART 和 sshd 深度数据均依赖主机工具、权限和系统配置。当前通用 Inspector
  浮层把列表/对象字段折叠成 item 数量，不提供 SMART attribute 或 sshd listener
  的逐项浏览，也不完整显示 field unit/source/timestamp。
- 网络 TUI 显示完整 endpoint，且当前无遮罩开关；JSON 遮罩也不覆盖远程端口、
  本地地址、Unix socket 路径或网卡 MAC。
- 洞察页目前是 collector/Inspector 数量和入口摘要，尚无自动瓶颈推理或异常时间线。
- 交互进程动作目前只暴露确认后的 `SIGTERM`，没有 renice 或批量动作。
- 当前 `dist/` 仍只是开发机产物；版本化 release、SBOM、签名与兼容基线尚未完成。
- 性能预算、aarch64/musl、发行版、真实 NVIDIA/AMD/Intel 硬件和广泛终端
  兼容矩阵尚未形成发布门禁证据。

更完整的目标与当前差距见 [项目计划](docs/PLAN.md)。

## 设计文档

- [项目计划与路线图](docs/PLAN.md)
- [架构设计](docs/ARCHITECTURE.md)
- [UI 与交互设计](docs/UI.md)
- [监控范围](docs/MONITORING.md)
- [深度检查](docs/DEEP_INSPECTION.md)
- [国际化](docs/I18N.md)
- [构建与打包](docs/PACKAGING.md)

## 许可证

wtop 采用 [Mozilla Public License 2.0](LICENSE)（SPDX：`MPL-2.0`）。它是
非 GPL 的文件级 copyleft：对 MPL 覆盖文件的修改在分发时仍需按 MPL 提供源码，
但允许与其他许可证的独立文件组成更大的作品。

> This Source Code Form is subject to the terms of the Mozilla Public License,
> v. 2.0. If a copy of the MPL was not distributed with this file, You can
> obtain one at https://mozilla.org/MPL/2.0/.

完整条款以 `LICENSE` 为准。
