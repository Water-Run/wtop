# wtop

[English](README.md) | **简体中文**

**WaterRun's top** 是使用 PUC Lua 5.5.1 和小型 C17 原生模块构建的 Linux
响应式终端性能工作台，不使用 LuaJIT。

> **状态：** 当前版本为 `0.1.0-dev` development preview，尚不是稳定发行版。
>
> **仅支持 Linux：** 构建和运行入口会拒绝 macOS、Windows、BSD 与
> Android/Termux。

## 核心能力

- 用响应式十标签 TUI 展示概览、进程、计算、内存、存储、网络、GPU、
  工作负载、系统和洞察。
- 直接采集 Linux 的 CPU 身份/拓扑/缓存/核心类型、内存构成与分页计数、PSI、
  带型号/容量/介质/调度器的块设备、带 inode 使用率的挂载点、带 IPv4/IPv6
  地址的网络接口、套接字、进程、CPU 频率、hwmon 传感器、powercap、
  cgroup v2、DRM/PCI/fdinfo GPU 数据，以及主机/内核/发行版/固件身份和电源；
  默认路径不依赖任何外部程序。
- 提供进程搜索、十一种可双向排序的列、树形视图、已解析的用户名、
  TIME+/虚拟内存/NI/线程数列、详情，以及带确认和 PID 重用保护的信号菜单
  （`SIGTERM`、`SIGKILL`、`SIGSTOP`、`SIGCONT`）。
- 主机工具和权限可用时，提供按需 SMART/NVMe、RAM bandwidth 和 sshd 检查。
- 默认采用 Lua 蓝配色，并支持差分渲染、多行图表、各核心条形阵列、
  按数值严重程度着色、单元格内嵌条、鼠标选行与点击列头排序、运行时切换主题、
  终端色彩降级、按显示宽度对齐的 CJK 文本、十种完整翻译且可运行时切换的界面语言，
  以及持久化布局。
- 可输出完整 JSON 快照（`--snapshot`）、紧凑自动化上下文（`--agent`）和
  能力报告（`--diagnose`）。
- 限制高成本采集，并明确报告 unavailable、denied、partial、truncated 和
  counter reset。

## 要求与安装

需要带可用 `/proc`、`/sys` 的 Linux、POSIX shell、`make`、C17 编译器，
以及 bootstrap 工具（`curl` 或 `wget`、`tar`、`sha256sum`）。
LuaRocks 安装要求 LuaRocks 3.13 或更新版本和 PUC Lua `>= 5.5, < 5.6`。

```bash
git clone https://github.com/Water-Run/wtop.git
cd wtop
luarocks --lua-version=5.5 make wtop-scm-1.rockspec
wtop --diagnose
```

LuaRocks 找不到 Lua 5.5 时请传入 `--lua-dir=/path/to/lua-prefix`。
`make luarocks-install` 可改为在 `.tools/` 下建立隔离安装。

## 从源码运行与测试

源码构建会下载官方 Lua 5.5.1、校验固定 SHA-256，并只保存在仓库内。

```bash
make run            # 构建并启动 TUI
make check          # 语法检查
make test-fast      # 隔离 Lua 测试与小型 PTY smoke 集
make test           # Lua 5.5 单元/fixture 测试与 PTY matrix
make test-all       # 两种 Lua ABI、LuaRocks 与两种 bundle 形态
make test-54        # 使用系统 Lua 5.4 验证纯 Lua 兼容子集
make test-luarocks  # 隔离安装与 CLI smoke test
make test-fuzz      # 向真实终端循环投放随机输入
```

每次推送都会在 CI 中于 Ubuntu 22.04 与 24.04 上用 gcc 和 clang 跑同样的目标，
另外还包括 sanitizer、fuzzer 与两种 bundle 形态。

交互模式要求 stdin 和 stdout 都是 TTY。脚本请使用 `wtop --snapshot` 或
`wtop --agent`；全部选项见 `wtop --help`，TUI 内按 `?`/`F1` 查看快捷键，
按 `q`/`Ctrl+C` 退出。

## 权限

核心监控可按普通用户运行。`sudo wtop` 直接提权启动；`wtop --sudo`（别名
`--elevate`）让 wtop 在采集前通过系统 `sudo` 重启，查看 help/version 不会触发
密码提示。TUI 和结构化输出会报告 root 状态；sudo 启动的会话会忽略文件配置、
用户语言包和持久化布局。只在需要时提权；`--safe-mode` 会禁止可选 helper。

## 文档

参见[计划](docs/PLAN.md)、[架构](docs/ARCHITECTURE.md)、
[UI](docs/UI.md)、[监控](docs/MONITORING.md)、
[深度检查](docs/DEEP_INSPECTION.md)、[国际化](docs/I18N.md)、
[打包](docs/PACKAGING.md)和 [Agent API](docs/AGENT.md)。

## 许可证

wtop 使用 [EUPL-1.2](LICENSE)：它是强 copyleft 许可证，不是 GPL；
完整条款以 `LICENSE` 为准。
