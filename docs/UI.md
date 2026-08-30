# UI 与交互

> 本文以 `0.1.0-dev` 的当前行为为准。“后续”或“目标”条目不是已交付功能。

## 1. 当前视觉基线

wtop 的视觉语言称为 **Waterline**：使用紧凑的等宽排版、语义色彩、简短的
sparkline 和有限边框。当前已内置 Water Dark、Water Light、High Contrast 和
Colorblind 四种主题，并可降级到 truecolor、256 色、16 色或无色模式。

Widget 使用语义 token，不直接把颜色当成状态的唯一信号。数据质量还会用
`+`、`!`、`~`、`×`、`-` 或 `·` 表示。

| Token | Water Dark | 用途 |
| --- | --- | --- |
| `surface.base` | `#080C12` | 主背景与 Panel 间留白 |
| `surface.raised` | `#0E151F` | Panel 和 overlay |
| `surface.header` | `#121D29` | 表头层级 |
| `surface.row_alt` | `#101923` | 低对比表格交替行 |
| `surface.selected` | `#193149` | 表格选中行 |
| `text.primary` | `#D6E2EE` | 主文本 |
| `text.muted` | `#75879A` | 次要标签和 unavailable |
| `accent.primary` | `#57C7FF` | 焦点、活动标签和选中内容 |
| `metric.good` | `#45D6B3` | fresh/ok |
| `metric.warn` | `#F6C177` | stale/estimated/确认状态 |
| `metric.critical` | `#FF7A90` | denied/error |

焦点只强化 Panel 边框和标题，不再给整块大 Panel 着色；活动标签使用低亮度底色与
accent 前景，而不是高亮反色块。表头、交替行和选中行使用三个独立 surface，避免
大面积黑蓝条纹，同时在 256/16 色下仍由粗体、边框和文字状态提供冗余区分。

## 2. 全局框架

```text
┌ wtop  [概览]  进程  计算  存储与 I/O  网络  GPU   更新频率：中
│ 当前标签的响应式 Widget 树
│ …
└ 1–8 标签   Space 暂停   f 频率   e 布局   ? 帮助   q 退出
```

框架只有三层：

1. 顶部一行显示品牌、当前可容纳的标签和可点击“更新频率”按钮；暂停时附加
   PAUSED 状态。窄屏会优先保留当前标签和频率按钮，隐藏较远标签并用 `‹`/`›` 提示。
2. 中央为当前标签的布局树。
3. 底部一行显示上下文快捷键、进程搜索/排序状态、持久化错误和短消息。

当前只有一个 overlay，没有 overlay 栈、toast 中心或命令面板。

## 3. 八个固定标签

| 编号 / ID | 当前内容 | 当前限制 |
| --- | --- | --- |
| `1` `overview` | CPU、内存、PSI、磁盘、网络、GPU、CPU 频率和最高 hwmon 温度摘要 | 不是可点击的资源钻取页 |
| `2` `processes` | 进程表、文字搜索、固定排序循环、PPID 树、选中项详情和确认 `SIGTERM` | 无线程行、列配置、PSS/USS、namespace 或组合过滤 |
| `3` `compute` | CPU 总体/每核、load、内存摘要、CPUFreq policy 和通用 hwmon 表 | 无 CPU 拓扑/缓存、NUMA、RAPL 或频率驻留 |
| `4` `storage` | 块设备 rate/延迟估算、mountinfo/statvfs 容量和 SMART 入口 | 网络/autofs/FUSE/fuseblk/virtiofs 默认不调用 statvfs；其余调用受 50 ms 后续调用预算约束但单次不可抢占 |
| `5` `network` | 接口 rate/链路摘要和 TCP/TCP6/UDP/UDP6/Unix socket 表 | 无路由/地址详情、连接筛选或 endpoint 遮罩开关 |
| `6` `gpu` | DRM 设备、vendor/driver/busy/VRAM、hwmon 温度/功率，以及 fdinfo 映射的进程、引擎利用率和内存 | 无 client/frequency-domain/memory-region 钻取或 vendor API；未匹配传感器仍显示 `—` |
| `7` `workloads` | cgroup v2 路径树的 CPU、memory、I/O、进程数、PSI 和质量摘要 | 无展开/折叠、选中项详情、systemd unit 或容器语义 |
| `8` `insights` | collector 可用数、背景快照中的进程/GPU 数和 SMART/RAM bandwidth/sshd 入口摘要 | 不为计数前台 1 Hz 采样进程/GPU；`Enter` 只打开 sshd Inspector；无自动推理 |

这些标签目前不能增删、重命名或重排。

## 4. 布局树与 schema v2

主配置 `$XDG_CONFIG_HOME/wtop/config.yml` 使用 config schema v1。独立的
`$XDG_CONFIG_HOME/wtop/layout.yml` 在当前版本写入 layout schema v2，不应将两个
`schema_version` 混为一谈。

