# wtop

[English](README.md) · [中文](README-zh.md) · [Français](README-fr.md) · [Русский](README-ru.md)

**WaterRun's top** 是一个终端系统监视器,目标是在任何地方运行:既能跑在
Linux、macOS 和较新的 Windows 上,也能跑在老旧机器和被现代工具抛弃的
旧式控制台上。

CPU、内存、磁盘、网络、进程、GPU 等所有内容都显示在一个随窗口大小
自适应的屏幕上。wtop 还会根据终端的实际能力进行调整——从支持鼠标
的 truecolor 终端,到没有颜色的普通 `cmd.exe` 窗口。

```bash
wtop                # 交互式监视器
wtop --snapshot     # 输出一个 JSON 快照,供脚本使用
wtop --diagnose     # 列出 wtop 在这台机器上能读取的数据
```

## 支持的系统

| 系统 | 状态 |
|---|---|
| Linux (x86_64) | 0.1.0 版本已发布,可通过 LuaRocks 安装 |
| Windows(32 位) | 开发中。已在 Windows Server 2008 和当前版本的 Windows 上测试;已针对 XP 编译 |
| macOS(Apple silicon、Intel) | 开发中。已在 macOS 26(Apple silicon)上运行 |

Windows 版是一个单一的 32 位软件包,目标覆盖从 XP 到 Windows 11 的
所有版本。它监视的是 Windows 本身,而不是跑在 Windows 之上的 Linux
兼容层。XP 只是编译目标,尚未在真正的 XP 机器上测试过。

> [!NOTE]
> 目前 Windows 和 macOS 版本需要从源码编译。0.1.0 版本和 LuaRocks
> 软件包仅面向 Linux。

## 为老旧硬件而设计

- **简单的控制台。** wtop 在使用颜色、鼠标、Unicode 或备用屏幕之前,
  会先检测终端实际支持什么。在没有 ANSI 转义序列的控制台(如旧版
  Windows 上的 `cmd.exe`)上,它通过 Windows 控制台 API 绘制界面,
  不会在屏幕上留下原始转义代码。
- **小屏幕。** 布局会一直自适应到非常小的窗口;无颜色的纯 ASCII
  模式仅使用键盘即可操作。
- **资源占用低。** 数据采集遵循定时器,并有合理的最小间隔;不可见
  的面板既不采集也不绘制。
- **零依赖。** 只需要 PUC Lua 和一个小型 C 模块。没有 Python,没有
  需要安装的运行环境,默认不调用任何外部程序。

## 显示内容

- 十个标签页:概览、进程、计算、内存、存储、网络、GPU、工作负载、
  系统和分析。
- 进程列表支持搜索、排序、树状视图,以及带确认的信号菜单。
- 可选的深度检测(SMART/NVMe、内存带宽、sshd),前提是机器上
  安装了相应的工具。
- 采集失败或不完整的指标会如实标注(例如 `denied` 或 `partial`),
  而不是显示为空或零。
- 界面支持十种语言,运行中按 `L` 即可切换;另有五种配色主题。

## 安装

### Linux

需要 LuaRocks 3.13+ 和 Lua 5.5:

```bash
git clone https://github.com/Water-Run/wtop.git
cd wtop
luarocks --lua-version=5.5 make wtop-scm-1.rockspec
wtop
```

如果 LuaRocks 找不到 Lua 5.5,请添加 `--lua-dir=/path/to/lua`。

也可以不用 LuaRocks,直接从源码运行 wtop。这会把 Lua 5.5.1 下载到
仓库目录中,校验其 SHA-256,并编译原生模块:

```bash
make run
```

需要 C 编译器、`make`,以及 `curl` 或 `wget`。

### Windows

在 Linux 下用 MinGW 交叉编译器(`i686-w64-mingw32-gcc`)编译
32 位软件包:

```bash
./tools/build_windows_x86.sh
```

把 `dist/windows-x86` 复制到 Windows 机器上,从 `cmd.exe` 或
PowerShell 中运行 `wtop.cmd`。在 Cygwin/OpenSSH 会话中,请改用
`wtop.sh`。

### macOS

```bash
make run
```

构建产物位于 `dist/macos/wtop`。目标平台为 Apple silicon 上的
macOS 11 和 Intel 上的 macOS 10.13。

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
| `--snapshot` | 输出一个 JSON 快照后退出 |
| `--unmask-remote-addresses` | 配合 `--snapshot`:导出完整的远端地址 |
| `--agent` | 输出紧凑 JSON,供脚本和 LLM 智能体使用 |
| `--diagnose` | 列出在当前环境中可用的数据源 |
| `--lang LOCALE` | 界面语言,例如 `fr-FR`、`zh-CN`、`ru-RU` |
| `--theme NOM` | `lua-blue`、`water-dark`、`water-light`、`high-contrast`、`colorblind` |
| `--interval MS` | 采样间隔,100 到 10000(默认 1000) |
| `--no-color` | 不使用颜色 |
| `--safe-mode` | 不运行任何可选的辅助程序 |
| `--sudo` | 通过 `sudo` 重新启动(Linux) |

</details>

设置也可以写入 `~/.config/wtop/config.yml`;参见
[config.example.yml](config.example.yml)。

### 需要 root 权限的情况

日常监视用普通用户即可。某些细节信息——例如其他用户的进程连接
情况或 SMART 数据——需要 root 权限:运行 `sudo wtop` 或
`wtop --sudo`。root 会话不会读取或写入你的个人配置和界面布局。

## 开发

| 命令 | |
|---|---|
| `make run` | 编译并运行 |
| `make test-fast` | 快速测试 |
| `make test` | 单元测试、fixtures 测试和终端测试 |
| `make test-all` | 全部测试,包括 LuaRocks 和打包 |

设计笔记(英文)见 [docs/](docs/):
[架构](docs/ARCHITECTURE.md)、
[跨平台](docs/CROSS_PLATFORM.md)、
[界面](docs/UI.md)、[监控](docs/MONITORING.md)、
[i18n](docs/I18N.md)、[打包](docs/PACKAGING.md)以及
[agent JSON](docs/AGENT.md)。

## 许可

采用 [EUPL-1.2](LICENSE) 许可证。
