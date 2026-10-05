# wtop

[English](README.md) · [中文](README-zh.md) · [Français](README-fr.md) · [Русский](README-ru.md)

**WaterRun's top** 是一个终端系统监视器，目标是在任何地方都能运行：
现代 Linux、macOS 和 Windows，也包括新工具已经抛弃的旧机器和旧控制台。

它在一个自适应的界面里展示 CPU、内存、磁盘、网络、进程、GPU 等信息，
并根据终端的实际能力进行调整——从支持鼠标和真彩色的终端，到完全没有
颜色的普通 `cmd.exe` 窗口。

```bash
wtop                # interactive monitor
wtop --snapshot     # one JSON snapshot, for scripts
wtop --diagnose     # what wtop can see on this machine
```

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

- 十个标签页：概览、进程、计算、内存、存储、网络、GPU、工作负载、
  系统和洞察。
- 进程列表支持搜索、排序、树形视图，以及带确认环节的信号菜单。
- 主机上具备相应工具时，可选的深度检查（SMART/NVMe、内存带宽、sshd)。
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
| `--snapshot` | 输出一份 JSON 快照并退出 |
| `--unmask-remote-addresses` | 配合 `--snapshot`：导出完整的远端套接字地址 |
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
