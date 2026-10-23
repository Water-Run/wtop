# wtop

[English](README.md) · [中文](README-zh.md) · [Français](README-fr.md) · [Русский](README-ru.md)

**WaterRun's top** 是一个终端系统监视器，目标是在任何地方都能运行：
现代 Linux、macOS 和 Windows，也包括新工具已经抛弃的旧机器和旧控制台。

它在一个自适应的界面里展示 CPU、内存、磁盘、网络、进程、GPU 等信息，
并根据终端的实际能力进行调整——从支持鼠标和真彩色的终端，到完全没有
颜色的普通 `cmd.exe` 窗口。

```bash
wtop                # 交互式监控
wtop --snapshot     # 供脚本使用的 JSON 快照
wtop --stream --count 60 > samples.jsonl  # 保存 60 份 JSON 快照
wtop --record --count 60 > samples.wtop  # 保存完整测量记录
wtop --replay samples.wtop              # 离线查看记录
wtop --report       # 英文 Markdown 硬件摘要
wtop --memory-bandwidth  # 按需测量内存带宽，输出 JSON（Linux）
wtop --diagnose     # 查看本机可读取的数据源
```

记录保留原来的测量时间。回放时，空格播放／暂停，Alt-左／右逐帧，Alt-Home／End 跳到首／末帧，`f` 调整倍速。回放期间不执行实时检查和进程操作。

## 运行平台

| 系统 | 状态 |
|---|---|
| Linux (x86_64) | 已发布 0.1.0，可通过 LuaRocks 安装 |
| Windows 32 位构建 | 开发中。已在 Windows Server 2008 和当前版本的 Windows 上测试；面向 XP 构建 |
| macOS (Apple silicon、Intel) | 开发中。可在 macOS 26 (Apple silicon) 上运行 |

Windows 构建是一个 32 位包，目标覆盖从 XP 到 Windows 11 的所有系统。
它监控的是 Windows 本身，而不是运行在其上的 Linux 层。XP 是构建目标，
但尚未在真实的 XP 机器上测试过。

> [!NOTE]
> Windows 和 macOS 构建目前直接来自源码树。0.1.0 版本和 LuaRocks
> 包仅支持 Linux。

## 为旧硬件而生

- **普通控制台。** wtop 在使用颜色、鼠标、Unicode 或备用屏幕之前，会先
  检测终端支持哪些能力。在没有 ANSI 转义序列支持的控制台上（例如旧版
  Windows 的 `cmd.exe`)，它改用 Windows 控制台 API 绘制，转义码不会
  残留在屏幕上。
- **小屏幕。** 布局可以重排到非常小的窗口，无颜色、纯键盘操作的 ASCII
  模式也能正常使用。
- **低开销。** 数据采集由定时器驱动，并设有合理的下限；看不见的面板
  不会被采集或绘制。
- **零依赖。** 它只依赖 PUC Lua 和一个小型 C 模块。不需要 Python，没有
  要安装的运行时，默认路径上也不依赖任何外部辅助程序。

## 展示内容

- 十个内置标签页：概览、进程、计算、内存、存储、网络、GPU、工作负载、
  系统和洞察。
- 进程列表支持搜索、排序、进程树导航、跳转到所属工作负载，以及带确认环节的信号菜单。
- Linux 和 Windows 开发构建在系统页列出显示设备与缓存 EDID 规格。选择设备后按 `Enter` 查看详情。
- 显示详情可查看缓存中的 CTA 视频、音频、色彩及 HDR/VRR 声明。这些是设备能力声明，不代表当前输出信号。
- Linux 开发构建可查看内核配置的输出模式和名义刷新率，并与缓存的显示器规格分开展示。
- macOS 开发构建在系统页显示在线显示设备、当前模式尺寸和名义刷新率。
- Linux 开发构建在设备详情中显示 PCI／USB 运行时电源管理状态、内核报告的 PCI 电源状态及累计活动时间。
- x86 Linux 开发构建可查看 CPUID 芯片能力，并与内核的 CPU 拓扑和缓存报告对照。
- Windows 开发构建可通过 Intel Sysman 读取受支持 GPU 的功耗、设备报告的功耗上限、频率和限制原因。
- 受支持的 AMD Windows 驱动可通过 ADL 提供显卡芯片功耗、温度、频率和风扇转速。
- Windows 开发构建在存储页显示 NVMe 温度及设备报告的上限。按 `s` 查看只读磁盘健康信息；选择 ATA 磁盘后才读取其 SMART 数据。
- 主机上具备相应工具时，可选的深度检查（SMART/NVMe、内存带宽、systemd 单元、sshd)。
- 在 Linux 上，按 `b` 打开实时内存带宽与读写图表。空格暂停采样，关闭面板即停止；读取计数器可能需要提升权限。
- 读取失败或不完整的指标会如实标注（例如 `denied` 或 `partial`)，
  不会显示为空白或零值。
- 十种界面语言，运行时按 `L` 切换；五种配色主题。

## 安装

### Linux

需要 LuaRocks 3.13+ 和 Lua 5.5:

```bash
git clone https://github.com/Water-Run/wtop.git
cd wtop
luarocks --lua-version=5.5 make wtop-scm-1.rockspec
wtop
```

