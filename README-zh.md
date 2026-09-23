# wtop

[English](README.md)

**WaterRun's top** 是使用 PUC Lua 5.5.1 和小型 C17 原生模块构建的 Linux
响应式终端性能工作台，不使用 LuaJIT。

> 当前版本支持 Linux。

## 核心能力

- 用十个标签页的 TUI 展示概览、进程、计算、内存、存储、网络、GPU、
  工作负载、系统和洞察。
- CPU、内存、磁盘、挂载点、网络接口、套接字、进程、传感器、cgroup v2、
  GPU 和电源数据全部直接读取自 `/proc` 和 `/sys`，默认路径不依赖任何
  外部程序。
- 进程搜索、十一种可双向排序的列、树形视图、已解析的用户名、详情，
  以及需要确认的信号菜单（`SIGTERM`、`SIGKILL`、`SIGSTOP`、`SIGCONT`），
  设计上防止误杀复用的 PID。
- 主机工具和权限可用时，可按需进行 SMART/NVMe、内存带宽和 sshd 检查。
- Lua 蓝配色，支持图表、各核心条形图、按严重程度着色、鼠标选行、
  点击列头排序、运行时切换主题、终端色彩降级、按显示宽度处理 CJK 文本、
  十种可运行时切换的界面语言，以及持久化布局。
- 可导出 JSON 快照（`--snapshot`）、紧凑的自动化上下文（`--agent`）和
  能力报告（`--diagnose`）。
- 高成本采集有上限；读取失败或不完整时如实报告 unavailable、denied、
  partial、truncated、counter-reset 状态，而不是留空。

## 要求与安装

需要带可用 `/proc`、`/sys` 的 Linux、POSIX shell、`make`、C17 编译器，
以及 bootstrap 工具（`curl` 或 `wget`、`tar`、`sha256sum`）。LuaRocks
安装需要 LuaRocks 3.13 或更新版本和 PUC Lua `>= 5.5, < 5.6`。

```bash
git clone https://github.com/Water-Run/wtop.git
cd wtop
luarocks --lua-version=5.5 make wtop-scm-1.rockspec
wtop --diagnose
```

LuaRocks 找不到 Lua 5.5 时传入 `--lua-dir=/path/to/lua-prefix`；改用
`make luarocks-install` 可在 `.tools/` 下建立隔离安装。

## 从源码运行与测试

源码构建会下载官方 Lua 5.5.1、校验固定 SHA-256，并只保存在仓库内。

| 目标 | 作用 |
|---|---|
| `make run` | 构建并启动 TUI |
| `make check` | 语法检查 |
| `make test-fast` | 隔离 Lua 测试与小型 PTY smoke 集 |
| `make test` | Lua 5.5 单元/fixture 测试与 PTY matrix |
| `make test-all` | 两种 Lua ABI、LuaRocks 与两种 bundle 形态 |
| `make test-54` | 使用系统 Lua 5.4 验证纯 Lua 兼容子集 |
| `make test-luarocks` | 隔离安装与 CLI smoke test |
| `make test-fuzz` | 向真实终端循环投放随机输入 |

每次推送都会在 CI 中用 Ubuntu 22.04 和 24.04、gcc 与 clang 跑同样的
目标，另外还包括 sanitizer、fuzzer 和两种 bundle 形态。`make test-fuzz`
不属于 `make test`：它很慢且结果不确定，这是设计使然。

交互模式要求 stdin 和 stdout 都是 TTY。脚本请使用 `wtop --snapshot` 或
`wtop --agent`；全部选项见 `wtop --help`，TUI 内按 `?`/`F1` 查看快捷键，
按 `q`/`Ctrl+C` 退出。

## 权限

核心监控用普通用户就能运行。`sudo wtop` 直接以提权方式启动；`wtop
--sudo`（别名 `--elevate`）会让 wtop 在采集前通过系统 `sudo` 重启自身；
查看 help 和 version 不会提示输入密码。TUI 和结构化输出都会标明 root
状态；sudo 启动的会话会忽略文件配置、用户语言包和持久化布局。只在需要时
提权；`--safe-mode` 会禁用可选 helper。

## 文档

参见[计划](docs/PLAN.md)、
[架构](docs/ARCHITECTURE.md)、[UI](docs/UI.md)、[监控](docs/MONITORING.md)、
[深度检查](docs/DEEP_INSPECTION.md)、[国际化](docs/I18N.md)、
[打包](docs/PACKAGING.md)和 [Agent API](docs/AGENT.md)。

## 许可证

wtop 使用 [EUPL-1.2](LICENSE)：它是强 copyleft 许可证，不是 GPL；
完整条款以 `LICENSE` 为准。
