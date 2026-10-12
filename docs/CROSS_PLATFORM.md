# 跨平台产品需求

## 产品方向与当前基线

wtop 的目标是做一个现代、响应式的系统监控工具，原生运行于 Linux、macOS
和 Windows。Windows 版本必须监控 Windows 主机本身。原生 32 位 x86 构建以及
Windows XP 兼容性是明确的实现目标。Windows Server 2008 是当前可用的真实
Windows 验证主机；目前没有 XP 测试环境。对旧硬件以及运行 `cmd.exe` 的经典
Windows 控制台(包括不支持 VT/ANSI 的控制台)的兼容性是首要需求。

功能完整的 top 与 HWiNFO 级别的硬件测绘是共同的产品方向。
硬件清单、拓扑、传感器和健康信息按原生数据源逐步补齐，
每项能力同时记录平台支持、权限、缺失状态和采样开销。

0.1.0 版本及其 LuaRocks 安装包仍是仅限 Linux 的发布。源码树目前已包含
macOS 和 Windows x86 的开发构建,带有原生主机采集器以及共享的
Snapshot/TUI 代码。下文给出了这些构建在真实主机上的冒烟证据;它们尚未作为
跨平台版本发布。

## 必备行为

1. **原生主机监控。** 在 Linux、macOS 和 Windows 上,TUI 均展示 CPU、内存、
   进程、存储、网络和基本系统标识信息。`--snapshot`、`--agent` 和
   `--diagnose` 在同一主机上可用。通用的 Snapshot 与质量契约在各个操作系统
   之间保持一致。在某个操作系统上没有等价数据源的指标,必须报告其真实
   可用状态;不得以零值或新鲜数据的形式出现。
2. **终端适配。** UI 既支持具备完整能力的 VT/ANSI 终端,也为不支持 VT/ANSI
   的控制台提供原生 Windows 控制台路径。在启用备用屏幕、鼠标输入、粘贴
   模式、颜色和 Unicode 字形之前,会先探测终端的实际能力。仅键盘操作、
   无彩色的 ASCII 呈现方式,在小型控制台上仍然可用。终端输入、尺寸调整、
   Ctrl+C 以及正常/异常退出,都要恢复用户的控制台状态。无法处理转义序列
   的终端不得显示原始转义码。
3. **旧设备行为。** 采集和渲染保持有界,不为隐藏面板做不必要的工作,并在
   UI 已支持的最小布局尺寸下保持可用。性能目标和最低硬件基线需要在受支持
   的最老机器上实测得出。
4. **平台相关控制。** 进程标识、进程操作、权限行为、配置路径和可选检查器
   均采用平台相关实现。只有在平台能够执行其安全检查并准确报告失败时,
   才会暴露相应操作。
5. **原生交付。** 每个受支持的操作系统都有构建与分发路径,可以在该系统上
   启动 TUI 及结构化输出命令。Windows XP 兼容性是代码和构建目标;在没有
   XP 运行时测试的情况下,它仍未验证,不得作为经过测试的发布承诺对外呈现。

## 实现边界

- Snapshot、ViewModel、组件(widget)、布局以及与后端无关的单元格差分渲染
  保持共享。按操作系统选择主机采集器和原生服务实现;Linux 的 `/proc` 和
  `/sys` 读取器保留在 Linux 后端中。
- 终端后端保留 `start`、`size`、`poll`、`present`、`capabilities` 和
  `stop` 接口。原生 Win32 控制台会话使用屏幕缓冲区 API 和原生按键事件;
  ANSI 流使用共享编码器。Cygwin/OpenSSH 启动器在程序运行期间将其 PTY
  设置为 raw 模式。
- 核心资源以外的硬件数据源按平台原生实现。Windows 通过 SetupAPI 枚举
  显示适配器,并结合 DXGI 1.1 获取适配器 LUID,作为 PDH GPU 计数器的键;
  处理器频率、ACPI 热区和 GPU 占用率来自使用英文名称的 PDH 计数器;
  电池信息来自 `GetSystemPowerStatus`;负载(workload)是按宿主进程分组的
  运行中服务。macOS 读取 IOAccelerator 统计、HID 温度服务、SMC 风扇和
  电源键值、IOReport 能耗与性能状态驻留、IOPowerSources、按进程统计的
  socket 描述符以及资源 coalition。IOReport、IOHID 事件、SMC 和 coalition
  查询没有 SDK 头文件,因此均在运行时解析;缺失的接口会将其数据源报告为
  不可用。
- Linux 在存在时通过 `dlopen` 打开 NVML(`libnvidia-ml.so.1`),并按 PCI
  地址将其与 DRM 设备关联;安全模式不会加载它。
- Windows x86 产物捆绑了配套的 32 位 Lua 运行时和原生模块,以 XP 目标宏和
  PE32 i386 格式构建。版本、架构和运行时间所需的新 API 调用均动态解析;
  CPU 计数器有一个动态选择的 pre-SP1 回退实现。这是构建和 API 层面的
  证据,不是 XP 运行时的实测结果。

## 验证矩阵

