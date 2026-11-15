wtop — WaterRun's top
中文说明见本文件下半部分 (Chinese below)

A terminal system monitor built to run where newer tools no longer do:
old machines, small screens, and plain consoles without ANSI support —
especially cmd.exe on old Windows. It shows CPU, memory, disks, network,
processes, GPU and more in one responsive screen, and adapts to what the
terminal can actually do, from truecolor with a mouse down to a colorless
80x25 cmd.exe window.

Where it runs
  Linux (x86_64)      Released as 26.a, installable with LuaRocks.
  Windows (32-bit)    Development build, one package targeting XP through
                      Windows 11. It monitors Windows itself, not a Linux
                      layer. The classic console path has real run records
                      on Windows Server 2008 and current Windows; XP is a
                      build target and hasn't been tested on a real XP
                      machine yet.
  macOS               Development build (Apple silicon and Intel).

Built for old hardware
  - Plain consoles. wtop checks what the terminal supports before using
    colors, mouse, Unicode or the alternate screen. On a console without
    ANSI, like cmd.exe on older Windows, it draws through the Windows
    console API instead, so escape codes don't end up on screen.
  - Small screens. The layout reflows down to very small windows; a
    colorless, keyboard-only ASCII mode stays usable.
  - Low overhead. Collection runs on a timer with sensible floors, and
    panels you can't see aren't collected or drawn.
  - No dependencies. PUC Lua plus a small C module. No Python, no runtime
    to install, no external helper on the default path.

What it shows
  Ten tabs: Overview, Processes, Compute, Memory, Storage, Network, GPU,
  Workloads, System and Insights. Process search, sorting, tree view and
  a confirmed signal menu; a hardware device tree with details, sensors
  and health; readings that failed or are incomplete are labeled as such
  (denied, partial, stale) instead of showing up as blank or zero.
  Ten interface languages, switchable at runtime with L; five themes.

Quick start
  Linux, with LuaRocks 3.13+ and Lua 5.5:
    luarocks --lua-version=5.5 make wtop-scm-1.rockspec
  Or from the source tree (downloads Lua 5.5.1, checks its SHA-256,
  builds the native module; needs a C compiler, make, curl or wget):
    make run
  Windows, cross-built on Linux with MinGW (i686-w64-mingw32-gcc):
    ./tools/build_windows_x86.sh
    Copy dist/windows-x86 to the Windows machine and run wtop.cmd from
    cmd.exe or PowerShell. Over Cygwin/OpenSSH use wtop.sh instead.
  macOS:
    make run

Command line
  wtop                interactive monitor
  wtop --snapshot     one JSON snapshot, for scripts
  wtop --stream       JSON snapshots until interrupted (--count N)
  wtop --record > samples.wtop   record measurements to a file
  wtop --replay samples.wtop     inspect a recording offline
  wtop --report       English hardware summary in Markdown
  wtop --agent        compact JSON context for scripts and LLM agents
  wtop --diagnose     what wtop can see on this machine
  wtop --help         all options

Keys
  1-9, 0, Tab   switch tabs and focus
  j/k, Enter    select a device, open its details
  f             change the update rate
  L             change language
  ? or F1       all keys
  q             quit

Everyday monitoring works as a normal user; some details (other users'
sockets, SMART data, some Windows drive queries) need elevation.
Settings: ~/.config/wtop/config.yml on Linux/macOS, %APPDATA%\wtop\config.yml
on Windows; see config.example.yml.
Design notes: docs/ (architecture, cross-platform, UI, monitoring, i18n,
packaging, agent JSON).

License: EUPL-1.2, see LICENSE.

------------------------------------------------------------------------

wtop — WaterRun's top

一个为老旧设备而生的终端系统监视器：旧机器、小屏幕、没有 ANSI 支持的
普通控制台——尤其是老 Windows 的 cmd.exe。它在一个自适应的界面里展示
CPU、内存、磁盘、网络、进程、GPU 等信息，并根据终端的实际能力调整，
从支持鼠标的真彩色终端，到完全没有颜色的 80x25 cmd.exe 窗口。

运行平台
  Linux (x86_64)      已发布 26.a，可通过 LuaRocks 安装。
  Windows (32 位)     开发构建，一个包覆盖 XP 到 Windows 11。它监控的是
                      Windows 本身，不是其上的 Linux 层。经典控制台路径
                      已在 Windows Server 2008 和当前版本的 Windows 上
                      留下真实运行记录；XP 是构建目标，尚未在真实的 XP
                      机器上测试过。
  macOS               开发构建（Apple silicon 与 Intel）。

为旧硬件而生
  - 普通控制台。wtop 在使用颜色、鼠标、Unicode 或备用屏幕之前，先检测
    终端支持哪些能力。在没有 ANSI 的控制台上（例如旧版 Windows 的
    cmd.exe），它改用 Windows 控制台 API 绘制，转义码不会残留在屏幕上。
  - 小屏幕。布局可以重排到非常小的窗口；无颜色、纯键盘的 ASCII 模式
    也能正常使用。
  - 低开销。采集由定时器驱动并设有合理的下限；看不见的面板不会被采集
    或绘制。
  - 零依赖。PUC Lua 加一个小型 C 模块。不需要 Python，没有要安装的
    运行时，默认路径上不依赖外部辅助程序。

展示内容
  十个标签页：概览、进程、计算、内存、存储、网络、GPU、工作负载、系统、
  洞察。进程搜索、排序、进程树与带确认的信号菜单；硬件设备树及其详情、
  传感器与健康信息；读取失败或不完整的指标会如实标注（denied、partial、
  stale），不会显示为空白或零值。十种界面语言，运行时按 L 切换；五种
  配色主题。

快速开始
  Linux，需要 LuaRocks 3.13+ 和 Lua 5.5：
    luarocks --lua-version=5.5 make wtop-scm-1.rockspec
  或直接从源码树运行（下载 Lua 5.5.1 并校验 SHA-256，构建原生模块；
  需要 C 编译器、make、curl 或 wget）：
    make run
  Windows，在 Linux 上用 MinGW 交叉构建（i686-w64-mingw32-gcc）：
    ./tools/build_windows_x86.sh
    把 dist/windows-x86 拷到 Windows 机器，在 cmd.exe 或 PowerShell 中
    运行 wtop.cmd。Cygwin/OpenSSH 会话请改用 wtop.sh。
  macOS：
    make run

命令行
  wtop                交互式监控
  wtop --snapshot     一份 JSON 快照，供脚本使用
  wtop --stream       持续输出 JSON 快照（--count N 限定份数）
  wtop --record > samples.wtop   把测量记录到文件
  wtop --replay samples.wtop     离线查看记录
  wtop --report       英文 Markdown 硬件摘要
  wtop --agent        供脚本与 LLM 代理使用的紧凑 JSON
  wtop --diagnose     查看本机可读取的数据源
  wtop --help         全部选项

按键
  1-9, 0, Tab   切换标签页与焦点
  j/k, Enter    选择设备，打开详情
  f             调整刷新率
  L             切换语言
  ? 或 F1       全部按键
  q             退出

日常监控用普通用户即可；部分细节（其他用户的套接字、SMART 数据、
部分 Windows 驱动器查询）需要提权。
配置文件：Linux/macOS 为 ~/.config/wtop/config.yml，Windows 为
%APPDATA%\wtop\config.yml，参见 config.example.yml。
设计文档：docs/（架构、跨平台、UI、监控、i18n、打包、agent JSON）。

许可证：EUPL-1.2，见 LICENSE。