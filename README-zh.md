# wtop

[English](README.md) · [中文](README-zh.md) · [Français](README-fr.md) · [Русский](README-ru.md)

**WaterRun's top** 是一个终端系统监视器，目标是哪里都能跑：新的
Linux、macOS、Windows 能跑，被新工具抛下的老机器、老控制台也能跑。

CPU、内存、磁盘、网络、进程、GPU 等信息集中在一个自适应的界面里。
它会按终端的实际能力调整显示：从支持真彩色和鼠标的终端，到没有任何
颜色的 `cmd.exe` 窗口，都能用。

```bash
wtop                # 交互式监视
wtop --snapshot     # 输出一份 JSON 快照，给脚本用
wtop --diagnose     # 看看 wtop 在这台机器上能读到什么
```

## 支持的系统

| 系统 | 状态 |
|---|---|
| Linux（x86_64） | 已发布 0.1.0，可用 LuaRocks 安装 |
| Windows 32 位版 | 开发中。已在 Windows Server 2008 和当前 Windows 上测试；按 XP 构建 |
| macOS（Apple 芯片、Intel） | 开发中。已在 macOS 26（Apple 芯片）上运行 |

Windows 版是一个 32 位包，覆盖从 XP 到 Windows 11。它监视的是 Windows
本身，而不是跑在上面的 Linux 子系统。XP 是构建目标，但还没在真实的 XP
机器上测过。

> [!NOTE]
> Windows 和 macOS 版目前从源码构建。0.1.0 正式版和 LuaRocks 包只支持 Linux。

## 为老设备而做

- **朴素的控制台。** wtop 先检测终端支持什么，再决定用不用颜色、鼠标、
  Unicode 和备用屏幕。遇到不支持 ANSI 转义的控制台（比如老版 Windows 的
  `cmd.exe`），就改用 Windows 控制台 API 绘制，不会满屏乱码。
- **小屏幕。** 布局能缩到很小的窗口；无颜色、纯键盘的 ASCII 模式也照样能用。
- **开销低。** 采集按定时器进行并有合理下限；看不见的面板不采集也不绘制。
- **没有依赖。** 只有 PUC Lua 和一个小的 C 模块。不需要 Python，不需要
  装运行时，默认路径上也不调用外部程序。

## 能看到什么

- 十个标签页：概览、进程、计算、内存、存储、网络、GPU、工作负载、系统、洞察。
- 进程列表支持搜索、排序、树形视图，以及需要确认的信号菜单。
- 主机上有相应工具时，可做 SMART/NVMe、内存带宽、sshd 等深度检查。
- 读取失败或不完整的数据会标明原因（比如 `denied`、`partial`），不会显示成空白或 0。
- 十种界面语言，运行时按 `L` 切换；五套配色主题。

## 安装

### Linux

需要 LuaRocks 3.13+ 和 Lua 5.5：

```bash
git clone https://github.com/Water-Run/wtop.git
cd wtop
luarocks --lua-version=5.5 make wtop-scm-1.rockspec
wtop
```

LuaRocks 找不到 Lua 5.5 时，加上 `--lua-dir=/path/to/lua`。

也可以不用 LuaRocks，直接从源码运行。它会把 Lua 5.5.1 下载到仓库里、
校验 SHA-256，再编译原生模块：

```bash
make run
```

需要 C 编译器、`make`，以及 `curl` 或 `wget`。

### Windows

在 Linux 上用 MinGW 交叉编译器（`i686-w64-mingw32-gcc`）构建 32 位包：

```bash
./tools/build_windows_x86.sh
```

把 `dist/windows-x86` 复制到 Windows 上，在 `cmd.exe` 或 PowerShell 里运行
`wtop.cmd`。通过 Cygwin/OpenSSH 登录时改用 `wtop.sh`。

### macOS

```bash
make run
```

构建结果在 `dist/macos/wtop`。Apple 芯片最低 macOS 11，Intel 最低 10.13。

## 使用

| 按键 | 作用 |
|---|---|
| `1`–`8`、`Tab` | 切换标签页和焦点 |
| `f` | 调整刷新频率 |
| `L` | 切换语言 |
| `?` 或 `F1` | 查看全部按键 |
| `q` 或 `Ctrl+C` | 退出 |

<details>
<summary><b>命令行选项</b></summary>

| 选项 | |
|---|---|
| `--snapshot` | 输出一份 JSON 快照后退出 |
| `--agent` | 输出给脚本和 LLM Agent 用的精简 JSON |
| `--diagnose` | 显示这台机器上哪些数据源可用 |
| `--lang LOCALE` | 界面语言，如 `zh-CN`、`fr-FR`、`ru-RU` |
| `--theme NAME` | `lua-blue`、`water-dark`、`water-light`、`high-contrast`、`colorblind` |
| `--interval MS` | 采样间隔，100 到 10000（默认 1000） |
| `--no-color` | 不用颜色 |
| `--safe-mode` | 不运行任何可选的辅助程序 |
| `--sudo` | 通过 `sudo` 重新启动（Linux） |

</details>

设置也可以写进 `~/.config/wtop/config.yml`，参见
[config.example.yml](config.example.yml)。

### root 权限

日常监视用普通用户即可。有些细节需要 root，比如其他用户进程的连接或 SMART
数据：运行 `sudo wtop` 或 `wtop --sudo`。root 会话不会读写你个人的配置和布局。

## 开发

| 命令 | |
|---|---|
| `make run` | 构建并启动 |
| `make test-fast` | 快速测试 |
| `make test` | 单元、fixture 和终端测试 |
| `make test-all` | 全部测试，包括 LuaRocks 和打包 |

设计文档在 [docs/](docs/)：[架构](docs/ARCHITECTURE.md)、
[跨平台](docs/CROSS_PLATFORM.md)、[界面](docs/UI.md)、
[监控](docs/MONITORING.md)、[国际化](docs/I18N.md)、
[打包](docs/PACKAGING.md)，以及 [Agent JSON](docs/AGENT.md)。

## 许可证

[EUPL-1.2](LICENSE)。