2026-10-12 核对：提交 `74a6687` 的
[CI 运行](https://github.com/Water-Run/wtop/actions/runs/38210309458)
已完成，14 个作业全部通过。覆盖 Linux x86_64/aarch64、Lua 5.5 与 Lua 5.4
子集、PTY、fuzz、ASan/UBSan、LuaRocks、两种捆绑形态，以及独立下载验收：
两种架构的下载包在 CI 内核验清单与原生身份，并以完整 PTY 通过。
此前 `9868791` 的 12 作业运行全部通过，但当时的下载复核发现 onedir
上传内容不完整；修复后的下载链以最新运行为准，经过见下方开发验证记录。
以下保留早期主机与提交的验证范围。

2026-10-09 核对：开发树提交 `aea04ad` 对应的
[CI 运行](https://github.com/Water-Run/wtop/actions/runs/37277030786)
于 2026-10-05 完成，12 个作业全部通过。覆盖 x86_64/aarch64 原生构建、
Lua 5.5 单元套件、Lua 5.4 子集、PTY、fuzz、ASan/UBSan、LuaRocks、
onedir/onefile，以及校验和、SBOM 和发布 ELF 基线。
macOS、Windows 的运行验证来自下表列出的主机记录。

| 运行时主机 | 终端场景 | 验收重点 |
| --- | --- | --- |
| Linux x86_64，2026-10-11 sshd 配置 | Fedora 44，kernel 7.2.9-200.fc44.x86_64 | `make check`、132 个 Lua 测试文件与完整 PTY 通过；实际配置读取为 denied，临时配置的 Include、多端口与连接 Match 原生查询通过。系统 Lua 五项回归、onedir/onefile 的配置与日志摘要独立场景、四种输出与发布清单检查通过。没有新增 XP 或 macOS 实测 |
| Linux x86_64，2026-10-11 日志摘要 | Fedora 44，kernel 7.2.9-200.fc44.x86_64 | `make check`、131 个 Lua 测试文件与完整 PTY 通过；通用日志和 sshd 摘要、滚动、刷新及返回实测。系统 Lua 五项相关回归通过；onedir/onefile 的两项独立摘要场景、四种输出与发布清单检查通过。没有新增 XP 或 macOS 实测 |
| Linux x86_64，2026-10-11 logind | Fedora 44，kernel 7.2.9-200.fc44.x86_64 | 130 个 Lua 测试文件与完整 PTY 通过；实际读取两个登记会话，会话到 scope 与返回实测。系统 Lua 相关回归通过；onedir/onefile 的会话导航、四种输出和发布清单检查通过。没有新增 XP 或 macOS 实测 |
| Linux x86_64，2026-10-11 unit journal | Fedora 44，kernel 7.2.9-200.fc44.x86_64 | 129 个 Lua 测试文件与完整 PTY 通过；当前启动的 system unit 日志、详情、刷新及返回均实测。onedir/onefile 的独立日志 PTY、四种输出与发布清单检查通过；没有新增 XP 或 macOS 实测 |
| Linux x86_64，2026-10-11 systemd unit | Fedora 44，kernel 7.2.9-200.fc44.x86_64 | 128 个 Lua 测试文件、严格 C 警告与完整 PTY 通过；系统和当前用户管理器均实际读取，unit/进程/cgroup 导航实测。六项系统 Lua 兼容回归、三项 Clang ASan/UBSan 回归通过。onedir/onefile 的输出与新导航冒烟通过，SBOM 与清单一致 |
| Linux x86_64，2026-10-11 本轮 | Fedora 44，kernel 7.2.9-200.fc44.x86_64 | `make check`、既有单元回归、新增 Type 10 夹具及完整 PTY 通过；tmux 和 cgroup 双向导航本轮实际执行；系统 Lua 的七项相关回归通过。Linux onedir/onefile 的 Snapshot、Agent、报告及硬件/工作负载独立 PTY 通过；onefile 快速 PTY 与发布清单检查通过。本机 DMI 为 denied；没有新增旧式板载设备可读字段、XP 或 macOS 的真机证据 |
| Linux x86_64，2026-10-11 本地 | Fedora 44，kernel 7.2.8-200.fc44.x86_64 | 该轮开发树的 126 个 Lua 测试文件与完整 PTY 通过；Type 8/22/37/38/39/41/42/43 在固件夹具中通过，本机实际读表为 denied，OS TPM `tpm0`、看门狗 `watchdog0`、四个 RF 开关及 10 个热区、25 个冷却设备则为 fresh。重建的 onedir 的 Snapshot、Agent、报告、System 硬件与进程 FD 下钻 PTY 通过，发布通知和清单校验通过；Windows x86 产物静态门禁通过。本行不构成 Windows 或 XP 运行验证 |
| Linux x86_64，CI | GitHub Actions，Ubuntu 22.04/24.04 | GCC/Clang 原生构建与严格警告；Ubuntu 24.04 的 120 个 Lua 测试文件、Lua 5.4 子集、PTY、fuzz、ASan/UBSan、LuaRocks 与两种捆绑形态；校验和、SBOM、发布基线构件已上传 |
| Linux aarch64，CI | GitHub Actions，Ubuntu 24.04 arm64 原生 runner | `make check`、120 个 Lua 测试文件、PTY 全部通过；已构建捆绑包并上传 `dist/BASELINE-arm64.txt` 发布 ELF 基线 |
| Linux x86_64，2026-10-09 本地 | Fedora 44，kernel 7.2.8-200.fc44.x86_64，glibc 2.43 | `make check`、120 个 Lua 测试文件与完整 PTY 矩阵通过；luainstaller 1.5.0 的隔离候选验证见下文 |
| Linux x86_64 | Fedora 44 开发主机,kernel 7.2.7 | 120 个 Lua 测试文件、Lua 5.4 子集以及 PTY 矩阵;带 DRM/fdinfo GPU 数据的 Snapshot;无 NVIDIA 驱动时 NVML 报告为不可用 |
| Linux x86_64,旧 libc | manylinux2014 容器,glibc 2.17,宿主内核 7.2.7 | 在 glibc 2.17 工具链上完成原生构建和全部 120 个 Lua 测试文件,`--version` 正常应答;合并的 glibc 下限为 2.17,而宿主构建需要 2.38。容器共享宿主内核,因此本行仅是 libc 证据,不能说明最低内核版本。 |
| Linux aarch64 | Ubuntu 24.04,DGX Spark(Cortex-X925/A725,NVIDIA GB10,驱动 580),SSH | 原生构建和 Lua 测试套件(当时运行时为 50 个文件);NVML 关联到 DRM 节点:利用率、频率、温度、功耗、UUID、驱动版本、按进程统计的 GPU 内存 |
| Linux | Debian 13 x86_64 SSH PTY | Snapshot、Agent、diagnose、TUI 退出(较早的一次运行) |
| macOS | macOS 26.5 arm64(M4)SSH PTY | CPU 按核显示 user/system/nice,基于性能状态驻留的 P/E 集群频率,内存,含受保护进程标识的进程列表,带估算繁忙时间的 IOKit 磁盘 I/O,64 位接口计数器,带属主的 socket,GPU 利用率、频率和显存,HID 温度,SMC 风扇和系统功耗,IOReport CPU/GPU/ANE/DRAM 能耗,coalition 负载,平均负载;Snapshot 和 TUI |
| Windows XP,32 位 x86 | 无测试环境 | PE32 i386 交叉构建；静态检查覆盖产物版本、依赖闭包和已知较新 API 的硬导入。完整 XP API 覆盖与运行时仍未验证 |
| Windows Server 2008 | 6.0.6003 x86_64 主机运行 x86 产物 | 原生资源:含每核 CPU 利用率和时间类别、CPU 标识和缓存、内存构成、物理磁盘 I/O、带属主进程的 socket、经 SetupAPI 获取的显示适配器(含驱动版本和显存)、电源计划和额定 CPU 频率、服务宿主负载、Snapshot、Agent、diagnose、配置/布局 I/O,以及 Cygwin/OpenSSH PTY TUI(含挂断退出) |
| 较新的 Windows | 10.0.26100 x86_64 主机运行 x86 产物 | 与 Server 2008 相同的资源,另有 64 位接口计数器、含睿频的有效 CPU 频率、一个 ACPI 热区、从 32 位构建读取 64 位进程内存,以及经 PowerShell/OpenSSH ConPTY 的原生 Win32 控制台 TUI,涵盖 Snapshot、Agent、diagnose |
| Server 2008 经典 CMD | 代码页 936 的遗留控制台,由 `tools/console_harness.c` 驱动 | 屏幕缓冲区绘制、双字节单元格中的中文文本、按键事件、页面切换、终止菜单、缓冲区尺寸调整、`q` 和 Ctrl+C 退出并恢复控制台 |
| 带 WSL 的 Windows | WSL 中的 Linux 运行时 | Linux 兼容性;这不构成原生 Windows 支持的证据 |

## 开发验证记录

### 2026-10-12：v0.2.0 标签与候选链验收

为 `45ffae4` 打出 `v0.2.0` 标签并推送，Release candidate 流程在该标签上
完整运行并通过（[CI 38218398365](https://github.com/Water-Run/wtop/actions/runs/38218398365)）：
两个架构构建 bin 传输归档与源 rock，verify 作业在独立 runner 上重新下载
产物、运行完整 PTY，并对每个产物执行 `gh attestation verify`——核对签名
工作流、源提交摘要并拒绝自托管 runner。发布作业按设计未运行：公开发布
需以 `publish=true` 显式调度，且依赖仓库尚未配置的 `LUAROCKS_API_KEY`
密钥；开发按用户指示在该节点收尾暂停。剩余发布动作：配置密钥并调度
发布，随后验收公开 Release 与 LuaRocks 按名称安装。

### 2026-10-12：main 红屏修复与首次下载验收

交接提交 `1c1a41a` 推送后，main 的
[CI 38199832495](https://github.com/Water-Run/wtop/actions/runs/38199832495)
在两种架构的 `test_release_evidence` 上失败：`bundle-dir` 的许可条款拷贝
断言读到了 macOS 配方。根因是同批交接改动把 macOS 打包目标（`bundle-dir`
等四个）加在 Makefile 顶部、Linux 定义之前；守卫按文本读取每个目标的
第一条配方，而 make 只解析所在平台的分支，因此只有文本读者看得见这次
重名。修复 `74a6687` 把 macOS 打包块移到文件末尾的独立 `ifeq` 分支并
写明该位置约束；修复主机没有 Linux 工具链，验证是按守卫读取器复刻的
静态检查（本机 `build/verify_recipe_reader.ps1`，不随 Git 分发）。

随后 [CI 38210309458](https://github.com/Water-Run/wtop/actions/runs/38210309458)
14 个作业全部通过，独立下载验收首次真实完成：两种架构的下载包在独立
runner 上核对外层校验和、与包内容完全一致的内层清单、SBOM 摘要一致和
原生模块身份，并以完整 PTY 运行 onedir 与 onefile。交付缺口表中下载
验收一项据此关闭。发布签名与溯源链仍由 Release candidate 流程在正式
发布时验证；`v0.2.0` 尚未发布。

### 2026-10-12：暂停交接

开发按用户要求暂停。源码和接续记录保存在 `main`，目标版本仍为 `0.2.0`。
仓库只保留 `main` 分支，后续开发直接提交到该分支，不使用 PR。
收尾提交包含跨平台开发改动，公开发布尚未执行。

Linux 交付修复的已推送提交为 `ae9686e`：归档保留隐藏载荷和权限，
LuaRocks 构建生成原生版本，提供版本 spec、源 rock、本地索引和签名候选
流程。下载包的工作区重命名测试已改用包内程序重新加载配置，取消对
开发 Lua 的依赖；该场景本地通过。最后一次查询时，
[CI 38198553446](https://github.com/Water-Run/wtop/actions/runs/38198553446)
有 6 个作业通过、其余运行中，
[候选流程 38198553449](https://github.com/Water-Run/wtop/actions/runs/38198553449)
仍在构建两个架构。下载与签名链的最终结果尚未确认；收尾推送也可能触发
后续运行，应按实际提交核对。此前 `0966fb5` 的构建和签名步骤成功，但
独立下载验收因上述开发 Lua 依赖失败，不计为完整通过。

跨平台开发改动的已有证据与剩余事项如下：

- Linux 共享原生版本头已编译，并通过版本身份相关回归。
- Windows x86 已改为静态链接 GCC 运行时。开发包的 Lua 解释器、Lua DLL
  和原生模块共 3 个 PE32 文件通过依赖闭包检查，不再需要外置 GCC/pthread
  DLL。尚未用本轮产物完成 Windows 主机运行或 luainstaller 原生打包。
- `yymac01` 的 macOS 原生构建、luainstaller onedir 和五种已安装 CLI 模式
  通过。快速 PTY 的 Network 页语义标记检查失败，任务退出码为 2；没有
  完成 onefile 构建。保留目录 `/tmp/wtop-v02-0966-mac1`、日志 `build.log`，
  原 PID 为 `45766`，任务已退出，接续时不要把该任务视为成功或仍在运行。
- 已核对用户给出的 Debian、两台 Windows、网关、DGX 和九台 Mac 的
  可达性。九台 Mac 为 arm64，系统为 macOS 26.5 或 26.6.2。实机验收只需
  这组设备；其他系统及硬件保留代码兼容目标。尚未完成本轮多机运行与
  性能预算，也未发布 `v0.2.0` 或公共 LuaRocks 包。

本机详细任务记录和日志位于 `build/series-fixes/`，该目录不随 Git 分发。
另一处开发应更新 `main`；已有远端任务需先按运行编号或保留目录核对
实际状态，再决定后续操作。

### 2026-10-12：0.2.0 交付修复的本地验收

本轮以 `9868791` 为基线，将开发版本更新为用户选定的 0.2.0。`rock-build`
现在先生成 Lua/C 版本身份，生成器只使用本项目自己的 Git 元数据。
scm 安装、0.2.0 源 rock 安装及本地索引上的按名称安装均通过五种 CLI 检查；
原生版本为 0.2.0，空版本会被检查拒绝。源 rock 构建时未携带 `.git` 或
开发目录中的头文件，安装过程实际生成了自己的版本头文件。

`make check test-55` 通过全部 132 个 Lua 测试文件。发布传输的八项 Python
回归覆盖隐藏原生模块、摘要、执行权限、符号链接、路径逃逸、外层摘要与
空的原生版本。两个 workflow 通过 SHA-256 校验的 actionlint 1.7.12 检查；
发布证据、清单与文档计数的三个既有 Lua 文件也通过。

本机新构建的 onedir / onefile 被收录到
`dist/wtop-0.2.0-linux-x86_64-glibc.tar.gz`，包括全部隐藏载荷、项目许可证、
SBOM、原始文件清单及发布 ELF 基线。独立外层清单覆盖包内所有文件，归档
旁另有 SHA-256。解包到源码目录以外后，两种程序均通过五种 CLI、JSON
契约和 quick PTY；测得的 glibc 下限为 2.38。

真实 CI 上传/下载和签名链尚待运行，公共发布尚未执行。当前的本地成功
不代替它们；也没有新增 aarch64、macOS、Windows、XP 或目标性能预算的
实测结果。日志和任务接续记录保存在 `build/series-fixes/`。

### 2026-10-12：双交付路径与实际下载包核对

核对对象为 `9868791b2e8ec59abbbf53675df4626b9008cc8e`，本机为 Fedora 44、
Linux `7.2.9-200.fc44.x86_64`、glibc 2.43。工作区起始干净；测试使用
`git archive HEAD` 导出的独立源码目录，原有 `build/` 和 `dist/` 未充当
新构建证据。使用仓库现有的锁定 Lua 5.5.1、LuaRocks 3.13.0 和
luainstaller 1.5.0 工具链。

干净源码经 `luarocks --lua-version=5.5 make wtop-scm-1.rockspec` 安装到
隔离的 tree，未预先运行 `make native` 或 `make build-id`。从源码目录之外
运行已安装的 `--version`、`--diagnose`、`--snapshot`、`--agent`、`--report`
全部退出 0，Snapshot 与 Agent 的现有 JSON 契约检查通过。
原生版本为空，诊断输出为 `Native: available ()`；`rock-build` 缺少版本
头文件生成依赖，现有安装测试只检查 CLI 版本和平台，未覆盖该缺口。

同一份独立源码随后完成 onedir / onefile 重建。两种产物复制到独立目录，
在 Bubblewrap 文件系统中分别运行上述五种 CLI 模式，全部退出 0；Snapshot
与 Agent 的 JSON 契约检查通过。该环境只有包本身、动态加载器、libc、libm
以及只读系统数据，没有源码、Lua 工具链或外部辅助程序，PATH 指向空目录。
已安装 rock、onedir 和 onefile 分别通过现有 quick PTY 场景，覆盖默认界面、
Network、Compute、ASCII/无色模式和信号退出。
新构件的发布 ELF 基线通过，glibc 下限为 2.38；SBOM、14 项文件清单和
发布许可检查通过。本轮没有重跑完整单元、完整 PTY 或性能基准，完整套件
结果引用上述同提交 CI。

从上述 CI 下载 `wtop-bundles`，构件 ID 为 `11697601223`。ZIP 中只有
`wtop/LICENSE`、`wtop/wtop`、`wtop/THIRD_PARTY_NOTICES.md`、`wtop-onefile`
和 `SHA256SUMS`。清单的 14 项中，4 项存在且摘要匹配，10 项不存在，均在
`wtop/.luai/` 下，包括原生模块、许可文本、重链接材料和清单。
为解包后的入口设置执行权限，再运行 `--snapshot`，退出 1，标准错误为
`wtop: native platform probe is unavailable`。

上传配置使用 `actions/upload-artifact@v4`，没有启用隐藏文件上传。
其[默认行为](https://github.com/actions/upload-artifact/tree/v4#uploading-hidden-files)
会排除点目录。上传前的完整性检查已通过，但没有下载后的检查来发现这一
传递过程中的缺失。该问题应通过完整归档与下载复验关闭；仅重复本地打包
不能证明修复有效。

公开入口也单独核对：GitHub API 的
[Release 列表](https://api.github.com/repos/Water-Run/wtop/releases)为空，
标签列表只有 `v0.1.0`；LuaRocks 公共搜索 wtop 返回 `No modules`。
因此当前可确认的是克隆源码后本地安装，以及 CI 构建能力；尚未确认公共
索引上的按名称安装或正式 bin 下载。aarch64 作业只上传发布 ELF 基线，
没有上传该平台的捆绑包。此次没有增加 macOS、Windows 或 XP 的运行证据。

本地核对记录保存在 `build/development-audit-20261012/`，包含
`state.json`、干净安装与新构建日志、隔离 CLI 和 quick PTY 结果、下载 ZIP 和
`ci-artifact-summary.json`；这些本机证据不随源码提交发布。

### 2026-10-11：sshd 当前文件配置查询

`sshd_config` 使用 [OpenSSH 退出式配置查询](https://man.openbsd.org/sshd.8)
展开当前文件、Include 和默认值；提供连接参数时由 OpenSSH 应用 Match。
单次命令限 500 ms、128 KiB，输出另限 512 行、每行 8192 字节和每项 128 个
重复值。`-G` 不受支持，或该版本仅在 `-T` 中接受 `-C` 时，保留查询参数
改用 `-T`，至多两次；配置错误、超时和权限拒绝不触发该兼容重试。

结果保留公开白名单，多条 Port/ListenAddress 不覆盖前面的值；主机密钥、
命令、环境变量、原始输出及连接参数不进入结果。失败配置值为 nil，
成功结果明确标为当前文件的估算，不能证明守护进程的启动覆盖项或已重载
内容。仅以端口筛选的 procfs 监听者也不再报告为确认的属主证据。

本机 `/etc/ssh/sshd_config` 对当前用户不可读，独立源码 PTY 实际显示
拒绝原因，并通过刷新、滚动和关闭。临时配置与临时主机密钥的原生查询
通过 Include、多端口及 Match：全局 MaxSessions 为 10，指定连接为 3，
PasswordAuthentication 由 no 变为 yes。该运行发现本机 `-G -C` 的模式限制，
修复兼容分支后连接查询实际通过；没有启动监听器或修改主机服务配置。

最终 `make check` 与全部 132 个 Lua 测试文件通过；完整 PTY 通过，清单包含
45 项场景，其中 41 项由完整套件执行。浮层专项覆盖 24 个导出构造器、
十种语言的 22,426 次渲染及 15,026 次滚动位置遍历；重复配置值逐行显示，
保留第 5 项之后的访问路径。242 个接口原因码的本地化检查通过。
系统 Lua 5.4.8 的配置、日志摘要、核心检查器、logind 与原因码五项回归通过。

最终 onedir/onefile 均通过配置权限状态、刷新、关闭及原有日志摘要的独立
PTY，没有跳过新增场景；Snapshot、Agent、报告与诊断四种输出通过，
Agent 符合现有 JSON Schema。配置查询不进入默认结构化输出，诊断已列出
实际使用的 sshd 辅助程序。发布通知、校验和及 SBOM 检查通过，三个构件
摘要与 14 项清单一致。本轮没有新增 XP、旧硬件或 macOS 的运行证据。

### 2026-10-11：日志查询摘要与 OpenSSH 文本分类

`journal_stats` 汇总现有的有界 journal 查询，保留条数、记录时间范围、
优先级、unit 来源关系、拒绝/不可读记录与权限/截断状态。日志内 `s` 切换
摘要，sshd 详情的 `s` 打开认证文本分类。分类格式参考
[OpenSSH auth_log](https://github.com/openssh/openssh-portable/blob/master/auth.c)，
只匹配 unit 直接发出的 OpenSSH 标识记录；未知格式和管理器引用不算认证。
样本不保留用户名、地址、指纹、原始消息或可跳转的 PID。计数不代表独立
尝试、连接或会话，不进入默认 Snapshot、Agent 或报告。

本机首次 sshd journal 请求触发 1 秒超时，保留 `unavailable`；随后三次
读取成功，均返回 100 项并标为 `partial/journal_data_truncated`。
该结果不是本次启动的完整认证总数。独立源码 PTY 验证通用日志摘要、
消息详情滚动、刷新和返回，以及 sshd 摘要、滚动、刷新和返回服务。
日志详情的滚动上限此前超出局部变量作用域；按键路径已修复并实际执行。

专项夹具验证五类认证文本、未知方法、标签/关系边界、多行和截断消息、
来源别名、失败来源的未知值、样本配置上限和隐私。样本上限不改变查询
统计；权限不足、损坏或无来源不会冒充零次失败。
系统 Lua 5.4.8 的五个相关文件通过。该回归发现原生模块缺席时，UID 查询
的错误文本曾被当作有效用户 ID；构造器现在只接受有效整数，用户 journal
在没有可验证 UID 时保持不可用。

最终 `make check` 与 131 个 Lua 测试文件通过。浮层检查覆盖 24 个导出构造器、
十种语言的 21,324 次渲染及 14,017 次滚动位置遍历；235 个接口原因码的
本地化检查通过。完整 PTY 通过，场景清单包含 44 项，其中 40 项由完整套件
执行；新增摘要场景实际运行，没有因日志来源缺失而跳过。

重建后的 onedir 和 onefile 均通过通用日志与 sshd 摘要的独立 PTY，
以及 Snapshot、Agent、报告、诊断四种输出检查；Agent 符合现有 JSON Schema。
发布通知、校验和及 SBOM 检查通过，三个构件摘要与 14 项清单一致。
这些结果来自当前 Linux 主机，没有增加 XP、旧硬件或 macOS 的运行证据。

### 2026-10-11：logind 登录会话与 scope 导航

`session.logind` 使用 [loginctl 的只读接口](https://github.com/systemd/systemd/blob/main/man/loginctl.xml)
读取最多 128 项登记会话，清单和批量属性查询各限 500 ms、256 KiB。
按 [logind 的会话属性](https://github.com/systemd/systemd/blob/main/man/org.freedesktop.login1.xml)
保留 UID、创建单调时间、PAM 服务、状态和 scope 等元数据。启动不执行查询；
身份还包含当前内核启动 ID，详情刷新与 scope 跳转前重新核对。
不查询远端主机、远端用户名或显示地址，也不进入默认 JSON。

本机 Fedora 44、Linux `7.2.9-200.fc44.x86_64` 实际返回两个 `ok/fresh`
会话：用户管理器 `1` 与图形登录 `3`。sshd 来源正常读取，PAM 服务匹配项
为零；正向 sshd 会话数据由夹具验证，本轮没有真实远程 SSH 登录证据。
独立源码 PTY 验证会话选择、详情刷新、`session-3.scope` 的 unit 查看、unit
刷新及返回会话。本机 systemd 没有返回 scope 的 Leader 属性，因此该 unit
保持主进程未知，没有复制 logind 的 PID。

夹具覆盖 UID、创建时间与启动变化、重复/无效字段、读取拒绝、空清单、
条数与字节上限、截断和 PAM 服务筛选。失败的 sshd 会话来源保留未知值，
不发布可读的空列表。会话的十语言视图与原因检查通过；logind、systemd、
既有检查器和原因本地化四个文件通过系统 Lua 5.4.8。

最终源码的 `make check` 和全部 130 个 Lua 测试文件通过；浮层回归覆盖
23 个构建器，233 个界面原因码在十语言目录中均有翻译。首轮完整 PTY
在既有 FD 下钻场景失败，随后两次独立运行通过。该测试改为持续持有一个
已知文件描述符，并根据重建的可见画面等待与核对，避免依赖标准流和完整
标签在绘制字节中的拼接形态；改进后的独立场景通过。
最终 `make test-pty` 完整矩阵通过，账本为 43 个可独立运行的场景，其中
39 个进入完整套件；会话导航与 FD 场景均实际执行。十语言浮层检查完成
20349 次渲染，没有内容丢失。

重建的 Linux onedir/onefile 均通过会话导航的独立 PTY，以及 Snapshot/v1、
Agent/v1、硬件报告和诊断输出；Agent 输出通过已发布的 JSON Schema，
诊断同时列出 `journalctl` 和 `loginctl`。onedir 的 FD 独立场景另行通过。
`make test-release-notices` 通过，3 项 SBOM 摘要与 14 项校验清单一致。
没有新增 XP、Windows 或 macOS 的运行证据。

### 2026-10-11：unit journal 与历史消息

unit 详情的 `l` 使用 [journalctl](https://github.com/systemd/systemd/blob/main/man/journalctl.xml)
读取当前启动的最新记录。每次先重新验证 unit，查询最多保留 100 条、512 KiB，
单次超时 1 秒。解析按 [journal 字段](https://github.com/systemd/systemd/blob/main/man/systemd.journal-fields.xml)
核对启动 ID、管理器和用户身份，区分 unit 发出的消息、slice 子成员和对 unit
的引用。历史 PID 不作为当前进程导航入口；多行消息净化控制字符并限制长度。
日志只出现在显式打开的本地视图，不进入默认 Snapshot、Agent 或硬件报告；
应用消息本身可能含有应用数据，不承诺任意文本的地址脱敏。

本机 Fedora 44、Linux `7.2.9-200.fc44.x86_64` 读取 `dbus-broker.service`
得到 `ok/fresh` 的 3 条记录，其中 1 条由 unit 发出，2 条是管理器引用，
没有拒绝的记录。真实 PTY 验证列表、消息详情、刷新和逐级返回 unit；
完整 `make test-pty` 通过，账本为 42 个可独立运行的场景，38 个进入完整套件。
该证据不构成旧版 systemd、大日志量或跨平台 journal 的实测。

夹具覆盖不同启动和用户、无关 unit、coredump 引用、权限受限、无记录、
二进制/多值消息、损坏 JSON、重复游标及截断。十语言视图与原因码检查通过，
日志、systemd 和本地化三个文件通过系统 Lua 5.4.8；诊断测试因没有配套
原生模块明确跳过。

最终源码的 `make check test-55` 通过，共 129 个 Lua 测试文件。
浮层回归覆盖 22 个构建器和十语言，18516 次渲染没有内容丢失；
225 个界面原因码在十个目录中均有翻译。
重建的 Linux onedir/onefile 均通过独立日志 PTY，以及 Snapshot/v1、Agent/v1、
硬件报告和诊断输出检查；Agent 输出另通过已发布的 JSON Schema。
`make test-release-notices` 通过，3 项 SBOM 摘要与 14 项校验清单一致。

### 2026-10-11：通用 systemd unit 与资源导航

`service.systemd` 使用 [systemctl 的只读接口](https://github.com/systemd/systemd/blob/main/man/systemctl.xml)
枚举和查询已加载 unit。其名称遵循
[systemd unit 规则](https://github.com/systemd/systemd/blob/main/man/systemd.unit.xml)，
不将名称拼进 shell。系统和当前有效用户的管理器各自成源；默认最多采集
1024 项，选择器在搜索后最多显示 256 项。Workloads 可以直接进入当前 unit，
返回的 `ControlGroup` 必须与所选节点匹配。unit 详情的主进程跳转同时核对
当前 PID/启动时间和 cgroup；缺少进程样本时只请求一次采样。

本机 Fedora 44、Linux `7.2.9-200.fc44.x86_64` 实际读取了系统管理器和 UID
1000 的用户管理器；一轮清单为系统 512 项、用户 336 项，系统源触及预算并
明确标记截断。`NetworkManager.service` 和用户 `app.slice` 都返回
`ok/fresh`。真实 PTY 验证系统 unit 搜索、主进程查看、返回、控制组跳转及
Workloads 直达；用户管理器的 `app.slice` 详情另有屏幕检查。

单实体入口原本在丢失选择器状态后调用默认 SMART 提供方；修复保留原检查器
和标题，安全模式下的 sshd PTY 可独立验证分派。`FS:exists` 也改为遵守注入
的读取/类型提供方，空夹具不会借用本机的 `/usr/bin/systemctl` 或 procfs。

`make check check-native-warnings test-55` 的 128 个测试文件通过；六个相关
文件通过系统 Lua 5.4.8。原生执行器、Runner 与 systemd 的三个文件通过
Clang ASan/UBSan；GCC sanitizer 构建因本机缺少 `libasan.so.8.0.0` 与
`libubsan.so.1.0.0` 失败，故本轮 sanitizer 证据来自 Clang。完整 `make test-pty` 通过，场景账本为 41 项，包含 unit 导航和单实体分派。
重建的 onedir/onefile 均通过 Snapshot/v1、Agent/v1、硬件报告、unit 导航与
sshd 分派的独立 PTY。`make test-release-notices` 通过，3 项 SBOM 摘要与
14 项校验清单一致。没有新增 XP、Windows 或 macOS 实测。

### 2026-10-11：实现梳理与旧式板载设备

按 [DMTF SMBIOS 3.9 §7.11](https://www.dmtf.org/sites/default/files/standards/documents/DSP0134_3.9.0.pdf)
读取 Type 10 的重复设备条目。它与 Type 41 共用板载设备采集器和 128 条上限，
以结构句柄和条目序号区分设备；固件没有给出 PCI 地址，因此不按名称合并
操作系统设备或 Type 41 记录。System 搜索、十语言详情、Snapshot 和报告
均保留结构类型。Type 45 只能引用未截断清单中完整的单设备 Type 10 结构，
多设备句柄不选择任意一个条目。

新增夹具覆盖多条目、多结构、与 Type 41 并存、启用/禁用、未知枚举、
重复句柄、奇数长度、无效字符串索引、128 条截断、隐私与 Type 45 引用。
Lua 5.5.1 的专项与相关回归通过；系统 Lua 5.4.8 的五个相关文件通过。
`make check`、既有 126 文件回归及快速 PTY 通过；新增文件另行执行通过，
该轮套件总数为 127。布局文档同步纠正了已经实现的增删替换和按目标移动，
计划区分了已实现的性能预算比较器与仍需真机校准的预算。

Linux 进程表直接按 `g` 时，现在只读取所选进程的当前 cgroup，并在读取
两侧复核启动时间。默认表格按需采样没有 cgroup 字段时，此前会错误地提示
归属不可用。夹具覆盖没有详情的进程、旧路径、读取失败、身份复用与退出；
Lua 5.5/5.4 的导航与按需采样回归通过。独立 PTY 固定选择受监督的测试
子进程，验证无需打开详情的跳转，避免依赖可能退出或无权限的最忙宿主进程。

修复后的 `make check test-pty` 完整矩阵通过；本轮 tmux 与 cgroup 场景
均实际执行，没有这两项的环境跳过。重建的 Linux onedir 与 onefile 均通过
Snapshot/v1、Agent/v1、硬件报告、硬件详情和进程/工作负载双向导航的独立
PTY；onefile 的五项快速 PTY 也通过。本轮单文件包已有实际运行证据。
`make test-release-notices` 通过，3 项 SBOM 摘要与 14 项清单一致。

本轮主机为 Fedora 44、Linux `7.2.9-200.fc44.x86_64`。源码 Snapshot 的
板载设备来源为 `denied`、设备数为零；Snapshot/v1、Agent/v1 和硬件报告
仍正常输出。Windows 读取入口由同一解码器的夹具验证，尚无本轮 Type 10
可读字段的 Linux/Windows 真机结果，也没有新增 XP 或 macOS 运行证据。

### 2026-10-11：Linux UEFI ESRT 固件资源

[Linux ESRT sysfs ABI](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-firmware-efi-esrt)
列出固件类别 GUID、版本、Capsule 标志和上次尝试字段。
[UEFI ESRT 定义](https://uefi.org/specs/UEFI/2.10/23_Firmware_Update_and_Reporting.html#efi-system-resource-table)
说明上次尝试状态 `0` 也可能意味着从未尝试更新。wtop 保留原始代码，
不把它改写成“更新成功”或实时健康状态。

采集器最多接受 128 个规范的 `entryN` 目录，字段逐项检查并保留失败状态。
在本机 Linux 沙箱，ESRT 有 9 个目录条目；属性权限为 `0400`，归属
`nobody`，当前进程读取均被拒绝。源码和 onedir `--snapshot` 均报告
`scanned=9`、整体 `partial`、各条 `denied`，不制造 GUID 或版本，也不
把无身份的条目放入 System 设备树。200×50 的源码 PTY 实际画出
“UEFI 固件资源 9 · 9 项无权限”；没有 DMI 时的同一摘要另有夹具覆盖。
该结果只证明降级行为，尚无本机可读
ESRT 字段的运行验证。

受控夹具覆盖可读字段、原始尝试代码、上限、目录名校验、重复 GUID、
拒绝读取、Snapshot、报告和 System 详情。Type 45 标准 GUID 仅在两边
各唯一时建立双向导航；它是固件清单与更新资源之间的引用，不是物理
父子关系。macOS 和 Windows 不读取 Linux ESRT。

最终源码的 `make check`、Lua 5.5.1 与系统 Lua 5.4.8 各 126 个测试文件、
完整 PTY 矩阵通过。重建 onedir 后，`--snapshot` 同样得到 9 个条目、
整体 `partial` 与各条 `denied`，快速 PTY 通过；onefile 构建成功，
本沙箱没有它的运行证据。完整 PTY 的 tmux 本地 socket 与跨命名空间
cgroup 成员两项按环境条件跳过，其余场景通过。Snapshot 的设备拓扑
关联 ID 与 TUI 的导航图由夹具逐项核对。

### 2026-10-11：SMBIOS Type 45 固件组件清单

按 [DMTF SMBIOS 3.9 Type 45 定义](https://www.dmtf.org/sites/default/files/standards/documents/DSP0134_3.9.0.pdf)
读取组件名称、版本、制造商、发布日期、镜像大小、静态状态和关联的 SMBIOS
句柄。关联数量来自记录里的专用字段，不由记录总长度推断；超限或短记录
保留部分状态。自由格式的 Firmware ID 可能是机器标识，不进入公开模型；
仅格式正确的标准 GUID 可出现在详情和 Snapshot。固件的可更新位不说明
wtop 能更新它，也不代表更新服务当前可用。

设备树仅将无歧义、当前可用的句柄映射为双向导航引用，不把关联解释为
物理父子关系。夹具覆盖 Type 43 TPM 的明确关联、额外尾字段、缺少或重复
句柄、非法 GUID、镜像大小哨兵、记录上限、拒绝读取、Windows 原生表输入、
TUI、Snapshot、报告及隐私边界。本机 Linux 沙箱读取原始 DMI 表为
`denied`，没有 Type 45 实机字段证据；Windows/macOS 也只有开发构建与
夹具证据，没有本项真机运行验证。

最终源码的 `make check`、Lua 5.5.1 与系统 Lua 5.4.8 各 126 个测试文件、
完整 PTY 矩阵通过。重建 onedir 后，`--snapshot` 将此宿主的
`firmware_components` 报为 `denied`，快速 PTY 通过；onefile 构建成功，
本沙箱没有它的运行证据。完整 PTY 中 tmux 本地 socket 和跨命名空间
cgroup 成员两项按环境条件跳过，其余场景通过。

### 2026-10-11：Linux 进程与线程的内核等待位置

[proc_pid_wchan(5)](https://man7.org/linux/man-pages/man5/proc_pid_wchan.5.html)
将 `wchan` 定义为任务休眠时所在的内核函数名；读取受 ptrace 读权限检查。
进程详情打开后读取首线程，线程详情打开后读取选中 TID；`0` 显示为未报告位置，
权限拒绝和畸形读数各有状态。该函数名不被当作故障原因。两种详情都在
补充读取后复核启动时间，避免 PID/TID 复用混合读数。

夹具覆盖未打开详情时不读取、只读取选中线程、两个任务的不同函数名、
`0`、拒绝、畸形内容和线程身份变化。本机 Linux 沙箱直接采样 PID 1，
进程与其首线程均返回 `do_wait`，状态为 `ok`。这些证据不包含 macOS、
Windows 或 XP 运行验证。

最终源码的 `make check`、Lua 5.5.1 与系统 Lua 5.4.8 各 126 个测试文件通过；十语言目录
编译、快速 PTY、独立线程下钻 PTY 均通过。重建 onedir 后，包内线程下钻
PTY 也通过，实际界面画出了等待位置字段。

同日继续把首线程的 `wchan` 放进 Linux 进程表的可选 `WCHAN` 列。采集请求
来自已绘制的列与视口，最多 256 行；隐藏列、窄布局省略的列、被浮层覆盖
的表格和屏幕外进程不打开该文件。每个符号读数在发布前再次核对启动时间；
内核的 `0` 在表格留空，拒绝读取显示状态。macOS/Windows 不提供此列，
跨平台导入的布局也不会把隐藏的 Linux 列算入当地列序。
夹具覆盖采样范围、滚动、PID 复用、上限、列顺序和默认 JSON 边界；
本机 PID 1 的实际可见行返回 `do_wait`。源码与重建 onedir 的独立 PTY
场景均通过，列编辑器和表格都画出了 `WCHAN`；原有 Queued 列场景也通过。
最终源码的 `make check`、Lua 5.5.1 与系统 Lua 5.4.8 各 126 个测试文件，
以及完整 PTY 矩阵通过。矩阵中的 tmux 本地 socket 与跨命名空间 cgroup 成员
场景按当前沙箱条件跳过；其余场景运行通过。

### 2026-10-11：Linux 进程文件描述符下钻

[proc_pid_fd(5)](https://www.man7.org/linux/man-pages/man5/proc_pid_fd.5.html)
说明 `/proc/<pid>/fd` 中的数字条目是文件描述符链接，读取链接目标受
ptrace 读取权限检查。wtop 只在进程详情按 `F` 时枚举至多 128 个链接；
扫描前后复核 `(PID,starttime)`，身份变化就丢弃所有目标。目录最多扫描
4096 个名字，先按数字排序再读取目标。目标文本净化
控制字符，过长目标标明截断；单个 FD 消失或权限不足时保留明确状态。
扫描不打开链接指向的文件，结果不进入 Snapshot 或 Agent。
[proc_pid_fdinfo(5)](https://man7.org/linux/man-pages/man5/proc_pid_fdinfo.5.html)
定义了描述符的偏移、八进制标志、挂载 ID 和可选 inode。列表选中一项按
`Enter` 后才读取其 `fdinfo` 前缀；读取前后再次核对进程身份与链接目标，
变化时不显示元数据。列表与详情之间的 FD 号也可能被复用，因此详情重新
读取并展示选择时的目标，不把旧列表目标当作当前文件。wtop 不打开描述符
指向的文件，也不导出这些字段。

夹具覆盖数字排序、目录上限、目标截断/控制字符、链接消失、权限拒绝、
PID 复用、身份变化后清空路径、八进制标志与长整数原样保留，以及单项
FD 复用后丢弃详情。真实 PTY 场景从进程详情打开 FD 列表，按 `Enter`
查看元数据，再按 `Esc` 逐级返回并再次打开；独立运行通过。本机对当前 Lua 进程的
按需采集返回 `ok`，四个描述符中有一个在扫描期间消失，因此质量为
`partial`，符合临时 FD 的预期。对该进程的 FD 1 单独读取 `fdinfo` 为
`ok/fresh`，报告偏移 0、八进制标志 `01` 及挂载 ID 18。
最终代码的 Lua 5.5、5.4 各 126 个测试文件通过；完整 PTY 矩阵通过，
其中 tmux 本地 socket 与跨命名空间 cgroup 成员场景按环境条件跳过。
重建的 onedir 清单包含新模块，包内 FD 下钻独立 PTY 通过；onefile
构建成功，3 项 SBOM 摘要与 14 项清单一致，但本沙箱仍无法解包运行。
Windows x86 开发包通过 5 个 PE32 映像、510 项导入的静态门禁；没有
本功能的 Windows 或 XP 运行证据。

### 2026-10-11：Linux 热区与冷却设备

[Linux thermal sysfs 文档](https://docs.kernel.org/driver-api/thermal/sysfs-api.html)
定义了 thermal zone 的温度、触发点和 `cdevN` 绑定，以及 cooling device 的
当前与最大状态、可重置的转换累计次数和各状态累计驻留毫秒数。wtop 只读
`/sys/class/thermal`，不读取写入用的 `stats/reset`，也不从这些累计数推断
变化率。这些原始状态由设备自行定义，不换算为风扇转速或百分比，阈值
也不是预计关机时间。

本机有 10 个热区和 25 个冷却设备，采集为 `ok/fresh`。`thermal_zone0`
报告 `acpitz` 温度，五个 `cdevN` 链接分别指向已枚举的冷却设备；设备树
建立双向引用。多个驱动把未知阈值写为 `-274000` m°C，低于绝对零度，
采集器将其留空而不显示为真实温度。夹具覆盖阈值、绑定与下钻、无效温度、
冷却状态超出最大值、目录上限、缺失及拒绝访问。本机 25 个冷却设备的
统计目录均可读取；`intel_powerclamp` 报告 101 个状态的驻留累计值。
夹具另覆盖重复/越界状态、缺失统计字段与计数器重置后原值的发布。
最终代码的 Lua 5.5、5.4 各 125 个测试文件通过；5.5 的 5 项快速 PTY
通过，5.4 的原生依赖按规则跳过。重建的 Linux onedir Snapshot、报告和
System 硬件详情 PTY 通过；其中 `cooling_device24` 的统计记录包含
64 个状态、1 次累计转换，本机中文详情也显示非零驻留时间与重置提示。
onefile 构建成功，3 项 SBOM 摘要与 14 项
清单一致；本沙箱运行 onefile 的 `--version` 时解包失败，不计为运行通过。
Windows x86 开发包通过 5 个 PE32 映像、510 项导入的静态门禁；没有本
功能的 Windows 或 XP 运行证据。

### 2026-10-11：Linux 无线开关

[Linux rfkill sysfs ABI](https://www.kernel.org/doc/Documentation/ABI/stable/sysfs-class-rfkill)
提供 `hard`、`soft` 和旧版 `state` 等属性。wtop 只读
`/sys/class/rfkill`：优先分别显示硬件与软件阻断；仅在两项属性都缺席时
读取旧版 `state`，它不能表达两种阻断同时发生。属性存在却没有可用值时
保留未知状态。未阻断不等于已连接，wtop 不修改无线开关。

本机有四个节点：`ideapad_wlan`、`ideapad_bluetooth`、`hci0` 和 `phy0`；
当前硬件、软件阻断值均为 0。前两者归属 PCI `0000:00:1f.0`，`hci0`
的路径经过 USB 接口 `3-10:1.0`，`phy0` 归属 PCI `0000:00:14.3`。
夹具覆盖现代属性优先级、旧版回退、无值与非法值、部分属性、数量上限、
缺失/拒绝访问，以及 PCI/USB 设备关系。
最终代码的 Lua 5.5、5.4 各 124 个测试文件通过，5.5 的 5 项快速 PTY
通过；5.4 的原生依赖按规则跳过。重建的 Linux onedir 的 Snapshot 为
`ok/fresh`，报告列出四个开关，设备树将 `hci0` 关联到
`usb-interface:3-10:1.0`，其他三个节点关联到各自的 PCI 功能；System
硬件详情 PTY 通过。onefile 构建成功，3 项 SBOM 摘要与 14 项清单一致；
本沙箱没有 onefile 运行时证据。Windows x86 开发包通过 5 个 PE32 映像、
510 项导入的静态门禁，没有本功能的 Windows 或 XP 运行证据。

### 2026-10-11：Linux 看门狗设备

[Linux watchdog sysfs ABI](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-class-watchdog)
定义了设备标识、active/inactive 状态、超时和可选的原始状态位。wtop
只读 `/sys/class/watchdog`；仅当状态为 active 时公布 `timeleft`，不打开
`/dev/watchdog`，也不发送保活。本机 `watchdog0` 为 `iTCO_wdt`，状态
inactive、配置超时 30 秒，但 sysfs 的 `timeleft` 仍返回 1 秒；采集器
正确省略该倒计时。类设备链接可追溯到 PCI `0000:00:1f.4`，设备树
因此建立该父子关系。

夹具覆盖 active 倒计时、inactive 禁止读取 `timeleft`、原始状态位、
`nowayout`、非法状态、数量上限、缺失与拒绝访问，以及 PCI 链接关系。
当前主机的采集结果为 `ok/fresh`。这些 sysfs 读数只说明内核报告的
配置和状态，不是看门狗健康或过去复位原因的推断。
最终代码的 Lua 5.5、5.4 各 123 个测试文件通过；5.5 的 5 项快速 PTY
通过，5.4 的原生依赖按规则跳过。重建的 Linux onedir Snapshot 显示
`watchdog0` 为 inactive、超时 30 秒、没有 `timeleft`，设备树的父节点是
`pci:0000:00:1f.4`；报告和 System 硬件 PTY 通过。onefile 构建成功，
3 项 SBOM 摘要与 14 项清单一致；本沙箱没有 onefile 运行时证据。
Windows x86 开发包通过 5 个 PE32 映像、510 项导入的静态门禁，
没有本功能的 Windows 或 XP 运行证据。

### 2026-10-11：Linux OS TPM 清单

[Linux TPM sysfs ABI](https://www.kernel.org/doc/Documentation/ABI/stable/sysfs-class-tpm)
定义了 OS 注册设备、可选状态位、TPM 规范主版本和 PCR 库目录。wtop
低频扫描 `/sys/class/tpm`，显示版本、内核驱动和各 PCR 库的可见文件数；
只枚举目录，不打开 PCR 值、密钥或 NVRAM。旧内核缺少 5.5 才加入的
`tpm_version_major` 时，可从有界的 `device/caps` 文本读取 TPM 1.x 的
TCG 版本。OS 节点与 SMBIOS Type 43 固件记录保持独立。

夹具覆盖 TPM 2.0 的 PCR 库目录、旧内核 TPM 1.2 回退、可选状态位、
非法版本、目录截断、缺失/拒绝访问与 PCR 文件从未被打开。当前主机的
`tpm0` 实测为规范主版本 2、驱动 `tpm_crb_acpi`、SHA-256 库有 24 个
可见 PCR 文件名，采集质量为 `fresh`。本沙箱仍无法读取原始 DMI 表，
因此不能证明这台 OS TPM 对应哪条 Type 43 固件记录。
`make check test-55 test-pty-quick` 的 122 个 Lua 文件与 5 项快速 PTY 通过；
`make test-54` 的同一套 122 个文件也通过，原生依赖按规则跳过。
重建的 Linux onedir Snapshot、报告与 System 硬件 PTY 均显示独立 TPM
节点，Agent/v1 正常输出。onefile 构建成功，3 项 SBOM 摘要与 14 项清单
一致；本沙箱没有 onefile 运行时证据。Windows x86 开发包通过 5 个
PE32 映像、510 项导入的静态门禁，这不是 Windows TPM 的运行验证。

### 2026-10-11：Linux 进程信号菜单

进程页 `k` 菜单在默认 SIGTERM 后加入 SIGHUP 和 SIGINT，仍需选择目标并按
Enter 确认。Lua 和原生 C 层的白名单一致；发送仍经 `(pid,starttime)`
复核和 `pidfd_send_signal`。Windows 保留原有的终止操作，不显示 POSIX
信号菜单。

单元夹具核对菜单顺序、身份参数、未列入白名单的信号和 Windows 拒绝路径；
PTY 场景实际打开菜单、确认 HUP/INT 可见后取消，没有发送信号。另在当前
Linux 主机各创建一个受控的 `sleep` 子进程，分别通过完整动作链发送
SIGHUP/SIGINT，两者按对应信号退出。最初实测找出原生白名单未同步的
异常，修正后原生单测和受控子进程实测通过。
`make check check-native-warnings test-55 test-pty-quick` 通过 121 个 Lua 测试文件、
5 项快速 PTY 与 4 个原生源码的严格告警检查。最终 Linux onedir 的菜单
PTY 通过；用目录包内原生模块重复受控 HUP/INT 测试也通过。onefile 构建
成功，3 项 SBOM 摘要与 14 项清单一致；本沙箱没有 onefile 运行时证据。
Windows x86 开发包通过 5 个 PE32 映像、510 项导入的静态门禁，这不构成
Windows 或 XP 进程操作的运行证据。

### 2026-10-11：Linux 电源状态的未知值

[Linux power supply class 文档](https://docs.kernel.org/power/power_supply_class.html)
说明驱动可以省略属性；[内核 sysfs ABI](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-class-power)
把 USB `online=2` 定义为在线且电压可编程，并规定电池缺少 `present`
时视为在场。wtop 对电池遵守该默认值；适配器缺少 `present` 时保持未知。
缺失或异常的在线状态显示“未知”并给出
`power_supply_data_incomplete`，不再绘制离线的零值。UPS 进入电量条；
明确 `present=0` 的电池不显示残留电量，也不贡献主机状态。
电池状态缺失时摘要不猜测为空闲。目录有设备但 `type` 不可读时也不误报
为“没有电源”。

夹具覆盖在线 0/1/2、缺失和非法值、混合已知/未知适配器、UPS、电池
`present` 缺失/拒绝访问/明确为零、缺失状态与设备类型，并检查 System
电源条及 Snapshot。Lua 5.4/5.5
专项测试、121 个 Lua 测试文件与 5 项快速 PTY 通过。本机实际的 `ADP0`
为 Mains/在线、USB 供电节点为离线，二者都没有 `present` 文件；重建的
Linux onedir Snapshot 保持这两个在线读数并省略 `present`，来源为
`ok/fresh`。onedir 的 System 硬件 PTY 与 Agent/v1 通过。onefile 已构建，
3 项 SBOM 摘要与 14 项清单一致；本沙箱没有 onefile 运行时证据。
Windows x86 开发包通过 5 个 PE32 映像、510 项导入的静态门禁；这些
Linux sysfs 行为不构成 Windows 或 XP 的运行验证。

### 2026-10-11：SMBIOS Type 42 管理控制器主机接口

[DMTF SMBIOS 3.8 Type 42 定义](https://www.dmtf.org/sites/default/files/standards/documents/DSP0134_3.8.0.pdf)
使用变长的接口专属数据和协议记录。wtop 仅保留接口类别、协议类别、
声明数量、数据长度与 OEM 企业编号；可能含管理网络配置的原始负载不进入
Snapshot。SMBIOS 3.2 之前的 OEM 布局只在已知入口版本时解析，不凭字节
形状猜测。Type 42 与 Type 38 可能描述同一接口，设备树暂不合并它们。

夹具覆盖网络接口的 IPMI/MCTP/Redfish 多协议、现代及旧版 OEM 布局、
缺失入口版本、长度损坏、64 条协议上限、重复句柄、Linux/Windows 来源、
缺失与拒绝访问，以及原始负载不出导出。新增采集器与现有固件采集器在
同一调度轮次共用一次 DMI 读取，下一轮重新采样。Lua 5.4/5.5 专项
测试和全量 121 个 Lua 文件、5 项快速 PTY 通过。最终 Linux onedir 的
Snapshot 将 `host_interfaces` 标为 `denied`，Agent/v1 与带有接口章节的
报告正常输出，硬件详情和关系两项独立 PTY 通过。onefile 构建成功，
3 项 SBOM 摘要与 14 项清单一致；本沙箱没有 onefile 运行时证据。
Windows x86 开发包重建后通过 5 个 PE32 映像、510 项导入的静态门禁。
当前沙箱原始 DMI 表不可读，没有 Type 42 真机字段或 Windows/XP 运行证据。

### 2026-10-11：SMBIOS Type 43 固件 TPM

[DMTF SMBIOS 3.8 Type 43 定义](https://www.dmtf.org/sites/default/files/standards/documents/DSP0134_3.8.0.pdf)
给出固定 31 字节结构。wtop 读取四字符厂商 ID、TPM 规范版本、两个固件
版本字段、描述和特征位；保留位异常标为部分质量，OEM 字段不公开。
Type 43 在 System 设备树、详情、Snapshot 和报告中保持独立，不把固件
声明当作操作系统中的 TPM 可用性或安全状态。

夹具覆盖 TPM 2.0 与 1.2、特征不支持、保留位、非法厂商 ID、短记录、
重复句柄、数量上限、TPM 1.x 第二固件版本字段异常、Linux/Windows
SMBIOS 入口、缺失与拒绝访问，以及私有字符串和 OEM 字段不进入导出。
新增 BMC/TPM 采集器与其他固件来源在同一调度轮次共用一次 DMI 读取，
下一轮重新采样。Lua 5.4/5.5 专项测试和全量 121 个 Lua 文件、5 项快速
PTY 通过。当前沙箱的原始 DMI 表读取为 `denied`，没有 Type 43 真机字段证据。
最终 onedir 的 Snapshot 保留 `denied` 质量，Agent/v1 与带有 TPM 章节的
报告正常输出，硬件详情和关系两项独立 PTY 通过。onefile 成功重建，
3 项 SBOM 摘要与 14 项清单一致；本沙箱尚无 onefile 运行时证据。
Windows x86 开发包重新构建并通过 5 个 PE32 映像、510 项导入的静态门禁，
尚无 TPM 功能在 Windows 或 XP 上的运行结果。

### 2026-10-11：SMBIOS Type 38 IPMI BMC 接口

按 [DMTF SMBIOS 3.8 Type 38 定义](https://www.dmtf.org/sites/default/files/standards/documents/DSP0134_3.8.0.pdf)
读取接口类型、BCD 版本、I²C 目标及非易失存储地址。16 字节记录保留原始
基地址字段；有修饰字节时才解码地址最低位、寄存器间距和可选中断。
完整 64 位地址以十六进制字符串保留。SSIF 不把未使用的修饰字段解释为
寄存器布局。固件记录独立进入 System 设备树、详情、Snapshot 和报告，
不作为 BMC 当前可用性或健康告警。

Linux 和 Windows 读取入口、KCS/SSIF、地址修饰位、64 位高地址、
重复句柄、截断、损坏记录、缺失及拒绝访问均由固件夹具覆盖。Lua 5.4
与 5.5 的专项测试通过；全量 121 个 Lua 文件及 5 项快速 PTY 通过。
当前沙箱读原始 DMI 表为 `denied`，因此没有 Type 38 真机字段证据。
最终代码重建的 Linux onedir 的 Snapshot 把 `firmware_bmcs` 正确标为
`denied`、设备数为零，Agent/v1 和包含 Type 38 章节的报告正常输出；
硬件详情与关系两项独立 PTY 通过。onefile 构建成功，3 项 SBOM 摘要与
14 项清单一致；本沙箱没有 onefile 运行时证据。Windows x86 开发包
重新构建并通过 5 个 PE32 映像、510 项导入的静态门禁，尚无 Type 38
在 Windows 或 XP 上的运行证据。

### 2026-10-11：逐行 Snapshot 输出

`--stream` 先建立一轮速率基线，再按 `--interval` 输出 Snapshot/v1 的
JSON Lines；`--count N` 可让脚本在 N 行后退出。每行沿用 `--snapshot`
的远端地址默认脱敏，并立即刷新 stdout。流模式按采集器各自的周期
刷新，不在每行强制重扫固件、SPD 等低频来源。

夹具覆盖命令冲突、次数边界、两行独立 JSON、序列递增、等待失败后的
引擎清理及首轮之后的路由缓存。另有夹具使第二行没有任何来源到期，
确认序列不增加、来源采样时间不变，但输出时刻和 `value_age_ms` 增长。
管道写入或刷新时的 EPIPE 正常停止，真正的写入错误仍在清理后报告；
源码树的 `--stream | head -n 1` 实际以退出码 0 结束，没有错误堆栈。
本机源码树实际运行
`--stream --count 2 --interval 1000`，得到两行 Snapshot/v1，序列为
2、3，采样时间相差约 1.1 秒。这是有界流验证，长期保存、轮转和
回放仍是独立缺口。

`make check test-55 test-pty-quick` 的 121 个 Lua 测试文件及快速 PTY 通过。
Linux onedir 包实际输出两行可独立解析的 JSON，序列同为 2、3，采样
间隔约 1.15 秒；管道读取时第一行在进程退出前已到达，随后约 1.12 秒
收到第二行。Windows x86 开发包中的 CLI 与应用模块同源码一致，
5 个 PE32 映像和 510 项导入通过静态门禁，没有本轮 Windows 运行结果。
onefile 已重建，3 项 SBOM 摘要与 14 项清单一致；本沙箱没有 onefile
运行时证据。
EPIPE 处理修正后，`make check`、Lua 5.4/5.5 的 CLI/导出定向用例及
重建包的许可证/SBOM 校验通过；新 onedir 的 `--stream | head -n 1`
同样安静地以退出码 0 结束。

### 2026-10-11：NVMe 命名空间已分配量

[Linux 稳定 NVMe sysfs ABI](https://docs.kernel.org/admin-guide/abi-stable.html)
说明读取 `nuse` 会刷新 Identify Namespace；[NVM Express 的命名空间说明](https://nvmexpress.org/resource/nvme-namespaces/)
将 NUSE 定义为当前已分配的逻辑块数。wtop 在稳定 `diskseq` 下复用
60 秒内的读数，保留原始采样时间及 `cached` 标志；换算字节数前检查
逻辑块大小与溢出，不把该值称为文件系统已用空间。

夹具覆盖首次读取、缓存复用、到期刷新、坏值、超过命名空间容量的值，
以及设备世代变化时不沿用旧读数。本机源码树实际读到 `nvme0n1` 的
`2,000,409,264` 个已分配逻辑块，按 512 字节换算为
`1,024,209,543,168` 字节；报告显示 `953.87 GiB`。

`make check test-55 test-pty-quick` 的 121 个 Lua 测试文件与快速 PTY 通过；
源码树和 Linux onedir 包的硬件详情、设备关系 PTY 通过。onedir 的
`--snapshot`、`--agent`、`--report` 实际运行成功：Snapshot 保留原始块数、
字节数、读取时间和 `cached=true`；报告显示 `953.87 GiB` 与 `cached`，
共 387 行。Windows x86 开发包中的模块与源码一致，5 个 PE32 映像与
510 项导入通过静态门禁，没有本轮 Windows 运行结果。onefile 已重建，
3 项 SBOM 摘要与 14 项清单一致；本沙箱没有 onefile 运行时证据。

### 2026-10-11：NVMe 多路径清单

[Linux NVMe 多路径实现](https://github.com/torvalds/linux/blob/master/drivers/nvme/host/multipath.c)
把聚合命名空间挂在 subsystem 下，并从聚合设备建立到各路径设备的 sysfs
链接；[稳定 sysfs ABI](https://docs.kernel.org/admin-guide/abi-stable.html)
定义 ANA 状态与子系统 I/O 策略。wtop 核对聚合设备、subsystem、路径
链接和控制器类路径后，才输出控制器路径及各自的状态、传输方式、ANA
状态与组号。每个聚合设备最多扫描 256 个目录项、输出 32 条路径；
不读取 NQN、序列号或传输地址。

夹具中的两个控制器路径分别为 optimized 和 non-optimized；错误链接、
缺失 subsystem 或目录、超过路径上限时不会发布未经证实的完整拓扑。
当前开发机只有单控制器直连命名空间，没有真实多路径运行证据。

`make check test-55 test-pty-quick` 的 121 个 Lua 测试文件与快速 PTY 通过；
源码树和 Linux onedir 包的硬件详情、设备关系 PTY 通过。onedir 的
`--snapshot`、`--agent`、`--report` 实际运行成功：`nvme0n1` 保留已核对的
单控制器，而 `paths` 缺省；报告的 `NVMe paths` 表为空，共 387 行。
Windows x86 开发包中的模块与源码一致，5 个 PE32 映像与 510 项导入
通过静态门禁，没有本轮 Windows 运行结果。onefile 已重建，3 项 SBOM
摘要与 14 项清单一致；本沙箱没有 onefile 运行时证据。

### 2026-10-11：NVMe 控制器诊断

[内核 NVMe sysfs ABI](https://docs.kernel.org/admin-guide/abi-stable.html)列出控制器的
传输方式及命令错误、重置、重连累计数。wtop 仅当命名空间的真实 sysfs
路径与控制器类链接互相吻合时读取这些字段，再把累计数与相邻样本的
增量分开显示。多路径聚合命名空间不能唯一指向一个控制器时保持未知；
不读取序列号、NQN 或传输地址。同轮多个命名空间共用一次控制器计数
读取，但各自保留独立的增量与质量。

夹具覆盖控制器绑定、链接不符、多路径聚合设备、计数增长/复位、
磁盘世代变化、缺失或损坏字段及共享读取。本机源码树实际输出
`nvme0n1 → nvme0`、`live`、`pcie`，命令错误和重置累计均为 0；
只有单控制器，尚无真实多路径主机验证。

`make check test-55 test-pty-quick` 的 121 个 Lua 测试文件和快速 PTY 通过，
源码树与 Linux onedir 包的硬件详情、设备关系 PTY 通过。onedir 的
`--snapshot`、`--agent`、`--report` 实际运行成功，报告的 `NVMe controllers`
行与 Snapshot 一致，共 383 行。Windows x86 开发包中的模块与源码一致，
5 个 PE32 映像和 510 项导入通过静态门禁，没有本轮 Windows 运行结果。
onefile 已重建，3 项 SBOM 摘要与 14 项清单一致；本沙箱没有 onefile
运行时证据。

### 2026-10-11：SMBIOS Type 8 固件端口

[DMTF SMBIOS 3.8 Type 8 定义](https://www.dmtf.org/sites/default/files/standards/documents/DSP0134_3.8.0.pdf)
给出固定九字节结构中的内部/外部标识、连接器类型和端口用途。wtop 最多
保留 128 条端口记录，未知枚举保留代码；Type 8 与其他固件采集器共用
同轮 SMBIOS 读取。固件未提供当前操作系统设备的身份，所以端口进入
设备树、System 详情、Snapshot 和报告，但不凭名称连接到 PCI、USB 或
网络接口。

夹具覆盖串口与只有外部连接器的 USB-C 端口、重复句柄、记录上限、
Linux/Windows 读取路径及共享表缓存；另有私有字符串不进入导出结果的
检查。当前开发机的原始 DMI 表不可读，尚无本机 Type 8 真值证据。

`make check test-55 test-pty-quick` 的 121 个 Lua 测试文件与快速 PTY 通过；
源码树和 Linux onedir 包的硬件详情、设备关系 PTY 通过。onedir 的
`--snapshot`、`--agent`、`--report` 实际运行成功：Snapshot 将固件端口
来源标为 `denied`，报告包含空的 `Firmware ports` 章节，共 377 行。
Windows x86 开发包包含相同模块，5 个 PE32 映像与 510 项导入通过静态
门禁；没有本轮 Windows 运行结果。onefile 已构建，3 项 SBOM 摘要与
14 项清单一致；本沙箱没有 onefile 运行时证据。

### 2026-10-11：MD 阵列成员位置与状态

[Linux MD sysfs 文档](https://docs.kernel.org/admin-guide/md.html)规定
`dev-*` 目录的 `block` 链接、`slot` 与逗号分隔的 `state`。wtop 经链接下的
`block/dev` 核对成员设备号，显示阵列位置与状态；`slot=none` 只表示
没有活动位置，不猜成某一种故障。成员读取最多扫描 512 个目录项、保留
64 个成员；重复设备号、损坏字段和截断带独立质量状态，不改变已读取的
阵列级缺失设备数。成员信息进入 System 详情、Snapshot 与报告，报告
另设全局 512 行上限。

夹具覆盖一块在位置 0 的同步成员和一块无活动位置的备用成员，验证设备
号、状态标志、隐私边界及表格输出；重复设备号、字段损坏、目录缺失和
列表截断不会形成看似完整的清单。本机没有 MD 阵列，成员角色尚无实机
运行证据。

`make check test-55 test-pty-quick` 的 121 个 Lua 测试文件和快速 PTY 通过，
源码树与 Linux onedir 包的硬件详情、设备关系场景通过。onedir 的
`--snapshot`、`--agent`、`--report` 实际运行成功；报告新增成员表后为
372 行，本机 7 个块设备中没有 MD 卷。Windows x86 开发包包含相同模块，
5 个 PE32 映像与 510 项导入通过静态门禁，尚无 XP 运行结果。onefile
已重建，3 项 SBOM 摘要与 14 项清单一致；本沙箱没有 onefile 运行证据。

### 2026-10-11：MD RAID 同步进度

[Linux MD sysfs 文档](https://docs.kernel.org/admin-guide/md.html)定义
`sync_action` 的恢复、重同步、检查、修复等动作，`sync_completed` 给出已处理
与总扇区数。wtop 将动作和进度送入 System 详情、Snapshot 与报告。读取
分数后再次核对动作；若动作已变，保留新动作并将进度标为 `gap`，不把旧
分数归到新动作。字段缺失、分数无效和 64 位扇区数均有夹具覆盖。

`make check test-55 test-pty-quick` 的 121 个 Lua 测试文件、快速 PTY，
以及源码树和 Linux onedir 包的硬件详情与关系场景通过。Windows x86 开发
包包含相同模块，5 个 PE32 映像与 510 项导入通过静态门禁。onedir 的
`--report` 实际运行成功，报告仍为 368 行；本机没有 MD 阵列，同步
进度路径尚无实机证据。onefile 已重建，3 项 SBOM 摘要与 14 项清单一致；
本沙箱没有 onefile 运行时证据。

### 2026-10-10：device-mapper 与 MD 卷状态

[内核 device-mapper sysfs 实现](https://github.com/torvalds/linux/blob/master/drivers/md/dm-sysfs.c)
提供映射器名称和暂停位；[MD sysfs 文档](https://docs.kernel.org/admin-guide/md.html)
定义 RAID 级别、活动状态、预期设备数及缺失设备数。wtop 只读这些公开
字段，不读取 DM/MD UUID、映射表或 MD 元数据镜像。卷名帮助人识别设备，
但不作为持久身份；字段缺失不让普通 I/O 读数变成零或失败。

夹具中的 `dm-0` 以 `cryptroot` 标识且可切换暂停位；`md0` 报告 raid1、
预期 2 台、缺失 1 台及 clean 状态。Storage、System、Snapshot 和报告
显示同一份状态；Agent 仅对当前且活动的缺失设备阵列给警告，不把陈旧、
inactive 或损坏字段当作故障。UUID 不进入解析或导出结果。
当前开发机没有 dm/md 设备，尚无真实卷状态运行证据。
`make check test-55 test-pty-quick` 的 121 个 Lua 测试文件和快速 PTY 通过；
源码树与 Linux onedir 包的硬件详情、设备关系 PTY 场景均通过。onedir 的
`--snapshot`、`--agent`、`--report` 实际运行成功：本机 7 个块设备中没有
dm/md 卷，卷状态章节为空，也没有 MD 缺失设备警告。Windows x86 开发包
包含相同的读取器、采集与导出代码，5 个 PE32 映像和 510 项导入通过静态
门禁；这不是 XP 运行验证。Linux onefile 已构建，3 项 SBOM 摘要与 14 项
清单一致；本沙箱的 onefile 解包限制见下文，不能据此声称运行通过。

### 2026-10-10：堆叠块设备的底层引用

[Linux 块层 holder 实现](https://github.com/torvalds/linux/blob/master/block/holder.c)
在 holder 的 `slaves` 目录及底层设备的 `holders` 目录建立双向 sysfs 链接。
wtop 读取 holder 链接中的设备号，再同本轮块设备清单核对；全部成员都唯一
命中时，设备树建立可导航的双向引用，而不把底层盘设为物理父节点。
链接缺失、名称歧义、自引用、列表截断或来源陈旧时，不输出未证实的关系。

夹具中的 `dm-0` 指向一个 NVMe 分区，System 详情、相关设备导航、
Snapshot 拓扑及 Markdown 报告都显示双向引用。另一组夹具证明两个底层
成员中有一个无法核对时不会发布半组关系。当前开发机没有 dm/md 堆叠
设备，尚无本功能的真实堆叠主机证据。
`make check test-55 test-pty-quick` 的 121 个 Lua 测试文件及快速 PTY
通过，Lua 5.4 的采集器/设备图定向测试通过。源码与重建 onedir 的硬件
详情及关联导航 PTY 均通过；onedir 的 Snapshot 含 7 个块设备节点，
依赖引用数为 0，报告显示空依赖清单。Windows x86 开发包通过 5 个
PE32 映像、510 项导入的静态门禁，但没有本功能的 Windows 运行证据。
onefile 已构建，3 项 SBOM 摘要与 14 项清单一致，本沙箱仍无运行时证据。

### 2026-10-10：分区容量与起点

[Linux 分区 sysfs 实现](https://github.com/torvalds/linux/blob/master/block/partitions/core.c)
把 `start` 与 `size` 分别接到分区起始扇区和块设备扇区数；
[块层扇区定义](https://github.com/torvalds/linux/blob/master/include/linux/blk_types.h)
规定基本扇区为 512 字节。采集器据此从分区自己的
`/sys/dev/block/<major>:<minor>` 换算字节，不拿父盘容量或逻辑块大小代替。
非整数、缺失及乘法溢出保持未知，分区仍不参与整盘 I/O 合计。

开发机 `nvme0n1p1` 给出 `size=1228800`、`start=2048`，Snapshot 与报告
对应 600 MiB 容量和 1 MiB 起点；设备树继续把它挂在父盘下。
夹具覆盖 Storage 行、System 详情、Snapshot、报告和坏输入。
`make check test-55 test-pty-quick` 的 121 个 Lua 文件与快速 PTY 通过，
Lua 5.4 的采集及导出定向测试通过。源码及重建的 Linux onedir 分别通过
硬件详情 PTY；onedir 的 Snapshot 与报告显示同一分区容量和起点。
Windows x86 开发包通过 5 个 PE32 映像、510 项导入的静态门禁，未做
本轮 Windows 分区运行验证。onefile 已构建，3 项 SBOM 摘要与 14 项清单
一致；本沙箱仍没有它的运行时证据。

### 2026-10-10：Linux NVMe 诊断计数

按[内核稳定 sysfs ABI](https://docs.kernel.org/admin-guide/abi-stable.html)
读取 NVMe 命名空间的命令重试、命令错误、路径故障切换，以及无可用路径时
I/O 重排队或失败的可选计数；有 ANA 属性时记录路径状态与组号。不读取
序列号、WWID 或会触发 Identify Namespace 的 `nuse`。普通磁盘速率仍以
`/proc/diskstats` 为准；诊断文件缺失不改变它的质量。

累计计数与相邻样本新增数分开。仅相同 `diskseq` 的设备可计算新增数；
首次读取、设备重建、计数器回退、解析失败或权限不足时不编造增量。
一轮最多检查 128 个 NVMe 命名空间，超出上限明确标记截断。Agent 只在
无可用路径 I/O 失败计数增加且磁盘来源当前时给出一条警告线索，
不对历史累计数或多个设备的同一事件求和。内核允许管理员改写计数器，
因此 `+N` 是观察到的差值，不独自证明 N 次真实故障。

本机 `nvme0n1` 的内核读数为重试 0、命令错误 0、路径故障切换 0，
Snapshot 的相邻样本新增数均为 0；这台机器没有提供无路径失败或 ANA
属性，不能当作多路径运行验证。夹具覆盖新增、重置、盘符复用、缺失文件、
无效文本与扫描上限，并验证 System 详情、报告、Snapshot 和 Agent 一致。
`make check test-55 test-pty-quick` 的 121 个 Lua 文件和快速 PTY 通过，
Lua 5.4 的采集、导出与原因码定向测试通过；源码及重建的 Linux onedir
均单独通过硬件详情 PTY。onedir 的 Snapshot 与报告读到上述三个零计数，
Agent 没有误报；发布校验确认 3 项 SBOM 摘要与 14 项清单一致。Windows x86
开发包含同一纯 Lua 解析和导出模块，5 个 PE32 映像、510 项导入通过静态
门禁，但没有 Windows NVMe 运行证据。onefile 已构建，在本沙箱仍没有
运行时证据。本机单次 100 轮短采样中，含诊断读取的磁盘采集耗时 63.1 ms，
将诊断读取替换为无操作时为 56.7 ms；这不是旧硬件预算。

### 2026-10-10：可阅读的硬件摘要

`--report` 将同一份 Snapshot 脱敏白名单转成英文 Markdown：主机、CPU、
内存、存储、网络、GPU、电池、固件设备、传感器与设备关系分别成表，来源
状态和原因在报告前部列出。未知值保持空缺表达；报告不输出进程、远端
连接或固件序列号，长字符串和 Markdown 表格特殊字符经过有界转义。
报告是当前字段的摘要，较深的设备属性仍可在 `--snapshot` 中核对。
报告只运行所展示的硬件采集器；独立的进程、连接、cgroup 等采集器不运行，
Linux GPU 的逐进程 fdinfo 扫描关闭。开发机连续三次源树运行的耗时由
1.087–1.139 秒降到 0.726–0.771 秒；这是本机短样本，不是旧硬件预算。

CLI、导出隐私及被拒绝来源夹具在 Lua 5.4/5.5 下通过；
`make check test-55 test-pty-quick` 的 121 个 Lua 文件与快速 PTY 通过。
重建的 Linux onedir 包实际输出 368 行 Markdown，包含本机 NVMe、GPU、
传感器、电池与 `denied` 固件来源；三次独立运行耗时 0.771–0.942 秒，
硬件详情 PTY 通过。onedir 与上面的源码树是不同测量对象，不把两组耗时
相互比较。包内 `--snapshot` 仍包含进程与连接质量记录。Windows x86 开发包
包含同一报告模块，5 个 PE32 映像、510 项导入通过静态门禁；没有本轮
Windows 运行结果。onefile 已构建，3 项 SBOM 摘要与 14 项清单一致，
但本沙箱启动时在解包阶段返回 `extraction failed`：其父目录 `/home` 与
`/tmp` 在沙箱里归 `nobody` 所有，而打包器的安全检查只信任 root 或当前
用户拥有的目录，因此这里没有 onefile 运行时证据。

### 2026-10-10：固件表同轮读取与解析复用

六个 SMBIOS 采集器原先在一次探测或采样中各自读取并解码同一张表。
调度器现在为每轮提供短生命周期缓存：相同平台、路径和读取后端只做一次
成功读取与解析，返回给各采集器的记录与问题列表仍是独立副本；下一轮重新
读取，直接采集器调用也不复用。夹具覆盖不同读取后端、探测与采样边界、
结果隔离及固件表更新。

本机 36,006 字节合成表、20 轮每轮六个采集器的 CPU 时间由 0.586 秒降至
0.115 秒，DMI 读取从 120 次降至 20 次。这是开发机夹具测量，不是旧硬件
或真实固件读取性能。Lua 5.4/5.5 的硬件、调度器和引擎定向测试通过；
`make check test-55 test-pty` 的 121 个 Lua 文件及完整 PTY 矩阵通过。
重建的 onedir 包在 Snapshot、Agent 和 System 硬件详情 PTY 下运行正常；
本机固件表被拒绝，因此没有实表加速数据。Windows x86 开发包包含同一
调度器与共享读取模块，5 个 PE32 映像和 510 项导入通过静态门禁，但没有
本轮 Windows 运行结果。onefile 已构建，3 项 SBOM 摘要与 14 项文件清单
一致，本沙箱没有其运行时证据。

### 2026-10-10：SMBIOS Type 22 固件电池

按 [DMTF SMBIOS 3.9 Type 22](https://www.dmtf.org/sites/default/files/standards/documents/DSP0134_3.9.0.pdf)
读取便携电池的位置、制造商、名称、化学类型、设计容量与电压、报告电量误差。
旧结构的容量倍率为 1；带倍率字段的结构按其值换算 mWh。容量、电压为 0
以及误差为 `FFh` 时保持未知。制造日期、序列号和 OEM 字段不进入解析结果。
固件设计值不与操作系统的当前电量或健康读数混用，也不凭名称猜测同一电池。

二进制夹具覆盖旧/新长度、倍率、未知值、异常字段、重复句柄、数量上限、
Windows 原生读取回退，以及 System 搜索、详情和 Snapshot 脱敏一致性。
本机读取 SMBIOS 表被拒绝，尚无 Type 22 真机电池数据。
`make check test-55 test-pty` 的 121 个 Lua 测试文件与完整 PTY 矩阵通过；
Lua 5.4 的硬件、原因与采集器清单定向测试通过。重建 onedir 的 Snapshot
包含空固件电池数组并报告 `denied` 质量，硬件详情和 ASCII PTY 通过，
manifest 包含新采集器。Windows x86 开发包包含同一源码，5 个 PE32 映像、
510 项导入通过静态门禁；没有本轮 Windows 或 XP 运行结果。onefile 已构建，
3 项 SBOM 摘要与 14 项清单一致，本沙箱没有取得它的运行证据。

### 2026-10-10：SMBIOS Type 39 固件电源

按 [DMTF SMBIOS 3.9 Type 39](https://www.dmtf.org/sites/default/files/standards/documents/DSP0134_3.9.0.pdf)
读取每个可能电源的位置、型号、制造商、固件状态、存在/未接电/热更换位、
额定持续输出及可选探针句柄。规范表格以瓦说明最大输出，旁注又提到
毫瓦；Snapshot 同时保留 16 位原值，界面按表格的瓦显示，供设备核对。
序列号和资产标签不进入解析结果。相同非零组号仅作为固件冗余配置引用，
不宣称当前两台电源都在供电，也不触发实时健康告警。

二进制夹具覆盖字段和位解析、未知额定值、缺失/重复/截断组、Windows
原生读取回退，以及 System 搜索、详情、导航和 Snapshot 的一致性。
本机读取 SMBIOS 表被拒绝，尚无 Type 39 真机电源数据。
`make check test-55 test-pty` 的 121 个 Lua 测试文件和完整 PTY 矩阵
通过；最终源码的快速 PTY 与 Lua 5.4 硬件夹具也通过。重建 onedir 的
Snapshot 含空电源数组，质量为 `denied`，System 硬件详情与 ASCII PTY
通过。Windows x86 开发包含相同解析器与采集器，5 个 PE32 映像和 510 项
导入通过静态门禁；没有本轮 Windows 或 XP 运行结果。onefile 已构建，
发布校验确认 3 项 SBOM 摘要与 14 项清单一致，但本沙箱没有运行证据。

### 2026-10-10：SMBIOS Type 37 内存通道

按 [DMTF SMBIOS 3.9 的 Type 37 定义](https://www.dmtf.org/sites/default/files/standards/documents/DSP0134_3.9.0.pdf)
读取通道类型、最大负载、设备数，以及每个 Type 17 设备的负载与句柄。
长度按记录自身的设备数检查，允许末尾扩展字段；总负载超过上限、
句柄缺失/重复、记录不完整或列表截断时，保留通道而不建立 DIMM 引用。
DIMM 仍以 Type 16 阵列为父节点，通道是独立的双向固件引用。

二进制夹具覆盖解析、Linux 与 Windows 共用的采集路径、System 搜索/详情、
相关设备导航、Snapshot，以及短记录、负载超限、缺失句柄和截断。
本机读取 SMBIOS 表被拒绝，尚无 Type 37 真机通道数据；旧固件是否提供
Type 37 也需实机验证。通道负载不代表实测内存带宽。
`make check test-55 test-pty` 通过 121 个 Lua 测试文件和完整 PTY 矩阵；
最终源码的 `make check test-55 test-pty-quick` 也通过，Lua 5.4 的硬件
夹具通过。重建 onedir 的 Snapshot 含通道数组并报告 `denied` 质量，
System 硬件详情与 ASCII PTY 通过。Windows x86 开发包包含相同的 SMBIOS
解析器与设备树模型，5 个 PE32 映像、510 项导入通过静态门禁；没有本次
Windows 运行结果。onefile 已构建，发布通知检查的 3 项 SBOM 摘要与
14 项清单一致，本沙箱没有取得它的运行证据。

### 2026-10-10：SMBIOS Type 41 板载设备

按 [DMTF SMBIOS 3.9 的 Type 41 定义](https://www.dmtf.org/sites/default/files/standards/documents/DSP0134_3.9.0.pdf)
读取板载标识、设备类型/实例、启用位与段/总线/设备/功能号。固件记录独立于
操作系统 PCI 树；只有启用、当前且无歧义的记录唯一命中已枚举 PCI 功能时
建立双向引用。整组 `FF` 地址表示没有 PCI 坐标；单个 `FF` 字段仍可能是
合法的总线或设备/功能值。序列号与原始固件表不进入导出。

二进制夹具检查解析、独立采集、System 搜索/详情、相关设备导航和 Snapshot，
并覆盖禁用、无地址、重复、截断、陈旧及 Windows 原生读取回退。本机非特权
运行读取 SMBIOS 表被拒绝，因此当前没有 Type 41 真机设备归属证据。
`make check test-55 test-pty` 通过 121 个 Lua 测试文件和完整 PTY 矩阵；
最终源码的 `make check test-55 test-pty-quick` 也通过，系统 Lua 5.4 的
硬件夹具通过。重建 onedir 的 Snapshot 包含板载设备槽及 `denied` 质量，
System 硬件详情 PTY 通过。Windows x86 开发包包含相同的 Lua 解析器和
采集器，5 个 PE32 映像、510 项导入通过静态门禁，尚无 Windows 运行结果。
onefile 已构建；发布通知检查的 3 项 SBOM 摘要与 14 项清单一致，
本沙箱没有取得它的运行证据。

### 2026-10-10：图表时间轴缩放

`z` / `Z` 把每格时间设为 0.5、1、2、4 或 8 秒，默认一秒；采集频率和
四分钟历史容量不变。较高面板在图表下沿标出实际窗口起点与当前时刻。
窗口超过历史容量时，采样区靠右，起点标签跟随有效采样区；块状和
Braille 模式显示同一段时间。单行趋势图也采用当前倍率。

图表夹具覆盖五档时间跨度、四分钟封顶、块状/Braille 对齐、短图中的
尖峰和时间标签位置。真实 PTY 场景验证 2→4→8 秒/格和最终的
`-240s` 标签；ASCII 场景验证 `z` / `Z` 及 0.5 秒/格仍为纯 ASCII。
完整 PTY 矩阵通过；坐标对齐修正后的 `make check test-55 test-pty-quick`
通过 121 个 Lua 文件。重建的 onedir 包通过缩放、Braille 与 ASCII
三项独立 PTY 场景。onefile 已重建，发布通知检查确认 3 项 SBOM 摘要
与 14 项清单一致；本沙箱未取得 onefile 的运行证据。Windows x86 包
按当前源码重建并通过 5 个 PE32 文件、510 项导入的静态检查；没有本次
Windows 或 XP 运行验证。

### 2026-10-10：Braille 趋势图

指标卡增加 `B` 键切换：每格两个时间分桶，每列四个垂直点；块状图仍是默认模式。
带时间戳的历史沿用原来的时间窗口、峰值归并和读数刻度。零值保留基线点，
没有读数的格显示缺口；无 Unicode 的终端保持 ASCII，并提示不能切换。

`make check test-55 test-pty` 通过 121 个 Lua 测试文件和完整 PTY 矩阵；
Lua 5.4 的图表及轴标签定向测试通过。新增 PTY 场景在真实终端验证
Braille 出现、切回块状后无残留；ASCII 场景验证 `B` 不输出 Unicode。
重建 onedir 后，两项场景再次通过。`make test-release-notices` 的
SBOM 三项摘要与 14 项清单一致。当前没有 XP 或经典 CMD 的盲文运行证据。

### 2026-10-09：源码与 luainstaller 升级评估

本次在上述 Fedora x86_64 主机验证 `aea04ad` 开发树，
文档整理期间未改动运行时代码。`make check` 与 `make test` 均通过，
后者包含 120 个 Lua 测试文件和完整 PTY 矩阵，涵盖缩放、tmux、
退出信号、工作区、线程、列编辑、十个页面及颜色/ASCII 回退。

luainstaller 1.5.0 使用已校验的正式源 rock，在独立目录通过内置
离线安装器部署；构建前用 `make build-id native locales` 刷新修订身份。
以下是切换默认版本之前、以 1.3.0 为默认打包链时的隔离候选结果：

| 检查 | onedir 候选 | onefile 候选 |
| --- | --- | --- |
| 构建及 Lua/原生修订一致 | 通过 | 通过 |
| `--version`、`--snapshot`、`--agent`、`--diagnose` | 通过；Snapshot/Agent JSON 契约通过 | 通过；Snapshot/Agent JSON 契约通过 |
| 快速 PTY | Overview、GPU、ASCII/无色、退出信号通过 | 同样通过 |
| 整体 glibc 下限 | 2.38 | 2.38，已计入两个内嵌 ELF；外层为 2.34 |

原生模块的 glibc 下限为 2.34。该打包器升级没有降低配套 Lua 运行时
带来的 2.38 下限。CLI 验证清空了 `LUA_PATH`/`LUA_CPATH`；
本次未运行无 Lua 的系统镜像、候选的完整 PTY、Windows/macOS 或 XP。
性能、许可证/SBOM/校验和及各平台的完整迁移检查见
[升级评估](PACKAGING.md#32-luainstaller-150-升级评估)。

### 2026-10-09：默认打包器迁移与硬件设备树

本轮开发树将默认打包器切换为 luainstaller 1.5.0，锁定正式源 rock
及安装后的 29 份载荷。PCI/USB 采集增加父设备、驱动、NUMA 节点、
PCIe 当前/最大链路与 USB 速率；共享模型用于系统设备表、设备详情和
`inventory.topology` 导出。hwmon 类链接保留完整祖先路径，用于将
相对设备链接的 NVMe 传感器关联回 PCI 控制器。

在同一台 Fedora 44、kernel 7.2.8、glibc 2.43 x86_64 主机上：

- Lua 5.5 的 120 个 Lua 测试文件通过；补充类链接后的六个相关测试通过。
- Lua 5.4 子集通过，原生模块相关项目按该目标的既有规则跳过。
- 源码、onedir 和 onefile 的完整 PTY 矩阵通过，含新增硬件详情场景。
  清单为 19 个场景，16 个由整套测试调用，其余可隔离运行。
- 严格原生警告检查、LuaRocks 已安装命令的版本/诊断及 Snapshot/Agent
  JSON 契约、许可证、SBOM/校验和一致性与发布 ELF 基线通过。
- 现场快照导出 21 个 PCI、7 个 USB 设备，9 条父设备关系、一个 GPU
  关联与一个 NVMe 传感器关联；拓扑未截断，也未报告不完整。

当前两种产物的整体 glibc 下限仍为 2.38。这一轮没有新增 Windows、
macOS 或 XP 的运行证据。线程 PTY 场景现在固定检查本轮启动的进程，
避免最忙的宿主进程退出或不提供可读线程时产生偶发失败。

### 2026-10-09：恢复开发，接入存储与网络设备关系

在上述未提交工作上扩展共享模型：Linux 磁盘、分区和网卡通过 sysfs
路径接入 PCI/USB 树，挂载通过设备号关联；TUI 和 JSON 使用同一关系。

- 夹具覆盖 PCI/USB 归属、分区、挂载别名和 bind mount、虚拟设备、
  重复身份、整盘 diskseq 变化、网卡改名、缺少总线清单以及模型/表格上限。
- 本机快照包含 21 个 PCI、7 个 USB、7 个块设备和 18 个网络接口，
  共 53 个节点、15 条可解析的父设备关系和 2 条挂载关联；未报告
  partial 或 truncated。NVMe 的三个分区、无线和有线网卡均关联正确。
- 160×40 英文真实 PTY 已验证分区挂载详情、`p` 返回整盘与网卡收发详情，
  并回放终端输出核对显示内容。
- `make test-all` 通过：Lua 5.4 子集与 Lua 5.5 各运行 120 个测试文件；
  源码、onedir 和 onefile 的完整 PTY 矩阵全部通过，含设备详情场景。
  LuaRocks 安装、严格原生警告、发布 ELF 基线、许可证及 SBOM/校验和
  一致性检查通过。Lua 5.4 的原生项目按该目标既有规则跳过。
- 清除 `LUA_PATH`/`LUA_CPATH` 后，两种包的 Snapshot/Agent JSON 契约
  均通过；53 个节点中的资源与挂载引用可解析。整体 glibc 下限仍为 2.38。

这台主机的 Btrfs 根挂载报告匿名设备号，本轮未将它关联到某个底层盘。
复杂存储栈关系仍待实现；本轮没有新增 Windows、macOS 或 XP 实测。

### 2026-10-09：CPU 频率域与 Linux NUMA

- 新增独立 NUMA 采集器、内存页表格和节点详情；系统设备树关联 CPU
  插槽/核心/逻辑 CPU、频率策略、NUMA 和 PCI 本地性。缺少实测拓扑 ID
  或在线状态时，详情保留未知状态。
- 夹具覆盖稀疏 NUMA 编号、仅有内存的节点、离线 CPU、跨插槽频率策略、
  权限不足、无数据源、内存计数错误、CPU 列表上限、距离长度错误和
  在线节点集合变化。后者会使本轮距离映射失效。
- 本机采到 1 个 NUMA 节点、16 个逻辑 CPU 和 16 个频率策略。
  共享树共 97 个节点，partial/truncated 均为 false；CPU/NUMA/频率策略
  引用可解析。多节点距离和跨插槽关系已用夹具验证，尚无多 NUMA 真机记录。
- Lua 5.5 的 120 个测试文件与完整源码 PTY 矩阵通过；清单扩展为
  20 个可隔离场景，其中 17 个由整套调用。NUMA 表也加入十语言宽度、
  状态列和布局检查。最后的选择状态修正后，NUMA 独立场景再次通过。
- Lua 5.4 运行本轮相关的 9 个测试文件通过。onedir 和 onefile 的
  Snapshot/Agent JSON 契约、快速 PTY、NUMA 表/详情及设备详情场景通过；
  LuaRocks 安装后的 CLI 通过。重建后的许可证、SBOM/校验和一致性和
  发布 ELF 基线检查通过，整体 glibc 下限仍为 2.38。

Windows/macOS 的 NUMA 原生提供方仍待实现，本轮没有新增这些平台的
运行证据。DIMM/SMBIOS、CPU 传感器归属和复杂存储关系继续保留在路线图中。

### 2026-10-09：SMBIOS 内存阵列与设备

- 共享解码器支持 SMBIOS 2.x/3.x 入口及 Type 16/17，覆盖基本/扩展容量、
  数据位宽、Rank、额定/配置 MT/s、电压、阵列纠错声明和设备归属。
  空槽、未知容量和逻辑非易失设备分开处理；原始表和私有身份字段不导出。
- Linux 普通用户读取本机固件表得到 denied；使用已有的非交互 sudo 权限
  进行只读验证，SMBIOS 3.4 报告一个阵列、两条各 16 GiB 的 DDR5，
  配置速率均为 5200 MT/s，解析质量为 fresh，未产生问题记录。
  这些速率来自固件配置，不是实时内存时钟测量。
- 真实 PTY 验证了普通权限的降级提示、提权后的模块详情及 `p` 到父阵列。
  短 ID 列保证相似的长槽位名截断后仍能区分。
- Lua 5.5 的 120 个测试文件与完整源码 PTY 通过；场景清单为 21 个，
  其中 18 个由整套调用。Lua 5.4 的六个相关测试文件通过。夹具还覆盖
  校验和、逐字节截短、重复句柄、越界字符串索引、上限和私有字段过滤。
- onedir/onefile 的 Snapshot/Agent 契约、快速 PTY、NUMA 场景、内存设备
  普通权限与提权详情通过；增强后的父阵列导航场景在源码和两种包上通过。
  LuaRocks 已安装 CLI、许可证、SBOM/校验和及发布 ELF 基线检查通过。
- Windows x86 构建通过。`GetSystemFirmwareTable` 使用动态解析，不出现在
  DLL 硬导入中；Wine 11 下 API 读取和解析路径返回无内存设备记录，降级
  正常。这不是 Windows 真机或 XP 的验证，macOS SMBIOS 提供方仍未实现。

### 2026-10-09：SMBIOS Type 19/20 内存地址映射

- 共享解码器新增阵列映射范围与设备映射范围，按 Type 19 → Type 16、
  Type 20 → Type 19/17 的明确句柄建立关系。旧版 KiB 地址与新版
  字节地址都转换为精确的闭区间；倒置、截短、越界和句柄冲突标记为部分数据。
  同一地址范围允许由交错设备共同引用，不把范围跨度相加推断模块容量。
- 本机 SMBIOS 3.4 只读采集为 fresh：1 个内存阵列、2 个内存设备、
  1 条阵列范围和 2 条设备范围，三条范围均建立预期的句柄关系。
  源码、onedir 和 onefile 的 Snapshot 一致；两种包在普通权限下
  都明确返回 denied，在只读提权后都返回上述 1/2/1/2 结果。
- 夹具覆盖旧/新地址格式、交错重叠、缺失与重复句柄、跨阵列冲突、
  截短表、私有字符串过滤及 Windows `read_smbios` 假后端。
  `make check test` 通过 120 个 Lua 5.5 测试文件和完整 PTY 矩阵。
  Windows 真机、XP 与 macOS 此路径尚未验证。

### 2026-10-09：SMBIOS Type 9 扩展槽

- 开发主机以只读提权从固件表采到 5 个扩展槽，质量 fresh：J6C1 报告
  “在用”并给出 `0000:00:1c.0`，其余 4 个报告“可用”。源码 Snapshot
  只为 J6C1 建立了一条 PCI 引用；其他槽位仍显示，但不认领当前设备。
- 该主机的 Type 9 BDF 指向上游端口。模型因此保留双向固件引用，
  不把对应 PCI 节点放到槽位之下，也不声称插入卡身份。夹具覆盖旧版
  短记录、Peer 组、长度错误、重复句柄、重复 BDF、空槽及 Windows
  `read_smbios` 假后端。Windows 真机与 XP 尚未验证此路径。
- `make check test` 通过 120 个 Lua 5.5 测试文件和完整 PTY 矩阵。
  onedir/onefile 均重新构建：普通权限 Snapshot 报 denied、零槽位；
  只读提权后均报告 5 个槽位、质量 fresh，引用数分别为 1/0/0/0/0。

### 2026-10-09：SMBIOS Type 4/7 处理器固件

- 共享 SMBIOS 读取入口供内存设备、扩展槽和处理器固件采集器使用。
  Type 4 插槽与 Type 7 缓存进入系统设备树、详情和 Snapshot；只有 Type 4
  明确引用且级别匹配的缓存才建立关系。固件记录与 Linux 实测 CPU 拓扑、
  缓存分开，序列号和资产标签不进入快照或 JSON。
- 本机 SMBIOS 3.4 的只读采集质量为 fresh：1 个处理器插槽、8 条缓存，
  插槽引用 3 条，另 5 条保留为独立节点。两种包的普通权限 Snapshot
  均返回 denied；只读提权后 onedir/onefile 均报告相同的 1/8/3/5 结果。
- 夹具覆盖短记录、扩展核心/线程计数、缓存大小编码、未引用及共享缓存、
  缺失和重复句柄、截短表、私有字符串过滤、Linux 权限和 Windows
  `read_smbios` 假后端。`make check test` 通过 120 个 Lua 5.5 测试文件与
  完整 PTY 矩阵。Windows 真机、XP 与 macOS 此路径尚未验证。

### 2026-10-09：CPU 温度归属与 Linux EDAC

- `coretemp` 的包号标签可将包温度连到 CPU 包；核心编号只在该包内唯一时
  连到对应核心。夹具验证了不同包复用核心编号、缺失核心和重复传感器。
- EDAC 控制器及 DIMM/rank 的可纠正、不可纠正错误累计计数进入硬件树、
  详情与 JSON；损坏、缺失或超过精确整数范围的字段保留逐字段问题。
  固件 SMBIOS 插槽和 EDAC 标签没有可靠共用身份键，因此未自动关联。
- 本机 `/sys/devices/system/edac/mc` 没有 `mc*` 控制器；EDAC 数据路径由
  模拟 sysfs 夹具验证，真实硬件计数尚待可用的主机验证。
- `make check test` 通过：120 个 Lua 5.5 测试文件、agent schema 校验、
  完整 PTY 矩阵。相关硬件与原因码测试也在系统 Lua 5.4 下通过。

### 2026-10-09：DDR5 SPD 与温度归属

- Fedora 开发主机发现两条 `spd5118` I²C 设备，地址为 `13-0050` 和
  `13-0052`。内核 EEPROM 属性标称 1024 字节，但两条设备都只读出前
  128 字节；从偏移 128 开始返回 ENXIO。分段原生读取保留了已读页，
  两条记录均报告 DDR5 SO-DIMM、SPD 1.0、最短周期 357 ps、质量 partial。
- 实机 `--snapshot` 的两条 SPD 拓扑节点各关联了同一 I²C 地址的
  `spd5118` 温度传感器；JSON 给出不可读页的问题和偏移，不包含原始
  EEPROM 或序列号。后续页、完整 CRC 与型号路径由夹具验证，本机不能
  证明这些字段在真实模块上可读。未建立 SPD 到 SMBIOS 槽位的映射。
- `make check test` 通过：120 个 Lua 5.5 测试文件、agent schema 校验和
  完整 PTY 矩阵；新增 SPD、分段读取与原因码测试也在系统 Lua 5.4 下通过。

### 2026-10-09：DDR4 SPD 与 JC42 温度关系

- Linux `ee1004` 驱动的 512 字节 EEPROM 加入相同采集器；夹具验证模块
  类型、修订版、最短周期、非堆叠容量/位宽/Rank、型号、基础与第二块
  CRC 与序列号过滤；3DS 不套用单片容量公式，后续页缺席或校验失败
  均报告降级。
- `jc42` 仅在同总线地址对应、基础块 CRC 有效、温度存在位有效时关联
  DDR4 SPD；SPD 1.0 按内核驱动的例外允许由实际发现的传感器补证。
  地址不符或声明不符的夹具保持未归属。开发机只有 DDR5 SPD，DDR4
  读取和温度关系尚缺真实 DDR4 主机验证。
- `make check test` 通过 120 个 Lua 5.5 测试文件和完整 PTY 矩阵；
  onedir/onefile 均重新构建，两个产物的实机 Snapshot 都显示两条 DDR5
  SPD 记录、partial 质量及各一条同地址温度关联。这验证打包后的模块
  可加载，不代替 DDR4 真机证据。

### 2026-10-09：DDR3 SPD 与 JC42 温度关系

- `at24` 的 `spd` 设备提供 256 字节 EEPROM。夹具验证 DDR3 模块类型、
  修订版、时基与精细偏移、标称容量、位宽、Rank、型号、两种 CRC 覆盖
  长度、序列号过滤及第二页不可读的降级。
- `jc42` 仅在 DDR3 类型字节、基础 CRC、温度存在位和同总线地址均成立时
  归属到 SPD；缺一项就保持未归属。开发机没有 DDR3 模块，尚无真机验证。
- `make check test` 通过 120 个 Lua 5.5 测试文件和完整 PTY 矩阵；
  onedir/onefile 重新构建后，两种产物的实机 Snapshot 仍显示两条 DDR5
  SPD 记录、partial 质量和各一条同地址温度关联。DDR3 路径仍只由夹具验证。

### 2026-10-09：DDR2 SPD 解码

- Linux 的 `spd` I²C 设备同时用于 DDR2 与 DDR3。DDR2 夹具覆盖模块类型、
  修订版、校验和、容量、位宽、Rank、最短周期与型号；校验失败不发布
  依赖基础字节的容量和时序。第二页不可读时，前 128 字节的字段保留，
  设备质量降为 partial。
- DDR2 使用字节 63 的简单校验和，独立于 DDR3/4/5 的 CRC；TUI 和 JSON
  各自显示相应状态。序列号与原始 EEPROM 不进入导出，也不根据同地址
  自动认领 `jc42` 温度。本机没有 DDR2 模块，这一路径仍只由夹具验证。
- `make check test` 通过 120 个 Lua 5.5 测试文件和完整 PTY 矩阵；
  十语言原因码检查通过。onedir/onefile 重新构建后均能完成实机 Snapshot，
  各有两条原有 DDR5 SPD 记录。SBOM 的 3 个摘要与 SHA256SUMS 的 14 项一致。
  这些结果验证打包与现有路径，不代替 DDR2 真机证据。

### 2026-10-09：DDR SPD 解码

- 同一个 `spd` 采集器现在区分 DDR 与 DDR2。DDR 的字节 5 直接表示 Rank 数，
  字节 31 按 DDR 的密度表解释；属性位可区分注册、缓冲和非缓冲模块。
  校验和、位宽、最短周期、型号及序列号过滤由独立夹具覆盖。
- 前 64 字节足以验证 DDR/DDR2 的校验和及基础几何字段；只有这部分可读
  时，设备保留基础字段并标记 partial。开发机没有 DDR 模块，尚无真机验证。
- `make check test` 通过 120 个 Lua 5.5 测试文件和完整 PTY 矩阵；DDR
  相关夹具与原因码检查也在系统 Lua 5.4 下通过。
- onedir/onefile 均重新构建并完成实机 Snapshot；两种包各报告两条原有
  DDR5 SPD 记录。SBOM 的 3 个摘要与 SHA256SUMS 的 14 项一致。
  这验证新解析器的打包和现有采集路径，不代替 DDR 真机验证。

### 2026-10-09：SDR SDRAM SPD 与旧 EEPROM 驱动

- [Intel 的 SDR SPD 定义](https://bitsavers.org/components/intel/spd/SPD_Spec_1.2B_199911.pdf)
  用于解码校验和、模块行数、位宽、每行容量、
  时钟周期、属性及型号。两行不同容量按两个密度位求和；混合密度且
  超过两行时容量保持未知。x4 ECC 颗粒不被误当作四位总线扩展。
- [Linux 旧 `eeprom` 驱动](https://www.kernel.org/doc/html/v5.7/misc-devices/eeprom.html)
  会绑定 0x50–0x57 的普通 EEPROM；采集器
  先按头部识别 SDR/DDR/DDR2 SPD，跳过其他内容，并限制额外探测数。
  128 字节 EEPROM 只读一页。夹具覆盖普通 EEPROM、混合密度、
  校验失败、短读、TUI/JSON 与序列号过滤。本机没有 SDR 模块。
- `make check test` 通过 120 个 Lua 5.5 测试文件和完整 PTY 矩阵；
  SDR 相关夹具在系统 Lua 5.4 下也通过。
- onedir/onefile 重新构建后均能完成实机 Snapshot，各有两条原有 DDR5
  SPD 记录。SBOM 的 3 个摘要与 SHA256SUMS 的 14 项一致；这证明打包
  加载正常，不代替 SDR 真机验证。

### 2026-10-10：FPM/EDO SPD 几何信息

- [TI 的 FPM/EDO SPD 技术参考](https://www.ti.com/lit/pdf/smmu001)与 [Tektronix 的字节表示例](https://download.tek.com/document/54W_21473_3_HR_Letter.pdf)都把类型码 `0x01`/`0x02`、行/列地址、模块物理 bank 数、总线位宽和简单校验和放在同一旧格式内；第 31 字节在这里是保留字段，不是 SDR 的密度位图。解析器据此分别识别 FPM 与 EDO，仅在校验和、数据位宽和地址几何有效时推容量。旧 `eeprom` 驱动只在头部匹配时纳入这两种类型。
- 夹具覆盖 36 位奇偶校验 EDO、单 bank 的 64 位 FPM、大小不同的两 bank、128 字节 EEPROM、短读、错误校验和及无效地址几何；TUI 与 Snapshot 显示模块 bank 数和容量，序列号不进入 JSON。Lua 5.5.1 与系统 Lua 5.4.8 的定向测试通过。本机没有 FPM/EDO 模块，解析结果尚无真机对照。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 文件及快速 PTY。重建的 onedir `--snapshot` 仍导出本机两条 DDR5 SPD 记录，包内硬件详情 PTY 也通过；这验证现有路径，没有验证 FPM/EDO 真机读取。`make test-release-notices` 通过，3 项 SBOM 摘要与 14 项清单一致。onefile 在当前沙箱仍报 `extraction failed`：打包器会拒绝不由 root 或调用用户持有的路径祖先，而本沙箱的只读 `/` 由 `nobody` 持有，故本轮也没有 onefile 运行时证据。

### 2026-10-09：进程 CPU 时间的时钟频率

- Linux 采集器将 `/proc/<pid>/stat` 的累计 tick 按本次采样使用的
  `clock_ticks_per_second` 换算为秒；可移植进程采集器也按原生提供方的
  频率换算。进程表时间列、进程和线程详情、`time` 排序/比较、Snapshot
  与 Agent 读取同一换算值。选中线程若有 `schedstat` 纳秒运行时间，
  详情仍优先显示这一更精确的来源。
- 250 tick/s 夹具验证 90 tick 显示为 360 ms，30 tick 的线程显示为
  120 ms，过滤阈值和导出数值一致；可移植假后端验证 375 tick 为 1.5 s。
  本机时钟频率是 100 tick/s，因此非 100 Hz 行为只有夹具证据。
- `make check test` 通过 120 个 Lua 5.5 测试文件和完整 PTY 矩阵。
  onedir/onefile 均重新构建；两种包的本机 Snapshot 前 50 条进程与
  Agent 前 10 条进程均带有 CPU 秒数。

### 2026-10-09：进程与线程已运行时间

- Linux 每次进程采样只读一次 `/proc/uptime`，用进程/线程启动 tick 和
  系统实际 `CLK_TCK` 算出 `elapsed_seconds`；缺少 uptime 时保持未知。
  可移植后端分别换算 Windows FILETIME 与 macOS Unix 微秒启动时间，
  先转为秒，避免直接放大 FILETIME 导致整数溢出。
- 进程详情和线程详情显示已运行时间；进程表可在列编辑器中开启 ETIME，
  `elapsed`/`age` 支持秒数比较，并可按已运行时间排序。默认列未改变。
  夹具覆盖非 100 Hz、连续采样递增、缺失 uptime、两种可移植时间单位、
  过滤、列目录、详情和导出。
- `make check test` 通过 120 个 Lua 5.5 测试文件和完整 PTY 矩阵。
  列编辑器的独立 PTY 场景随后补测了开启 ETIME 后进程表实际出现该列。
  onedir/onefile 的本机 Snapshot 前 50 条进程和 Agent 前 10 条进程均
  带有已运行秒数；两种包的校验和复核通过。Windows/macOS 的这一路径
  尚无本轮实机验证。

### 2026-10-09：内置标签栏显示与顺序

- 布局编辑模式按 `b` 打开标签管理：空格显示/隐藏，左右移动，回车打开。
  至少保留一个可见页面；隐藏页面的布局树留在文件中，重新显示后可继续使用。
  layout schema v5 仅保存可见标签顺序；v1–v4 文件继续显示全部十页。
- 单元测试覆盖最后一页保护、隐藏页不能选中、恢复与重排、旧 schema、
  v5 严格解析和命名工作区布局。CLI 布局导出、导入和迁移保留标签顺序。
  独立 PTY 从隐藏进程页开始，跨重启恢复并移动它；源码、onedir 和
  onefile 均通过该场景。
- `make check test` 通过 120 个 Lua 5.5 测试文件及完整 PTY 矩阵。
  标签管理浮层纳入十语言、20–240 列宽的内容完整性检查。
  Windows/macOS 此交互尚无本轮实机验证。

### 2026-10-09：移除控件的布局持久化

- 复现：在概览页移除一个控件后保存并重新加载，旧读取器会把它当成
  “新版新增的默认控件”重新加回（保存前 10 个，读取后 11 个）。
  v5 现在分别记录单布局的 `removed_widgets` 和命名工作区的
  `removed_workspaces`；仍会补进真正由新版本增加的默认控件。
- 单元测试覆盖文件往返、未来默认控件的迁移、不同工作区各自的移除
  选择，以及布局导出、导入和迁移。完整 Lua 5.5 测试的 120 个文件通过；
  更新断言后完整 PTY 矩阵通过。真实终端场景连续启动两次、每次移除
  一个概览控件，第二次保存仍保留两条移除记录。
- onedir/onefile 均重新构建，两种包上的控件移除跨重启场景和标签栏
  保存场景通过。Windows/macOS 此路径尚未做本轮实机验证。

### 2026-10-09：混搭控件的自定义页面

- 标签管理按 `n` 从聚焦控件新建页面，布局编辑的 `a` 可加入任一内置页
  的控件；`r` 重命名，连续两次 `x` 才永久删除。最多八个页面。
  layout schema v6 保存稳定页面 ID、名称、初始控件和各工作区的布局树；
  v1–v5 继续加载。采集器按自定义页实际可见控件进入前台，GPU 客户端
  和连接属主扫描仍只在对应表格可见时启用。
- 单元测试覆盖跨页控件组合、工作区独立布局、v6 严格解析、CLI 导出/
  导入/迁移以及采样可见性。源码 PTY 新建 CPU 卡片加进程表的页面，
  重启后打开进程详情，再验证重命名与删除。`make check test` 通过
  120 个 Lua 5.5 测试文件和完整 PTY 矩阵。
- onedir/onefile 均重新构建并通过相同的自定义页 PTY 场景。
  Windows/macOS 与 XP 此路径尚未做本轮实机验证。
- 标签管理新增 `c`，可把任一内置页或自定义页的完整布局复制成独立页面。
  单元测试验证源页与副本编辑互不影响、各命名工作区复制自己的源布局。
  源码及两种包的 PTY 从概览页复制 11 个控件，重启后只在副本移除一个：
  源页仍有 11 个，副本为 10 个。`make check test` 的 120 个 Lua 文件和
  完整 PTY 矩阵通过，Windows/macOS 此操作尚无实机验证。

### 2026-10-09：进程优先级的排序与过滤

- 进程表 PRI/NI 列可点击排序，循环排序扩展至十三个键；状态栏对每个
  键都显示本身的翻译，不把 CPU 时间、线程等排序误写成 CPU 百分比。
  `nice<0`、`pri<=10` 等查询支持负数，缺失的值即使取反也不匹配。
- Linux 实机 Snapshot 的进程行提供 PRI/NI 字段；夹具覆盖顺序、缺失值、
  负数、列点击元数据和十语言目录。`make check test` 通过 120 个 Lua
  测试文件与完整 PTY 矩阵。renice 尚未加入动作菜单。
- onedir/onefile 重新构建成功；两种产物的 `--version` 与 `--snapshot`
  均正常返回，本机快照各包含 50 条导出进程和两条 SPD 设备记录。

### 2026-10-10：从进程跳回工作负载

- 进程页和进程详情可按 `g` 跳到所属工作负载；仅用进程报告的 cgroup v2
  完整路径定位 Linux 节点，沿父链展开已折叠的行并把选中行移进视口。
  目标页尚未采样或已有快照未命中时，先切页等待新采集结果。隐藏的工作负载标签页、缺失
  归属或无法匹配的节点给出明确消息。
- Windows 服务宿主按 PID 与创建时间共同组成的节点 ID 匹配；缺少创建
  时间时不凭 PID 猜测。macOS 进程目前没有可用于反向定位的 coalition ID。
  Linux 源码 PTY 从进程页完成跳转并显示对应工作负载详情；Windows 规则
  仅由夹具验证，尚无本轮 Windows/macOS 真机结果。
- `make check test` 通过 120 个 Lua 5.5 测试文件与完整 PTY 矩阵；
  导航和语言目录的定向测试在系统 Lua 5.4 下也通过。
- onedir/onefile 重新构建，各自的双向 cgroup PTY 场景与 Snapshot 均通过；
  SBOM 的 3 个摘要与 SHA256SUMS 的 14 项一致。这是 Linux 实机路径，
  不作为 Windows 服务宿主或 macOS coalition 归属的运行证据。

### 2026-10-10：进程树父子跳转

- 进程页先按 `t` 显示树，再按 `[` 选择当前行的可见父进程，按 `]`
  选择当前排序中的第一个可见子进程。跳转沿进程表已有的稳定身份关系，
  不清除查询或 cgroup 过滤；目标被过滤或截断时明确提示。
- 夹具覆盖祖先链、子节点、过滤、行数上限和树未开启时的拒绝。
  源码 PTY 在进程树中执行两个按键；本机进程树的具体父子形态由
  当时运行的进程决定，不以同一 PID 排序作为交付承诺。
- `make check test` 通过 120 个 Lua 5.5 测试文件与完整 PTY 矩阵；
  相关控制器与交互测试在系统 Lua 5.4 下也通过。
- onedir/onefile 重新构建后，各自通过含进程树父子按键的响应式 PTY
  场景；SBOM 的 3 个摘要与 SHA256SUMS 的 14 项一致。

### 2026-10-10：NUMA 页分配位置计数

- Linux [NUMA numastat 文档](https://docs.kernel.org/admin-guide/numastat.html)
  将六个字段定义为页分配计数，而非实际内存访问。采集器按节点读取
  六项累计值，从连续样本计算 `local_node` 与 `other_node` 页/秒；
  计数器回退时速率标为 reset。旧内核缺失该接口不损害拓扑质量。
- 夹具覆盖原始计数、速率、回退、畸形字段、缺失文件及 TUI/JSON。
  本机 `node0/numastat` 有六项数据，源码 Snapshot 全部导出；NUMA
  详情 PTY 显示页分配语义。只有一个 NUMA 节点，跨节点分配与多节点
  负载的真机行为仍待验证。
- `make check test` 通过 120 个 Lua 5.5 测试文件与完整 PTY 矩阵；
  相关采集、导出、详情和语言目录在系统 Lua 5.4 下通过。
- onedir/onefile 重新构建，各自通过 NUMA 详情 PTY；两种包的实机
  Snapshot 都导出该节点的六项计数。SBOM 的 3 个摘要与 SHA256SUMS 的
  14 项一致。此处没有多节点真机结论。

### 2026-10-10：USB 接口节点与驱动

- [Linux USB sysfs ABI](https://github.com/torvalds/linux/blob/master/Documentation/ABI/testing/sysfs-bus-usb)
  的接口条目另列为设备树节点，保留接口号、当前替代
  设置、端点数、类别/子类/协议、驱动及明确的父 USB 设备。
  网卡或传感器位于已列出接口路径下时归属到该接口；普通设备与接口
  分别计数，扫描与输出都有上限，序列号不读取。
- 夹具覆盖双接口设备、一个接口有驱动而另一个未绑定、网卡/传感器
  归属、TUI/JSON 和旧有未知接口的保守回退。本机源码 Snapshot 读取
  7 个 USB 设备和 10 个接口，10 个接口都有可解析的父节点。
- `make check test` 通过 120 个 Lua 5.5 测试文件与完整 PTY 矩阵；
  接口清单与共享设备树的定向测试在系统 Lua 5.4 下也通过。
- onedir/onefile 重新构建并各自通过设备详情 PTY。两种包的 Snapshot
  均导出 10 个 USB 接口且父节点引用全部可解析；SBOM 的 3 个摘要与
  SHA256SUMS 的 14 项一致。Windows/macOS 没有本轮接口节点实机证据。

### 2026-10-10：进程 NUMA 映射页位置

- Linux [numa_maps 文档](https://github.com/torvalds/linux/blob/master/Documentation/filesystems/proc.rst)
  给出每段映射的节点页数与内核页大小。进程详情将两者相乘后按节点汇总；
  大页按本段大小换算，缺少大页大小时不猜测。该值包含共享映射，
  不当作 PSS、独占物理内存或访问速率。
- 仅打开进程详情时扫描一个进程；读取限 2 MiB、解析限 8192 段和
  128 个节点，结果按 `(pid,starttime)` 缓存 10 秒。可选文件缺失或
  超限不会降低整张进程表质量。映射地址、文件名以及按需汇总不进入
  Snapshot。
- 夹具覆盖普通页与 2 MiB 大页、空映射、溢出、缓存、PID 重用、
  多选择拒绝、详情展示和导出边界。本机 Lua 进程的 `numa_maps` 可解析为
  32 段、1 个节点、2,822,144 映射字节；源码及两种 Linux 包的 PTY
  都在被监控进程详情中显示节点数值和共享页语义。
- `make check test` 通过 120 个 Lua 5.5 测试文件与完整 PTY 矩阵；
  新场景在源码及两种包中独立通过，定向单测在系统 Lua 5.4.8 下通过。
  本机只有一个节点，多节点布局与跨节点迁移没有实机验证。

### 2026-10-10：ASCII 终端的页面身份

- 不支持 Unicode 时，标签栏在原有页面名之前显示页面位置：前九页为
  `1`–`9`，第十页为 `0`，后续自定义页显示完整序号。这与前十页的
  数字键一致；支持本地语言字符的经典控制台仍保留原有页面名。
- 十种目录的二十个完整参考行原先有 21 处不同页面同形，改后为 0。
  11 个同名页面的直接测试确认第十和第十一页不同；简体中文 ASCII
  PTY 的真实标签栏显示 `1 ??`、`2 ??` 与 `0 ??`，且输出不含 Unicode。
  极窄布局仍可能只容纳隐藏页计数，按原有行为处理。
- `make check test` 通过 120 个 Lua 5.5 测试文件与完整 PTY 矩阵；
  标签栏测试在系统 Lua 5.4.8 下通过。onedir 和 onefile 重新构建，
  两者的中文 ASCII PTY 场景均通过。本轮无 Windows 经典控制台真机验证。
- 打包中发现 `test-release-notices` 曾先计算校验和、再由 `sbom` 重建
  onefile，导致两份摘要冲突。依赖顺序已改为先完成双包与 SBOM，再计算
  校验和；发布证据测试固定该顺序。重跑后 3 项 SBOM 摘要与 14 项清单
  条目一致，整份 SHA256SUMS 校验通过。

### 2026-10-10：保留值的真实年龄

- `quality[resource].timestamp_ns` 继续表示最近一次采集尝试。新增可选的
  `value_timestamp_ns` 表示当前安装值的时间；Snapshot 和 Agent JSON
  还给出相对本次捕获的 `value_age_ms`。失败重试不会刷新值时间，
  第一次失败或旧值来源不明时不填这两个字段。传感器详情的过期判断改用
  值时间，因此失败后重试不会将旧传感器读数误判为刚更新。
- 夹具覆盖 99 秒旧值刚重试、再次失败、成功恢复、首次失败，
  以及 Snapshot、Agent、Schema 和传感器详情。四个相关测试在系统
  Lua 5.4.8 下通过；`make check test` 通过 120 个 Lua 5.5 测试文件
  与完整 PTY 矩阵。本机源码的 `--snapshot` 与 `--agent` 各有 19 条
  带值时间的资源记录，年龄全部与捕获时间一致。
- onedir 与 onefile 重建后，各自的 `--snapshot` 和 `--agent` 也分别
  导出 19 条值时间记录且年龄一致；发布校验确认 3 项 SBOM 摘要与
  14 项校验和一致。本轮没有新增 macOS、Windows 的实机验证。

### 2026-10-10：Agent 阈值信号与保留值

- Agent 保留失败采集器的旧指标和 Top 行，供结合 `data_quality` 查看，
  但只用当前可用的来源生成利用率、内存、压力、磁盘繁忙、GPU 和温度
  阈值信号。失败本身仍产生质量信号；一个来源失败不会阻止其他来源的
  当前读数告警。磁盘在完整设备列表中选当前最繁忙者，因此五个旧行
  占满 Top 列表时也不会漏掉第六个当前繁忙设备。
- 夹具先让上述六类读数跨越阈值，再使采集失败并保留 99 秒旧值，
  断言阈值信号消失、旧值和年龄仍可查、失败质量信号存在；再分别验证
  局部恢复、来源映射和设备/传感器行自身的旧值标记。定向测试在
  Lua 5.5 与系统 Lua 5.4.8 下通过；`make check test` 通过 120 个
  Lua 测试文件与完整 PTY 矩阵。
- onedir 与 onefile 重建并通过发布校验：3 项 SBOM 摘要与 14 项清单
  一致。两种包的实机 `--agent` 均符合 Schema；本机当时没有跨阈值
  告警，因此旧值抑制的运行路径由可控夹具验证，不能称作本机故障实测。

### 2026-10-10：PCIe AER 设备与根端口计数

- [Linux AER sysfs ABI](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-bus-pci-devices-aer_stats)
  定义了设备的可纠正、非致命、致命文件，以及根端口的子树汇总。
  每个文件的 `TOTAL_ERR_*` 是消息总数，错误类别数不能相加替代它。
  计数发生在观察并报告错误的一侧，故障端点可能是链路另一侧；
  根端口汇总包含下游消息，不与设备计数合计。
- PCI 清单每 30 秒刷新时仅在第一个 AER 文件存在后读取其余设备
  文件和可用的根端口文件，每个设备文件上限 16 KiB。无接口时不生成
  零计数；部分缺失、权限拒绝或畸形内容只标记该设备 AER 小节。
  Snapshot 和设备详情使用同一 PCI 设备记录，详情仅展开非零错误类别。
- 夹具覆盖类别数之和与总数不同、根端口/端点分开、文件缺失、权限
  拒绝、整数溢出、TUI 与 JSON。定向测试在 Lua 5.5 和系统 Lua 5.4.8
  下通过；`make check test` 通过 120 个 Lua 测试文件与完整 PTY 矩阵。
  本机源码和两种 Linux 包的 Snapshot 均读取 3 个带 AER 的 PCI 设备，
  其中 1 个带根端口汇总；当前计数均为零，尚无真实错误事件验证。
- onedir/onefile 重建后，发布校验确认 3 项 SBOM 摘要与 14 项清单一致。
  本轮没有 macOS、Windows 的 AER 路径实机验证。
- 相邻扫描还保留每类消息的新增数与实际间隔。夹具覆盖总数 `4→7`
  得新增 `3`、根端口 `8→10` 得新增 `2`、计数下降标 `reset`，
  以及同一 PCI 地址换成不同设备标识时标 `gap`；两类计数没有合并。
  本机两次直接扫描相隔约 1.01 秒，3 个设备均可比较且没有新增错误。
  同型号设备在同一地址热插拔不能靠现有可见标识完全区分，
  因此此处只声明同一可见 PCI 身份下的计数变化。
- 验证包内 Snapshot 时纠正了一条旧文档假设：`--snapshot` 和
  `--agent` 共享两次采样及最多 250 ms 的间隔等待，包内两种输出
  的序号均为 2。两种包的 Snapshot 都导出上述 3 个 AER 设备的可比较
  零增量；源码注释、Agent 文档和等待上限的常量名已与实际行为对齐。
  修改后 `make check test-pty-quick`、定向单测及发布校验均通过。
- Agent 对本轮新增的致命和非致命 AER 报告分别给出至多一条严重/警告
  信号，不把端点与根端口的同一事件相加，也不指认故障端点。
  可纠正、首次采样、计数器重置及保留的旧清单不产生这两种信号。
  夹具覆盖端点与根端口同时报错、仅根端口报错、旧值重放和局部故障；
  定向测试在 Lua 5.5 和系统 Lua 5.4.8 下通过，`make check test`
  通过 120 个 Lua 测试文件与完整 PTY 矩阵。两种 Linux 包的 Agent
  均符合 Schema，本机当时没有新增 AER 错误，因此实机仅验证了
  **无事件时不误报**；非零事件由可控夹具验证。发布完整性校验全绿。

### 2026-10-10：Agent 主机健康与可选来源

- 本机普通用户调用旧逻辑时，Agent 给出 `overall=critical`、9 条信号：
  无权限读取的 3 类 SMBIOS 固件信息各被当作严重的数据故障，
  CPU 频率估算、GPU/挂载/电源/SPD 的部分数据又被误称为陈旧。
  当时 CPU、内存和进程监控均正常，没有资源阈值事件。
- 现在 CPU、内存、进程来源无法读取才产生严重的数据质量信号；
  磁盘、网络、挂载和系统来源失败产生警告。失败后保留旧值仍报告
  `data_unavailable`；状态为 `ok` 而质量为 `stale` 时才用
  `data_stale`，核心速率缺口和部分数据分别用 `data_gap`、
  `data_incomplete`。可选硬件来源的缺失、拒绝、估算和局部数据
  继续进入 `data_quality`，不单独提高整机严重度。
- 夹具覆盖上述全部核心和支撑来源、可选固件拒绝、旧指标仍可查、
  核心阈值信号不重放，以及估算/部分数据不被标为陈旧；定向测试在
  Lua 5.5 和系统 Lua 5.4.8 下通过。`make check test` 通过 120 个
  Lua 测试文件和完整 PTY 矩阵。
- onedir 与 onefile 重建并通过发布校验，3 项 SBOM 摘要与 14 项清单
  一致。两种包的实机 Agent 均符合 Schema，给出 `overall=ok`、
  0 条信号，3 项 SMBIOS `denied` 仍列在 `data_quality`。本机没有
  真正的核心采集失败；其严重度路径由可控夹具验证。
- TUI 顶栏过去把每个被拒绝的可选采集器都计入 `!N`，与已修正的
  Agent 总体状态不一致。现在两者读取同一份核心/支撑来源分级；
  夹具验证可选固件缺失不计数、核心失败只计一次，陈旧内存和挂载
  容量不触发当前阈值。源码 PTY 在本机的 160 列顶栏不再显示旧的
  `!3`；onedir 与 onefile 的真实 160 列 PTY 顶栏也都无 `!`，
  两种包的 Agent 均为 `ok/0` 且保留 3 项可选固件 `denied`。
  Insights 采集器行仍保留权限状态和原因。顶栏另有当前内存/本地
  挂载容量提醒，不与 Agent 的信号集合逐项等同。本轮
  `make check test` 通过 120 个 Lua 测试文件和完整 PTY 矩阵；
  重建后的发布校验确认 3 项 SBOM 摘要与 14 项清单一致。

### 2026-10-10：Linux SR-IOV 物理功能与虚拟功能

- [PCI sysfs ABI](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-bus-pci)
  将 `sriov_totalvfs` 定义为 PF 公布的 VF 上限，将 `sriov_numvfs`
  定义为当前启用数；VF 的 `physfn` 链接指向 PF。采集器只读这些
  信息。设备树保留 VF 原有的 PCI 桥接父节点，另以 `pf_id` 和
  `vf_ids` 双向引用连接功能，不从地址或名称猜测归属或 VF 索引。
- 夹具覆盖 PF 容量 4、启用 2、可见 2 个 VF 的完整关系，以及
  已启用数与可见数不符、启用数不可读、同一功能同时呈现 PF/VF
  属性的局部结果。定向测试在 Lua 5.5.1 与系统 Lua 5.4.8 下通过，
  同时核对设备详情、Snapshot JSON 与 PCI 总线父节点保持不变。
- 本机 sysfs 实测一个 PF `0000:00:02.0`，公布上限 7，当前启用 0。
  因此本机只能验证 PF 计数与零 VF 的完整关系；活跃 VF 的双向引用
  目前只有夹具证据。源码与重建的 onedir 包的 Snapshot 都导出该 PF、
  空 `vf_ids` 与 `sriov_membership_complete=true`；onedir 硬件详情 PTY
  场景通过。macOS、Windows 本轮没有对应路径的实机验证。
- `make check`、120 个 Lua 单元测试文件、完整源码 PTY 矩阵通过。
  当前受限执行环境的 tmux 本地 socket 被拒绝，cgroup 成员文件把
  命名空间外的 PID 显示为 `0`，对应两项 PTY 场景明确跳过；其余场景
  运行通过。onedir 与 onefile 重建后，发布校验确认 3 项 SBOM 摘要
  与 14 项文件清单一致。onefile 在本环境无法启动：解包器要求路径
  自 `/` 起由 root 或当前用户持有，而此沙箱将 `/` 标记为 `nobody`；
  改用工作区内的 `TMPDIR` 仍被拒绝。因此本次只有 onefile 的构建
  与完整性证据，没有它在本环境中的运行证据。

### 2026-10-10：Linux 网络接口队列清单

- [Linux Networking Stack Scaling 文档](https://www.kernel.org/doc/html/latest/networking/scaling.html)
  描述了 `/sys/class/net/<iface>/queues/rx-N` 与 `tx-N` 的队列接口。
  wtop 枚举有界目录并分别报告 RX/TX netdev 队列数；这些数不等同于
  物理网卡通道数。结果每 30 秒重扫，接口索引或设备路径变化时立即
  重读。读取失败和目录截断只影响队列小节，不遮蔽网络流量计数器。
- 夹具覆盖首次采集、快采样复用、到期重扫、接口索引变化、截断、
  权限拒绝与目录缺失，并核对设备详情和 Snapshot JSON。定向测试在
  Lua 5.5.1 与系统 Lua 5.4.8 下通过。本次沙箱的实时网络命名空间
  只暴露 `lo`；源码 Snapshot 的 `lo` 队列为 RX 1、TX 1，与 sysfs
  对应目录一致。多队列网卡仍缺少本机实测。
- 当前源码套件包含 132 个 Lua 测试文件；此前矩阵和按日期记载的
  120 文件运行是当时的验证结果，不计作本轮新增测试的覆盖证据。
- `make check test-55 test-pty-quick` 通过，121 个 Lua 文件均通过；
  源码和 onedir 的硬件详情 PTY 场景也通过。onedir Snapshot 导出
  `lo` 的 RX 1、TX 1 和 `queues.status=ok`，网络整体质量仍为 fresh。
  onedir/onefile 重建后，3 项 SBOM 摘要与 14 项清单一致。onefile
  在本轮相同的沙箱根目录所有权限制下仍报 `extraction failed`，
  没有运行时验证。macOS、Windows 尚未验证该队列字段。

### 2026-10-10：Linux IOMMU 组成员关系

- [Linux IOMMU group ABI](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-kernel-iommu_groups)
  描述每组的 `devices` 目录，[VFIO 文档](https://kernel.org/doc/html/latest/driver-api/vfio.html)
  给出 PCI 设备 `iommu_group` 链接与组内非端点设备的实例。采集器只读
  链接及有界成员目录；设备树保留 PCI 总线父节点，另给当前清单中可见
  的同组 PCI 功能建立双向引用。导出的组成员名称不限于 PCI，
  可见 PCI 引用不被当作完整组，也不据此判断 VFIO 可用性。
- 夹具覆盖 group 0、同组 PF/VF、非 PCI 成员、独立组、缺失/拒绝/截断的
  成员目录、链接与目录矛盾，以及错误的数字链接；核对设备详情、
  PCI 清单和拓扑 JSON。定向测试在 Lua 5.5.1 与系统 Lua 5.4.8 下通过。
- 本次沙箱可见的 PCI 设备没有 `iommu_group` 链接，
  `/sys/kernel/iommu_groups` 也没有数字组目录。因此没有本机真实
  成员关系可验证；本项关联目前只有夹具证据。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 测试文件及快速
  PTY；源码和 onedir 的硬件详情 PTY 场景也通过。重建的 onedir
  Snapshot 列出 21 个 PCI 功能、0 个 IOMMU 组、0 条同组引用，与
  本机 sysfs 一致。onedir/onefile 的 3 项 SBOM 摘要与 14 项文件清单
  一致。onefile 在当前沙箱仍因解包路径所有权限制报
  `extraction failed`，没有本轮运行证据。macOS、Windows 本轮未验证。

### 2026-10-10：Linux 逐 TX 队列超时计数

- [Linux netdev 队列 ABI](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-class-net-queues)
  把 `tx_timeout` 定义为该 TX 队列观察到的发送超时事件数。wtop 与
  队列目录一起每 30 秒读取，保留每条队列的累计数和状态；目录完整且
  全部计数可读时才给出接口总数。本轮只报告累计数，不据此产生新事件告警。
- 夹具覆盖 `tx-0` 的非零值、30 秒缓存与刷新、截断目录、畸形计数、
  拒绝读取及跨接口最多 512 次探测的上限；Snapshot JSON 与设备详情
  使用同一计数。定向测试在 Lua 5.5.1 与系统 Lua 5.4.8 下通过。
  本次沙箱的 `lo/tx-0/tx_timeout` 为 0，源码 Snapshot 导出总数 0、
  `timeout_status=ok`；非零超时事件目前只有夹具证据。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 文件及快速 PTY。
  onedir 的实机 Snapshot 也导出 `lo` 的总数 0、单队列 0 和 `ok`，
  打包后的硬件详情 PTY 场景通过。onedir/onefile 重建后，3 项 SBOM
  摘要与 14 项校验清单一致。onefile 在当前沙箱仍因解包路径所有权
  限制报 `extraction failed`，本轮没有运行证据。

### 2026-10-10：TX 超时增量与 RPS/XPS 队列配置

- [Linux netdev 队列 ABI](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-class-net-queues)
  分别定义了 RPS CPU 掩码与 flow 数、XPS CPU/接收队列掩码、TX
  最大速率和 TX 超时计数。wtop 每 30 秒读取一次这些配置；配置读取
  每次最多 512 项，队列数独立于配置读取预算，目录截断仍标 partial。
  `tx_maxrate=0` 明确表示
  限速关闭，缺失属性不被填零。这些 sysfs 掩码不等同于网卡硬件 RSS
  配置。
- 对相同接口及队列集合，相邻 TX 超时扫描给出实际间隔与新增数；
  首次扫描、身份或队列集合变化标记 `gap`，计数下降标记 `reset`。
  夹具覆盖 `4→7` 得新增 `3`、`7→2` 重置、接口索引变化、RPS/XPS
  非零与零掩码、TX 限速开启/关闭、缺失/拒绝/畸形属性及全局配置
  读取预算。定向测试在 Lua 5.5.1 与系统 Lua 5.4.8 下通过。
- 本次沙箱的 `lo` 只有一对队列：RPS CPU 掩码 `0000`、flow 数 0，
  TX 限速 0、XPS 接收队列掩码 `0`；`xps_cpus` 在此环境不可读。
  源码 Snapshot 对配置给出 `ok`，TX 超时总数 0，首次增量为 `gap`。
  非零超时、RPS/XPS 启用和限速中的硬件路径目前只有夹具证据。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 测试文件与快速
  PTY；onedir 硬件详情 PTY 也通过。重建后的 onedir Snapshot 同样导出
  上述 `lo` 配置及超时状态，3 项 SBOM 摘要与 14 项校验清单一致。
  onefile 在本沙箱仍因解包路径所有权限制报 `extraction failed`，
  没有本轮运行证据；macOS、Windows 本轮未验证这些字段。

### 2026-10-10：PCI MSI 向量与 CPU 中断计数

- [Linux PCI sysfs ABI](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-bus-pci)
  定义 `msi_irqs/<N>` 的数字 IRQ 和 MSI/MSI-X 模式；
  [/proc/interrupts](https://man7.org/linux/man-pages/man5/proc_interrupts.5.html)
  给出每 CPU 的累计次数。采集器仅按 sysfs 数字 IRQ 关联，
  不从驱动标签猜测设备。最多读取每设备 256、每次扫描合计 4096 个
  向量；每向量仅保留累计计数最高的四个 CPU，不将其称作当前亲和性。
- 夹具覆盖两台 PCI 设备各自的向量、相邻扫描增量、计数下降重置、
  设备身份变化、缺失/重复 IRQ 行、共享数字 IRQ 的矛盾归属、畸形
  CPU 标头与整数溢出，以及向量上限；设备详情与 Snapshot JSON
  读同一记录。定向测试在 Lua 5.5.1 与系统 Lua 5.4.8 下通过。
- 本机 21 个可见 PCI 功能中，10 个有 MSI/MSI-X 向量目录。Wi-Fi
  功能 `0000:00:14.3` 的 16 个向量可按数字 IRQ 对上计数，并在双采样
  Snapshot 中产生相邻扫描增量。另两台功能只有部分已分配向量出现在
  `/proc/interrupts`，因此不发布设备总数；未出现的向量不是零中断。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 文件与快速 PTY。
  重建的 onedir Snapshot 同样列出 10 台有 MSI 向量的设备，其中 8 台
  计数完整、2 台 partial；Wi-Fi 的 16 个向量给出实际扫描间隔与新增数。
  onedir 硬件详情 PTY 通过，3 项 SBOM 摘要与 14 项校验清单一致。
  onefile 在当前沙箱仍因解包路径所有权限制报 `extraction failed`，
  没有本轮运行证据；macOS、Windows 本轮未验证这些字段。

### 2026-10-10：PCI IRQ 的允许与生效 CPU 列表

- [SMP IRQ affinity](https://www.kernel.org/doc/html/latest/core-api/irq/irq-affinity.html)
  将 `smp_affinity_list` 定义为允许的 CPU 列表；
  [托管 IRQ 文档](https://www.kernel.org/doc/html/next/core-api/irq/managed_irq.html)
  展示了 `effective_affinity_list` 与允许列表不同的情况。wtop 只读这两项，
  保留内核原有 CPU 列表表示；每次扫描最多读取 1024 个亲和性属性。
  托管 IRQ 关闭时生效列表可能为 `0`，因此单凭这个值不能断言 CPU0
  正在接收中断。
- 夹具让 IRQ100 的累计次数最多落在 CPU1，同时生效列表为 `0`、
  允许列表为 `0-1`；详情与 JSON 分别展示三者。夹具还覆盖生效列表
  缺失、畸形大范围及全局读取上限，计数质量不受亲和性缺失影响。
  定向测试在 Lua 5.5.1 与系统 Lua 5.4.8 下通过。
- 本机 10 台有 MSI 向量的 PCI 功能中，8 台亲和性列表完整、2 台
  partial。Wi-Fi 功能的 IRQ159 生效与允许列表均为 CPU4，历史累计
  最多的是 CPU11；源码 Snapshot 因此能直接展示两者区别。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 文件及快速 PTY。
  重建后的 onedir Snapshot 同样导出 IRQ159 的 `4`、`4` 与累计最多的
  CPU11；onedir 硬件详情 PTY 通过，3 项 SBOM 摘要与 14 项文件清单
  一致。onefile 在当前沙箱仍因解包路径所有权限制报
  `extraction failed`，没有本轮运行证据；macOS、Windows 未验证。

### 2026-10-10：Linux hwmon 本次会话统计

- [Linux hwmon 接口](https://docs.kernel.org/hwmon/sysfs-interface.html)
  区分当前 `*_input`、驱动历史 `*_lowest`/`*_highest`、驱动平均值
  和累计 `energy_input`。wtop 只对直接读到的温度、风扇、功率、
  电压与电流 `input` 计算本次进程会话的最小/最大/采样算术平均，
  记录样本数与首末单调时间；不把驱动历史值或估算值混入。
- 夹具中温度 `42→45→输入不可读→39` 得最小 39、平均 42、最大 45，
  共 3 个直接样本。输入不可读时保留统计但不重复计数；阈值失败而
  `input` 新鲜时仍计数。夹具还覆盖标签变化、设备身份变化、
  弱身份、时钟未推进、估算替代输入与累计能量，并核对传感器详情和
  Snapshot JSON。定向测试在 Lua 5.5.1 与系统 Lua 5.4.8 下通过。
- 本次沙箱的源码双采样 Snapshot 有 22 个带会话统计的直接传感器
  通道，每个已有 2 个样本；能量通道没有此统计。这里的平均是
  两次样本的平均，不是时间加权平均，也不是硬件历史平均。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 文件与快速 PTY。
  重建的 onedir Snapshot 同样有 22 个直接通道、各 2 个样本，
  包内真实 PTY 的传感器浮层显示会话范围和样本数。3 项 SBOM 摘要
  与 14 项文件清单一致。onefile 在当前沙箱仍因解包路径所有权限制
  报 `extraction failed`，没有本轮运行证据；macOS、Windows 未验证
  此 Linux hwmon 会话统计。

### 2026-10-10：跨平台传感器会话模型

- 会话统计移至不探测硬件的共享模型。Linux hwmon 仍只计直接
  `readings.input`；macOS/Windows 原生采集器、设备和通道需有 fresh 质量与实际
  `input` 才计数。设备 ID、来源、通道 ID、类型、单位和标签必须连续；
  当前或前次有重复 ID、同类型标签重复或标签缺失时不继承历史。
  累计能量与估算替代值仍排除。
- 伪原生夹具覆盖 Windows PDH 热区 `40→44` 得平均 42、macOS HID
  温度 `32→35` 得平均 33.5、SMC 功率 `10→20` 得平均 15；还覆盖
  估算/陈旧值、标签或来源变更、重复通道/设备 ID 及重复标签。Lua 5.5.1 与系统 Lua 5.4.8 的
  定向测试通过，Portable Snapshot JSON 包含相同会话字段。
- 本轮没有 macOS 或 Windows 实机运行，因此这两条平台路径目前
  只有可控原生返回夹具证据；Linux hwmon 的实机与包内结果见上节。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 文件及快速 PTY。
  新的共享模型进入重建的 onedir；其 Snapshot 仍有 22 个直接通道、
  各 2 个样本，包内真实 PTY 显示会话范围与样本数。3 项 SBOM 摘要
  与 14 项文件清单一致。onefile 在当前沙箱仍因解包路径所有权限制
  报 `extraction failed`，没有本轮运行证据。

### 2026-10-10：Linux 进程与线程的允许 CPU/内存节点

- `/proc/<pid>/status` 的 `Cpus_allowed_list` 与 `Mems_allowed_list` 进入进程详情和 Snapshot JSON；选中线程从自己的 `/proc/<pid>/task/<tid>/status` 读取，详情注明首线程与选中线程的区别。缓存的进程列表读数保留首次观察时间，打开详情会刷新。
- Lua 5.5.1 和系统 Lua 5.4.8 的解析、采集、导出、线程详情及 PCI IRQ 亲和性定向测试通过。夹具含两个允许 CPU 集合不同的线程、缓存刷新、畸形列表和缺失字段；畸形的可选列表不丢弃其他进程状态字段。
- 当前 Linux 沙箱中，临时把受控 `sleep` 子进程限制到 CPU 0 后，内核状态与源码 `--snapshot` 均报告列表 `0`、数量 1。此验证只覆盖 Linux，不作为 macOS 或 Windows 的实机证据。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 文件及快速 PTY。重建的 onedir 包对同样的受控子进程也报告 CPU `0`、数量 1，包内线程下钻 PTY 场景通过。`make test-release-notices` 通过，3 项 SBOM 摘要与 14 项文件清单一致。onefile 在当前沙箱仍于解包阶段报 `extraction failed`，本轮没有它的启动证据。

### 2026-10-10：所选 Linux 进程的文件描述符用量

- 所选进程详情按 4096 项预算读取首线程的 `/proc/<pid>/fd`，并从 `/proc/<pid>/limits` 读取打开文件上限；普通进程扫描与 Snapshot JSON 不附带这项只在详情模式采集的读数。目录截断时显示下界，权限拒绝不被当作零。
- Lua 5.5.1 与系统 Lua 5.4.8 的定向测试覆盖软/硬/无限上限、畸形或缺少的上限行、截断和拒绝状态、详情行以及导出边界。在当前 Linux 沙箱，用一个受控子进程打开 12 个额外文件后，wtop 和 `/proc/<pid>/fd` 均报告 15 个描述符，软/硬上限分别为 256/512。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 文件及快速 PTY；`make test-54` 的 121 个文件也通过，依其纯 Lua 合约跳过原生产物检查。重建 onedir 后，真实 PTY 的进程详情画出 FD 数值与软/硬上限；`make test-release-notices` 通过，3 项 SBOM 摘要与 14 项清单一致。onefile 在本沙箱仍于解包阶段报 `extraction failed`，没有本轮运行证据。

### 2026-10-10：所选 Linux 线程的独立 FD 表

- 线程详情从 `/proc/<pid>/task/<tid>/fd` 读取当前选中 TID 的描述符数量，并与首线程数量并列显示；选中首线程时复用已有读数。两者数量相同不被解释为共用 FD 表。拒绝或截断的线程目录保留各自状态。
- 夹具覆盖只读选中 TID、首线程复用、线程与首线程数量不同、截断下界和权限拒绝。Lua 5.5.1 与系统 Lua 5.4.8 的定向测试通过。
- 本机受控 Python 子进程中，一个线程调用 `unshare(CLONE_FILES)` 后额外打开 5 个文件。内核目录显示首线程 4 个、该线程 9 个；wtop 采集器对两个目录分别报告 4 和 9，状态均为 `ok`。这是一条 Linux 实测，未覆盖 macOS 或 Windows。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 文件及快速 PTY；系统 Lua 5.4.8 的进程/线程与语言目录定向测试通过。源码和重建 onedir 的独立线程下钻 PTY 场景均通过，onedir 的真实线程详情绘出线程 FD 数值。`make test-release-notices` 通过，3 项 SBOM 摘要与 14 项清单一致。onefile 在本沙箱仍于解包阶段报 `extraction failed`，没有本轮运行证据。

### 2026-10-10：进程页按可见需求读取详情与排队计数

- 进程页的光标不再触发 `io`、`smaps_rollup`、FD 目录等详情读取；只有进程/线程浮层打开时才请求这些文件。Queued 列只有画在未被浮层遮住的表格上时才为可见行读 `schedstat`，被用户隐藏或响应式布局省略时不读。GPU 页打开宿主进程详情会让进程采集器以前台频率刷新。
- 用带文件读取计数的源码 PTY 会话，在进程页筛选并停留约两秒，`io`、`smaps_rollup`、FD 目录和 `schedstat` 四类读取均为 0；打开详情并停留约两秒后四类分别为 2、2、2、2。Queued 列、线程下钻、NUMA 详情和进程列编辑的独立 PTY 场景通过。
- 同一计数器驱动线程选择器并停留约两秒时，逐线程 `status`、`io` 和 FD 目录的读取均为 0；进程级 `io`、`smaps_rollup`、FD 目录和 `schedstat` 在先前详情页各读取 2 次，选择器停留期间没有继续增加。按 `Enter` 打开线程详情后，逐线程 `status` 和 `io` 各读取 2 次。该场景选中的是首线程，FD 目录复用进程级读数，因此逐线程 FD 目录仍为 0。夹具还确认选择器继续刷新任务 `stat` 行。
- Lua 5.5.1 与系统 Lua 5.4.8 的定向测试覆盖默认列表、隐藏/显示的 Queued 列、滚动视口、从 GPU 打开的详情、线程选择器、关闭或被其他浮层替换的详情。
- Queued 列的独立源码与 onedir PTY 场景通过。场景先关闭列编辑器，再等待两次读数；它检查具体进程行上的 `/s` 速率。浮层仍遮住表格时不会为 Queued 列读取视口，这也解释了旧场景在编辑器里等待却看不到速率。

### 2026-10-10：按需全进程 I/O 排序与过滤

- Linux 进程页默认不读 `/proc/<pid>/io`。切换到 I/O 排序或输入有效的 `ioread`/`iowrite` 数值比较后，按当前进程采集上限批量读取，最多 8192 个 PID；同一身份的读数五秒内复用，新 PID 立即读取。表格在首批读数前提示正在读取，权限或上限导致部分覆盖时显示已覆盖数，不把未知值填零。
- 夹具验证全部三行参与排序和过滤、五秒缓存、PID 复用后的重读、缺失 I/O 的部分覆盖以及状态行；Lua 5.5.1 和系统 Lua 5.4.8 的定向测试通过。真实源码 PTY 中，默认进程页触发 0 次原生 I/O 批量读取，输入 `ioread>=0` 后触发 1 次，包含 4 个 PID。直接原生采样验证首次批量读取、下一秒复用以及五秒后重读。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 文件及快速 PTY。重建的 onedir 在真实 PTY 中输入 `pid:<当前进程> ioread>=0` 后得到非空进程表；`make test-release-notices` 通过，3 项 SBOM 摘要与 14 项清单一致。onefile 在当前沙箱仍于解包阶段报 `extraction failed`，没有本轮运行证据。
- 完整源码 PTY 矩阵也通过了页面、布局、线程详情、进程列和 Queued 场景。当前沙箱的 tmux socket 被拒绝、PID 命名空间隐藏 cgroup 成员，矩阵明确跳过这两项；其余场景运行通过。

### 2026-10-10：Linux 进程存储层 I/O 速率

- 进程 I/O 的 `read_bytes` 与 `write_bytes` 只对同一 `(pid,starttime)` 的相邻有效读数取差并除以实际单调时间差。首样本、时钟未前进、计数回退或字段缺失不填零；两次批量刷新之间保留的速率标为 held。详情显示读写速率和状态，进程列 `IO R/s`、`IO W/s` 默认隐藏；速率排序与 `ioreadps`/`iowriteps` 数值比较会请求两秒一次的批量读取，累计量排序保持五秒间隔。
- 夹具覆盖首样本、六秒实际间隔、保持、PID 复用、单侧计数回退、两秒速率预算、速率列与排序/过滤；Lua 5.5.1 和系统 Lua 5.4.8 定向测试通过。真实 Linux 受控子进程向项目构建目录写入并同步 1 MiB 后，wtop 在约 303 ms 的采样区间算出约 3.5 MB/s 的写入速率。源码 PTY 中，可选 `IO R/s` 列出现了进程行的 `0 B/s` 读数，`ioreadps>=0` 过滤在第二次读数后得到非空进程表。
- [proc_pid_io(5)](https://man7.org/linux/man-pages/man5/proc_pid_io.5.html) 提醒 32 位内核上的 64 位计数器读取可能不是原子的；本轮实机证据只来自当前 Linux x86_64 沙箱，尚不能证明旧 32 位 Linux 主机不会出现瞬时撕裂读数。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 文件及快速 PTY；重建 onedir 的真实 PTY 同时显示 `IO R/s` 列和 `ioreadps>=0` 过滤后的速率行，包内进程列、Queued 与线程下钻的独立场景通过。`make test-release-notices` 通过，3 项 SBOM 摘要与 14 项清单一致。onefile 在当前沙箱仍于解包阶段报 `extraction failed`，没有本轮运行证据。

### 2026-10-10：Linux 进程 I/O 完整快照

- `--snapshot` 为有界进程集合读取两次 `/proc/<pid>/io`，第二次不等待交互式两秒刷新期限；导出的 `processes.top[].io` 保留累计量，`io_rate` 保留实际间隔、读写速率和质量，`processes.io_scan` 保留整个扫描的覆盖数。`--agent` 保持原有紧凑投影，不请求这项全进程扫描。macOS 和 Windows 开发构建未在本轮运行。
- Lua 5.5.1 和系统 Lua 5.4.8 的定向夹具覆盖短间隔强制重读、实际速率、导出白名单和 Agent 不携带快照独有的 I/O 对象。Linux 源码快照中，受控子进程向项目构建目录写入约 4 MiB；其 Top 行报告 `fresh`、约 1.09 秒的间隔与约 3.29 MB/s 的存储层写入速率，第二次扫描覆盖 5/5 个进程。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 文件及快速 PTY；重建的 onedir `--snapshot` 导出 3/3 个 `fresh` 进程速率，`--agent` 仍通过既有 JSON Schema 且不包含快照独有的 I/O 对象。`make test-release-notices` 通过，3 项 SBOM 摘要与 14 项清单一致。onefile 在当前沙箱仍于解包阶段报 `extraction failed`，本轮没有其运行时证据。

### 2026-10-10：Linux 线程选择器的光标与身份

- 真实 PTY 中，用三个线程的受控 Python 进程复现了缺陷：按 `↓` 后高亮仍停在首线程。选择器刷新会按旧 TID 找回原位置，覆盖刚刚移动的行号。现在按键和滚轮先更新所选线程身份，再刷新画面；打开详情后保留 TID 与 `stat` 启动时间，线程退出或 TID 复用不会把新线程的详情当作旧线程显示。
- 修复后的独立 PTY 场景确认高亮移到第二个工作线程，`Enter` 打开该线程的实际 TID；既有线程下钻场景仍通过。Lua 5.5.1 与系统 Lua 5.4.8 的夹具验证两种复用时序：选中之后、采样之前发生的复用不读取新线程详情；附加文件读取期间发生的复用由最后一次 `stat` 校验发现，混合读数被丢弃。累计 I/O 排序和过滤还修正了一个语义错误：只有每秒速率而无累计计数的行保持未知，不参与累计量比较。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 文件、Agent schema 和快速 PTY；新场景在源码与重建的 onedir 中均通过。`make test-release-notices` 通过，3 项 SBOM 摘要与 14 项清单一致。onefile 在当前沙箱仍于解包阶段报 `extraction failed`，未取得运行时证据。

### 2026-10-10：可折叠的进程树

- 进程页的 `c` 现在折叠或展开所选进程的子树；状态绑定 `(PID, starttime)`，进程消失或 PID 复用时不会继承旧折叠。搜索和 cgroup 过滤会临时打开命中项的祖先，清除条件后恢复折叠；`▸`/`▾` 区分两种状态，`折叠隐藏 N 行` 与真正达到视图上限的截断分开。`]` 从折叠节点进入子进程时先展开节点。顺带更正了十种语言中父节点、子节点和“先开启进程树”三条原因文案错位的问题。
- 夹具覆盖折叠与展开、搜索/过滤命中、选择重新锚定、PID 复用、视图上限以及 `]` 导航。受控父子进程的真实 PTY 在源码与重建的 onedir 中均验证折叠后子行消失、父行显示 `▸`，再按 `]` 恢复子行；完整 `make test-pty` 通过，场景账本现列 25 个可独立运行的场景。当前开发机上，合成 8192 进程树的单次模型重建约 25 ms、折叠约 26 ms；这只是该主机的局部测量，不构成最低硬件性能门禁。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 文件，Lua 5.4 定向夹具通过。`make test-release-notices` 的 3 项 SBOM 摘要与 14 项清单一致；Windows x86 开发包与 PE 静态门禁通过，旧 Windows 控制台仍需实机验证。

### 2026-10-10：Linux 线程工作负载跳转

- [Linux 内核的 cgroup v2 文档](https://docs.kernel.org/admin-guide/cgroup-v2.html)说明线程模式可以让同一进程的线程位于不同子组。进程详情的 `g` 仍使用进程 cgroup；线程详情现在使用该 TID 独立读取的 cgroup。只在进程身份、TID 和线程启动时间都与当前样本一致时定位，读数未到或身份变化时不退回进程路径。
- 夹具让进程位于 `/process`、线程位于 `/thread`，并覆盖尚无线程读数、进程身份变化、TID 复用、线程组不符与 cgroup 读取失败。源码和重建的 onedir 都在真实 PTY 中从线程详情按 `g` 到达 Workloads 页，状态行点名 TID；包内进程详情按 `g` 仍点名 PID。完整 `make test-pty` 通过，tmux socket 与 cgroup 成员交叉链接场景因当前沙箱隔离按设计跳过。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 文件、Agent schema 与快速 PTY；Lua 5.4 的线程导航夹具通过。`make test-release-notices` 的 3 项 SBOM 摘要与 14 项清单一致，包内 manifest 含进程采集、导航模型和 TUI。Windows x86 开发包与 PE 静态门禁通过；这不是 macOS 或 Windows 的线程工作负载运行时证据。

### 2026-10-10：线程化 cgroup 与命名空间成员

- [Linux 内核 cgroup v2 文档](https://docs.kernel.org/admin-guide/cgroup-v2.html)规定，线程化子组读 `cgroup.procs` 会返回不支持，`cgroup.threads` 列出 TID。采集器只在前者返回不支持时核对 `cgroup.type`，确认线程化后读 TID；进程数保留未知。按 `Enter` 最多复核 64 个 TID 的 `/proc/<tid>` 启动时间、线程组和当前 cgroup，再筛出所属进程，超限时报告检查范围。夹具覆盖两个 TID 对应一个进程、重复 TID、非线程化错误、线程列表拒绝、TID 复用和迁移。
- 当前沙箱没有可供完整 TUI 操作的线程化子组。真实 `/proc` 验证了单个可见 TID 到其线程组的复核路径；真实 cgroup 根列表则出现了大量 `0` 成员条目。采集器现在保留可见 ID 与 `0` 条目数，总进程数保持未知：一次源码扫描有 204 个组、159 个未知进程数、2 个可见 PID，根组有 263 个 `0` 条目，因它们造成的解析失败从部分节点数中消失。重建的 onedir 快照在另一次扫描中有 205 个组、160 个未知进程数和 4 个可见 PID；这些动态计数不是同一时刻的对照。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 文件，Lua 5.4 定向夹具与完整 `make test-pty` 通过；真实 Workloads 页与线程下钻的包内 PTY 场景也通过。`make test-release-notices` 的 3 项 SBOM 摘要与 14 项清单一致，onedir manifest 含 cgroup 采集器和按需线程解析器。Windows x86 开发包静态门禁通过，尚无线程化子组的真机运行证据。

### 2026-10-10：Linux 每 CPU 接收栈积压

- [Linux 内核的 `softnet_seq_show`](https://github.com/torvalds/linux/blob/master/net/core/net-procfs.c)分别公布已处理包、丢弃包、处理预算耗尽次数，以及较新格式中的积压长度和 CPU 编号。wtop 把它们放在独立的 `network.softnet` 小节：接口 `rx_drops` 仍只说明那张网卡的计数。只有明确 CPU 编号且前后 CPU 集合相同，才按实际单调时间差计算速率；首次读取、计数回退或 CPU 热插拔时速率保持缺失。
- 夹具覆盖两 CPU 的积压与速率、CPU 集合变化、计数回退、旧格式缺少 CPU 编号、缺失和损坏的文件，以及 Snapshot 有界逐 CPU 列表与 Agent 摘要。源码 `--snapshot` 在当前 Linux 沙箱读到 16 个 CPU 的 `fresh` 数据，积压与丢弃均为 0；180×45 PTY 的 Network 页实际画出了独立的接收积压面板。这是该宿主机的正常状态，不证明有丢包时的真机行为。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 文件、Agent schema 和快速 PTY，完整 `make test-pty` 也通过。重建的 onedir 的 Snapshot 与 Agent 均导出 16 个 CPU 的 `fresh` softnet 数据，Network 页同时画出接收积压、接口和连接面板。`make test-release-notices` 通过，3 项 SBOM 摘要与 14 项清单一致。onefile 在当前沙箱仍于解包阶段报 `extraction failed`，没有本轮运行时证据。

### 2026-10-10：Linux 接口链路状态转换

- [内核的 netdev sysfs 实现](https://github.com/torvalds/linux/blob/master/net/core/net-sysfs.c)分别公布 `carrier_changes`、`carrier_up_count` 和 `carrier_down_count`。wtop 对有界接口集合读取它们，在相同 ifindex、名称、iflink 与设备路径的相邻样本间报告新增转换；计数回退、身份变化和缺失文件不会变成零次。Network 表列出新增数，接口详情区分累计及本次新增的上升/下降，Snapshot 和 Agent 保留机器值。
- 夹具验证链路已恢复但两次采样间发生三次转换、其中两次为下降；还覆盖计数回退、ifindex 变化、三项独立读取不一致时隐藏相矛盾的上/下行增量、旧内核只提供总数、缺失文件及 768 次 sysfs 读取预算。当前沙箱的 `/proc/net/dev` 只列出 loopback，源码 Snapshot 对它报告 `fresh` 和新增 0 次。将宿主 Wi‑Fi 接口名放入隔离的 netdev 夹具、其余 sysfs 读取仍走真实文件时，采集器读到累计 122 次、上升和下降各 61 次，相邻样本新增 0 次；该接口不在沙箱网络命名空间的真实 `/proc/net/dev` 中，所以这不是一次完整 wtop 会话对 Wi‑Fi 的观测。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 文件和快速 PTY，完整 `make test-pty` 也通过。重建的 onedir Snapshot 对 loopback 导出 `ok/fresh` 与新增 0 次，180 列包内 Network 页同时画出链路变化、softnet、接口和连接。`make test-release-notices` 通过，3 项 SBOM 摘要与 14 项清单一致。onefile 在当前沙箱仍于解包阶段报 `extraction failed`，没有本轮运行时证据。

### 2026-10-10：Linux CPU 热节流计数

- [Linux 内核文档](https://docs.kernel.org/admin-guide/thermal/intel_thermal_throttle.html)说明，同一封装的计数会由该封装下每个 CPU 报告。采集器保留逐 CPU 原值及相邻样本增量；首次读取或计数回退不推断新增事件，Agent 只取各 CPU 报告的最大新增数，不求和。
- 夹具覆盖共享封装的重复通知、CPU 数量上限、首次读数、复位、坏值、无数据源、Compute 表、Snapshot 与 Agent。当前 Linux 开发机的 sysfs 暴露 16 个 CPU，真实连续采样为 `ok/fresh`；CPU0 的核心累计 12653 次、封装累计 1807995 次，CPU1 封装累计 1807996 次，两次紧邻采样新增均为 0，累计时长仍为 0 ms。这些累计次数不能说明采样时仍在热节流。
- 重建的 onedir `--snapshot` 导出 16 个 CPU 的 `fresh` 计数；一次带实际采样间隔的运行报告 CPU0 核心新增 3 次、封装新增 21 次。独立的 `--agent` 运行给出逐 CPU 最大新增核心 16 次、封装 21 次，180×45 包内 PTY 能看到面板及 CPU 行。两条 CLI 结果来自不同时间窗口，不宜相互比较为同一时刻读数。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 文件、Agent schema 与新增的 Compute PTY 检查；增强后的热节流夹具还分别通过 Lua 5.5 和 5.4。`make test-release-notices` 通过，3 项 SBOM 摘要与 14 项清单一致，onedir manifest 包含新模块。Windows x86 开发包交叉构建和 PE 静态门禁通过；没有 Windows 运行时热节流读数。
- CPU 设备树现在仅凭明确的逻辑 CPU ID 建立引用：线程保存自己的报告，核心和封装列出关联 CPU，不聚合重复的封装数。双封装/SMT 夹具验证封装、核心、线程详情与 `inventory.topology` 的相同引用；重复的报告 ID 拒绝归属，来源读取失败时不展示保留值。当前 Linux 主机的 CPU 信息和热节流来源均为 `ok`，图中的一个封装关联 16/16 个逻辑 CPU，中文设备详情实际列出了 16 行逐 CPU 计数。
- 本次设备树关联改动通过 `make check test-55 test-pty-quick` 的 121 个 Lua 文件、Lua 5.4 定向夹具和完整 `make test-pty`；tmux socket 与 cgroup 成员交叉链接场景因当前沙箱隔离而按设计跳过。重建的 onedir `--snapshot` 把 16 个线程全部关联到一个封装，包内硬件详情 PTY 场景通过；`make test-release-notices` 的 3 项 SBOM 摘要与 14 项清单一致。Windows x86 开发包及其 PE 静态门禁仍通过，未取得 Windows 热节流运行时数据。

### 2026-10-10：Linux CPU 空闲态计数

- [Linux CPUIdle 文档](https://docs.kernel.org/admin-guide/pm/cpuidle.html)说明，逐 CPU 的 `usage` 是状态使用计数，`time` 是内核以微秒记录的状态时间，不能据此断言硬件实际驻留。wtop 保留原值，并在相邻样本间计算增量；首次读取、计数器回退或缺失字段时不填零。Compute 表显示使用次数及报告时间的增量，Snapshot 保留驱动、governor、逐 CPU 状态参数和质量。
- 夹具覆盖多 CPU/状态、首次采样、正常增量、复位、坏值、资源缺席、权限错误和采集上限。当前 Linux 开发机的 `intel_idle`/`menu` 驱动组合暴露 16 个逻辑 CPU，每个 CPU 有四个状态。真实连续采样均为 `ok/fresh`；CPU0 的 C3_ACPI 在约 1.1 秒间新增 738 次使用及 546708 微秒内核报告时间。这个读数仅证明本机 sysfs 的采集路径，不代表硬件 C3 驻留时间。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 测试文件和 5 项快速 PTY；Lua 5.4 定向夹具通过。源码与最终重建目录包的 Snapshot 都读取到 16 个 CPU、64 个状态及本轮增量，质量为 `ok/fresh`；目录包的 5 项快速 PTY 也通过。单文件包重建成功；`make test-release-notices` 的 3 项 SBOM 摘要与 14 项清单一致。当前沙箱不能运行单文件包的解包阶段，因此没有本轮单文件包运行证据。
- System 设备图现在按逻辑 CPU ID 关联空闲态，核心和封装仅列出有报告的 CPU，不合并报告时间。夹具验证了设备详情、Snapshot 拓扑引用、重复 CPU ID 及失败/过期采样排除；源码与重建目录包的 Snapshot 都在当前主机连上 16 条逻辑 CPU 引用，封装节点覆盖这 16 个 CPU。真实 CPU0 设备详情显示四个状态的增量与延迟，目录包的 5 项快速 PTY 通过。Compute 与 System 设备树可见时才把该采集器切到 5 秒前台间隔。
- [CPUIdle 文档](https://docs.kernel.org/admin-guide/pm/cpuidle.html)还定义 `rejected`、`above` 与 `below`：被拒绝的进入请求、实际时长短于目标、以及更深状态本可匹配。采集器独立保留三个累计数、相邻样本增量和各自质量，Compute 表、逻辑 CPU 详情及 Snapshot 使用同一数据；缺文件不会把整个 CPUIdle 读数降级。夹具覆盖首次读取、正常增量、复位、坏值和旧内核缺文件。当前主机 16 个 CPU 的四个状态均提供这些文件；一次约一秒的连续采样中，CPU0 的 C2_ACPI `above` 新增 499，`rejected` 为 0。计数只描述状态选择，不直接判定硬件故障。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 测试文件与 5 项快速 PTY，Lua 5.4 定向夹具通过。重建目录包的 Snapshot 对 16 个 CPU、64 个状态输出三项独立质量与增量，全部 `ok/fresh`；包内 5 项快速 PTY 通过。单文件包构建与 `make test-release-notices` 的 3 项 SBOM 摘要、14 项清单核对通过；Windows x86 开发包重新构建并通过 5 个 PE32 文件和 510 项导入的静态门禁。单文件包与 XP 的运行时仍需在可运行环境验证。

### 2026-10-10：Linux CPUFreq 硬件反馈平均值

- [Linux CPUFreq 文档](https://docs.kernel.org/admin-guide/pm/cpufreq.html)把 `cpuinfo_cur_freq` 定义为从硬件取得的当前值、`cpuinfo_avg_freq` 定义为基于硬件反馈的短时平均，且提醒 `scaling_cur_freq` 在多数驱动上可能只代表最近请求的 P-state。采集器按这个顺序选择读数，保留各原值与来源；硬件值缺席时才把调频读数标为 estimated。空闲 CPU 返回 EAGAIN 和零值不会被当作 0 Hz 或采集故障。
- 夹具覆盖瞬时硬件值优先、硬件反馈平均值回退、调频估算回退、EAGAIN/零值、Compute 表的来源/质量、System 策略详情、Snapshot、Agent 的加权平均及采集失败后的旧值拒绝。当前 Linux 开发机的 16 个策略均暴露 `cpuinfo_avg_freq`；源码采集为 16/16 个 measured，重建的 onedir Snapshot 也为 16/16 个 `cpuinfo_avg_freq`、资源质量 fresh。包内 Agent 报告 `average_hz=2145005250`、source=`cpuinfo_avg_freq`、quality=`measured`；180×45 包内 Compute 页实际显示“硬件均值”。这些值是不同时间窗口的样本，不作瞬时逐物理核心频率的承诺。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 文件和快速 PTY，Lua 5.4 定向夹具与完整 `make test-pty` 通过。`make test-release-notices` 的 3 项 SBOM 摘要与 14 项清单一致，Windows x86 开发包的 PE 静态门禁通过；其他平台的硬件反馈频率仍需真机验证。

### 2026-10-10：CPUFreq 策略与核心温度关联

- [当前 coretemp 文档](https://docs.kernel.org/hwmon/coretemp.html)和[旧版内核文档](https://docs.kernel.org/6.2/hwmon/coretemp.html)区分核心与封装温度；旧版文档的封装标签为 `Physical id N`，当前主机发布 `Package id N`。设备图接受两种明确标签，但只引用已归属且有有效读数的通道。CPUFreq 策略的所有成员都能映射到同一实测核心时显示“核心”温度；否则仅在全部成员属于同一实测封装时显示“封装”温度，不称其为策略自身的传感器。
- 夹具覆盖单核心、跨核心同封装、跨封装、未知成员、缺失核心读数、重复传感器以及过期/失败的传感器、CPU 身份和频率来源；Compute 表、System 策略详情与 Snapshot 拓扑使用同一个设备图结果。当前 Linux 开发机的 16 个策略均关联到明确的核心温度通道，源码策略表与详情显示“Core”层级，并在 JSON 中保留传感器、通道和核心节点来源。
- `make check test-55 test-pty-quick` 通过 121 个 Lua 测试文件与 5 项快速 PTY；Lua 5.4 定向夹具通过。重建目录包的 Snapshot 同样关联 16/16 个策略，包内快速 PTY 的 5 项场景通过。`make test-release-notices` 的 3 项 SBOM 摘要与 14 项清单一致；Windows x86 开发包重新构建并通过 5 个 PE32 文件、510 项导入的静态门禁。Windows/XP 与单文件包的运行时路径仍需在可运行环境验证。

### 2026-10-10：页面切换输入延迟与 PTY 背压

- 固定脚本在本机轮流进入 Overview 与 Processes。旧事件顺序先执行刚转为前台的采集器、再绘制页面；逐阶段测量发现 `hwmon` 通常占约 30 ms，偶尔因 ACPI 读数接近 95 ms，渲染本身只需几毫秒。在持续排空 PTY 的同一测量方式下，旧顺序的 20 次切换 p95 约 104 ms。现在页面切换先从已有快照画出新页，再在同一轮采集并差分补画新读数。
- 基准脚本原来在看到标题后停止读取终端输出并睡 100 ms，完整帧可能堵在 PTY 缓冲区里，把测试端背压计入下一次按键延迟。现在固定的 100 ms 间隔内继续读取剩余输出，并在 JSON 与终端输出中分别列出各目标页的延迟。变更后的同机正式测量：源码首帧 362.7 ms、峰值 RSS 32964 KiB、20 次切换 p95 24.8 ms；重建目录包首帧 306.3 ms、峰值 RSS 50560 KiB、p95 15.1 ms。两次运行的 Linux 主机相同，`/proc` 中仅 4 个进程；这些值不证明 1000 进程或最低硬件的性能预算。
- `make check test-55 test-pty` 通过 121 个 Lua 文件和完整 PTY 矩阵，含 200×45 页面切换与旧终端回退；tmux socket 和 cgroup 成员场景因当前沙箱隔离按既有规则跳过。目录包快速 PTY、`make test-release-notices` 的 3 项 SBOM 摘要与 14 项清单、Windows x86 开发包的 5 个 PE32 文件/510 项导入静态门禁均通过。单文件包与 XP 的运行时仍需在目标环境验证。

### 2026-10-10：1000 条进程记录的 Linux `stat` 快路径

- 原生 `proc_batch` 新增 `stat_parsed` 模式：读取同一份 `/proc/<pid>/stat` 后直接发布已校验的字段表。原生解析不接受的行仍以原文交给 Lua 解析器；遇到不支持该模式的旧原生模块也继续请求原有的 `stat` 字符串。原生单元测试将真实进程和 300 组含额外右括号、负 nice/优先级的记录逐字段与 Lua 解析器对照，并检查越界值、读取失败槽位和旧模块回退。纯 Lua 5.4 路径保持原解析器。
- 在当前主机用相同的 1000 条合成 `stat` 记录重复 100 次，Lua 解析约 11.8 ms/1000 条，原生字段解析约 1.0 ms/1000 条。同一夹具与模拟批量读取器连续三轮配对测量，1000 进程整段采集的 Lua 字符串路径为 24.6–27.2 ms CPU/次，原生字段路径为 11.0–11.9 ms CPU/次；这只隔离了解析与 Lua 模型开销，不包括真实 1000 进程的内核读取成本，不能据此宣告单核 2% 的发布预算达标。原生模块通过 `-Wshadow -Wconversion -Wsign-conversion -Wpointer-arith -Werror` 严格编译，纯 Lua 5.4 定向夹具通过。
- `make check test-55 test-pty` 通过 121 个 Lua 测试文件及完整 PTY 矩阵，进程树、线程、列编辑和页面切换均正常；tmux socket 与 cgroup 成员场景因当前沙箱隔离按既有规则跳过。重建目录包的 Snapshot 对当前可见的 4 个进程导出 `ok/fresh` 与完整 `(pid,starttime)` 身份，包内原生模块直接返回 `stat_parsed` 字段表；包内进程树折叠和线程下钻两项独立 PTY 场景通过。`make test-release-notices` 的 3 项 SBOM 摘要与 14 项清单一致；Windows x86 开发包重新构建并通过 5 个 PE32 文件、510 项导入的静态门禁。单文件包与 XP 的运行时仍需在目标环境验证。

### 2026-10-10：按需进程 OOM 选择分数

- [oom_score](https://man7.org/linux/man-pages/man5/proc_pid_oom_score.5.html) 是内核当前用于 OOM 选择的分数，[oom_score_adj](https://man7.org/linux/man-pages/man5/proc_pid_oom_adj.5.html) 是独立的调整值；数值不是被杀概率。采集器只在进程详情打开时读取这两个文件，分别保留有效、缺失、拒绝和坏值状态，不把它们加入全进程扫描或普通进程质量。现有附加读取后的 `(PID,starttime)` 复核仍覆盖这两项。
- 夹具验证未选中进程不取得 OOM 字段、缺失双文件时不丢失进程、越界值不当作分数、单文件拒绝不遮盖另一项。当前 Linux 开发机对所选进程读到 `oom_score=800`、`oom_score_adj=200`，英文详情浮层显示两项与解释文字。
- `make check test-55 test-pty` 通过 121 个 Lua 测试文件及完整 PTY 矩阵；tmux socket 与 cgroup 成员场景受沙箱隔离跳过。Lua 5.4 的定向进程夹具通过。重建目录包的线程下钻场景及实测进程详情中的 OOM 分数、调整值通过；发布包的 3 项 SBOM 摘要与 14 项校验清单一致。Windows x86 开发包重建后通过 5 个 PE32 文件、510 项导入的静态门禁；单文件包与 XP 的运行时未在本轮验证。

### 2026-10-10：EDAC 与固件内存槽位的同名引用

- 共享设备图为 EDAC DIMM 和已填充的 SMBIOS Type 17 槽位建立双向 `unique_label` 引用，条件是两份来源当前可用、列表未截断、非占位标签在各自来源中均唯一。比较仅忽略首尾空白与 ASCII 大小写；重复标签、空槽、rank 或陈旧来源均保持独立。EDAC 模块仍属于自己的控制器；TUI 明示同名不等于物理身份，Snapshot 在拓扑节点中导出双方 ID 和匹配方法。
- 夹具覆盖双向详情与导出、重复的已填充或空槽标签、重复的 DIMM/rank 标签、截断列表和陈旧 EDAC 来源。本机 `/sys/devices/system/edac/mc` 无 `mc*` 控制器，因此没有真实模块的槽位对应证据；SPD 到固件槽位的可信映射仍未建立。
- `make check test-55 test-pty` 通过 121 个 Lua 测试文件和完整 PTY 矩阵；tmux socket 与 cgroup 成员场景受沙箱隔离跳过。Lua 5.4 的定向硬件夹具通过。重建的 Linux onedir 包通过硬件详情 PTY，`--snapshot` 导出 92 个拓扑节点；3 项 SBOM 摘要与 14 项校验清单一致。Windows x86 开发包重建后通过 5 个 PE32 文件、510 项导入的静态门禁；onefile 与 XP 的运行时未在本轮验证。

### 2026-10-10：Network 连接表的字面文本筛选

- Network 页用 `/` 复用行编辑输入，在当前采集的套接字中按可见端点、协议、状态、队列、UID 和属主做 ASCII 不区分大小写的字面匹配，再选出至多 512 行。状态行分开报告采集器总数、匹配数与实际显示数；`Esc` 清除筛选。遮蔽远端地址时，匹配只检查遮蔽后的端点；从完整地址切到遮蔽模式时清除原查询，避免把查询里可能出现的完整 IP 留在屏幕上。该筛选只作用于交互式表格，Snapshot 输出契约不变。
- 600 条连接夹具验证第 600 条可在筛选后出现；双地址夹具验证遮蔽模式不能用隐藏的完整远端地址命中，却可用遮蔽后的地址命中。独立 PTY 场景覆盖输入、确认、清除和切换遮蔽模式。
- `make check test-55 test-pty` 通过 121 个 Lua 测试文件和完整 PTY 矩阵，当次场景账本为 26 项；tmux socket 与 cgroup 成员场景受沙箱隔离跳过。两个相关测试文件在 Lua 5.4 下通过。重建的 Linux onedir 包单独通过 Network 筛选 PTY 场景，3 项 SBOM 摘要与 14 项校验清单一致；Windows x86 开发包通过 5 个 PE32 文件、510 项导入的静态门禁。沙箱空闲时 `/proc/net/{tcp,tcp6,udp,unix}` 只有表头，因此该轮筛选 PTY 只验证空结果；下文的 `socketpair` 用例补上了真实连接。onefile 与 XP 的运行时未在本轮验证。

### 2026-10-10：Network socket 属主到进程详情

- 原有属主扫描按 fd 逐条发布，复制同一 socket fd 会把一个进程列成多个属主，并耗掉每 socket 的属主预算。现在按 PID 合并，导出属主的 `fd_count`，内部保留匹配 fd 列表。`/proc/<pid>/comm` 的行尾换行在清理控制字符前移除，属主名称不再带多余的 `?`。
- Network 连接表支持键盘和鼠标选择。Linux 上按 `Enter`，单一属主直接进入进程详情，多个不同进程先列出属主供选择。打开时在读取 fd 链接前后复核 `/proc/<pid>/stat` 的 `(PID,starttime)`，至少一个 fd 仍须指向所选 socket inode；当前进程快照暂缺时按需触发进程采样，详情只跟随相同身份。无属主、fd 改变或 PID 复用时不按数字 PID 猜测目标。其他平台尚未提供这条下钻。
- 夹具验证复制 fd 不重复计属主、备选 fd 可完成复核、fd 改变/PID 复用会拒绝导航，以及导出只发布 fd 数、不发布内部 fd 列表。真实 PTY 以 `socketpair` 创建可见的 Unix socket，分别验证单一属主直达详情与两个进程共享 socket 时的选择列表；沙箱不允许 `bind` 新 socket，但 `socketpair` 可用。
- `make check test-55 test-pty` 通过 121 个 Lua 测试文件和完整 PTY 矩阵，场景账本现为 27 项；tmux socket 与 cgroup 成员场景受沙箱隔离跳过。四个相关测试文件在 Lua 5.4 下通过。重建的 Linux onedir 包单独通过真实 socketpair 下钻场景；发布包 3 项 SBOM 摘要与 14 项校验清单一致。Windows x86 开发包重建后通过 5 个 PE32 文件、510 项导入的静态门禁；跨平台属主下钻、onefile 和 XP 运行时仍待验证。

### 2026-10-10：IPv4/IPv6 procfs 路由视图

- [Linux procfs 文档](https://github.com/torvalds/linux/blob/master/Documentation/filesystems/proc.rst)将 `route` 与 `ipv6_route` 列为内核路由表；[IPv4 `fib_route_seq_show`](https://code.googlesource.com/linux/torvalds/linux/+/90f055df112162fd9e093c16be1c21f38c35b907/net/ipv4/fib_trie.c)给出字段次序与原生字节序的十六进制输出。采集器复用现有读取，解析有界的目的前缀、下一跳、接口、metric 与标志，另保留 IPv6 源前缀。Network 页 `g` 浮层与 Snapshot 使用同一份结果，并说明 procfs 视图不包含全部策略路由表。
- 路由清单最多保留 2048 条，浮层最多展示 256 条并报告总数；即使清单已满，默认路由选择仍检查全部有效行，并把选中的默认项留在清单中。IPv6 `::/0` 的未启用回退项不再被当作默认路由。本机 `/proc/net/route` 当前只有表头，`ipv6_route` 有三条有效记录，其中两个 `lo` 回退项未启用；实际解析报告 IPv4/IPv6 均 `ok`、总数 3、无坏行和无可用默认路由。夹具覆盖 IPv4 小端字段、IPv6 前缀/下一跳、坏掩码、展示上限和上限之后的默认路由。
- 当前 x86_64 开发主机的同一组合成 2048 条 IPv4 路由重复解析 10 次，平均约 24.2 ms CPU/次。普通主机的路由数远少于该上限；该测量也提示大路由表在 1 Hz 网络刷新下可能超过低功耗预算。尚未在最低目标硬件上校准或建立门禁，不能由本机小路由表的运行推断旧设备表现。
- `make check test-55 test-pty` 通过 121 个 Lua 测试文件及完整 PTY 矩阵，场景账本为 28 项；tmux socket 与 cgroup 成员场景受沙箱隔离跳过。Lua 5.4 的采集器、原因和导出定向测试通过。重建的 Linux onedir 包单独通过路由浮层 PTY，`--snapshot` 导出本机 3 条解析后的路由；发布包 3 项 SBOM 摘要与 14 项校验清单一致。Windows x86 开发包重建后通过 5 个 PE32 文件、510 项导入的静态门禁；完整策略路由、onefile 与 XP 运行时仍待验证。

### 2026-10-10：路由清单按需采样

- 上一条记录的合成 2048 路由解析约 24.2 ms CPU/次，而 Network 页每秒采样。现将默认路由判断保留为按秒的轻量扫描：只为前缀零的候选解析 metric 和标志；完整地址解码与有界清单仅在 `g` 浮层或 `--snapshot` 请求时执行。浮层打开使网络任务立即到期，保持打开时十秒重读一次；默认路由改变会提前重读，关闭后保留的旧清单标为 stale，避免被当成新读数。
- 同一台 x86_64 主机、同一组合成 2048 条 IPv4 路由各重复 20 次，默认路由轻量扫描约 1.1 ms CPU/次，完整清单约 19.9 ms CPU/次；这是解析器与夹具的 CPU 测量，不包括真实 procfs 读取成本，也不证明最低硬件达到性能目标。夹具确认轻量/完整扫描对 IPv4/IPv6 默认接口及各自 metric 给出一致答案、未启用的 IPv6 回退不入选，并验证浮层打开立即采样、十秒期限、默认路由变化触发刷新及关闭后 stale 状态。本机普通 Network 采样不构建清单，按需样本读到三条 IPv6 记录。
- `make check test-55 test-pty` 通过 121 个 Lua 测试文件与完整 PTY 矩阵，场景账本仍为 28 项；tmux socket 与 cgroup 成员场景受沙箱隔离跳过。Lua 5.4 的采集器、引擎和导出定向测试通过。重建的 Linux onedir 包单独通过路由浮层 PTY，`--snapshot` 导出 3 条质量为 fresh 的完整路由记录；3 项 SBOM 摘要与 14 项校验清单一致。Windows x86 开发包静态门禁检查 5 个 PE32 文件和 510 项导入通过；旧硬件预算、完整策略路由、onefile 和 XP 的运行时仍待验证。

### 2026-10-10：硬件图跨引用导航

- `Hardware.related` 只从共享图中已经解析且目标存在、身份无歧义的 EDAC↔固件槽位、扩展槽↔PCI、SR-IOV、IOMMU、固件缓存/插槽、内存地址映射、NUMA/CPU/频率策略及子节点引用构建目的地；原始固件地址本身不构成跳转。最多列 256 个，重复目标合并，超限时报告真实总数。
- 系统或内存硬件详情按 `r`：一个目的地直接打开，多个目的地进入选择列表；`Esc` 从列表返回原详情，`b` 从已打开的设备返回上一详情，`q` 仍关闭。夹具验证 EDAC/固件槽位双向跳转候选、在用扩展槽的 PCI 引用与空槽无目标、子节点上限；真实 PTY 从 NUMA 节点打开相关 CPU，再按 `b` 返回原节点。
- `make check test-55 test-pty` 通过 121 个 Lua 测试文件和完整 PTY 矩阵，场景账本现为 29 项；tmux socket 与 cgroup 成员场景受沙箱隔离跳过。Lua 5.4 的硬件和布局定向测试通过。源码与重建的 Linux onedir 包均单独通过关联设备 PTY，包括无色 ASCII 输出；3 项 SBOM 摘要与 14 项校验清单一致。Windows x86 开发包通过 5 个 PE32 文件、510 项导入的静态门禁；其他平台的实际硬件关系与 XP 运行时仍需目标主机验证。

### 2026-10-10：进程到 Network 连接的反向导航

- Linux 进程页与进程详情的 `n` 跳到 Network，按选中进程完整的 `(PID,starttime)` 限定连接；文字查询仍可继续缩小范围，`Esc` 逐层清除。跳转强制请求新连接样本，在其完成前不展示旧属主。仅为目标进程在 fd 扫描前后读取两次 `/proc/<pid>/stat`，身份一致才给内部属主记录加 id；PID 复用或进程退出时不会把新进程的连接归给旧进程。目标进程即使落在普通扫描上限之外也优先占一个名额，总扫描仍保持有界。
- 夹具覆盖 PID 已复用、扫描中发生复用、目标被有界目录列表遗漏、512 行显示上限之前的精确筛选、同一时钟刻度下等待新样本及采样失败后结束加载。真实 PTY 持有一对 Unix socket，从进程详情进入限定后的连接表，再从进程页验证 `Esc` 清除范围。标准 JSON 快照仍不触发目标扫描，跨平台进程到连接导航尚未实现。
- `make check test-55 test-pty` 通过 121 个 Lua 测试文件与完整 PTY 矩阵，场景账本现为 30 项；tmux socket 和 cgroup 成员场景受沙箱隔离跳过。三个相关测试文件在 Lua 5.4 下通过。重建的 Linux onedir 包单独通过进程到真实 socketpair 的 PTY 场景；`make test-release-notices` 的 3 项 SBOM 摘要与 14 项清单一致。Windows x86 开发包重新构建并通过 5 个 PE32 文件、510 项导入的静态门禁；onefile 与 XP 运行时未在本轮验证。

### 2026-10-10：Network 字段组合筛选

- 不含已识别字段条件的查询仍将整段文本视为一个字面短语，保留现有搜索行为。有字段条件时以空白分词并取交集，可按协议/地址族、状态、本地或屏幕可见的远端端点、属主、精确 PID/UID/端口，以及 TX/RX/合计队列比较；`!` 排除条件。未知或畸形表达式按字面匹配，不把坏数字变成零。属主映射不完整时，否定式属主条件不会把未知结果当作确定的不匹配。
- 匹配仍遍历整个当前连接集合，然后按原排序选最多 512 行；结构化 `remote:` 与普通字面查询共用已遮蔽的远端文本。夹具覆盖上限之后的命中、两种队列方向与比较运算、缺失或溢出的队列、旧短语语义、部分属主扫描和隐私遮蔽；真实 PTY 用一对 Unix socket 验证协议与精确 PID 条件一起生效。
- `make check test-55 test-pty` 通过 121 个 Lua 测试文件和完整 PTY 矩阵，场景账本现为 31 项；tmux socket 与 cgroup 成员场景受沙箱隔离跳过。三个相关测试文件在 Lua 5.4 下通过；重建的 Linux onedir 包单独通过结构化筛选 PTY。`make test-release-notices` 的 3 项 SBOM 摘要与 14 项清单一致，Windows x86 开发包通过 5 个 PE32 文件和 510 项导入的静态门禁；onefile 与 XP 运行时本轮未验证。

### 2026-10-10：Workloads 树搜索与单文件包沙箱限制

- Workloads 页的 `/` 在完整节点集合中搜索名称、路径以及已解析的服务/容器/Pod 身份，结果保留祖先后才应用 512 行上限。搜索暂时显示折叠路径而不修改保存的折叠状态；清除搜索后恢复，筛选期间的折叠键会说明拒绝原因。详情跟随可见选择，旧选择被筛掉时转到第一条直接命中，空结果不保留隐藏节点的详情。
- 夹具覆盖深层命中、祖先、折叠恢复、语义标签、空结果详情与第 600 条节点；真实 PTY 验证搜索、拒绝折叠和 `Esc` 清除。单文件包在当前沙箱运行 `--version` 返回 `luainstaller-onefile: extraction failed`：解包器逐级要求临时根路径由 root 或当前 UID 持有，而沙箱内 `/` 与 `/home` 显示为 UID 65534，当前用户是 1000。该运行不能证明目标系统上的单文件包是否可用，也不应通过放宽发行包的路径所有权校验来掩盖。
- `make check test-55 test-pty` 通过 121 个 Lua 测试文件与完整 PTY 矩阵，场景账本现为 32 项；tmux socket 和 cgroup 成员场景因沙箱隔离跳过。三个相关测试文件在 Lua 5.4 下通过；重建的 Linux onedir 包单独通过 Workloads 搜索 PTY。`make test-release-notices` 的 3 项 SBOM 摘要与 14 项清单一致，Windows x86 开发包通过 5 个 PE32 文件与 510 项导入的静态门禁；XP 运行时仍未验证。

### 2026-10-10：Workloads 实测数值组合筛选

- Workloads 的 `/` 保留整句字面搜索；出现已识别的数值或字段项时，按空白将文字与 `cpu`、`mem`、`read`、`write`、`procs`、`threads`、`pressure` 比较取交集，再补上命中节点的祖先。`mem` 与 I/O 速率使用二进制字节后缀；CPU/压力接受百分数字面量。缺失的线程数或其他数值，即使被否定也不变成零；畸形比较保留为字面查询。
- 夹具覆盖多个条件、第 600 条节点、I/O 字节每秒、百分号、负向文字、缺失的线程数及畸形数值。当前 Linux 宿主的 cgroup 根缺少 `memory.current`，但当前进程所在子组有该文件；真实 PTY 的 `mem>=0` 查询命中至少一个可见工作负载，证明数值路径实际接通，而不是只展示输入文本。
- `make check test-55 test-pty` 通过 121 个 Lua 测试文件及完整 PTY 矩阵，场景账本仍为 32 项；tmux socket 与 cgroup 成员场景受沙箱隔离跳过。三个相关文件在 Lua 5.4 下通过，重建的 Linux onedir 包单独通过含 `mem>=0` 的 Workloads PTY。当前开发机对 4096 个合成节点各跑 50 轮，仅筛选器匹配耗时约 1.3 ms（CPU 条件）、3.3 ms（内存加文字）和 4.5 ms（整句文字）/轮；不包含视图建模、终端绘制或旧硬件成本。`make test-release-notices` 的 3 项 SBOM 摘要与 14 项清单一致，Windows x86 开发包通过 5 个 PE32 文件及 510 项导入的静态门禁；onefile 与 XP 运行时仍未在本轮验证。

### 2026-10-10：System 设备树搜索

- System 页的 `/` 在完整共享设备图上按显示名称、设备 ID、总线和类别作字面匹配，`bus:pci driver:nvme` 等字段条件可组合驱动、厂商与型号。先寻找命中节点及图中已确认的父节点，再按树顺序取最多 512 行；空结果按 `Enter` 不会打开另一个设备，`Esc` 清除查询。搜索字段明确列白名单，原始固件、序列号与资产标签不在其中。
- 夹具覆盖扩展槽句柄、PCI 桥下的驱动命中及父节点、未公开序列号不匹配，以及原始树中位于第 512 行之后的逻辑 CPU 仍可连同其核心和封装被搜出。真实 PTY 验证零结果、拒绝错误详情、清除，以及 `bus:cpu` 找到当前设备树；Memory 页无 DIMM/NUMA 清单时仍打开明确的不可用详情，不受 System 空搜索拒绝影响。
- 首次全量 `make check test-55 test-pty` 的 121 个 Lua 文件通过，PTY 在既有 Memory 空清单详情场景发现过宽的空结果拒绝；缩小到“System 页且筛选非空”后，相关 Lua 5.4/5.5 夹具与完整 `make test-pty` 均通过，场景账本现为 33 项。源码和重建的 Linux onedir 包各自通过 System 搜索与 Memory 空清单两项 PTY。`make test-release-notices` 的 3 项 SBOM 摘要与 14 项清单一致，Windows x86 开发包通过 5 个 PE32 文件和 510 项导入的静态门禁；tmux socket、cgroup 成员受当前沙箱隔离跳过，onefile 和 XP 运行时仍未在此环境验证。

### 2026-10-10：Storage 挂载点与容量筛选

- Storage 页的 `/` 保留整句字面搜索，也可组合 `path`、`source`、`type`、`kind`、只读状态与 `used`、`avail`、`size`、`inodes` 实测阈值。先按原规则隐藏伪文件系统并归并重复挂载路径，再筛选全部可见挂载，最后选最多 512 行。缺失容量不按零匹配，错误数值不变成阈值。
- 夹具覆盖第 600 条挂载、已用率、字节后缀、inode 占用、只读状态、伪文件系统开关和同路径后一次挂载。真实 PTY 验证输入及 `Esc` 清除；首次场景发现伪文件系统隐藏数量把查询挤到面板之外，因此筛选时将查询状态排在前面，隐藏数量仍保留在后面。
- `make check test-55 test-pty` 通过 121 个 Lua 测试文件和完整 PTY 矩阵，场景账本现为 34 项；tmux socket 与 cgroup 成员场景因当前沙箱隔离跳过。三个相关文件在 Lua 5.4 下通过，重建的 Linux onedir 包单独通过 Storage 搜索 PTY。`make test-release-notices` 的 3 项 SBOM 摘要与 14 项清单一致，Windows x86 开发包通过 5 个 PE32 文件及 510 项导入的静态门禁；onefile 与 XP 运行时仍未在本轮验证。

### 2026-10-10：Windows x86 开发包加载条件静态门禁

- 当前源码的 `./tools/build_windows_x86.sh` 成功交叉构建，并在产物生成后运行 `tools/check_windows_x86.py`。五个 PE 文件均为 PE32 i386，操作系统与子系统加载器版本均为 4.0；工具核对了 510 项具名导入的 DLL 闭包，并拒绝把源码中按需解析的 API 变成硬导入。[微软的 `GetTickCount64` 文档](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-gettickcount64)将其最低客户端列为 Vista，[`GetSystemTimes`](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getsystemtimes)则要求 XP SP1，因此这两项都必须继续按需解析。
- `make check` 运行伪造的 PE 报告测试，验证错误架构、PE32+、超出 XP 的加载器版本、未捆绑 DLL 与硬导入较新 API 均被拒绝。此检查不能证明每个系统 DLL 导入都存在于 XP，也不是实际运行：本轮 Wine 在沙箱内被 `wineserver: bind: Operation not permitted` 阻止；XP 和经典 CMD 仍需目标主机验证。

### Windows 与 macOS 的既有主机记录

2026-09-28,x86 开发包在两台 Windows 主机上为全部 50 个导出的 top 进程
报告了累计读写传输字节数。在 Server 2008 上,一次 80×25 代码页 936 的
经典控制台运行打开了进程详情,I/O 计数器非零,并干净退出。同一视图在较新
的 Windows 主机上也可用。在每台主机上,当前进程的批量计数器均未超过随后
直接调用 `GetProcessIoCounters` 的读数,直接查询也拒绝了故意不匹配的
创建时间。较新主机上有一个进程的读字节数超过 1440 亿,在 x86 构建中
实际命中了 64 位计数器路径。这些是进程的累计 I/O 传输量,不是磁盘吞吐量。

2026-09-28,同一天的构建在两台 Windows 主机上新增了设备清单:SetupAPI 的
PCI 和 USB 枚举器列出在场设备及其 id 和驱动提供的名称(Server 2008 为
25 个 PCI + 5 个 USB;10.0.26100 为 20 个 PCI + 8 个 USB),以 `inventory`
导出并显示在 System 页。该处的 PCI 类别列保持为空,因为 SetupAPI 不提供
类别代码;任何平台都不会读取序列号。

同一天,macOS 26.5 arm64 主机也接入了该能力:IOKit 的 IOPCIDevice 和
IOUSBHostDevice 枚举报告了 8 条 PCI 条目(Apple Silicon 公开的主要是
内部桥接器,注册表名称形如 `pcic3-bridge`)和 2 个带 `locationID` 标识的
USB 集线器,在一次 `--snapshot` 运行中以 `inventory` 导出。Apple Silicon
的 PCI 条目没有 OpenFirmware `reg` 地址,因此地址列保持为空,而不是编造
`00:00.0`;供应商名称使用与 GPU 数据源共享的小型供应商映射,因为 macOS
不带 `pci.ids`。微软的
[`GetProcessIoCounters` 参考文档](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getprocessiocounters)
将 Windows XP 列为最低客户端版本;这是 API 证据,不是 XP 运行时结果。

同样在 2026-09-28,一个禁用批量采集器的验证构建在 Server 2008 上经由
Toolhelp 回退路径运行了相同检查。全部 76 行进程都带有累计读写字节数,
没有部分行;当前进程行的计数器未超过随后直接 `GetProcessIoCounters` 的
读数,故意不匹配的创建时间也被拒绝。`--snapshot` 为全部 50 个 top 进程
导出了 `io_read_bytes`/`io_write_bytes`,一次 80×25 代码页 936 经典控制台
运行打开了进程详情,其 I/O 区域显示非零计数器后干净退出。这验证了该主机
上的回退采集器;它不是 XP 运行时结果。

Server 2008 的 SSH 会话走 Cygwin 管道。为了直接考验遗留控制台本身,
`tools/console_harness.c` 在该主机上分配一个真实控制台,在其上启动 wtop,
然后读取屏幕缓冲区并注入按键和尺寸调整事件。这检查的是控制台中实际
存储的内容,而不是物理显示器和字体如何呈现它;机器前的人眼检查仍是
最终确认。较新 Windows 上的 ConPTY 运行考验了 Win32 控制台后端,但
不能证明旧 CMD 的显示质量。没有 XP 测试环境,XP 就无法获得经运行时
检验的结论。macOS 的部署目标为 arm64 对应 11.0、x86_64 对应 10.13;
实际运行过的只有 arm64 的 macOS 26.5。

2026-09-28,在 Server 2008 上一次 80×25 代码页 936 控制台 harness 运行
中用 `h` 打开了中文传感器浮层。该主机没有热区读数,因此浮层显示了
不可用原因和空数据提示。Esc 返回页面,`q` 以退出码 0 退出,控制台屏幕
被恢复。这次运行验证的是空状态和控制台行为,不是传感器数值更新,也不是
物理显示器的字形渲染。

在 10.0.26100 主机上,同一个 80×25 代码页 936 harness 显示了一条
ACPI 热区读数 27.85 oC,质量为新鲜,浮层保持打开达六秒。Esc 和 `q`
同样返回并恢复了控制台。读数保持恒定,因此这次运行没有考验数值变化的
情形。

随后在两台 Windows 主机上进行的 80×25 Overview 运行中,都在传感器
采集器五秒后台期限之前打开了 `h`。浮层的下一帧即显示了 Server 2008 的
不可用原因和较新主机的新鲜 ACPI 读数,尽管传感器组件并不存在于紧凑
页面中。两个控制台在退出后都恢复了屏幕。一次由时钟控制的调度器检查
确认,关闭浮层会使采集器恢复其后台节奏。

2026-09-28 的代码页 936 控制台后续检查还验证了翻译后的采集器标签。
在中文界面下,Server 2008 显示了传感器不可用状态和可读的 Windows 热区
原因;较新主机在其 ACPI 读数周围显示正常/新鲜状态。两个 80×25 浮层
都能容纳,两个控制台退出后都恢复了屏幕。Server 2008 的 `--snapshot`
仍导出原始的 `thermal_zone_counters_unavailable` 原因码。

2026-09-28,当前的 x86 开发包在 Server 2008 主机上运行了 `--snapshot`。
C: 和 D: 返回了完整容量。WMI 将 D: 报告为可移动驱动器。在三次直接原生
挂载采样中,D: 在首次调用时为 pending,一秒后变为 fresh;C: 一直保持
fresh。这考验的是带可用介质的后台探测。空介质或慢介质、热插拔以及映射
网络驱动器在本构建下仍未测试。

在同一主机上另行进行的一次背靠背原生调用采样中(丢弃每个采集器的首次
调用),八次调用的中位数为:进程 2.56 ms,GPU 0.01 ms,磁盘 0.74 ms,
挂载 0.04 ms。这测量的是批量进程采集器出现之前的采集器热调用;不包括
定期重扫或 TUI 的 CPU 占用。

x86 Windows 采集器现在通过动态解析的
[`NtQuerySystemInformation` SystemProcessInformation 调用](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntquerysysteminformation)
读取进程表。它将返回的布局与自身进程对照校验,并保留 Toolhelp 采集器
作为回退。路径和属主标签仍在按身份键控的缓存需要刷新时按进程解析。
在 Server 2008 上,约 78 个进程的八次热调用使用批量路径耗时
0.80–0.94 ms,而旧采集器为 2.49–2.62 ms。在 10.0.26100 主机上,约
380 个进程的热调用耗时 4.26–5.09 ms,旧采集器为 9.69–10.57 ms。
两个开发包都产出了新鲜快照。在较新主机上,批量表中受保护的 Secure
System 进程的工作集为 55,963,648 字节,与 PowerShell 一致;旧的
按进程查询报告为 131,072 字节。32 位批量内存字段若饱和,会通过现有
支持 64 位的进程查询重新读取。Server 2008 上一次 10 秒的进程页经典
控制台运行占用了单核的 1.56%,并以控制台恢复状态退出。这些运行不能
证明 XP 兼容性,也不能证明 1,000 个进程规模下的性能。

路径和属主缓存现在每个哈希桶保存八个身份。在同主机、交替直接采集器
对比中,Server 2008 上 76 行的 11 次热调用,使用旧的直接映射缓存为
0.60–0.85 ms,使用新缓存为 0.38–0.63 ms。在 10.0.26100 主机上,约
375 行的调用分别为 3.98–5.29 ms 和 1.73–2.17 ms。每次运行几乎都保留了
全部可用路径和属主,没有被拒绝或竞争态的行。这些都是短时热采集器采样;
整 TUI 使用情况和 1,000 个真实进程需要单独检查。

经典控制台 harness 现在可以在选定窗口内测量子进程 CPU 时间。在这台
Server 2008 主机上,带帧合并和可打印 ASCII 布局的产物,在两秒预热后、
多次重复的 10 秒窗口中:Overview 占用单核 1.71–1.87%,进程页
3.43–4.05%,GPU 页 1.71%。在这些改动之前,同一批页面在各自单独的
运行中约为 14%、21% 和 7%。之后引入的单单元格网格覆写和直接 ASCII
写入路径,在进程页为 2.80–2.96%,Overview 为 1.56%;其前一个产物在
进程页上交替运行时为 3.58–3.89%。每次运行进程都正常退出。这些短时
单主机运行不能确立发布性能基线。

2026-09-28,负载(Workloads)页在一台运行中的 cgroup v2 主机
(Debian 13,176 个 cgroup 节点)上获得了键盘导航:方向键移动选择,
详情面板跟随选择,`c` 折叠或展开选中的子树,隐藏整个子树而不仅是
直接子节点。两项功能都在该主机上通过 SSH 端到端驱动验证。
默认更新速率下,经典控制台上的 60 秒窗口覆盖了完整的定期刷新周期
(15 秒适配器缓存、30 秒路径和属主刷新)。Server 2008 在 Overview 上
占用单核 1.72%,进程页 2.29%,GPU 页 1.56%。约 380 进程的
10.0.26100 主机在 Overview 上为 2.58%,进程页 2.81%。两个进程都正常
退出。在 Linux 上,`make benchmark` 提供可重复的测量脚本,它会记录
测量对象:每个结果都注明其 **subject**(`source-tree` 或 `bundle`)
和其 **host**(内核、机器、核数),无论打印输出还是 JSON 中都如此。这
不是装饰——两个 subject 是两个不同的程序,而工具自身"仅比较同一
主机"的提示,在不知道数字出自哪台主机时是无法使用的。要测量发布实际
交付的产物而不是开发树:

```bash
make benchmark BENCH_EXECUTABLE=dist/wtop/wtop
make benchmark BENCH_EXECUTABLE=dist/wtop-onefile
```

上文的 Windows 数字来自经典控制台 harness 驱动产物,因此它们始终
测量的是产物。Linux 数字则不是:在此次改动之前,`make benchmark` 默认
驱动开发树且没有任何记录说明这一点——这就是一个 Linux 数字和一个
Windows 数字曾被并排当作同一程序来描述的原因。2026-09-28 稍晚时候,
Linux 进程采集器按 `(pid,starttime)` 缓存静态身份字段(UID、解析后的
用户、命令行),并用直接扫描替代了贪婪的 `/proc/stat` comm 模式:一个
550 进程的热采样从约 68 ms 降至约 29 ms,该主机上整个 TUI 的进程页
从单核 7.6% 降至 4.8%。身份缓存每次采样都从活动进程集合重建,因此
PID 复用不会提供过期身份;选中的行仍会为重读状态和命令行的详情页
重新读取。

当天最后一轮改动新增了原生批量 `/proc` 读取器(`proc_batch`:每个
stat 文件一次 Lua 到 C 的跨界,保留单文件读取器的 O_NOFOLLOW、常规
文件和超大文件检查,EACCES 单独报告),并去掉了代际重校验对完全
缓存行仍会执行的多余第二次 stat 读取与解析。该主机上 540 进程的热
采样降至约 21 ms,整个 TUI 的进程页降至 3.8–4.0%,与 Overview 页相差
0.2–0.4 个百分点以内;剩余的下限来自按进程解析 stat 和构建行,而非
I/O。"1,000 进程时 2%"的发布目标仍未达成:仅该主机的共享渲染基线就
约为 3.5%,因此这个目标需要经过校准的最低硬件才有意义。

进程表现在只格式化视口访问到的行。在两次交替的 10 秒经典控制台
运行中,前一个产物占用单核 3.12% 和 3.27%;惰性行产物为 2.34% 和
2.02%。另一次插桩运行测得 ViewModel 工作在跳过其他页面模型之前,
九个进程页帧共 43.2 ms,之后为 20.2 ms。此后的整进程 CPU 采样有所
波动,因此这些测量不能确立稳定的 2% 结果,也不能确立 1,000 进程
目标。

扁平进程控制器现在在采集集合能放进其行数上限时直接排序,为每次
重建缓存比较值,并在行视图中保留进程字段而不复制每个字段。
在 Server 2008 上,30 次合成的 1,000 进程更新在改动前中位数为
21.93 ms,改动后为 8.06 ms;4,096 进程更新在 15 次采样中从 88.51 ms
降至 38.37 ms。该主机真实的进程页约为 78 行。此控制器改动前的两次
10 秒经典控制台 CPU 运行占用单核 1.87% 和 1.71%;改动后的两次稳态
运行为 1.71% 和 1.40%。这些短时运行展示的是控制器的扩展性改进,不是
1,000 个真实进程下的整 TUI 结果。

Server 2008 上的一次后续经典控制台运行显示,进程页命令列默认展示
可执行文件基名。按 `p` 切换为映像路径;80 列视图从头部开始截断,
以保持可执行文件名可见。稍晚一次从最终源码树出发的运行正常退出。
在 macOS 26.5 上,两次 160 列 SSH PTY 运行确认了默认基名以及按 `p`
后从头部截断的可执行路径;两个会话都正常退出。

在同一台 Mac 上,`proc_pidinfo` 对约 760 个进程中的约 300 个拒绝了
无特权账户的访问。此前的采集器直接丢弃这些行,并把剩余行报告为新鲜。
现在 `KERN_PROC_ALL` 进程表回退会保留这些进程的 PID、启动时间、
名称、用户、父进程和可执行路径,同时将 CPU 和内存标记为不可用。
在一次后续快照中,768 个候选导出了 766 行,其中 306 行受权限限制,
一个进程竞争态,进程质量为 partial。八次直接采集器调用耗时
2.06–10.96 ms;后四次为 2.06–2.37 ms。这是单台 M4 主机的采样,不是
旧设备的性能结果。

## 性能记录

### 2026-10-11：源码与 onedir 同机短基准

Fedora 44、x86_64、16 CPU 的本机沙箱，对当前源码与重建的 onedir
分别运行 `make benchmark`：120×34 PTY、1 秒刷新、Overview 与 Processes
各 5 秒稳态窗口、20 次翻页。全部阶段只观察到 5 个宿主进程。
源码 / onedir 的首帧为 380.8 / 365.1 ms，峰值 RSS 为
36,728 / 58,744 KiB，Overview CPU 为单核 2.18% / 2.20%，
Processes CPU 为 1.40% / 1.20%，翻页 p95 为 16.8 / 27.2 ms。
先前各 3 秒窗口、10 次翻页的快速试跑曾测得 Processes CPU
6.9% / 7.6%，故单次短窗不能用来裁决回归。这里既没有 1,000 个进程，
也不是最低配置主机；这些数字只作本机开发记录，不形成发布预算。

### 2026-10-11：预算检查增加阶段进程数

当前 `tools/perf_benchmark.py` 的 `measurement_version = 3` 记录首帧、每个
稳态窗口起止、每次切页前及结束时的可见进程数；`benchmark-check` 要求
这些观测全部落在目标机器的进程数范围内。此前只在首帧后数一次，工作负载
即使在稳态窗口边界或切页前已经变化，也可能拿到一份“合格”的预算结果。
阶段取样仍不能证明两次观测之间没有短暂波动。真实 onedir
运行产生 26 次进程数观测，均为 4；用该记录临时构造的本机预算通过，
将第 5 次切页观测改为 5 后，校验器明确报出该阶段超出范围。这个预算
仅用于验证门禁，没有进入仓库或被当成发布阈值。另一次
`make benchmark-check` 用同机临时预算完成基准并通过七项限值检查，
验证了 Makefile 到校验器的完整路径。预算现在必须写明 `subject_path`；
`dist/wtop/wtop` 的预算会拒绝 `dist/wtop-onefile` 的结果，缺少入口路径也
无法通过。它约束包形态，不把预算锁在某次构建的哈希上。

同机、同一脚本的 onedir 基准为首帧 335.0 ms、Overview/Processes 稳态
CPU 2.38%/1.00%、峰值 RSS 56,916 KiB、切页 p95 17.3 ms。可见进程仅 4 个，
这些数值不能证明 1000 进程或最低硬件的性能目标。尝试按需加载交互模式
不使用的导出模块时，源码峰值 RSS 只下降 164 KiB；打包形态两次运行的
RSS 相差约 2.5 MiB，大于初次看见的改善，因此撤回该改动。

### 2026-10-10：完整帧基准与预算检查入口

基准原来把页名当作翻页完成标记，但页名在每个页面的标签栏里都可见。
这次修复让脚本等待目标页专属内容，再等 ANSI 编码器的帧末复位；首帧也等
完整编码帧，而不是只等 `wtop` 字样。当时结果带 `measurement_version = 2`、
测量脚本参数和人工指定的机器/负载 profile；更早的结果不能通过那一版预算检查。
启动与翻页超时可调，供慢机器测量。

在已经构建好的 Linux 目录包上运行 `make benchmark-check` 时，
`BENCH_EXECUTABLE` 指向可执行文件，`BENCH_PROFILE` 和 `BENCH_BUDGET`
选择目标机器的预算。预算文件需写明同一内核/架构/CPU 数、进程数范围、
页面、窗口时长与延迟样本数，并为首帧、峰值 RSS、各页稳态 CPU 和
各目标页 p95 翻页时间给出上限。缺项、主体不符、负载不符或超限都会失败。
预构建产物只运行轻量资源预检，不要求构建机的 2–4 GiB 可用内存。

在目标主机上先记录同一脚本的测量值，再按该主机的预算运行：

```bash
make benchmark BENCH_EXECUTABLE=dist/wtop/wtop \
  BENCH_ARGS='--profile target-host --pages 2 --window-seconds 10 --latency-samples 20 --json /tmp/target-host.json'
make benchmark-check BENCH_EXECUTABLE=dist/wtop/wtop \
  BENCH_PROFILE=target-host BENCH_BUDGET=/path/to/target-budget.json \
  BENCH_ARGS='--pages 2 --window-seconds 10 --latency-samples 20'
```

当前预算 JSON 的 `subject_path` 写被测包入口，`host` 包含 `kernel`、
`machine`、`cpus`，`host_processes` 包含
`min`/`max`，`settings` 与命令的页面、窗口时长、样本数和终端尺寸一致。
`maximum` 用 `first_frame_ms`、`rss_peak_kib`、
`steady_cpu_percent.page_1` 等键，以及 `input_latency_ms.p95` 和各页
`page_N_p95` 键给出上限。精确的可运行格式由
[`tests/test_perf_budget.py`](../tests/test_perf_budget.py) 的夹具覆盖。

本机约 4 个进程、每页 5 秒稳态窗口及 20 次翻页，使用同一脚本得到：

| 测量对象 | 首帧 | Overview / Processes 单核 CPU | 峰值 RSS | 翻页 p95 |
| --- | ---: | ---: | ---: | ---: |
| 开发树 | 334.4 ms | 2.40% / 1.59% | 34248 KiB | 13.7 ms |
| onedir | 333.9 ms | 2.20% / 1.19% | 51640 KiB | 18.3 ms |

onedir 通过了仅用于工具冒烟的宽松预算；把首帧上限改为 1 ms 会明确
失败。检查器还拒绝 0.5 秒/4 次翻页的短窗，避免以不稳定的 p95 冒充
发布性能证据。两次运行不足以确定稳定差距，也不是发布阈值。
旧硬件与典型主机尚未给出各自的预算，所以这项发布门禁仍未关闭。

以下测量从已有的计划记录归入本页，来自 Fedora x86_64 开发主机。
它们用于同主机对比，尚未据此建立目标硬件上的预算或回归阈值。

| 日期 | 测量对象 | 进程数 | 首帧 | CPU，Overview / Processes（单核） | 峰值 RSS | 翻页延迟 p95 |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-09-28 | 开发树；当时尚无测量对象字段 | 537 | 约 242 ms | 3.4% / 7.8% | 约 29 MiB | 约 109 ms |
| 2026-10-02 | 开发树 | 581 | 283.6 ms | 4.17% / 4.78% | 36752 KiB | 112.8 ms |
| 2026-10-02 | onedir 开发候选，`dist/wtop/wtop` | 581 | 326.4 ms | 3.58% / 5.55% | 46016 KiB | 110.5 ms |

Windows 的经典控制台测量和各次优化结果仍保留在上文的主机记录中。

## 开发构建

在 macOS 上运行 `./tools/build_macos.sh`;可执行包位于
`dist/macos/wtop`。在 Linux 上使用 32 位 MinGW 交叉编译器运行
`./tools/build_windows_x86.sh`,并将 `dist/windows-x86` 拷贝到
Windows。在 CMD 或 PowerShell 中运行 `wtop.cmd`。在
Cygwin/OpenSSH PTY 中,使用 `wtop.sh`,以便键盘输入不经行缓冲直接
送达。两个包都包含 Lua 5.5.1 及其配套原生模块。

x86 Windows 包以 `_WIN32_WINNT=0x0501` 构建。`lua.exe` 和
`wtop_native.dll` 均为 PE32 i386,原生模块不硬导入 `GetTickCount64`
等较新 API。CPU API
[`GetSystemTimes`](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getsystemtimes)
的文档从 XP SP1 起才有,因此该模块动态解析它,并为更早的 XP 提供
NT 处理器计数器回退。该回退在 Server 2008 上被强制启用做验证时,
与 `GetSystemTimes` 计数器一致。它在 XP 本身上仍未验证。

## 已知问题

- Windows 进程页在规模下的性能仍未证实。一个较早的 TUI 产物在其
  默认页面上,于 10.0.26100 主机占用了约 15% 的单核。其进程列表
  每次调用约 15 ms,socket 表约 6 ms;Server 2008 上显示适配器
  查询约 18 ms,磁盘 11 ms,挂载 8 ms。显示适配器标识现在最多缓存
  15 秒。进程路径和属主标签以 PID 和创建时间为键,存放在每个
  4,096 项、八路的有界缓存中,避免两个进程身份哈希到同一首槽时
  重复打开句柄。属主标签在 30 秒后重新查询,查询失败时则 5 秒后
  重试。磁盘采集器在定期重扫之间跳过不存在的物理驱动器号。
  热采集器调用和整 TUI CPU 已在 Server 2008 上按上文测量。TUI
  现在按所选更新间隔合并自动重绘,并对可打印 ASCII 使用直接
  宽度路径。进程行在视口访问时才格式化,活动进程页会跳过其他页面
  的模型。进程控制器避免重复排序,也不再把每个采样字段复制进
  行中。该主机上早些时候的某些运行中,进程页超出了 2% 单核目标。
  定期刷新时序和更广泛的硬件测量仍然需要做。
- Windows 没有压力或电源区域数据源,将其显示为不可用。其 CPU 频率
  自 Windows 7 / 2008 R2 起来自 PDH;更旧的系统报告额定频率作为
  估计值。没有 WDDM 驱动的适配器,或 DXGI 在服务会话中不列出的
  适配器,有标识和显存但没有利用率。
- Windows 在无法读取容量时保留盘符挂载行,容量标记为 partial 而
  不是零。固定驱动器的文件系统标识缓存 30 秒。可移动介质和光驱的
  容量/标识查询现在最多使用两个后台工作线程。首次采样可以是
  pending;完整结果缓存 30 秒,失败结果 5 秒后重试,过期结果在
  刷新期间标记为 stale。两个永久阻塞的设备可能阻止其他可移动探测
  启动;采集器不会等待这些工作线程。可用可移动介质已在 Server 2008
  上检查过,但慢介质和空介质的情形仍未覆盖。映射网络驱动器保留在
  列表中且容量标记为 partial,因为查询已断开的Server可能会阻塞。
  宽存储表显示挂载质量。
- macOS 没有压力数据源,也没有按进程的 GPU 占用。非 root 运行时,
  受保护进程只有基本标识,没有 CPU 或内存指标;socket 和负载只覆盖
  调用者自己的进程。磁盘繁忙时间是由请求服务时间求和估算的。
  集群到 CPU 的编号是从性能层级数量推断的。
- macOS 的传感器、能耗、频率和负载数据源使用私有接口。它们仅在
  M4 和 macOS 26.5 上验证过;其他芯片和版本可能将它们报告为不可用。
- 经典控制台将线条图形显示为 ASCII。控制台代码页内的文本(例如
  代码页 936 上的中文)按原样显示;其他字符显示为 `?`。没有
  `LANG` 或 `--lang` 时,Windows 控制台仅当其代码页能显示该语言时
  才跟随显示语言。

## 仍待确定的基线

- 必需的 x86 之外的 Windows XP 服务包和 CPU 架构变体。
- Windows x64 产物的范围,以及将在哪些版本上验证。
- 更早的 macOS 版本和 Intel 硬件的运行时验证。
- 最低 Linux 内核、libc 和 CPU 架构。libc 一半已有答案并设有
  门禁:`tools/baseline.conf` 承诺一个 glibc 下限,`make baseline`
  测量每个交付的 ELF 并在超限时失败,当前 Fedora x86_64 构建需要
  glibc 2.38。同一份源码在 manylinux2014 容器中构建需要 2.17,并
  能通过全部单元套件,因此该下限是构建宿主属性,是一个有实测范围
  的值而非单一数字;`make cross-libc` 可复现它。内核一半的答案
  是"无",各数据源的降级行为见
  [Monitoring Scope and Performance Operations](MONITORING.md),
  该性质由 `tests/unit/test_engine.lua` 固定。CPU 架构覆盖仍未
  确定:只构建过 x86_64。
- 面向旧硬件的 CPU、内存、启动和输入延迟的实测预算。

在这些基线选定并验证之前,不应将兼容性目标作为已发布平台的承诺对外
呈现。