如果 LuaRocks 找不到 Lua 5.5，加上 `--lua-dir=/path/to/lua`。

也可以跳过 LuaRocks，直接从源码树运行。这会把 Lua 5.5.1 下载到仓库中，
校验其 SHA-256，并构建原生模块：

```bash
make run
```

需要 C 编译器、`make`，以及 `curl` 或 `wget`。

### Windows

在 Linux 上用 MinGW 交叉编译器（`i686-w64-mingw32-gcc`）构建 32 位包：

```bash
./tools/build_windows_x86.sh
```

把 `dist/windows-x86` 复制到 Windows 机器上，在 `cmd.exe` 或 PowerShell
中运行 `wtop.cmd`。通过 Cygwin/OpenSSH 会话使用时，改用 `wtop.sh`。

### macOS

```bash
make run
```

构建产物位于 `dist/macos/wtop`，目标平台是 Apple silicon 上的 macOS 11
和 Intel 上的 10.13。

`make test-bundles` 会构建并检查目录包与单文件包，产物位于
`dist/macos-bundle/`。

## 使用

| 按键 | 作用 |
|---|---|
| `1`–`9`、`0`、`Tab` | 切换标签页和焦点 |
| `e`，再按 `b` | 显示、隐藏、重排、新建或复制页面 |
| `e`，再按 `a` | 向当前页面添加组件 |
| 硬件表格中的 `j`/`k`、`Enter` | 选择设备并查看详情 |
| 进程详情中的 `F` | 在 Linux 上查看打开的文件描述符及详情 |
| `d` / `D` | 在 Linux 上查看 systemd 单元 / sshd |
| 单元详情中的 `l` | 在 Linux 上查看近期日志 |
| `u` | 在 Linux 上查看登录会话 |
| 日志或 sshd 详情中的 `s` | 在 Linux 上查看日志摘要 |
| `f` | 调整刷新频率 |
| 概览、计算或 GPU 页的 `p` | 查看实时功耗、上限、百分比、条形图、会话统计与限制原因 |
| `!` | 查看当前健康警报、传感器标志与 NVMe 详情 |
| `B` | 切换块状图和盲文图 |
| `z` / `Z` | 显示更长 / 更短的图表时间 |
| `L` | 切换语言 |
| `?` 或 `F1` | 查看全部按键 |
| `q` 或 `Ctrl+C` | 退出 |

<details>
<summary><b>命令行选项</b></summary>

| 选项 | |
|---|---|
| `--snapshot` | 输出一份 JSON 快照并退出 |
| `--stream` | 持续输出逐行 JSON 快照，直到中断 |
| `--record` | 向重定向的标准输出写入回放记录 |
| `--replay FILE` | 离线查看记录，也可配合 `--snapshot`、`--agent` 或 `--report` |
| `--replay-frame N` | 配合 `--replay`，从第 N 帧开始 |
| `--record-limit-mib N` | 记录大小上限，默认 256 MiB |
| `--count N` | 配合 `--stream` 或 `--record`：输出 N 份后退出 |
| `--report` | 输出英文 Markdown 硬件摘要 |
| `--memory-bandwidth` | 测量一次内存带宽并输出 JSON（Linux，需要 perf 权限） |
| `--memory-pmu NAME` | 配合 `--memory-bandwidth` 选择 PMU，或用 `list` 列出 PMU |
| `--unmask-remote-addresses` | 配合 `--snapshot`、`--stream` 或 `--record`：保留完整远端套接字地址 |
| `--agent` | 输出供脚本和 LLM 代理使用的紧凑 JSON 上下文 |
| `--diagnose` | 显示本机哪些数据源可用 |
| `--lang LOCALE` | 界面语言，例如 `zh-CN`、`fr-FR`、`ru-RU` |
| `--theme NAME` | `lua-blue`、`water-dark`、`water-light`、`high-contrast`、`colorblind` |
| `--interval MS` | 采样间隔，100 到 10000（默认 1000） |
| `--no-color` | 不使用颜色 |
| `--safe-mode` | 不运行任何可选的辅助程序 |
| `--sudo` | 通过 `sudo` 重启（Linux） |

</details>

设置也可以写入 `~/.config/wtop/config.yml`;参见
[config.example.yml](config.example.yml)。

### Root 权限

日常监控用普通用户即可。部分细节信息（例如其他用户的套接字连接或
SMART 数据）需要 root 权限：运行 `sudo wtop` 或 `wtop --sudo`。root
会话不会读取或写入你的个人配置和布局。

Windows 的部分磁盘查询需要管理员权限。

## 开发

| 命令 | |
|---|---|
| `make run` | 构建并启动 |
| `make test-fast` | 快速测试 |
| `make test` | 单元、夹具和终端测试 |
| `make test-all` | 全部测试，包括 LuaRocks 和打包 |

设计说明见 [docs/](docs/)：[架构](docs/ARCHITECTURE.md)、
[跨平台](docs/CROSS_PLATFORM.md)、[UI](docs/UI.md)、
[监控](docs/MONITORING.md)、[国际化](docs/I18N.md)、
[打包](docs/PACKAGING.md)以及 [agent JSON](docs/AGENT.md)。

## 许可证

[EUPL-1.2](LICENSE)。