```yaml
schema_version: 2
pages:
  gpu:
    type: split
    axis: horizontal
    ratio_micros: 666667
    gap: 1
    children:
      - type: split
        axis: vertical
        ratio_micros: 500000
        gap: 1
        children:
          - type: leaf
            widget_id: "gpu_summary"
          - type: leaf
            widget_id: "gpu_table"
      - type: leaf
        widget_id: "gpu_process_table"
```

schema v2 规则：

- node 只能是 `leaf` 或二叉 `split`；`split.children` 必须恰好两项。
- `axis` 只能是 `horizontal` 或 `vertical`。
- `ratio_micros` 是 `1..999999` 的整数；`gap` 是 `0..16` 的整数。
- 深度上限 32、node 上限 511，文件上限 1 MiB。
- 每页只接受该页的固定 Widget ID，拒绝重复 Widget、未知 page 和未知 key。
- 已保存页缺失的新默认 Widget 会自动附加；缺失整个 page 时使用默认树。
- 读取器仍接受 schema v1 的 Widget 顺序列表。只有用户编辑布局且事件循环通过
  `q`、`Ctrl+C` 或已捕获的退出信号有序结束后，才会原子写为 v2（权限 `0600`）。

当前编辑器只操作现有 leaf：

- `Tab`/`Shift+Tab` 选择 Widget。
- 方向键把焦点 leaf 移到当前 leaf 顺序中的相邻目标前/后，并按方向重建
  对应 split；它不是按屏幕几何寻找最近 Widget。
- `[`/`]` 以 0.05 为步长调整焦点 leaf 的最近父 split，交互范围限制为
  0.10..0.90。
- `u`/`U` 分别撤销/重做，每页内存上限 50 步。事件循环结束前不落盘；崩溃或
  `SIGKILL` 不保存当次编辑。

尚未实现 Widget 增删/替换、独立 split 工具、拖拽、布局命名、导入/导出、
跨页移动或崩溃后恢复。

## 5. 响应式模式

布局使用 `(columns, rows)`、Widget 最小尺寸、优先级与焦点求解：

| 判定 | 模式 | 当前行为 |
| --- | --- | --- |
| 列 `>=120` 且行 `<30` | `wide-short` | 最多四列；低矮超宽终端优先使用此模式，不再误折叠为 tiny |
| 非 wide-short，且列 `<70`、行 `<=12` 或 `<=80×<=24` | `tiny` | 按最小尺寸换轴/重排；空间仍不足才按焦点和优先级隐藏 |
| 列 `<120`（且非 tiny） | `narrow-tall` | 优先单列垂直排布 |
| 列 `>=180` 且行 `>=45` | `wide-tall` | 最多三列、优先 full |
| 其他 | `standard` | 最多两列、优先 full |

当 split 原轴向容不下两个 child 时，求解器会尝试换轴；仍容不下时保留焦点/
高优先级一侧并隐藏另一侧。隐藏的 Widget 仍在布局树中，窗口放大后可重新出现。
Flow 会比较候选列数能保留的 form 丰富度，因此相邻窗口尺寸不会仅因模式阈值就在
单列和多列间无条件跳变。Panel 的最小尺寸包含边框占位；表格先为所有可见关键列
分配最小宽度，再共享剩余空间。页脚用 `可见数/总数` 提示响应式隐藏。

TUI 会先求出实际 placement，再把可见 Widget 集合交给调度器和 ViewModel。隐藏的
高基数表不会建立行模型；没有任何 placement 需要的 collector 使用背景间隔，而
不是继续按当前标签的前台间隔运行。共享 collector 仍可为其他可见组件保持前台：
例如 GPU 摘要可继续更新设备数据，但只有 `gpu_process_table` 实际 placement 可见时
才扫描 `/proc/<pid>/fdinfo`。Insights 的单个摘要 Widget 不会把进程或 GPU 提升到
前台 1 Hz。

### 5.1 高基数表上限

- 进程 collector 默认最多枚举 8192 个 PID；进程页在已采集集合上搜索/排序，
  ViewModel 最多保留 2048 行，并把采集上限和显示截断分别报告。
- 连接、挂载点、workload 与 GPU 进程表各最多建立 512 行。连接、挂载和 GPU
  进程使用有界优先集合，workload 保持 collector 顺序的前 512 行。连接状态显示
  collector 总 socket 数，GPU 进程状态显示 visible/total；挂载点和 workload 表
  当前没有单独的 ViewModel-cap 截断提示。
- 表中没有某行不等于对象不存在。collector 自身达到扫描预算时使用
  `partial`/`truncated`；纯 ViewModel 行上限不会伪造 collector quality。因此尤其
  对当前无显示截断提示的挂载点/workload 表，未出现某行不能证明对象不存在。

## 6. 快捷键

### 6.1 全局

| 键 | 当前行为 |
| --- | --- |
| `1`–`8` | 直接选择八个标签 |
| `←` / `→` | 前/后循环标签；布局编辑模式中移动 Widget |
| `Tab` / `Shift+Tab` | 前/后移动 Widget 焦点 |
| `Space` | 暂停/继续 collector 调度 |
| `f` | 循环九档更新频率 |
| `e` | 进入/退出布局编辑模式 |
| `r` / `Ctrl+L` | 强制实际 placement 所需 collector 立即到期，并使 renderer 全量重画一帧 |
| `?` / `F1` | 打开帮助 overlay |
| `s` | 打开 SMART/NVMe 设备选择器 |
| `b` | 执行 RAM bandwidth Inspector |
| `d` | 执行 sshd Inspector |
| `q` | 主界面退出；overlay/SMART 选择器中关闭当前浮层 |
| `Ctrl+C` | 在主界面、搜索、确认或任何 overlay 中始终退出 |

### 6.2 进程页

| 键 | 当前行为 |
| --- | --- |
| `↑` / `↓` | 移动选中进程 |
| `/` | 编辑大小写不敏感的子串搜索；匹配 PID、name、command、user、state |
| `Enter` / `Esc` | 确认/取消正在编辑的搜索；搜索已确认时 `Esc` 清空 |
| `o` | 循环 CPU 降序→内存降序→PID 升序→名称升序→I/O 读降序→I/O 写降序 |
| `t` | 切换 PPID 树；搜索时保留直接匹配项的祖先 |
| `Enter` | 无搜索编辑时打开选中进程详情 overlay |
| `k` | 为选中进程创建 `SIGTERM` 确认；只有 `y` 执行，任何其他键取消 |

I/O 和 cgroup 详情只对当前选中进程按需采集，因此 I/O 排序不等价于一个
对所有进程持续采集 I/O 的 `iotop`。

### 6.3 overlay 与鼠标

- 普通 overlay：`↑`/`↓`、`PgUp`/`PgDn`、`Home`/`End` 或滚轮滚动；
  `Esc`、`Enter`、`q`、`?` 或 `F1` 关闭。
- SMART 选择器：上述导航键改变设备，`Enter` 检查，`Esc`/`q` 关闭。
- 鼠标：支持顶部可见标签和右上角更新频率点击、进程表滚轮、overlay/SMART 选择器滚轮。
  不支持表格行点击、split 拖动或 Widget 拖放。

`h j k l`、`:`、`Ctrl+K`、命令面板、全局搜索和键位重绑定尚未实现。

## 7. 数据表达和访问性

- metric Widget 使用带时间戳历史和单行 block sparkline；每列固定代表 1 秒并按列
  聚合同一时段的样本，最多显示 240 秒，无 Unicode 时降级 ASCII。当前没有
  Braille、可缩放时间轴、图例或多序列交互。
- 非数值样本显示为 gap 点，不补零。暂停时 collector 不继续定期采样，顶部显示 PAUSED。
- renderer 以 terminal cell 而非 Lua 字节长度计算宽度，包含 CJK、组合字符、emoji
  和 variation selector 处理；实际终端 wcwidth 差异仍可能造成个别错位。
- 支持 `NO_COLOR` 和 `--no-color`。尚无 `--no-animation`、RTL 镜像、伪语言或稳定语言
  截图回归矩阵。

## 8. 当前验证与后续验收

当前 `make test` 运行 36 个 Lua 单元/fixture 测试文件，并使用真实 PTY 覆盖
`40×10`、`60×20`、`80×24/25`、`80×50`、`160×24`、`200×22`、`180×45`，
检查中文渲染、右上角更新频率真实鼠标点击、标签/进程/帮助/暂停/刷新/布局交互、alternate-screen 恢复、
layout schema v2 写入和 `0600` 权限。最后一个大尺寸用例会先暂停读取以塞满 PTY
输出队列，并确认完整底行仍送达，防止半帧被错误记为成功。响应式求解器和 layout 树还有纯 Lua 单元/随机
不变式测试。额外 PTY profile 分别断言 truecolor、256 色、16 色和无色 ASCII
输出，并覆盖 Water Light、High Contrast 与 Colorblind 主题。进程、计算、存储、
网络、GPU、工作负载和洞察页还会在 `180×45` 各自停留为最终终屏，逐单元检查
完整绘制并匹配页面专属标题，不能依靠后续清屏掩盖中间页残帧。

尚未形成发布证据的项目包括：连续 resize、tmux/SSH、更多极端尺寸、每种稳定语言
截图、伪语言/RTL、广泛终端兼容、崩溃期间布局恢复和详情页的统一资源导航。
