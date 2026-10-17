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

2026-10-17 核对：Windows GPU/温度隔离提交 `48b0145` 的
[主 CI](https://github.com/Water-Run/wtop/actions/runs/38917845385) 16 个作业与
[Windows CI](https://github.com/Water-Run/wtop/actions/runs/38917845643) 两个作业
全部成功。四归档摘要为 Linux `b0aa4888`、ARM `53612703`、Mac `477ce31c`、
Windows `62c6fdb0`；八项静态与提供主机验收成功。M4 保留 43 个传感器、
七个功耗域和 25 个接口，Windows 保留八/六 CPU、原有 GPU 及热区可用性。
本机两种 Linux 包另验功耗墙、真实计数与采样窗口、百分比和三个功耗入口。
收据见 `build/hardware-windows-gpu-thermal-isolation-20261016/ACCEPTANCE.json`。

2026-10-16 核对：Windows 频率隔离提交 `50f716c` 的
[主 CI](https://github.com/Water-Run/wtop/actions/runs/38905648100) 16 个作业与
[Windows CI](https://github.com/Water-Run/wtop/actions/runs/38905648652) 两个作业
全部通过。四归档摘要为 Linux `6094e9c5`、ARM `44092995`、Mac `1985352a`、
Windows `25dffa1b`，静态门禁及 Linux、M4、Windows 11、Server 2008 的
相应主机复验通过。两种 Windows 包保留八/六 CPU 的频率及经典控制台
操作。收据见 `build/hardware-windows-frequency-isolation-20261016/ACCEPTANCE.json`。

2026-10-16 核对：Windows 处理器组与频率采样提交 `0fa8243` 的
[主 CI](https://github.com/Water-Run/wtop/actions/runs/38888120377) 16 个作业与
[Windows CI](https://github.com/Water-Run/wtop/actions/runs/38888120222) 两个作业
全部通过。四归档摘要为 Linux `8ff3f785`、ARM `ed51d503`、Mac `a6178901`、
Windows `15799ef6`。两种 Windows 包在 Windows 11/Server 2008 保留八/六
CPU 的组编号、PDH/PowrProf 来源和可见 GHz 表，五 CLI、经典控制台及硬件
导航通过；Linux 功耗墙、有效频率与 Mac 来源故障检查也通过。收据见
`build/hardware-windows-frequency-groups-20261016/ACCEPTANCE.json`。

2026-10-16 核对：Mac 网络隔离提交 `4f51aa3` 的
[主 CI](https://github.com/Water-Run/wtop/actions/runs/38879542466) 16 个作业与
[Windows CI](https://github.com/Water-Run/wtop/actions/runs/38879542561) 两个作业
全部通过。四归档摘要分别为 Linux `d09f8f8c`、ARM `a92a00d3`、Mac
`5efda92b`、Windows `c2d7947f`，静态检查和提供主机复验通过。精确 Mac
两种包的六组网络阻塞检查在约 32–75 ms 退出，恢复后的约 1.039 s 窗口
计算及父进程清理通过，保留 43 个传感器、25 个接口和三个网卡父设备。
收据见 `build/hardware-macos-network-isolation-20261016/ACCEPTANCE.json`。

2026-10-16 核对：逐逻辑 CPU 有效频率及夹具修复提交 `83ea2fe` 的
[主 CI](https://github.com/Water-Run/wtop/actions/runs/38847321798) 16 个作业和
[Windows CI](https://github.com/Water-Run/wtop/actions/runs/38847321801) 两个作业
全部成功，含两个 Linux 架构的最终下载与完整终端矩阵。
四归档摘要分别为 Linux `32629a69`、ARM `15e1a4ed`、Mac `3788f2f5`、
Windows `69a1f06a`。Linux 两形态另验实际计数器/窗口计算、普通权限拒绝、
真实空闲零值、超时回收、八组 CPU 详情与两个逻辑 CPU 表，以及三个功耗
入口和 Snapshot/Agent 百分比。M4、Windows 11、Server 2008 的两种包
通过对应 CPU/GPU/功耗/传感器/父设备与经典控制台验收。收据见
`build/hardware-cpu-ci-fix-20261016/ACCEPTANCE.json`。当前有效频率的固定
计数器后端只覆盖列出的 Intel Core 型号；XP 与旧 Intel Mac 仍无实测。

2026-10-16 核对：DRM/fdinfo 读取与 SDK 能量窗口提交 `7559398` 的
[主 CI](https://github.com/Water-Run/wtop/actions/runs/38837419804) 16 个作业和
[Windows CI](https://github.com/Water-Run/wtop/actions/runs/38837419677) 两个作业
全部通过，含源码、消毒器、完整终端和两个 Linux 架构的最终归档下载复验。
x86_64 归档 `8c31973a` 两形态另验五 CLI、quick PTY、共享 DRM 子进程与
Agent、超时、三个 SDK 的功耗和六组预热后挂死终端；真实 Sysman 保持
300 MHz、fresh 零限制掩码、唯一设备合并，不补造缺失的功耗域。
普通权限与 root 的 CPU 限制、三个功耗入口、20/26/114 W 配置及
Snapshot/Agent 计算通过。硬件、固件、DRM 的原生故障恢复和九个读取器
退出通过。ARM 归档 `21165689` 的本机证据为摘要与静态检查，原生运行
来自下载 CI；两个 Linux 归档仍需 glibc 2.38。
M4 归档 `ce65ff3d` 和 Windows 归档 `3880832b` 两形态在原有主机通过
GPU/时钟/传感器/CPU/父设备和经典控制台相应验收。四归档静态门禁通过，
收据见 `build/hardware-drm-isolation-20261016/ACCEPTANCE.json`。XP、旧
macOS 和没有提供的厂商硬件仍没有新增实际运行证据。

2026-10-16 核对：共享 SMBIOS 输入提交 `f5fbc2a` 的
[主 CI](https://github.com/Water-Run/wtop/actions/runs/38832930268) 16 个作业与
[Windows CI](https://github.com/Water-Run/wtop/actions/runs/38832930197) 两个作业
全部通过，包含两个 Linux 架构的完整源码套件、消毒器、终端矩阵和最终
归档下载后的运行。x86_64 归档 `76871f39` 两形态在本机另验五 CLI、quick
PTY、共享固件输入与 11 个视图超时、三个 GPU SDK 的功耗和六组预热后
挂死终端；普通权限拒绝、root 当前 MSR 限制、三个功耗入口与
Snapshot/Agent 算术均通过。真实 Intel Sysman 保持唯一设备合并、300 MHz
和 fresh 零限制掩码，不补造缺失的 GPU 功耗域。
ARM 归档 `1a37ce2a` 的本机证据为摘要与包内检查，原生运行证据来自上述
下载 CI。两个 Linux 归档仍需 glibc 2.38，旧 libc 的源码运行另行记录。
M4 归档 `c6cac313` 两形态通过五 CLI、GPU/时钟/功耗、43 个传感器、10 个
Mach CPU 和当前网卡父设备。Windows 归档 `f5f71497` 在 Windows 11 和
Server 2008 两形态通过五 CLI、无 ANSI 经典控制台、CPUID/缓存、父设备
导航与三个功耗入口。四归档静态门禁通过；完整摘要和范围收据见
`build/hardware-smbios-isolation-20261016/ACCEPTANCE.json`。XP 与旧 macOS
仍没有实际运行证据。

2026-10-16 核对：硬件 I/O 隔离提交 `9b3f43b` 的
[主 CI](https://github.com/Water-Run/wtop/actions/runs/38824471534) 16 个作业与
[Windows CI](https://github.com/Water-Run/wtop/actions/runs/38824471536) 两个作业
全部通过，包括两个 Linux 架构的 140 个 Lua 测试文件、消毒器、完整终端
矩阵，以及下载最终归档后的原生运行。x86_64 归档 `4649b611` 两形态在本机
另验五 CLI、quick PTY、七类硬件读取和三个 GPU SDK 的预热后故障、独立
恢复与退出；普通权限拒绝、root 当前 MSR 限制、功耗条和三个功耗入口、
Snapshot/Agent 算术均通过。真实 Intel Sysman 两形态读到 300 MHz 和
fresh 零限制掩码，缺失的 GPU 功耗域保持缺失。
ARM 归档 `cc99c469` 的本机证据为摘要与包内检查，运行证据来自原生 CI。
两个 Linux 归档仍需 glibc 2.38，源码在 glibc 2.17 的另验不改变该下限。
M4 归档 `5f8f81b7` 两形态通过五 CLI、GPU/时钟/功耗、43 个传感器、10 个
Mach CPU 与当前网卡父设备导航。Windows 归档 `c57fa968` 在 Windows 11
和 Server 2008 两形态通过五 CLI、80×25 无 ANSI 控制台、CPUID/缓存与
父设备导航、三个功耗入口。四归档静态门禁通过；原始摘要与验收收据见
`build/hardware-io-isolation-20261016/ACCEPTANCE.json`。XP 和旧 macOS
仍缺实际运行证据。

2026-10-16 核对：混合 GPU 连续观测提交 `de92b1e` 的
[主 CI](https://github.com/Water-Run/wtop/actions/runs/38813098799) 16 个作业与
[Windows CI](https://github.com/Water-Run/wtop/actions/runs/38813098741) 两个作业
全部通过，包括两个 Linux 架构的 139 个 Lua 测试文件、GCC ASan/UBSan、
三轮计时敏感终端回归和最终归档下载后的完整 PTY。
Linux x86_64 精确归档 `acb29dd1` 在本机另验两形态五 CLI、quick PTY、
三个 SDK 的功耗/占比与预热后挂死的六组真实 PTY；两个程序均通过普通权限
拒绝、root 当前 CPU 限制、功耗条、三个入口和 Snapshot/Agent 计算验收。
真实 Intel Sysman 在两形态读到 300 MHz、fresh 零限制掩码及唯一 PCI
合并，原采样时间一致；驱动缺失的 GPU 功耗域保持缺失。
aarch64 归档 `f370c154` 的本机检查为摘要与包内清单，运行证据来自上述
原生下载 CI。两个 Linux 归档的执行下限均为 glibc 2.38。
M4 精确归档 `3be52219` 的两形态通过五 CLI、原 200 列 GPU 时钟、功耗、
43 传感器、10 个 Mach CPU 身份和父设备导航。Windows 归档 `f6b778e7` 在
Windows 11 与 Server 2008 两形态通过五 CLI、80×25 无 ANSI 控制台、
13 个芯片缓存、AVX 状态、父级导航和三个功耗入口。macOS 部署下限及
Windows 11 个 PE 映像的 1,055 个命名导入静态门禁通过。
完整摘要和验收记录保存在 `build/hardware-gpu-continuity-20261016/`。
XP、旧 macOS、AMD SMI 真机和 Sysman 功耗域硬件仍缺少本轮运行证据。

2026-10-16 核对：三个 GPU SDK 隔离与 Sysman 修复提交 `6702c31` 的
[主 CI](https://github.com/Water-Run/wtop/actions/runs/38794231258) 16 个作业与
[Windows CI](https://github.com/Water-Run/wtop/actions/runs/38794231138) 两个作业
全部通过，包括两个 Linux 架构的 139 个 Lua 测试文件、GCC ASan/UBSan、
三轮计时敏感终端回归和下载最终归档后的完整 PTY。
Linux x86_64 精确归档 `12c47f48` 在本机另验两形态五 CLI、quick PTY、
三个隔离 SDK 的测试驱动功耗/占比，以及各驱动挂死时的页面导航和退出。
普通权限的拒绝状态、root 的真实 CPU 限制、功耗条、三个功耗入口与
Snapshot/Agent 百分比和剩余功率计算均通过。两形态也用真实 Intel Sysman
驱动确认 300 MHz、fresh 当前限制掩码及 PCI 合并；缺失的 GPU 功耗域未补值。
aarch64 归档 `8cbe5915` 的本机检查为摘要与包内清单，运行证据来自原生 CI。
两种 Linux 归档的执行下限均为 glibc 2.38；本轮 glibc 2.17 的源码构建、
`6702c31` 当时的 139 个 Lua 文件与三个 SDK 的原生隔离夹具另已通过。
M4 的精确归档 `2612277e` 两形态通过五 CLI、原 200 列 GPU 时钟、功耗、
43 传感器、10 个 Mach CPU 身份和父设备导航。Windows 归档 `5d745d25` 在
Windows 11 与 Server 2008 两形态通过五 CLI、80×25 无 ANSI 控制台、
CPUID/缓存与 AVX 状态、父级导航及三个功耗入口。macOS 部署下限与
Windows 11 个 PE 映像的 1,055 个命名导入静态门禁通过。
完整摘要和记录保存在 `build/hardware-vendor-workers-20261016/`。
XP、旧 macOS、AMD SMI 真机与带 Sysman 功耗域的设备仍缺少本轮运行证据。

2026-10-16 核对：`dcbd971` 的
[主 CI](https://github.com/Water-Run/wtop/actions/runs/38772147745) 16 个作业与
[Windows CI](https://github.com/Water-Run/wtop/actions/runs/38772147754) 两个作业
全部通过，包括 GCC ASan/UBSan、两个 Linux 架构下载最终归档后的完整 PTY。
Linux x86_64 精确归档 `21cb8a5a` 在本机另验两形态五 CLI、quick PTY、
独立 NVML 读取器、假驱动的功耗/占比与挂死驱动导航；普通权限的拒绝状态与
提权后的真实 CPU 限制、功耗条、三个功耗入口均通过。
aarch64 归档 `b56bb923` 的本机检查仅为摘要和包内清单，运行证据来自原生 CI。
两种 Linux 归档的执行下限均为 glibc 2.38；glibc 2.17 的源码构建另有实测。
M4 的精确归档 `2f0edbaf` 两形态通过五 CLI、原 200 列 GPU 时钟、功耗、
43 传感器与 10 个 Mach CPU 身份验收。Windows 归档 `b60a8696` 在
Windows 11 与 Server 2008 两形态通过五 CLI、80×25 无 ANSI 控制台、
CPUID/缓存父级导航与三个功耗入口。完整摘要与记录保存在
`build/hardware-nvml-worker-20261015/`。XP 与更早 macOS 仍缺少真机证据。

2026-10-15 核对：`4c8a09d` 的
[主 CI](https://github.com/Water-Run/wtop/actions/runs/38748001998) 16 个作业与
[Windows CI](https://github.com/Water-Run/wtop/actions/runs/38748002139) 两个作业
全部通过，包括两个 Linux 架构下载最终归档后的完整 PTY 验收。
Windows 精确归档 `33ef455d` 在 Windows 11 与 Server 2008 验收两种形态、
五 CLI、80×25 无 ANSI 控制台、原基本在线状态、硬件父级导航与三个功耗入口。
两种形态均实际启动包内 x64 CPUID 读取器，Snapshot、Agent 和分页详情核对
AMD 6 核/3 计算单元/AVX 不可用、Intel 4 核/8 线程/AVX 可用，以及 CPUID
13 个缓存实例与各自独立的 OS 报告。M4 的精确归档 `1dc631f8` 两形态通过
五 CLI、原 200 列 GPU 频率、时钟详情、功耗/IOReport、43 传感器与 10 个
Mach CPU 身份验收。Linux x86_64 归档 `cae79161` 在本机另验完整性、CLI/JSON
和两形态 quick PTY；aarch64 归档 `a6ed1c9b` 的本机检查仅为摘要与包内清单，
运行证据来自上述原生 CI。静态门禁核对 macOS 部署下限和 Windows 11 个
PE 映像的 1,055 个命名导入；可选 x64 读取器与主 x86 映像分别验证。
完整摘要和原始验收记录保存在 `build/hardware-cpuid-20261015/`。

2026-10-15 核对：`f5f22cf` 的
[主 CI](https://github.com/Water-Run/wtop/actions/runs/38731850859) 16 个作业与
[Windows CI](https://github.com/Water-Run/wtop/actions/runs/38731850813) 两个作业
全部通过。精确 macOS arm64 归档 `eb8918c4` 和 Windows x86 归档 `366fd05d`
在 M4、Windows 11、Server 2008 验收两种形态、五种 CLI、硬件导航和功耗窗口；
M4 保留原 200 列 GPU 频率断言，Windows 使用经典无 ANSI 控制台。
Linux x86_64 精确归档的完整性、CLI/JSON 与 quick PTY 通过；aarch64 归档
的下载运行验收由对应原生 CI 作业完成，本机只核对摘要、传输清单和包内声明。
macOS 与 Windows 静态门禁通过。完整摘要和日志在
`build/hardware-nvml-limits-20261015/`。

2026-10-15 核对：`dfbc192` 的
[主 CI](https://github.com/Water-Run/wtop/actions/runs/38721400428) 16 个作业与
[Windows CI](https://github.com/Water-Run/wtop/actions/runs/38721400562) 两个作业
全部通过。精确 macOS arm64 归档 `815afef8` 和 Windows x86 归档 `543539a6`
在既有三台主机上验收两种形态、全部 CLI、硬件导航和功耗窗口；M4 保留原
200 列 GPU 时钟严格验收，两台 Windows 使用实际经典无 ANSI 控制台。
Linux 精确归档的完整性、CLI/JSON 与 quick PTY 通过；平台静态门禁也通过。
完整 SHA-256 和日志保存在 `build/hardware-amdsmi-20261015/`。

2026-10-15 核对：`1b0b052` 的
[主 CI](https://github.com/Water-Run/wtop/actions/runs/38712039796) 16 个作业与
[Windows CI](https://github.com/Water-Run/wtop/actions/runs/38712040017) 两个作业
全部通过。macOS arm64 最终归档 SHA-256 前缀 `e5767596` 在 M4 验证两种形态、
全部 CLI、三个功耗窗口入口，以及原 200 列 GPU 表中的 `~755 MHz` 和频率详情；
Windows x86 最终归档前缀 `0c0d0edd` 在 Windows 11 和 Server 2008 验证两种
形态、全部 CLI、经典无 ANSI 控制台与功耗窗口。Linux 两种归档在普通用户与
已有 root 权限下均复验 CPU 当前/历史限制、Agent 和三个功耗入口，实际捕获
当前 PL1；权限不足的读数不显示条形图。静态门禁核对 macOS 11.0
部署下限和七个 PE32 i386 映像的 843 个命名导入。Linux 最终归档两种形态的完整性、原生身份、CLI/JSON 和 quick PTY 验收通过；
复核记录与原始日志保存在 `build/hardware-limit-reasons-20261015/`。

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

### 2026-10-16：混合 GPU 来源的连续观测

- 修复某个来源等待时，被另一个正常来源的新样本从清单中挤掉的问题。
  各来源保留独立观测，旧值标为 stale，保留实际时间；新读数优先。完整
  枚举确认移除和已知 DRM 身份变化会放弃旧关联，部分枚举仍可保留遗漏项。
- Snapshot 与 Agent 携带每来源、每指标的时间与保留标记。过期设备不进入
  当前利用率汇总或曲线，不挤掉 Agent 中有当前利用率的设备；旧功耗不生成
  正常占比。功耗详情显示读数年龄和原因，十种语言的状态标识通过回归。
- 额外负例覆盖只有当前功耗的健康 GPU 被旧利用率挤掉，以及旧厂商功耗
  遮住有效 hwmon 通道。修复后优先展示当前读数，传感器功耗只配对自己的
  上限和质量；过期身份/清单/通道不建立新关联，旧平均窗口不跟随新通道。
- 原负例实际失败后，混合三厂商、部分枚举、替换、成功响应的缺失字段、
  64 设备预算、停止/安全模式/文件系统/时钟回退及旧快照不被修改的测试通过。
- 三家真实隔离读取进程分别先正常出数，再通过测试 DSO 控制文件挂死，
  均经过 pending、timeout 和恢复：设备与旧值保持，时间不续期，其他厂商
  仍有新读数，主进程没有厂商库映射。三种场景的真实 PTY 同时验证过期标识
  可见、其他行正常、功耗/进程/系统导航与正常退出。
- 以上厂商故障由独立 SDK 夹具产生，不代表新增三厂商真机覆盖。证据保存在
  `build/hardware-gpu-continuity-20261016/`；原始终端记录位于
  `build/native-gpu-worker/*-warmed-stale.*`。
- 本轮并行验收还发现基线夹具共用固定临时文件的问题，以及缺失已指定 ELF
  时仍打印满足基线的错误结论。夹具改用独立临时路径；缺失输入现在计入
  无法测量项，不给出数值执行下限或通过结论。六个并发 Lua 5.4/5.5 进程的
  基线及发布证据测试通过，原失败日志保留在上述记录目录。
- 最终程序源码在本机 Lua 5.5、Lua 5.4 和 glibc 2.17 环境均通过 139 个
  测试文件；glibc 2.17 同时通过三个 SDK 的原生生命周期与故障夹具。
  目录包、单文件包、LuaRocks 安装版均通过三种预热后挂死的真实 PTY 场景，
  共九组。三种形态的本机 Intel Sysman 查询也都读到 300 MHz、fresh 零限制
  掩码、原采样时间和唯一 PCI 关联；驱动未暴露的 GPU 功耗域保持缺失。

### 2026-10-16：同步硬件 I/O 的阻塞负例

独立 FUSE 常规文件夹具确认 `native.readfile` 即使使用 `O_NONBLOCK`，仍会
等待约 1.2 秒。真实 TUI 在正常显示后，把一次传感器读取定向到该夹具；
终端已处于 raw 输入模式，`q` 仍等待约 1.2 秒，释放读取后正常退出。
夹具进程和挂载均已核对清理，未修改真实传感器文件。这是改动前的响应性
负例；首批隔离结果见下段。原始结果与终端记录在
`build/hardware-io-isolation-20261016/`。
`O_NONBLOCK` 的常规文件语义见 [open(2)](https://man7.org/linux/man-pages/man2/open.2.html)，
sysfs 读取调用设备属性方法的流程见
[内核 sysfs 文档](https://www.kernel.org/doc/html/latest/filesystems/sysfs.html)。

### 2026-10-16：首批 Linux 硬件 I/O 进程隔离

hwmon、cpufreq、powercap、CPU 当前限制、热节流计数、cpuidle 和热区的默认
采集现运行在独立进程；每个来源最多两个控制器，不能回收的读取占据自身
配额。读取器嵌入锁定的 Lua 与必要模块，完整执行现有采集器并保留自己的
计数和传感器历史。父进程不执行这些来源的文件读取，也不在失败时退回
同步读取。显式注入的采集器、时钟和文件系统继续使用调用方指定的实现。

每个请求限时两秒，失败后五秒重试。短于 100 ms 的正常等待不会制造图表
缺口；持续等待会把已有样本标记过期。测量时间与接收时间分别保留，图表
按测量时间记录，旧功耗不产生当前占比。过期传感器不再显示旧的正常或
告警状态，频率和空闲状态表也使用来源的过期状态。

本机验证了真实 FUSE 常规文件阻塞：读取尚未释放时，raw 模式下的 `q`
约 20 ms 正常退出。守护进程、读取进程、TUI 和挂载随后均核对清理。
自动夹具验证正常采样后挂死、超时回收、其他来源继续响应和重新采样；
RAPL 首次观测不编造瓦数，后续能量差值与真实窗口、25 W 上限的占比计算
一致，真实终端的功耗/进程/系统导航和退出通过。本地 GCC ASan/UBSan 的
同类进程夹具通过；运行库由已验签的 Fedora RPM 提取到任务目录，未安装
系统软件包。证据在 `build/hardware-io-isolation-20261016/`。

glibc 2.17 的 140 个 Lua 文件通过后，新增独立解释器验收暴露了退出崩溃：
旧加载器没有按原方式保活已经加载的模块，回收线程可能继续执行已卸载的
代码。现改为在进程生命周期持有一次加载引用；私有 userdata 也使用新的
结构版本。旧环境的三个 SDK 生命周期、硬件超时/恢复/功耗计算，以及三次
同时取消七个读取器的独立 Lua 退出均已通过。对应加载器行为的官方修复
讨论见 [glibc 维护记录](https://sourceware.org/legacy-ml/libc-alpha/2015-07/msg00434.html)。

这覆盖上述七类默认 Linux 来源。DRM/sysfs、固件及其余 Linux 读取仍需
隔离；macOS 和 Windows 的同步驱动调用尚未由本次改动隔离。`9b3f43b`
完整发布链与精确最终包已通过，范围见上方验证矩阵。

### 2026-10-16：共享 SMBIOS 输入隔离

七类读取器之外的 DMI 表仍能阻塞终端：使用实际 FUSE 常规文件替换一次
固件表读取，正常界面进入 raw 模式后按 `q`，仍等待约 1.2 秒，释放读取后
正常退出。这份负例保留在上一节的任务目录，挂载与进程已核对清理。

`f5fbc2a` 为 11 个 SMBIOS 视图共用一个原始输入读取器。传输有界的
二进制表和入口元数据，父进程继续共用一次批量解析，各视图保有独立结果
及能力状态；测量时间使用原始输入的读取时间。挂死时不会回退到父进程
文件读取，其他硬件来源仍可更新。单个视图关闭不会取消其他视图的输入，
读取器由 Engine 统一关闭。

本机真实 FUSE 阻塞下，释放 DMI 读取之前约 91 ms 正常退出。原生故障
夹具验证 11 个视图每批只读一次、原始时间一致、过期旧值、两秒超时回收、
五秒重试恢复及独立来源继续响应；八个异步读取器的三次独立 Lua 退出和
本地 GCC ASan/UBSan 通过。普通权限保留 denied，root 安装数据来自同一
输入时间。源码在 glibc 2.17 通过同类原生故障和独立解释器退出；目录包、
单文件包及源码 rock 的安装入口均通过共享输入和超时检查。最终 CI、四类
精确归档与提供主机复验全部完成，范围见上方验证矩阵。记录保存在
`build/hardware-smbios-isolation-20261016/`。

### 2026-10-16：默认引擎的平台封装回归

`8eb860c` 的精确 Mac 归档在完整主机复验中丢失了传感器：同机 `83ea2fe`
仍读到 43 个，新包为零且原因为 `hardware_worker_unavailable`。默认引擎
此前只按进程 API 是否存在启用 Linux sysfs/SMBIOS/DRM 封装；Mac 新增
同名接口后也进入了该分支。已使用注入采集器的隔离夹具绕过了这个默认
构造路径，因此此前的针对性数据与故障检查未覆盖这一回归。

该封装现限定在 Linux 上。新增默认构造检查要求 Darwin/Windows 保留
原采集器，Linux 仍使用隔离读取；去掉平台条件可复现检查失败。四个
针对性 Lua 文件及本机 Linux 默认采集通过；修复后的 Mac 目录包、单文件包
均恢复 43 个传感器，并保留七个功耗域、两组 CPU 频率、GPU 与真实窗口。
两种包的 CLI/quick PTY 和七个 Mach-O 部署检查通过。修复提交 `e76046a`
的主 CI 16 个作业、Windows CI 两个作业及四类精确归档验收已完成；
Linux、M4、Windows 11 和 Server 2008 的两种包均完成主机复验。
不把 `8eb860c` 记为完整主机通过。完整收据保存在
`build/hardware-macos-default-engine-fix-20261016/ACCEPTANCE.json`。

### 2026-10-16：macOS 三类硬件读取隔离（开发中）

CPU 频率、GPU 和功耗各自使用独立的原生读取进程，完整的 IOReport 订阅、
驻留/能量历史及共享 Lua 派生状态留在读取器内。单个来源超时保留旧数据和
原始时间，健康来源继续更新。新进程先预热，一次性导出会等有界的下一次
真实观测；私有预热提示不进入 Snapshot/Agent。Mac 单文件和目录模块中的
内嵌读取器也纳入 Mach-O 依赖与最低版本检查。

提供的 M4 上，真实 IOReport Energy Model 调用边界被暂停后，同步基线需
等约 5 s 放开调用才能退出。开发源码与两种安装包的冷启动、预热后阻塞
复验均在放开调用前退出，按 `q` 后实测约 25–72 ms，阻塞读取器已回收。
持续观测保持原功耗时间，CPU/GPU 继续更新；约 5.46 s 后重新预热并恢复，
137.348 ms 的实际能量窗口与功耗计算一致。强制终止父进程时，读取器与
其私有文件约 17 ms 内消失，测试仍保持 API 阻塞。

新增原生传输门禁不要求机器提供功耗/GPU 数据：验证三个进程、单调时间、
暂停后的超时回收、独立轮询、恢复、错误配置、文件清理和三次解释器关闭。
该门禁、现有八项 Mac 原生夹具、两种包五 CLI/quick PTY 和七个 Mach-O
检查已通过。本机 142 个 Lua 文件、原生 ASan/UBSan、glibc 2.17 原生来源
通过。后继修复 `e76046a` 的精确 CI/归档已验收，M4 两种归档内程序的四组
真实阻塞退出约 27–69 ms，均在释放 API 前回收读取器。
其他 Mac 采集器及 Windows 的同步驱动路径仍在后续范围内。

旧 libc 回归暴露了另一项竞争：控制线程并发查询不存在的可选符号时，
glibc 2.17 的加载器错误存储可能与 Lua 关闭动态库同时释放；其
[实现保留了共享错误缓冲区回退](https://github.com/bminor/glibc/blob/glibc-2.17/dlfcn/dlerror.c)。
现在线程启动前解析该符号并清空错误状态。同一保存的环境中，修复前再次
出现 fasttop 重复释放，修复后 100 次关闭、每次十个读取器通过；完整旧
libc 原生流程也通过。失败日志、对照构建和实际主机记录保存在
`build/hardware-macos-io-isolation-20261016/`。

### 2026-10-16：macOS HID/SMC 传感器读取隔离

传感器作为第四个 Mac 硬件读取进程，原生 HID/SMC 状态、通道身份和 Lua
会话统计均留在读取器内。超时保留旧通道、原始时间和统计次数；其他三类
来源继续更新。重新启动的读取器从首个有效直接样本重建最小/最大/平均值，
不把新旧进程的统计拼接在一起。

提供的 M4 上，分别暂停真实 `IOHIDServiceClientCopyEvent` 与 hwmon 的
`IOConnectCallStructMethod` 调用。同步基线会等待约 5 s 释放调用；开发
源码及两种本地包的冷启动与预热后故障均在释放前退出，八组包内复验按
`q` 后约 26–85 ms，阻塞读取器已回收。HID 与 SMC 连续观测各自验证旧值、
时间和统计不变，健康功耗、CPU/GPU 时间推进；恢复后统计从 1 到 2，
恢复并取得第二样本约 7.4 s。SMC 调用仍阻塞时强制结束父进程，读取器及
其私有文件约 16 ms 后消失。

两种包均保留 43 个传感器、七个功耗域、两组 CPU 频率及 GPU，传感器
详情与终端响应通过。现有八项 Mac 原生夹具、四读取器传输/回收门禁、
两种包五 CLI/quick PTY 和七个 Mach-O 部署检查通过；单元夹具另检查
独立传感器读取和进程内统计重建。后继 `68dba87` 的主 CI 16 个作业与
Windows CI 两个作业、四类最终归档及现有主机复验均已完成。精确 Mac
包的八组传感器阻塞退出约 26–67 ms；HID 与 SMC 的恢复及第二样本分别
约 7.30/7.45 s，强制结束父进程后读取器与私有文件约 12 ms 清理。两种包
均有 43 个 fresh 通道及会话统计。本机两种 Linux 包的实际功耗、20/26/114 W
约束、占比和三个功耗入口，以及 Windows 11/Server 2008 的两种包复验通过。
完整收据为该目录的 `ACCEPTANCE.json`。记录保存在
`build/hardware-macos-sensor-isolation-20261016/`；其他 Mac 来源、Windows
同步驱动读取、XP 与旧 Intel Mac 运行时仍在后续范围内。

### 2026-10-16：终端逐帧样式比较开销

M4 的采样区分了语言目录校验等启动成本与持续刷新。排除前 3 s 后，Lua
指令采样的主要位置包括网格、宽度计算和差分渲染的样式比较；原生网络
枚举也有可测开销。源码候选在每帧内只复用最后一对样式的比较结果，空间
固定，下一帧重新比较。不同表但等价的样式仍不输出多余内容；帧间改变
颜色、索引或任一属性会触发重绘。

用原算法与候选处理同一真实网格，逐帧核对光标位置、文字、终端宽度、样式
及重绘元数据。Linux 11 个会话共 54 帧、M4 11 个会话共 74 帧，以及
Windows 11/Server 2008 各两种经典控制台配置共 72 帧，全部一致。覆盖
16/256/RGB、无色 ASCII、主题切换、调整尺寸、页面/功耗导航和信号退出。
Windows 的只读测试运行时也通过五个 PE 镜像检查；这不是 XP 运行证据。
九项样式属性和 RGB/索引颜色的帧间修改夹具通过 Lua 5.4/5.5。

同一 M4、同一 Lua 和精确 `68dba87` 原生模块下，基线/候选/候选/基线各
观测 15 s，180×45 总览、1000 ms 刷新、四个读取器保持不变。主进程占
一个核心的均值约从 5.92% 到 5.51%，短时相对下降约 6.9%。该观测不证明
旧硬件预算达标，也不是各终端尺寸的性能承诺。精确提交 `cd87b5a` 的主 CI
16 个作业、Windows CI 两个作业、四类最终归档及提供主机复验均已完成。
同一 M4 的精确目录包按基线/候选/候选/基线各观测 20 s，主进程单核占比
均值约从 5.61% 到 5.08%。这里仍是短时配对观测。完整收据与记录保存在
`build/hardware-renderer-style-pair-20261016/`。

### 2026-10-16：macOS 网络读取隔离

网络作为第五个 Mac 硬件读取进程，完整原生读取、接口身份、64 位计数器及
Lua 速率基线留在进程内。原生接口仍在读取前后复核 IOKit 实例、接口索引和
唯一 PCI/USB 祖先，不减少复核次数。等待或超时时保留旧接口、速率和原始
采样时间，接口表单独显示过期与来源原因；新进程的首个观测只建立基线。

在提供的 M4 上暂停实际 `sysctl(NET_RT_IFLIST2)` 数据读取，同步基线首次
绘制要等待约 5 s 释放调用，预热后的 `q` 实测等待约 2.9 s。源码原型与
两种本地开发包的冷启动/预热后复验均在释放调用前退出，包内六组检查按
键后约 28–44 ms，阻塞读取器已回收，接口表的过期提示也已实测。

连续观测验证旧对象、时间和速率不变，功耗、CPU/GPU 和传感器继续更新；
恢复后先无速率，再按新进程自己的约 1.047 s 窗口取得有效速率，计数差值
计算一致。恢复并取得第二样本约 6.26 s。父进程被强制结束时，仍阻塞的
读取器与私有文件约 13 ms 清理。默认引擎及两种包保留 25 个接口、三个
网卡父设备、43 个传感器、七个功耗域、两组 CPU 频率与 GPU；接口清单与
独立 `ifconfig` 枚举一致。五 CLI、快速 PTY、五读取器生命周期/故障检查
和七个 Mach-O 部署检查通过。

同一解释器与原生构建下，以是否启用网络进程作四轮 20 s 对照，180×45
总览、1000 ms 周期保持不变。主进程单核占比均值约从 5.24% 到 4.36%，
进程族合计约从 8.23% 到 8.45%；逐进程 footprint 合计的观测范围重叠。
这是为阻塞时的响应能力付出的实测资源取舍，不证明旧设备预算达标。
上述为源码和本地开发包证据，`4f51aa3` 的精确归档复验见验证矩阵；记录保存在
`build/hardware-macos-network-isolation-20261016/`。其他 Mac 来源、Windows
同步调用、XP 与旧 Intel Mac 运行时仍在后续范围内。

### 2026-10-16：Windows 处理器组与频率采样

频率策略按 PDH 返回的处理器组和组内编号建立，保留两个编号并关联全局
逻辑 CPU ID，不再以当前组的 CPU 数量截断其他组。名称必须完整有效；
重复项、无穷值、NaN、零比例和越界 Hz 不生成当前频率。最多保留 512 项，
超出时报告截断。XP 兼容的电源信息回退按返回的 Number 匹配，只有单组
时采用，不把没有组信息的结果猜配到多组 CPU。

PDH 第一次采集标记预热，至少间隔 1 s 后取得第二样本；DWORD 计时回绕
保持有效。查询失败、数组缺失或处理器组拓扑变化会关闭旧查询并重新预热，
不会把先前格式化的值作为新样本。电源计划名称每次采样查询一次，在构造
Lua 结果前释放系统分配的 GUID，数组也在任何结果分配前释放。

Windows 11 与 Server 2008 上，共享生产实现的 33 个确定性 Win32 API
场景通过，覆盖组/边界/重排/冷启动/回绕/故障/拓扑变化和 Lua 内存不足。
每台机器扫描 180 个分配失败位置，33 次内存不足和 147 次成功调用后，
系统对象、数组和查询的释放断言均通过。七项原生夹具、八/六 CPU 实际
读数、五 CLI、Snapshot 组编号及可见的经典控制台 GHz 表也通过。
首次重复终端夹具因 XDG 路径不适用于 Windows 而复用了旧布局；改用独立
APPDATA 后两台主机重验通过，原失败日志保留。控制台 CI 同步修正路径。

PDH 是 Windows 性能计数器视图，电源信息回退标记 estimated，均不冒充
APERF/MPERF 的独立计数窗口测量。频率表分别显示 PDH 和 PowrProf 来源，
导出同时保留来源字段。多处理器组目前是夹具证据，未提供真实
多组机器；XP 也未实测。新提交的 CI/最终归档另验，源码记录位于
`build/hardware-windows-frequency-groups-20261016/`。

### 2026-10-16：Windows 频率读取进程隔离

默认程序入口配置读取器启动路径。源码使用当前解释器和入口脚本，目录包与
单文件包使用程序自身；子进程在 CLI 和终端启动前进入读取循环，保留完整
Portable 采集器及原生 PDH 状态。父进程只复制有界结果，不等待驱动调用。
消息检查来源、序号、标志、长度、摘要和时间窗口；关闭和 Lua 内存不足均
有独立的帧/任务所有权，只有进程句柄确认退出后才释放读取器名额。

两台提供主机的同步基线在电源 API 阻塞时约 3.0–3.3 s 才能响应退出。
源码和两种私有包暂停实际电源或电源计划调用后，冷启动和预热场景仍可
绘制并退出。包内 20 项阻塞/父进程结束检查通过，按键退出测得约 60–62 ms，
父进程强制结束后约 4–11 ms 完成相应检查，读取器均先于解除阻塞退出。
辅助程序的发键函数含固定 60 ms 等待，因此该按键测量不用于推导更细的
界面延迟或旧设备性能预算。

挂起和崩溃时，旧对象、读数与测量时间保持不变，健康内存来源继续更新；
新 PID 在约 5.1–6.4 s 后恢复，PDH 重新预热。初次 PDH 查询或计数器打开
失败且 API 可用时每 5 s 重试；API 缺失时保留旧系统估算回退。35 项频率
夹具验证该行为，180 个 Lua 分配失败位置仍有 33 次内存不足与 147 次成功。

26 项原生传输场景覆盖消息损坏、截断、超时、提前退出、策略变更、过期帧、
创建失败和两读取器上限。48 个 Lua 分配失败位置、五处 C 分配失败及十二轮
并发关闭均检查自有句柄、临界区、C 内存和名额归还；另持有子进程句柄确认
实际退出。进程总句柄包含 Windows/CRT 延迟初始化资源，作为独立观测保留，
不代替自有资源守恒检查。原始失败和修正后的证据均保存在
`build/hardware-windows-frequency-isolation-20261016/`。

`50f716c` 的 18 个 CI 作业、四类精确最终归档与提供主机验收均已完成。
真实 XP/多处理器组硬件与旧设备预算仍在后续范围内。

### 2026-10-16：Windows GPU 与温度读取进程隔离

频率、GPU、温度各有独立来源编号和两个读取器名额。完整 Portable 采集器、
原生查询及缓存留在相应子进程；单一来源用满名额时，其他来源仍可启动。
协议拒绝属于另一个有效来源的响应。现有 GPU 与温度算法保持不变，本次
没有新增 GPU 功耗提供者。

Windows 11 和 Server 2008 的默认入口均启动三个不同 PID，保留八/六 CPU、
同一个 SetupAPI 显卡标识和实际测量时间。Windows 11 保留一个 ACPI 温度
通道；Server 2008 继续报告 `thermal_zone_counters_unavailable`。两种私有
包在两台主机通过五 CLI、结构校验、可见频率表、经典控制台导航与退出。

故障钩子只用于独立测试包，暂停真实的显示适配器 SetupAPI 枚举、热区 PDH
计数器打开或采集。GPU 预热场景等待实际 15 s 缓存到期；温度预热故障只
在具有热区的 Windows 11 验证。七组同步基线等待约 3.0–3.35 s；源码十二组
隔离检查和两种包共 24 组退出/父进程检查均在释放阻塞前回收读取器。包内
按键测量约 60.9–62.3 ms，父进程检查约 3.1–11.3 ms；发键辅助程序包含
固定 60 ms 等待，不能据此推导更细的界面延迟。

六组挂起/崩溃连续观测保留旧数据对象与测量时间，挂起期间其他两个来源
继续刷新，新 PID 约 5.1–5.4 s 后恢复。29 项原生传输场景新增三来源并行、
名额独立和错误来源拒绝，保留分配失败、并发关闭与自有资源守恒检查，
在两台主机通过。

相同源码、原生模块和解释器作 ABBA 四轮对照，频率读取器始终启用，
对照仅关闭 GPU/温度的隔离描述；80×25 无颜色经典控制台，每轮预热 5 s、
采样 20 s。Server 2008 进程族单核 CPU 均值约 2.14%→1.90%，私有提交
总量约 38.19→50.63 MiB；Windows 11 约 2.95%→3.14%、43.10→57.13 MiB。
工作集求和会重复计算共享页；该短时观测不是旧硬件性能预算认证。辅助
程序失败、按 PID/创建时间核实后的清理及有效重测记录均保留。

证据位于 `build/hardware-windows-gpu-thermal-isolation-20261016/`。
`make check`、143 个 Lua 5.5 测试文件及 Lua 5.4 定向测试通过。上述为源码
与私有开发包证据；`48b0145` 的精确 CI/最终归档及提供主机验收已完成。XP、真实多处理器组、
旧 Intel Mac 和未提供的厂商功耗硬件仍未
新增实测证据。

### 2026-10-17：绘制分配与包内回收模式

程序入口在加载 CLI 或读取器之前选择分代回收，与官方 Lua 命令行入口一致。
目录和单文件包的嵌入式状态此前使用增量回收；源码启动已采用分代模式，因此
源码的内存数据不能替代包内观测。网格复用当前帧的单元格，快照仍复制单元格；
覆盖、清除及窄字符快速路径会清理宽字符的 continuation/lead_x 元数据。

候选的 CLI 和绘制定向测试在 Lua 5.4/5.5 下通过，两种 ABI 的 18,000 次
确定性编辑对照核对单元格、脏区、快照与差分输出。旧入口和缺少元数据清理的
初版候选会触发回归失败。Win11、Server 2008 和 M4 的完整候选源码也各通过
同组网格对照、绘制和 CLI/入口检查；最终归档仍需单独验收。

主源码的 `make check`、Lua 5.4/5.5 各 148 文件回归和 PTY 检查通过。
本机源码的 Snapshot/Agent/Report 与终端检查保留 16 线程、10 核心、28 缓存
及两类硬件核心；逐 CPU 身份和缓存关系与内核报告一致。

本机另取 `b013088` 的 Linux 载荷和原生模块，用同一本地 Lua 5.5 静态库
重链接两份私有程序，候选只替换上述入口与网格。在 120×34、1 s 周期、
总览和进程页各 12 s 窗口中做四轮 ABBA，观察器 UID 为 0，程序 UID 为 1000。
约 640 个可见进程时，进程族 CPU 均值由 5.66%/6.95% 到 5.53%/5.48%，
平均 PSS 由 69.05/73.66 MiB 到 53.95/67.16 MiB；两轮采样峰值原版为
84.10/73.81 MiB，候选为 71.69/71.81 MiB。首帧均值为 186.94/188.11 ms，
没有改善；进程页切换 p95 为 5.89/9.65 ms，不据此声称延迟改善。

再加入 382 个有界空闲进程，四轮观测的可见进程数为 1023–1027。CPU 均值
由 6.10%/7.78% 到 5.44%/6.49%，平均 PSS 由 69.30/76.81 MiB 到
56.45/70.16 MiB；原版采样峰值为 87.61/87.36 MiB，候选为 80.09/71.89 MiB。
切页均成功，临时进程全部回收。原始样本、方法、源文件、库与工具哈希保存在
`build/performance-renderer-gc-20261017/`。这些是本机短时私有对照，不是最终
发行包或旧硬件预算证明；2% CPU 与 60 MiB 目标仍未达到，完整回归和最终
产物验证已完成，性能与完整硬件目标继续推进。

实现提交 `1fb428e` 的 [主 CI](https://github.com/Water-Run/wtop/actions/runs/39006864026)
16 个作业与 [Windows CI](https://github.com/Water-Run/wtop/actions/runs/39006864096)
两个作业全部通过，含两种 Linux 架构的下载后完整终端矩阵和 ASan/UBSan。
本地 `make check`、148 文件的 Lua 5.4/5.5 回归和终端检查通过，四类精确
归档、五项产物/主机验收及源码审计通过。本机两种包保留 CPU 拓扑/缓存、
20/26/114 W 限制、功耗占比、有效频率和温度余量；两台 Windows 的两种包
及 M4 两种包保留现有控制台、硬件和功耗采集。上述私有对照仍不替代最终包
的目标硬件性能预算，旧硬件和完整 HWiNFO 覆盖继续推进。

### 2026-10-17：进程族性能测量与启动开销

性能工具升级为 `measurement_version = 4`。旧版本只读取主 PID 的 CPU 和
RSS，无法代表隔离读取器的总成本。受控的忙碌子进程占满约一个核心并持有
32 MiB 内存时，旧方法仍报主进程约 0% CPU、约 13 MiB RSS；回收后的
1.22 秒子进程 CPU 也未计入。新工具按 PID/启动时间、线程子进程关系及已等待
子进程计数取样，检查前后名册和回收变化；旧内核可回退到有界 PPID 扫描。

内存分别记录采样 PSS、私有驻留量和 RSS 总和，主进程 VmHWM 单独保留。
32 MiB 共享映射的回归确认，子进程回收会令 RSS 总和下降，但 PSS 总量基本
不变。缺失、拒绝和采样竞争不补零；HugeTLB 不可确认或不为零时，PSS 预算
不会通过。这里只覆盖已观察的后代及完整等待链的 CPU，不宣称捕获未观察到的
守护进程逃逸或两次采样之间的绝对内存峰值。

读取器保持 `PR_SET_DUMPABLE=0`，普通权限可能无法读取其 `smaps`。CPU 和
内存状态分开；需要完整内存观测时可由有权限的观测脚本配合 `--target-uid`
启动普通用户的被测程序。启动文件也按目标用户权限检查，观测脚本随后恢复
自身权限。记录包含程序指纹、观测脚本哈希、运行 UID、原始窗口/取样、采样
周期和观测 CPU 开销。预算拒绝旧协议、口径/UID 不符、数据缺失以及观测间隔、
窗口或自身开销超限的结果；它仍需由目标硬件给出实际预算。

程序本身也减少了固定文本格式化和目录校验的开销：无插值文本在保留输入
检查后走快速路径，字符串键使用原生排序，异常键保留原比较方式。
17,577 个内置文本及边界样例在 Lua 5.4/5.5 下与原实现逐项一致。
本机 120×34、普通用户、同一源码/原生模块的 ABBA 短时观测中，组合修改
首帧均值约由 254.1 ms 到 170.5 ms；Overview/Processes 的进程族 CPU 约为
5.61%/5.58% 与 5.64%/5.40%，翻页 p95 结果有波动，不据此声称稳态 CPU 或
所有输入延迟改善。完整方法、源码哈希与原始样本位于
`build/performance-process-family-20261017/`。这不是最终包、1000 进程、旧硬件
或跨平台性能预算证明；完整回归和最终产物验证已完成。

实现提交 `b013088` 的 [主 CI](https://github.com/Water-Run/wtop/actions/runs/39003222213)
16 个作业与 [Windows CI](https://github.com/Water-Run/wtop/actions/runs/39003222223)
两个作业全部通过，含两种 Linux 架构的下载后完整终端矩阵及 ASan/UBSan。
本地 148 文件套件在 Lua 5.4/5.5 下通过，Python 3.6.15 的真实进程族、旧
procfs、共享内存、回收竞争和门禁回归通过；三台提供主机的目录/格式化源码
检查也通过。首次完整套件发现新增辅助工具漏入发布工具清单；补齐分类后
重跑通过，失败记录保留。远端源码测试包缺依赖的问题另行修正并复验。

四类精确归档的摘要、载荷、原生格式和许可核对通过，五项最终包/主机验收及
源码审计均通过。本机保留 16 线程/10 核心/28 缓存、各档功耗墙与占比、有效
频率和温度余量；两台 Windows 的两种包保留经典控制台、共享 CPU 读取器和
存储路径，M4 两种包保留 43 个传感器及七个功耗域。当前记录仍不证明旧硬件
或 1000 进程的目标预算，性能目标和完整 HWiNFO 覆盖继续推进。

### 2026-10-17：现代 AMD CPUID 拓扑与核心类型

开发源码已解码 AMD 的 `80000026` 扩展层级、`0B` 和 `80000008`/`8000001E`
回退。按 APIC 地址域分组已观察的线程、核心和封装；诊断容量不作为在线人口。
确定性缓存按共享地址域归并并检查几何与成员关系，原有 AMD15h CMT 语义保留。
`80000026` 的原生枚举与 TopologyExtensions 标志分开，旧缓存和 `1E` 仍检查该标志。

拓扑依据 [Linux 的 AMD 拓扑说明](https://www.kernel.org/doc/html/latest/arch/x86/topology.html)，
字段依据 [EDK2 的 AMD CPUID 寄存器定义](https://github.com/tianocore/edk2/blob/2c8ab5c4cfd11320b7447ee19358453e4e26e9ed/MdePkg/Include/Register/Amd/Cpuid.h)。
核心类型与功耗效率排序值分开，后者只在有效标志为真时保留；零值有效，
不按排序值推算瓦数或即时性能。Snapshot、Agent、报告、Compute 与线程详情
保留类型、原生模型、来源和适用的排序值；同核线程类型冲突会标记部分结果。

[hwloc 的四组上游硬件记录](https://github.com/open-mpi/hwloc/tree/1bc29f95a41330d5e2e1a623920365480ce9897e/tests/hwloc/x86)
经有界重封装后，与独立 XML 的每个封装、核心、缓存成员及容量、缓存行逐项
比较：Zen/Zen3/Zen4/StrixPoint 分别为 96/128/384/24 个逻辑 CPU、48/128/192/12
个核心、2/2/2/1 个封装及 160/400/600/38 个缓存实例。StrixPoint 两类核心为
4 核 8 线程和 8 核 16 线程。来源、原文件与派生文件哈希及 BSD 许可位于
`tests/fixtures/cpuid/amd/`；回放中的传输和亲和性标志为合成包装，未采得 XCR0，
不作为 wtop 的真实 AMD 亲和性、OS 指令可用性或主机验收证据。

原生捕获回归、APIC/层级矛盾、诊断数量、排名有效性、不完整名册及 384 CPU
的 Windows 协议坐标已有定向检查。完整源码、最终归档与现有主机回归已完成；
本轮未取得现代 AMD 主机的原生实测。任务记录位于
`build/hardware-amd-cpuid-20261017/`。

实现提交 `39effdc` 的 [主 CI](https://github.com/Water-Run/wtop/actions/runs/38996243931)
16 个作业及 [Windows CI](https://github.com/Water-Run/wtop/actions/runs/38996243865)
两个作业全部通过，含两种 Linux 架构的下载后完整终端矩阵及 ASan/UBSan。
本地 148 文件套件在 Lua 5.5、5.4 下均通过，原生/严格警告及快速终端检查通过。
首次完整回归发现新增翻译原因码的位置与显示清单不符；修正十个目录和原因清单，
保留失败记录后重跑通过。过期样本中的核心类型行一同标为过期，相关反例与
修复后的导出检查已通过。九个夹具/参考/清单文件可从固定上游原文逐字节重建。

四类精确归档的 SHA-256、载荷、原生格式和许可已核对，五项最终验收与源码审计
均通过。本机两种安装包保留 16 线程/10 核心/28 缓存、功耗墙占比和温度余量；
两台 Windows 保留共享 32/64 位读取器、经典控制台与存储功能；M4 两种包保留
43 个传感器和七个功耗域。以上主机覆盖仍不包含现代 AMD 处理器；寄存器回放、
共享原生代码回归与新硬件实测各自保留范围，见任务目录 `ACCEPTANCE.json`。

### 2026-10-17：Linux x86 芯片级 CPUID

Linux x86 开发构建通过独立硬件读取进程取得逐逻辑 CPU 的 CPUID、XCR0、
APIC、拓扑、确定性缓存和指令能力。与 Windows 共享有界的指令枚举层；
Windows 原有 v1 数据协议保留，Linux v2 使用真实 Linux CPU 编号，不生成
Windows 处理器组。读取器只绑定自身线程，读取前后核对实际 CPU 与签名，
恢复后再次核对完整亲和性；主程序不执行原始 CPUID 或修改自身亲和性。

[Linux 的亲和性接口](https://man7.org/linux/man-pages/man2/sched_setaffinity.2.html)
以线程为单位且受 cpuset 限制；不能读取的 CPU 保留失败状态，不借用另一
CPU 的叶数据。支持范围、稀疏编号和输出有界，超时/分配失败/恢复失败给出
独立原因。只查询 [CPUID 故障策略](https://man7.org/linux/man-pages/man2/arch_prctl.2.html)，
不会重新启用读取线程已禁用的 CPUID。32 位 Linux 的 SSE OS 状态未独立证实
时保留未知；扩展状态按 [XCR0](https://www.kernel.org/doc/html/v6.0/x86/xstate.html)
核对，不把硬件位等同于系统可用性。

CPUID 作为独立硬件视图保留，Linux 内核的拓扑、缓存和核心分组不被覆盖；
静态结果在父进程缓存，成功后回收读进程。按 CPU 成员关系和缓存几何逐项比较。只有名册齐全、身份/几何完整时才给出
一致或不同，缺少证据保留未知。失败保留同一名册的旧能力与原始时间、标为
过期，旧结果不生成当前一致性判断；CPU 名册、身份或时钟纪元变化则重建。

本机 i7-13620H 普通权限下采得 16 个逻辑 CPU、10 个物理核心、28 个缓存实例，
拓扑和缓存均与内核报告一致。逐 CPU 的 CPUID.1A 为 12 个 Intel Core 逻辑 CPU
（6 个物理核心）及 4 个 Intel Atom 逻辑 CPU（4 个物理核心）；类型解释依照
[Intel 的 CPUID.1A 说明](https://www.intel.com/content/www/us/en/developer/articles/guide/12th-gen-intel-core-processor-gamedev-guide.html)，
不按类型编号大小推断性能。原始记录位于 `build/hardware-linux-cpuid-20261017/`。

独立原生夹具已检查稀疏编号到 1048575、掩码扩展、亲和性/身份/恢复失败、
超时、分配失败和 Lua OOM；实际禁用指令的线程仍能返回禁用原因。真实读取
API 等待十秒时，旧时间保留且独立传感器继续刷新，读取器在解除阻塞前回收，
恢复后重取新样本；父退出场景约 0.14 秒完成。传感器独立性使用可控文件夹具，
不据此声称取得额外物理温度。Windows 共享模型和 32/64 位帮助程序编译通过，
完整回归与精确产物验证已完成；AMD 更新拓扑、非 x86、32 位 Linux 和大规模
CPU 真机覆盖保留各自的未验证边界。

Ubuntu 22.04 的 Clang 14 头文件将 `__get_cpuid_max` 声明为有符号返回值，
初始 `c8d127f` 的严格检查因此失败。保留原诊断，在同版 Clang 14.0.0 独立复现；
改为显式 32 位寄存器转换后，同组选项编译通过，没有关闭警告规则。
`ea246ac` 的 Linux 双架构检查随后暴露测试阻塞夹具忽略 `fscanf` 返回值，
强化头文件将其作为错误；在 Ubuntu GCC 13 的同一强化选项下复现，检查
返回值后编译通过。该测试工具默认启用 `_FORTIFY_SOURCE=2`，原生阻塞/恢复/
退出场景再次通过，原错误记录保留。修复后的
实现提交 `6593c66` 的 [主 CI](https://github.com/Water-Run/wtop/actions/runs/38991219700) 16 个作业与 [Windows CI](https://github.com/Water-Run/wtop/actions/runs/38991219615)
两个作业全部通过，含两种 Linux 架构的下载后完整终端矩阵、ASan/UBSan 和
重复时序检查。本地两种 Lua ABI 的 147 文件套件、严格警告、原生和快速 PTY
检查通过；独立 Ubuntu GCC 13 的 ASan/UBSan、泄漏检查及真实禁用指令保护通过。

四平台精确归档已核对 SHA-256、载荷、原生格式与许可。两种 Linux 包在普通用户
下均取得相同的 16 CPU、10 核心和 28 缓存，逐 CPU APIC/身份与内核对照通过，
Snapshot、Agent 和报告包含相同证据；有效频率的普通用户/root、200×60/80×25
详情保留。两台 Windows 的目录包与单文件包继续通过五种 CLI、共享 CPUID、
硬件导航、Storage/SMART 和经典控制台；M4 两种包保留 43 个传感器通道及七个
功耗域，Linux 的 14 个 CPU/NVMe/DIMM 临界温度通道与余量显示保留。五项精确
验收和最终源码审计均通过，见同目录的 `ACCEPTANCE.json`。

同一源码、同一原生模块只切换 CPUID 开关，在 200×60 Compute 页作 ABBA
短时观测，每轮预热 5 秒、采样 20 秒。进程族单核 CPU 均值约 8.28% / 8.45%，
私有驻留内存均值约 55.04 / 55.37 MiB，稳态进程数量均为 11；计入已回收子进程
CPU，内存按私有驻留/PSS 观察，不将工作集求和作为独占内存。该结果只对应
记录的源码/原生哈希和本机负载，不作性能改善、冷启动成本或旧硬件预算证明。

### 2026-10-17：Windows AMD ADL 只读采集

Windows 开发构建增加 AMD ADL1/ADL2 独立读取器，主程序仍为 32 位，读取器随
本机选择 32/64 位。只从系统目录加载已安装驱动，SDK 加载、枚举和读取在
受看门狗约束的子进程执行。AMD、Intel、NVIDIA 与磁盘等来源分别占用名额，
AMD 查询失败不阻塞其他来源。没有新增调节、超频、显示激活或驱动安装命令。

采用 [AMD ADL SDK 固定声明](https://github.com/GPUOpen-LibrariesAndSDKs/display-library/tree/84c881cb2136f04287eb3af12de00a9e2867aa9e/include)，
所有使用结构的大小、对齐和字段偏移均以独立上游声明校验 Win32/Win64；
API 使用 cdecl、分配回调使用 stdcall。原始时钟按 10 kHz、温度按毫摄氏度
转换；[Overdrive6 当前功率](https://gpuopen-librariesandsdks.github.io/adl/group__OVERDRIVE6API.html)
类型 0 是 ASIC 功率，以 8 位小数换算瓦数，在功耗详情和导出保留芯片范围。
功耗调节百分比不作为瓦数上限，因此该来源单独不生成占比或到功耗墙的余量。

适配器通过 PCI 地址与经核实的厂商/设备标识关联。读取后再次枚举确认索引
未被复用；同地址显示别名去重，矛盾身份、无终止符、异常数值及未填写输出
不用于显示。当前提供的旧 Radeon 驱动在服务会话中报告未显示的重复记录，
温度和频率等读取返回无效适配器索引且不导出当前功率入口；程序保留诊断，不生成
第二张假显卡或 0 W。本轮不据此声称已取得 Radeon 真实物理功耗。

Windows 11 与 Server 2008 各通过 132 项独立 ADL1/ADL2、32/64 位场景，
覆盖 10 kHz/毫摄氏度/定点瓦数、合法零瓦、无权限、不支持、未填写输出、
重复/冲突身份、枚举重排、索引复用及加载/初始化/读取阻塞和异常。两个主机
分别通过两项缓存字节固定、篡改拒绝与恢复检查，以及四项预热后阻塞/父退出
检查；旧功耗与观测时间保持、真实 CPU 频率继续刷新，读取器按 PID/创建时间
核实在十秒阻塞结束前退出。原生传输的 49 项资源、协议与独立额度检查通过。

两主机的 80×25 无颜色经典控制台在概览、Compute、GPU 三个功耗入口均显示
夹具 22.5 W 和 GPU 芯片范围；瓦数上限和百分比显示缺失。该画面不把电源
调节量当作分母。标准 Windows 构建的 11 个 PE、945 个命名导入静态检查通过。

本机 Linux 同轮 root 实采 CPU 封装约 19.25 W，MMIO 的 20 W 持续限制对应
96.25%、约 0.75 W 余量；另有 26/114 W 限制。封装限制寄存器独立报告 PL1
当前有效，不把高占比本身当作限频证据。终端中实测瓦数、三档上限、百分比条
和余量已核对。这是该时间窗口的一次读数，不是负载基准或性能预算。

验证原始记录位于 `build/hardware-windows-adl-20261017/`。独立 SDK 夹具的
22.5 W 等数值只用于验证接口、ASIC 范围和单位，不能替代厂商硬件实测。
XP、真实经典 CMD、广泛厂商驱动和旧硬件预算仍需各自的运行证据。

实现提交 `f2b91f8` 的 [主 CI](https://github.com/Water-Run/wtop/actions/runs/38980981063)
16 个作业及 [Windows CI](https://github.com/Water-Run/wtop/actions/runs/38980981056)
两个作业全部通过，包含两种 Linux 架构的下载后完整终端矩阵、内存检查和
重复时序检查。两种 Lua ABI 的 146 文件套件已通过；本地 Lua 5.5 首轮仅因
文档仍写 145 而失败，当前计数修正后的定向复验与精确 CI 完整套件通过，
原记录保留。Windows CI 另通过 132 项 ADL SDK 场景和四项 API 生命周期检查。

四类精确归档已核对外层/载荷 SHA-256、原生格式及许可；两种 Windows 包共
核对 23 个 PE 和 1969 个命名导入，三个厂商读取器的位数、声明摘要及许可
均匹配。两台 Windows 上的目录包和单文件包通过五种 CLI、JSON、硬件导航、
Storage/SMART、经典控制台及 ADL 实际降级检查。M4 两种包保留 43 个传感器
通道和七个功耗域；Linux 两种包通过普通用户/root 下的功耗墙、有效频率、
原生故障和 30 次多读取器退出测试，14 个 CPU/NVMe/DIMM 临界温度通道及
中英文余量界面通过。包内另一窗口读到约 22.80 W 对 20 W、约 114%，该次
快照的寄存器报告电气限制；超过 100% 的百分比和负余量按实际计算保留。
这些短窗口读数不作为配置上限正在限频的替代证据。

五项精确产物验收与最终源码核对均通过，记录位于同目录的 `ACCEPTANCE.json`。
完整 HWiNFO 厂商覆盖、Windows CPU 物理瓦数、真实 XP 与更早硬件预算仍未完成。


### 2026-10-17：Windows Intel Sysman 功耗与独立读取

当前实现将 Linux 的只读 Level Zero Sysman 能量、功耗域、上限、频率与限制原因
接入 Windows 原生位数读取器。主程序仍为 PE32，Intel 与 NVIDIA 各有独立额度、
缓存、原观测时间和失败状态。SDK 只在读取进程加载；旧初始化回退先确认旧进程
已退出，再以新进程的独立环境启动。没有新增设置、超频或驱动安装命令。

Win32 与 Win64 的全部使用结构对照摘要固定的上游 v1.5.0/v1.34.0 声明编译。
两台提供的 Windows 分别通过 100 项 SDK 语义/故障场景，覆盖计数预热、四个
重叠域、当前频率、限频位、上限单位/启用/歧义、设备枚举重排及挂起/崩溃。
这些场景用独立 SDK 夹具提供 30/40/50 W 等值，不是提供主机的物理 Intel 功耗。
原生传输扩至 44 项，两台均通过，包含 Intel/NVIDIA 相互独立的额度，以及旧初始化
前后使用不同 PID。首次现代主机旧初始化因 CRT 与 Win32 环境不同步失败，原记录
保留；在子进程同步两种环境后通过。旧主机最初的批处理误用名为 bash 的 CMD
启动器，未运行任何原生场景；改用已核实的 `/bin/sh` 后通过，未沿用其退出零作证。

两主机分别完成 32/64 位的预热后 API 阻塞和父退出共四项场景：SDK 能量入口
等待十秒时，真实 CPU 频率仍更新，旧功率及时间保留并标过期、不再生成当前比例；
按 PID/创建时间确认读取器在等待结束前退出，新进程先重建能量基线。旧 Windows
父退出至确认回收约 0.10/0.20 秒。缓存另验证固定字节、独立额度、恢复与篡改拒绝；
篡改只改 DOS stub，保留有效 PE 头，避免把系统拒绝损坏 PE 当作字节校验的证据。

空温度描述符或仅有哨兵值时，存储采集可使用同盘 NVMe Composite 温度；有效
属性温度保持优先，属性元数据保留，不把其阈值转给回退来源。Lua 5.5/5.4 定向
检查、Linux 两版 SDK 布局/语义/OOM 回归及当前 Windows 生产构建的九个 PE、
806 个命名导入静态检查通过。标准生产运行时在两台真实主机都报告
`levelzero_library_not_found`，保留原 GPU 枚举与其他监控，未据此生成物理瓦数。
真实经典控制台在 80×25 对概览、Compute、GPU 三个功耗入口分别核对同一画面的
30.0 W、40.0 W、75% 及 `[######--]` 条形图；这些数值均来自 SDK 夹具。
最初测试误要求 `75.0` 而超时，原结果保留，后续按实际百分比格式验证。

GPU 页采用相同编译器、Lua 运行时及 CPUID/NVML 读取器输入作 ABBA 观测，
每次 5 秒预热后以 200 ms 间隔采样 20 秒，进程族按 PID/创建时间关联：

| 提供主机 | 基线/候选单核 CPU 均值 | 基线/候选进程族私有提交内存均值 |
|---|---|---|
| Server 2008 | 1.36% / 1.28% | 62.14 / 62.85 MiB |
| Windows 11 | 2.33% / 2.29% | 68.93 / 69.88 MiB |

这是记录中候选源码哈希的短时观测，不用作最终版本或旧硬件预算证明，也不把
CPU 小幅变化解释为性能改善。

实现提交 `6bb9278` 的 [主 CI](https://github.com/Water-Run/wtop/actions/runs/38973884554)
16 个作业与 [Windows CI](https://github.com/Water-Run/wtop/actions/runs/38973884466)
两个作业全部通过，包含两种 Linux 架构的下载后完整终端测试。精确提交的
Linux x86_64/ARM64、macOS ARM64、Windows x86 四归档已核对外层和载荷摘要、
原生格式及许可；Windows 两种包共验证 19 个 PE、1681 个命名导入，两个厂商
读取器的位数、声明摘要和 SDK 许可均已核对。

两台 Windows 的两种精确包通过五种 CLI、JSON、硬件导航、Storage/SMART、
经典控制台和缺失 Level Zero 的实际降级检查。M4 两种包仍有 43 个传感器通道、
七个功耗域及 CPU/GPU 数据；Linux 两种包通过普通用户/root 实测频率、功耗墙
比例、原生故障和 30 次多读取器退出测试，14 个 CPU/NVMe/DIMM 临界温度通道
及中英文余量界面通过。源码哈希、CI、四归档和五项主机验收的最终核对已完成，
记录位于 `build/hardware-windows-levelzero-20261017/ACCEPTANCE.json`。

后续只读探测确认旧主机有 AMD ADL1/ADL2 驱动，但当前服务会话中的重复适配器
记录标为未显示，读取返回无效适配器索引，且无当前功率接口导出。旧/新上下文
和全适配器枚举对照均未得到可用数据，未修改显示状态或驱动设置，也未接入
程序或生成 AMD 瓦数。其 SDK 版本、声明、日志和范围另存上述目录的
`next-amd-readonly/`，不据此泛化其他 Radeon 或驱动的能力。

接口与调用约定按 [Sysman API](https://oneapi-src.github.io/level-zero-spec/level-zero/1.7.8/sysman/api.html)
及 [固定版 SDK 声明](https://github.com/oneapi-src/level-zero/blob/v1.34.0/include/ze_api.h) 核对；
XP、真实 Intel 厂商驱动物理瓦数和广泛旧设备预算不据此宣称通过。

### 2026-10-17：Windows 磁盘温度、健康与 I/O 隔离（候选验证）

当前开发源码把磁盘 I/O 与健康查询分别移入独立读取进程，保留 NVML 原有
协议编号及独立名额。提供的现代 Windows 经标准 NVMe 查询实采 Composite
盘温约 40°C，驱动报告警告 125°C、临界 140°C；这些是磁盘自己的声明，
不是 CPU 默认阈值。旧 Windows 的所选 ATA 盘读取了 22 项校验有效的原始
SMART 属性，未按 190/194 等编号合成温度。默认查询不发送 ATA 深读取，
选择磁盘后才读其 SMART；测试未调用设置、自检或固件命令。

两台主机通过扩展后的原生磁盘夹具及 41 项进程/协议/生命周期场景，包含
五个 Lua 来源与 NVML 的独立额度、磁盘/健康来源分别挂起时其他来源可读。
磁盘夹具覆盖稀疏磁盘号、枚举重排、描述符/协议长度和类型、权限拒绝、
热插拔及健康数组分配失败的资源清理。最初热插拔夹具把两块盘都换了身份
却预期只剔除一块，原失败保留，夹具已限定仅目标盘变化。

实际 API 入口的测试构建插入 10 秒等待：同步调用约十秒才返回，隔离路径
保留旧值及原观测时间，健康的频率/GPU 和另一磁盘来源继续推进；超时读取器
在解除等待前退出，删除触发条件后以新 PID/创建时间恢复。两主机共 12 项
同步、隔离/恢复及父进程退出对照通过，四项父退出检查从父进程启动至确认
回收约 1.3–3.3 秒，均短于十秒等待。现代 SSH 把预期退出码 19 映射为 1 的
原失败保留，后续用带随机标识的子进程退出记录核对实际 19，未放宽退出断言。

真实经典控制台在 80×25 通过 Storage、选择磁盘、只读健康详情和正常退出。
240×65 窗口调整曾被测试控制台拒绝（错误 87）；该次不能作为宽屏证据，
原失败保留。无 ANSI、弱身份虚拟盘不关联、私有身份不进入公开 JSON 均已核对。
驱动挂起钩子仅进入测试翻译单元；标准生产构建的七个 PE 与 663 个命名导入
通过静态门禁。这不构成 XP 真机或广泛旧硬件性能预算证明。

协议与单位按 [Windows 存储温度接口](https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ns-winioctl-storage_temperature_data_descriptor)
及 [NVMe 健康日志](https://learn.microsoft.com/en-us/windows/win32/api/nvme/ns-nvme-nvme_health_info_log)
核对。Lua 5.5 / 5.4 的 145 个测试文件、静态检查及快速 PTY 回归通过。
仓库新增磁盘 API 生命周期门禁，六项同步/隔离/退出用例在现代 Windows
实机通过；CI 无 GPU 时只核对不可用来源仍被查询，不声称获得 GPU 测量。

两台主机另以测试构建在真实经典控制台触发磁盘 I/O 或健康 API 的十秒阻塞，
确认仍能切到 System、正常退出，并按 PID/创建时间确认读取器在等待结束前
回收。四项从确认阻塞到回收约 0.14–0.21 秒。旧主机最初因没有 Python 及
随后 CMD 引号错误未启动界面，失败保留；改用自带 Lua 启动器后通过。

四次整程序 ABBA 短时观察（5 秒预热、20 秒/200 ms 采样）按 PID/创建时间
统计私有提交内存及单核 CPU：旧/新 Windows 当前平均约 64/67 MiB、
2.1/3.1%。原资源脚本配置目录不一致和后续日志同名错误均保留，修正后的
记录继续已有的首个样本，未重复成功操作。编译环境不完全相同，首个样本
与生命周期夹具活动重叠；这些是主机观测，不作增量开销归因或性能预算认证。

标准生产构建的目录版和单文件版在两台 Windows 均通过五种 CLI 模式、
JSON 契约、硬件导航、Storage 与所选 NVMe/ATA 健康详情的真实控制台检查。
私有包版本与生成的完整本地构建标识一致；初始启动器误按浅克隆的短标识
断言失败，记录保留，核对真实构建标识后仅继续未完成的项目。
实现提交 `75feed3` 的 [主 CI](https://github.com/Water-Run/wtop/actions/runs/38963276009)
16 个作业与 [Windows CI](https://github.com/Water-Run/wtop/actions/runs/38963276013)
两个作业均通过。精确提交的 Linux x86_64、Linux ARM64、macOS ARM64、
Windows x86 四类归档已核对外层和载荷摘要、原生格式与许可；Windows 包
共检查 15 个 PE、1385 个命名导入，Mac 保留声明的 Mach-O 切片。
Windows CI 日志另核对 41 项传输、35 项频率和六项磁盘 API 生命周期测试。

两台 Windows 的两种精确包均通过五种 CLI、JSON、硬件导航、Storage 和
NVMe/ATA 详情的经典控制台检查。提供的 M4 两种包保留 43 个传感器通道、
七个功耗域和 CPU/GPU 数据；Linux 两种包通过普通用户/root 频率、功耗比例、
真实终端、原生故障与 30 次多读取器退出检查，14 个 CPU/NVMe/DIMM 临界温度
通道及中英文余量界面也通过。证据位于
`build/hardware-windows-storage-20261017/ACCEPTANCE.json`；完整 HWiNFO 范围、
XP 真机及广泛旧设备性能预算仍未完成。

### 2026-10-17：温度临界余量与首屏摘要

候选源码在 Compute、传感器详情、Snapshot、Agent 和硬件报告中呈现同一通道的
临界温度及余量。过期、错误、故障、时钟回退和临界值缺失均不生成当前余量；
无临界值时不增加空表列。`max`、`crit` 与 `emergency` 保留各自含义，配置
阈值不作为实际限频位。这些字段的区分遵循
[hwmon 温度接口](https://docs.kernel.org/hwmon/sysfs-interface.html#temperatures)。

本机源码实测 14 个有效临界温度通道，包含 CPU、DIMM 和 NVMe；一次采样中
CPU 封装为 72°C / 100°C、余量 28°C，NVMe Composite 为
45.85°C / 87.85°C、余量约 42°C，DIMM 为 45°C / 85°C、余量 40°C。
这是各通道读数，不是主机统一的温度墙。英文 200×60 与中文 80×25
真实终端均显示摘要及临界余量，正常退出；原窄屏全量列表把临界值置于
首屏之外的记录保留，详情现先显示至多三个最接近各自临界值的通道。

Agent 同时保留全部有效温度中的最小余量及对应设备，不受最热列表上限影响。
定向语义与格式测试覆盖负/零余量、部分读取、故障、旧数据和摄氏/华氏温差。
Mac 和两台 Windows 的当前源码通过四个相关 Lua 文件及 Snapshot/Agent/报告；
两台 Windows 同时通过经典控制台的传感器入口、无 ANSI 和正常退出。M4 保留
43 个通道、现代 Windows 保留一个，旧 Windows 保留不可用状态；均没有新增
物理临界温度读数。源测试复用已验收的原生模块，不替代新构件验收。
两台 Windows 的真实经典控制台另用明确标注的温度夹具验证
102.5°C / 临界 100°C / 余量 -2.5°C，以及 65°C / 100°C / 35°C；
控制台无 ANSI，正常退出，夹具值不计为物理传感器读数。
本地原生/语法/Agent 契约检查、144 个 Lua 5.5 文件、Lua 5.4 纯 Lua
兼容子集及快速 PTY 通过。十种语言的完整浮层换行/滚动检查已加入临界温度
通道，并通过。证据位于 `build/hardware-thermal-headroom-20261017/`；
跨平台最终构件验收继续使用该提交的 CI 产物。

### 2026-10-17：Windows NVML 功耗与限制读取器

候选源码把 NVML 放入原生位数的独立读取器，与 SetupAPI/DXGI/PDH 分开。
32 位主程序可访问 x64 驱动，原生模块及 Lua 运行时仍按 XP 目标构建；新增
两个 SDK 读取器的位数、导入与摘要也纳入静态门禁，当前共七个 PE 映像。
这不是 XP 运行时证明。

独立夹具使用 NVIDIA 原始生成头文件编译，确认其设备句柄为指针，避免
把 Go 绑定修改过的句柄声明误当原始 ABI。57 个 Linux 参考场景与两台
Windows 主机、两种读取器位数作差分，共 256 项；包含零值、哨兵、字段
类型、旧接口、部分可用、限制掩码、挂起、崩溃和输出噪声。39 项原生
传输场景在两台主机通过；新增 96 个 Lua 分配位置为 23 次内存不足、73 次
成功，均检查自有资源和四来源名额归还。

两台主机的同步基线在构造、初始化、设备计数或利用率 API 阻塞时约
3.1 s 才退出。源码 30 项对照和两种私有包的 28 项退出/父进程检查通过，
隔离读取器均先于解除阻塞退出。按键约 60–63 ms，测试发键本身包含固定
60 ms 等待；父进程检查约 2–20 ms。四项挂起/崩溃连续观测保留原功耗与
测量时间，健康设备枚举、频率和热区查询继续推进，新 PID 约五秒后恢复。
旧主机没有温度通道，其热区查询推进不能作为新增温度实测。

后续包复验在旧主机发现一次父进程结束后读取器未于一秒内确认退出，
该失败保留，未计作通过。并发启动原来允许继承全部可继承句柄，现为
Vista 及以后动态启用显式白名单，并在子进程清除协议句柄的继承标志；
CPUID 启动路径也使用同一封装，缺少 API 时保留 XP 回退。确定性夹具验证
无关可继承事件未进入子进程、属性初始化失败清理和旧 API 缺失回退。
新增属性分配也纳入六处 C 分配失败检查。白名单修复后，旧主机包内的
同一回收门禁仍出现过失败，相关记录均保留。

受控实验进一步复现了守护线程的启动竞态：让线程保持挂起，旧版先进入
持有加载器锁的 SDK 构造函数，再恢复线程时，线程无法完成 DLL 初始化，
父进程结束后读取器仍未回收。新版在加载 SDK 或创建采集器之前等待守护
线程进入用户代码并发出就绪事件，同一实验在两台主机均先于解除阻塞
回收读取器。该握手检查已纳入独立 SDK 门禁。修复后的两种私有包在
两台主机通过 28 项完整故障场景和 32 次冷启动父进程退出压力检查，均在
解除阻塞前确认读取器退出；相应的功耗条和限制原因可见检查也通过。


源码与两种私有包的三个功耗入口在真实经典控制台显示 300.0 W、355.5 W、
`[#######-] 84.4%` 和软件功耗限制原因。数值来自独立 SDK 夹具，不是提供
主机的物理 GPU 功耗：两台主机当前均缺少可用的 NVML 功耗提供者。
实际无驱动路径保持原来的 GPU、八/六 CPU 和热区可用性，不补造读数。

两台主机、两种位数的缓存测试验证同时创建、字节一致、存活期间禁止
改写、名额上限、损坏拒绝及恢复。测试专用 SDK、路径替换和同步基线均
留在独立测试构建，不进入干净交付包。Windows 两种包均附带 NVML
接口许可；补齐许可的归档核对了所有原有成员字节不变。仓库门禁可重新构建这些夹具并在
Windows 执行。资源对照在无远端编译干扰时进行，始终保留三个基础读取器，只切换 NVML。
每台主机按 ABBA 顺序运行四轮，每轮预热五秒、采样二十秒；无颜色 80×25
经典控制台、1000 ms 默认间隔。使用两个夹具 GPU 时，Windows 11 进程族
单核 CPU 均值约 2.14%→3.03%，私有提交总量约 49.48→52.18 MiB；Server
2008 约 1.90%→2.06%、43.00→42.16 MiB，后者内存差异不代表优化收益。
工作集求和会重复计算共享页，Toolhelp 采样本身也有成本。初次观测因家族
只按 PID 追溯而出现异常成员数，已保留并排除；重测逐条核对父子创建时间，
持有对应进程句柄并保存成员清单。这些仍是短时观测，不是旧设备预算认证。

原始日志、失败及修正记录位于
`build/hardware-windows-nvml-20261016/`。当前 `make check`、144 个 Lua 文件、
Lua 5.4 定向测试及两台主机各八项原生夹具通过。精确 CI/最终归档仍待
验收；真实 NVML 硬件、XP 和更广的旧设备预算尚未证明。

### 2026-10-16：CPU 计数器夹具的强化读取 ABI

`c49e656` 的主 CI 在 GCC 13 消毒器作业中失败。独立 Ubuntu 24.04、
GCC 13.3、glibc 2.39 环境复现到首个 CPU 样本 `read_errno=5`：强化后的
调用经 `__pread_chk` 读取临时文件，夹具只拦截了普通入口，未能转换固定
寄存器偏移，生产读取器按短读返回 EIO。Debian GCC 14 和本机 GCC 16
原有入口通过，因此本机消毒器通过不能证明这一编译器组合已验证。

夹具现覆盖普通、大文件及两种强化读取入口。新增 ABI 探针使用不同的
APERF/MPERF 数据验证固定偏移、设备身份与两种强化入口的越界中止，
首次样本断言仍要求预热且没有有效频率，并补充原因和错误码诊断。
CPU 夹具也已接入严格警告与 FORTIFY 门禁。Ubuntu GCC 13 的目标消毒器
和 glibc 2.17 原生来源复验通过。完整套件首次运行 141 个 Lua 文件，
仅中文字符宽度断言因容器未设置语言环境失败；同一消毒器模块在 UTF-8
环境下的该项复验通过。完整套件另在 UTF-8 环境验收，原 CI 的失败
记录保留，跨平台结果以修复后提交对应的流水线与精确归档为准。
记录保存在 `build/hardware-cpu-ci-fix-20261016/`。

### 2026-10-16：逐逻辑 CPU 有效频率（开发中）

新增独立的 `cpu_clocks` 来源，读取受支持 Intel Core CPU 的固定只读
APERF/MPERF 计数器。每个读取保留单调时间边界，按实际窗口计算计入
空闲的有效频率，保留窗口不确定度、原始计数和无量纲 A/M 比值。未知
计数布局保持不支持，其他原有频率来源不受影响。

本机 root 下 16 个逻辑 CPU 通过实际读取，普通权限显示 denied。
独立 Python 只读 MSR 观测包围了 Native 的两次读取：一秒窗口中，
CPU 0 的有效频率约 4.069 GHz，位于独立读数的约 4.058–4.085 GHz
边界内，周期差计算完全一致。这个数是此次受控单核心负载下的观测，
不是固定硬件参数。进程、负载与文件描述符在检查后均已结束或关闭。

原生固定地址/设备身份/短读/失败/Lua OOM 门禁与 CPU 读取进程的
超时回收、其他来源响应、重新预热通过；同类 ASan/UBSan 通过。
142 个 Lua 文件、glibc 2.17 原生来源和 root/普通用户的 200×60、80×25
CPU 详情通过。目录包、单文件包与源码 rock 的实际入口通过读取权限、
周期差/窗口、Agent 上限、隔离子进程的真实空闲零值和冷启动超时检查。
两种最终本地包的完整终端矩阵通过；提交后的精确 CI/归档仍待验收。记录位于
`build/hardware-cpu-effective-20261016/`。

### 2026-10-16：DRM 与 fdinfo 读取隔离

默认 Linux GPU 采集现分成 DRM 输入和三个厂商 SDK 来源。一个读取进程
负责 DRM/sysfs、PCI 名称与 fdinfo 文件，保留进程计数基线；父进程合并
独立来源，不在等待或失败时同步回读驱动文件。显式注入的采集器、文件系统
和时钟保留调用方约定的执行路径。

GPU 页的深扫描策略通过每次请求传递；策略改变时丢弃不匹配的旧响应，
不增加另一套读取进程。浅扫描不会抹去有效的 fdinfo 基线，重启读取进程后
首次计数重新预热。过期设备和字段保有原始时间，旧进程记录被清除；同一
PCI 地址上，当前 SDK 读数优先于保留的旧 DRM 数据。确认移除后不重新
恢复旧设备。Snapshot 和 Agent 均保留 DRM 来源的故障与观测时间。

安装包回归进一步发现，25 ms 的 DRM 轮询会把 SDK 的能量采样压到其
100 ms 最小窗口以内，导致单次输出可能停在预热帧。现把 SDK 查询间隔
独立控制，复用回复时保留来源时间；确定性预取帧夹具和真实 SDK 夹具的
75/100/125% 占比检查通过；最终安装形态、精确归档与 CI 已完成验收。

本地故障夹具已通过实际 IPC 的深浅切换、fdinfo 差值/窗口计算、两秒超时
回收、五秒重试恢复、独立 SDK 和真实终端的 GPU/进程/系统导航及退出。
同类 ASan/UBSan 夹具与 glibc 2.17 的原生来源通过；完整源码、最终 CI、
四类归档与原有主机复验已完成，具体范围见上方验证矩阵。证据保存在
`build/hardware-drm-isolation-20261016/`。这不代表其余 Linux 文件读取或
macOS/Windows 的同步调用已隔离。

### 2026-10-16：三个 GPU SDK 隔离与 Sysman 原生遥测

- NVML、AMD SMI、Level Zero 共用一份无 Lua 依赖的读取器 ELF，分别在
  独立进程运行。每个来源最多两个控制器，全进程最多六个。默认查询不等
  驱动；原 NVML 隔离入口保留 50 ms 兼容等待。三个默认提供方均不会退回
  主进程的直接 SDK 调用。停止只取消自己的会话。
- 修正 Level Zero 原后端的初始化、驱动枚举与遥测接口。完整结构的大小、
  对齐和全部字段偏移与官方 v1.5.0、v1.34.0 头文件一致；测试 DSO 也分别
  按这两份原始头文件编译。优先独立 Sysman 初始化；旧方式通过重新执行
  读取器切换，保持 PID 和协议通道，并在加载 SDK 前设置兼容环境。
  不混用独立 Sysman 和 core 句柄。
- 设备按 PCI 地址关联，不按位置猜测。温度、实际频率、请求频率、功率域、
  配置上限及十种当前频率限制分别保留。能量差值窗口为 100 ms–5 s；
  板卡、封装、子设备和显存域不会相加。默认 TDP 不作为当前上限，电流
  限制不转成瓦数，供电来源未确认时不推断当前适用上限。
- 三个 SDK 的混合会话、每源配额、独立停止、18 种挂死/崩溃/噪声/损坏
  协议场景、文件描述符与子进程回收通过。两个 NVIDIA 读取器挂住时，
  AMD 与 Intel 仍能返回。640 个受控分配预算中有 301 次解码内存不足、
  339 次成功；重试保留读取器 PID。混合 Clang ASan/UBSan 同样通过。
- 真实 Snapshot 调用在测试 SDK 下得到三个独立 GPU 的 30/40/50 W，
  配置上限 40 W，对应 75/100/125%。私有序列号和读取器 PID 不进入导出。
  三来源的构造器挂死时，真实 PTY 均可切换页面、打开功耗窗口并退出。
  单 GPU 假时钟验收覆盖冷启动、能量预热和 2250 ms 的一次性导出等待上限。
- 本机 Raptor Lake UHD Graphics 使用 Fedora 签名 RPM 解压出的 Intel
  runtime 26.35.39758.11、loader 1.33.1 完成真实 Sysman 验证。普通权限与
  root 均得到同一个 PCI 设备、300 MHz 实际/请求频率、100–1500 MHz 范围；
  Snapshot 与既有 DRM 设备合并，没有新增重复 GPU。该驱动没有提供温度或
  功耗域，这两项保留缺失。
- 实机验证修正了事件能力的误判：`isThrottleEventSupported` 只表示能否注册
  异步通知，不能门控 `zesFrequencyGetState` 的当前原因。SDK 回归覆盖事件
  订阅不支持但当前 PL1 标志可读；实机修复后读到 fresh 的零掩码，与 i915
  当次未触发状态一致。接口语义见
  [Sysman Frequency](https://oneapi-src.github.io/level-zero-spec/level-zero/1.19.12/sysman/api/apis/frequency.html)。
- AMD SMI、带可用 Sysman 功耗域的硬件和多 GPU/tile 仍缺少新增真机结果。
  同步 sysfs 隔离、更多旧系统与低配硬件性能预算继续开放。记录保存在
  `build/hardware-vendor-workers-20261016/`。

### 2026-10-16：Linux NVML 故障隔离与采样时效

- 默认 NVML 提供方改用原生模块内嵌的独立读取进程，驱动加载、初始化、
  查询和关闭均离开主进程。后台处理启动、两秒查询截止和回收；前台每次
  最多等待 50 ms，全进程最多两个控制器。标准输出、错误输出与协议分离。
- SDK 会话与 UUID 采样游标跨请求保留，响应在完整校验后解码；Lua 内存
  不足时保留同一响应供重试。采样起止时间随结果导出，功耗字段在交付时
  重算新鲜度。无 DRM 节点的设备可在异步发现完成后更新能力；驱动失败时
  保留旧数据的 stale 含义，不把它重新标为 fresh 或零功耗。
- 真实假驱动覆盖构造器、初始化、枚举和查询挂死、关闭挂死、崩溃、标准
  输出噪声、慢启动、损坏协议、超长帧和文件描述符泄漏检查。正常与拒绝
  memfd/pidfd 系统调用的两条路径均通过；每条路径有 360 个查询分配预算、
  35 个构造预算、VM 关闭取消、独立会话、双读取器上限和子进程回收检查。
  Clang ASan/UBSan 同样通过；独立读取器的正常退出通过泄漏检查。
- 真实 PTY 在驱动构造器永久阻塞时仍能切换概览、进程、系统、GPU 和功耗
  浮层并退出，已纳入 `make check`。glibc 2.17 容器构建、138 个 Lua 文件
  和原生生命周期测试通过；模块与内嵌读取器的符号下限均为 2.17。
  容器共享现代内核，拒绝新系统调用的夹具也不等于旧内核真机验证。
- 本机缺少 GCC 的 ASan 运行库；CI 的完整 GCC ASan/UBSan 已通过，
  包括两条原生执行路径和 137 个非 benchmark Lua 测试文件。
  AMD SMI、Level Zero 和同步 sysfs 读取仍不在本次进程隔离范围内。
  证据保存在 `build/hardware-nvml-worker-20261015/`。
- 本机 Lua 5.5 与 Lua 5.4 各 138 个文件、严格原生警告检查和源码 rock 隔离安装通过。
  Linux onedir、onefile 和 rock 实际运行内嵌读取器，假驱动的 300 W / 355.5 W
  对应 84.39%，限制原因保留原采样时间；三种入口均通过挂死驱动下的导航
  与退出检查。两种二进制包的五 CLI 通过，包内全部 ELF 的组合下限仍为
  glibc 2.38，onefile 扫描到三个内嵌 ELF，其中一个是 NVML 读取器。

### 2026-10-15：隔离 CPUID、芯片缓存与系统可用指令集

Windows x86 开发构建新增独立的 CPUID 数据源。主程序和原生模块仍是
PE32 i386；模块内嵌两个有摘要和长度声明的读取器。在 x64 Windows 上启动
原生 x64 读取器，避免 WOW64 的 32 位掩码丢失组内第 32 至 63 号 CPU。
读取器只修改并恢复自己的线程亲和性，按指定逻辑 CPU 查询有界、已支持的
叶；CPUID 和 XGETBV 异常处于子进程内。XGETBV 仅在 XSAVE 与 OSXSAVE
均声明时执行。当前还没有 32 位 XP 或超过 32 个逻辑 CPU 主机的实测证据。

父端按 Lua VM 管理缓存和异步工作线程，首次最多等 100 ms，之后返回明确的
pending/error。完成结果缓存 60 秒，失败 5 秒后重试；OS 逻辑 CPU 身份、
核心/插槽或 CPU Set 元数据变化会废弃旧任务。每进程最多两个工作线程，
Lua VM 关闭只请求取消，工作线程持有独立引用并保持模块加载。正常管道等待
有 3.5 秒期限；TEMP 文件系统或系统加载器永久阻塞时，线程仍可能留存，但
不会无限增加任务或等待它。OS CPU 信息保持独立可用，后台补充读数就绪后
由短间隔复采接入。模块引用的使用依据 Microsoft 的
[GetModuleHandleExW](https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getmodulehandleexw)
与 [FreeLibraryAndExitThread](https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-freelibraryandexitthread)
契约；这些接口的 XP 最低版本声明不等于 XP 实机验收。

共享解码器保留逐 CPU 厂商、签名、family/model/stepping、地址宽度、
Hypervisor 接口位、XCR0、选定原始叶，以及硬件支持/OS 状态/可用性。
Hypervisor 位不直接解释为“正在虚拟机内”；AMX、NX、Long mode 等没有
对应 OS 使用证据的能力保留未知可用性。AVX/AVX2/FMA 要求硬件和启用的
XMM/YMM 状态，AVX512 还要求基础能力及 opmask/ZMM 状态。

Intel 拓扑优先 `1F`，其次 `0B`，用实际 CPU 名单及 APIC 位域计数。
[Intel SDM](https://cdrdv2-public.intel.com/868137/325462-089-sdm-vol-1-2abcd-3abcd-4.pdf)
卷 1 表 21-69 明确将 EBX 层级计数用于显示/诊断；表 21-14 定义缓存几何和
共享地址位宽，二者都不能代替 OS 可见 CPU 的实际数量。本轮也对照渲染页
核对了表格。AMD Family 15h Models 00h–0Fh 按
[42301 BKDG](https://www.amd.com/content/dam/amd/en/documents/archived-tech-docs/programmer-references/42301_15h_Mod_00h-0Fh_BKDG.pdf)
的 `8000001D/1E` 定义解释：整数核心共享计算单元，不当作 SMT；初始 APIC
与可改写的当前 ExtendedApicId 分开保存。L3 的可见 ways 可因分区不同，
重叠视图的几何不一致时不生成物理总量。较新 AMD 和未知拓扑目前保留原始
叶、身份与特性，继续使用 OS 拓扑/缓存，尚未套用旧 AMD 的语义。

只有完整且一致的成员关系才用于首选拓扑和缓存汇总，并保留 `os_topology`、
`os_caches`、`os_cache_summary`。部分 CPU 名单不提升为完整系统总量。
Compute 显示能力覆盖，硬件详情显示逐 CPU 地址宽度、APIC、XCR0 和指令集；
共享树支持核心 → 计算单元 → 插槽及缓存归属。Snapshot 保留逐 CPU 原始寄存器
与来源，Agent 仅带有界汇总，报告列出支持与可用 CPU 数；十种语言有对应标签。

提供主机的独立 32/64 位读取器和原生父端已实测：

| 主机 | OS 报告 | CPUID 观察与核对 |
| --- | --- | --- |
| Windows 11，Intel family 6/model 0x97 | 8 逻辑 CPU、4 核、13 缓存实例 | `1F`，4 核/8 线程、13 实例；L3 地址容量 16 并未算成 16 个已观察 CPU；8 个 CPU 均支持且可用 AVX |
| Server 2008，AMD family 15h/model 1 | 6 核、18 个系统缓存报告 | 6 个整数核心、3 个计算单元、13 个共享缓存实例，含 8 MiB L3；6 个 CPU 均声明 AVX，但 OSXSAVE 未启用，实际可用数为 0 |

两台主机的原生故障夹具覆盖错误响应、超大响应、指令异常、超时、创建失败、
取消、两个 VM 和全局并发限额、80 组首次与 30 组缓存路径的 Lua OOM、3 组原生堆 OOM；父线程
亲和性不变，任务堆分配和临时文件均释放，预热后句柄数保持稳定。
真实二进制捕获保存在 `tests/fixtures/cpuid/`，共享回归还覆盖诊断计数与实际
人口差异、AVX512 状态门控、AMD 非线性初始 APIC、缓存分区冲突、畸形包和
异步复采。137 个 Lua 文件、相关 Lua 5.4 回归、`make check` 与 quick PTY
通过。M4 共享回归和实际 10 个 Mach 逻辑 CPU 的快照通过，未生成 x86 能力。
两台 Windows 的五 CLI 和真实 80×25 无 ANSI 控制台通过；分页核对 AVX 硬件
与系统可用状态，并逐级导航核心、计算单元和插槽。
另以构造的 512 个逻辑 CPU 包核对完整共享分组和默认 Snapshot 编码，成功
导出约 5.9 MB；这属于协议/模型边界夹具，不是大规模硬件实测。
证据在 `build/hardware-cpuid-20261015/`；此节源树运行结果不代表
最终包、XP、其他芯片或尚未实现的 AMD 拓扑已验收。

### 2026-10-15：CPU 与 GPU 的当前限制原因

Linux 的已核对 Intel Core 型号增加独立 `cpu_limits` 数据源，读取固定的
`MSR_CORE_PERF_LIMIT_REASONS`（64Fh）。型号与位定义依据
[Intel SDM Vol.4，335592-085US，Table 2-39](https://cdrdv2-public.intel.com/835765/335592-sdm-vol-4.pdf)
的 2-354、2-361 至 2-364 页；本机 06_BA 的包级状态可区分 PL1、PL2/PL3、
温度、PROCHOT、供电、最大睿频和切换等原因。白名单之外的布局保持不可用，
例如 Goldmont 的同地址使用不同位定义，不按 Core 布局解码。

采集器按系统报告的封装归并，读取前后核对在线 CPU、型号和封装名册。
首选逻辑 CPU 无法读取时可使用同一已核对封装的其他成员。原生入口只接受
CPU 编号，只读这个固定寄存器，并核对字符设备类型、major 和对应 CPU minor；
没有放宽普通文件读取器。需要已有的 msr 驱动和读取权限。

当前状态与历史记录位分别提供。历史位的清除时刻未知，不作为本轮新事件，
也不作为“从启动以来”的计数。短读、拒绝、名册变化、未知位和旧采样失效
不会显示成当前未受限。本机只读 100 轮采样均实际读到 PL1 当前置位；
另外 30 轮 GT 状态正常可读。CPU 每轮平均约 5.88 ms，GT0 约 0.15 ms，
文件描述符从 4 保持为 4。原始数据保留在
`build/hardware-limit-reasons-20261015/root-sampler.json`。

i915 使用[内核公开的逐 GT 状态](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/i915/gt/intel_gt_sysfs_pm.c)，
分别采集 PL1、PL2、PL4、温度、PROCHOT、RATL 和 VR 限制。两轮读数不一致
时保留为采样缺口；部分 GT 或状态不可读、枚举截断时不报告整张卡均未触发。
此接口没有历史位，不补造历史记录。其他驱动的限制原因尚待接入。

功耗窗口先显示当前限制摘要与功耗条形图，完整来源、作用范围和历史位可
继续滚动查看。GPU 表、Snapshot、Agent 和报告保留同一语义；过期资源不
继续发布当前活动原因。功耗来源同时保留接口和实际读取方式。
NVML/AMD SMI 为 DRM 设备补充有效功耗时，同步更新该读数的质量与能力；
缺少 hwmon 的旧标记不会遮蔽成功的厂商读数。合并路径的回归同时核对 UI、
Snapshot 与 Agent 占比，以及正常 0 W、无效上限和过期状态。

新增原生夹具覆盖固定只读地址、设备身份、拒绝、短读、关闭错误和 Lua OOM，
严格 C17 与 Clang ASan/UBSan 均通过。Lua 夹具覆盖型号布局、封装归并、备用
读取成员、名册变化、逐 GT 一致性、未知/缺失/拒绝/截断和过期导出。
新采集器在 manylinux2014 的 glibc 2.17 上完成编译，测得组合符号下限仍为
2.17；这不构成最低内核运行证据。系统 Lua 5.4 的新状态语义夹具也通过。

Linux 普通/root 终端的新功耗窗口与快速 PTY 回归通过。提供的两台 Windows
通过共享语义夹具、三个功耗入口、经典控制台无 ANSI 和 JSON/Agent/报告；
M4 通过同一夹具与三个入口，并在 200 列终端恢复实测 `~755 MHz`、时钟
详情、来源与估算标记。本轮 CPU MSR 和 i915 当前原因的实机证据来自 Linux；
其他平台的相应数据源保持不可用，没有以普通频率变化替代硬件原因。

上一轮 `92ea261` 精确最终包的 Windows 两形态、两主机与 Mac 两形态已完成
CLI、功耗入口和相关原生路径复验；Mac 验收同时确认 200 列 GPU 表中，空的
高优先级功耗列挤掉了实测频率。原失败证据保留，本轮改为优先展示有数据的
列，使用原 200 列频率/估算标记与时钟详情条件复验，不将旧失败记作通过。

### 2026-10-15：NVIDIA 实时限制、瞬时功耗与采样质量

Linux NVML 后端读取十一种当前时钟事件：空闲、应用时钟、软件功耗上限、
硬件降速、同步加速、软/硬件温度限制、外部电源刹车、显示时钟、板级限制与
可靠性策略。优先使用 EventReasons 接口，兼容旧 ThrottleReasons 名称；
函数缺失或返回不支持时回退。单次 64 位当前掩码保持完整，支持能力另读，
拒绝/不支持/设备丢失不会变成零。新版本的未知位保留在原始十六进制值中。
不将空闲称为温度故障，也不为 NVML 当前事件编造历史记录。
依据 [NVIDIA 当前时钟事件定义](https://docs.nvidia.com/deploy/nvml-api/latest/api/group__nvmlClocksEventReasons.html)。

功耗优先使用 GPU-only 的 FI186 瞬时值，并保留 FI185 的一秒平均值；各字段
分别检查状态、类型和作用域，模块的 CPU+GPU 总功耗不作为 GPU 读数。上限
仍独立读取当前强制执行的 mW 上限。旧通用 PowerUsage 的读数保留为设备采样，
不猜其为瞬时还是平均。Snapshot/Agent 保留测量类型、窗口、时间戳和各值质量，
`p` 显示测量类型、平均窗口、原始/支持状态位和实际限制原因。
相关单位与语义见 [NVML 查询接口](https://docs.nvidia.com/deploy/nvml-api/latest/api/group__nvmlDeviceQueries.html)。

FieldValue 的时间戳为 UTC 微秒，不能与进程样本的 CPU 时间戳混用。wtop 将
超过五秒的字段读数标为 stale，缺失时间或超前超过一秒标为 gap；这类值保留
以便诊断，但不会生成新鲜功耗占比。有新鲜平均值时不优先选择旧瞬时值。
这些阈值是 wtop 的显示策略，不是 NVIDIA 的精度或响应时间承诺。

SDK 会话由各 Lua VM 独立持有并在关闭时清理，缺库和初始化失败可以重试。
会话在采样间保留，进程游标按 UUID 对应，不再随枚举索引串卡；内存分配失败
不会提前消费样本。PCI 地址保留 SDK 功能号，高 domain 和互相矛盾的地址不
截成其他设备。数值边界和完整 SDK 结构布局有独立验证。

进程接口兼容 v3/v2/v1，计算/图形列表的重复报告先折叠，利用率取最新样本，
首次取到的驱动缓冲历史标为估计值。多上下文显存不直接相加：
[MIG 的计算实例可以共享内存](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/latest/concepts.html)。
缺少可靠的整个设备报告时保留各上下文与读数，并把最大已报告上下文标为
估计值，来源为 `largest_reported_context`；不把它当作已经证明的进程总量。
完整 MIG 拓扑、共享范围和实机归属验证仍需继续补齐。

NVIDIA 13.4.92 官方完整头文件及独立摘录均验证了消费结构的尺寸、对齐、成员
偏移和调用参数。五种动态库形态覆盖现代、v1、v2、缺失符号和名称回退；
44 种场景、两 VM 生命周期、缺库恢复、UUID 重排、350 点首次分配故障及
100 点已有缓存故障通过。Clang ASan/UBSan 和泄漏检查通过；与 AMD 桥接相同，
仅排除无法表达跨 SDK 类型名称等价关系的 function 类型检查。

最终 `make check test-55` 的 136 个文件、相关 Lua 5.4 回归、quick PTY、
严格原生警告、三台提供主机的共享模型/窗口语义回归通过；新版组合 glibc
符号下限在既有 manylinux2014 构建中仍为 2.17。源码和两种包均通过实际原生
模块到 Snapshot/Agent 的瞬时/平均/旧值/未来值/无时间戳链路；两种包的实际
`p` 窗口验证 300 W / 355.5 W / 84.4%、平均 42.25 W / 11.9% 和旧值无条形图，
并显示软件功耗限制与原始掩码。以上功耗数值来自测试 SDK，不是本机显卡读数。
NVIDIA 接口许可作为独立具名许可记录在 SBOM，并随原生模块和包携带。
证据位于 `build/hardware-nvml-limits-20261015/`；本轮没有 NVIDIA 实际显卡
或 XP 运行证据，不能据此宣称完整厂商覆盖。

### 2026-10-15：AMD SMI 原生接口与功耗单位

Linux AMD SMI 包装按已核对的公共 SDK 布局读取数据：ROCm 5.7.1、6.0.2、
6.1.5、6.2.4、6.3.3、6.4.4、7.0.2、7.1.1、7.2.4。根据运行库报告的完整
版本选择八种布局；未知版本报告 `amdsmi_abi_unsupported`，DRM/hwmon 路径
仍然可用，不试写尺寸未知的传感器结构体。

使用官方 `libamd_smi.so` 名称与 GPU 初始化标志。处理器是 opaque 句柄，
按 socket 枚举并核对处理器类型、重复项和有界容量。结构体包含全部保留字段，
不再以短前缀接收厂商库写入。设备名和驱动版本按版本布局读取，UUID 使用
调用者提供的缓冲区，PCI domain 超出当前地址模型时不截成另一块设备。

`get_power_info` 的 Linux 读数为 W；当前功耗不可用时可使用平均功耗，并将
`power_measurement` 标为 `current` 或 `average`。25.5 不依赖未填写的
`socket_power` 成员。上限独立使用 `get_power_cap_info` 的微瓦并除以一百万，
不从不同版本的 `power_limit` 成员猜测单位。显存使用独立字节接口；时钟从
MHz 转为 Hz，温度使用 EDGE/CURRENT 的摄氏度，风扇百分比从原始值和最大值
计算。正常零值保留，错误、未知哨兵和不一致的容量不冒充读数。

每次查询在创建 Lua 对象前完成采集、关闭 SDK 会话和动态库；驱动初始化
失败或后续热插拔不会被永久缓存成缺失。设备列表变化、单 socket 失败和
截断传播为 partial，并在 Snapshot/Agent 的 provider 元数据保留 SDK 版本、
原因和截断状态。进程 GPU 计数沿用 DRM fdinfo。

原生假库覆盖九个版本的八种布局，每版检查完整接口、缺少可选符号和缺少
必要符号三种库，直接执行实际 `dlopen` 包装。24 类场景包括初始化失败、
版本不支持、枚举增长、重复/空句柄、非 GPU、完整结构体写入、未终止字符串、
哨兵、零功耗、平均值回退、355.5 W 上限、部分指标失败、关闭失败和缺库恢复，
另逐项注入 Lua 内存分配失败。还以 SHA-256 固定的官方原始头文件重新编译
假库并执行；Clang ASan/UBSan 及泄漏检测通过。Clang 的 function 类型检查
无法表示跨 SDK 的局部版本类型，桥接处仅排除此项，其余检查保持启用。

最终 `make check test-55` 的 136 个 Lua 文件通过；严格 C 警告、原生
Clang ASan/UBSan 门禁、Lua 5.4 相关回归、quick PTY 和两种形态的许可/SBOM
核对通过。相同 Lua 合并/Agent 语义、功耗与 GPU 时钟用例在 M4、Windows 11
及 Server 2008 的现有运行时通过。新版原生模块和 Lua 在既有 manylinux2014
容器重编译后的组合 glibc 下限仍为 2.17；这不证明最低内核版本。
源码、onedir、onefile 均用实际原生模块和假 SDK 完成 Snapshot/Agent 链路，
核对 300 W / 355.5 W、84.388% 和测量种类，未将夹具数值称作本机读数。

AMD 声明及测试摘录保留 MIT 许可。Linux 原生模块含许可文字，onedir 有
独立文本；SBOM 将其与 Lua 的 MIT 文本分开记录。证据与原始头文件位于
`build/hardware-amdsmi-20261015/`。本轮没有 AMD GPU 实机，SDK 夹具不构成
实际显卡兼容性认证；XP 运行证据也没有增加。

### 2026-10-15：当前功耗、配置上限和占比

概览、Compute 和 GPU 页按 `p` 可打开持续刷新的功耗窗口。每个来源分别显示
当前瓦数、持续/短时/峰值上限、采样与限制时间窗口、占比、条形图和距上限的
瓦数。Compute 表保留各项约束，GPU 表使用该设备的功耗与上限。ASCII 条形图
不依赖颜色，浮层可滚动；十种语言的字段和按键说明同步提供。

按 [Linux powercap ABI](https://docs.kernel.org/power/powercap/powercap.html)，
RAPL 瓦数从能量增量和实际间隔计算。`max_power_uw` 是允许设置的最大值，
不作为当前配置上限。上限为零、无读数、控制禁用和旧采样失效不会产生占比；
正常 0 W 保留为 0%。占比超过 100% 时保留数值，只将条形图填满。采样窗口
与限制窗口可能不同，比例本身不证明硬件正在节流。控制状态保留 zone 与
control-type 的三值状态，不推断系统未提供的逐约束启用位。

本机 i7-13620H 读取到以下配置，MSR/MMIO 两条来源没有合并成一个上限：

| 来源 | 持续上限及窗口 | 短时上限及窗口 | 峰值上限 |
|---|---|---|---|
| intel-rapl | 26 W / 31.981568 s | 26 W / 2.44 ms | 114 W |
| intel-rapl-mmio | 20 W / 27.983872 s | 26 W / 2.44 ms | 114 W |

普通用户能读配置，能量计数器返回权限不足；使用已有 sudo 权限只读采样后，
一次约 2.01 s 的程序采样得到 17.31 W，对 MMIO 持续上限为 86.6%。其他负载
下也观察到超过 100% 的界面数值。没有修改硬件功耗设置。本机集成显卡缺少
独立功耗上限，不用 CPU 封装或 uncore 的上限替代 GPU 上限。

GPU 占比仅配对同一 NVML/AMD SMI 来源的功耗与上限，或
[hwmon 同一功耗通道](https://docs.kernel.org/hwmon/sysfs-interface.html)的读数与
`cap`；不把告警阈值、其他电源轨或另一个提供程序的上限用作分母。
Snapshot、Agent 和硬件报告保留功耗约束与窗口；Agent 和报告明确标注列表截断。

Linux 普通/root 终端均通过三个入口、滚动、无颜色条形图和正常退出；提供的
两台 Windows 通过新功耗夹具、经典控制台三入口、无 ANSI 和 JSON/Agent/报告；
M4 通过同一夹具与真实功耗浮层，缺失上限仍为空。厂商 GPU 的功耗/上限配对
由夹具覆盖，本轮没有新增相应独显实机证据。证据位于
`build/hardware-power-20261015/`，XP 运行证据仍未补齐。
最终 `make check test-55` 的 135 个 Lua 文件全部通过，`make test-pty-quick`
通过；80×24 中文真实终端另验功耗浮层、条形图、翻页、返回和正常退出。

### 2026-10-15：Windows CPU 分组、核心关系与系统缓存报告

Windows CPU 后端已独立管理拓扑与计数。新系统运行时解析 CPU Set 和扩展
拓扑接口，Server 2008 使用 `GetLogicalProcessorInformation`，更早系统
缺少这些接口时保留可用的身份与线程汇总。逻辑身份同时记录处理器组和
组内编号；程序使用 `group × 64 + index` 标识逻辑 CPU。CPU Set 的核心
编号属于处理器组，旧接口没有硬件核心/插槽编号时，以已核对关系中的
最小逻辑 CPU 作为程序标识，并保留编号方法与来源。

读取前后核对组数量、当前线程数、CPU Set 身份/核心/能效类别，以及核心、
插槽和缓存描述。枚举重排不影响身份，重复、交叠和不一致的成员不建立
混合关系。停放是电源状态，不表示离线；能效类别保留系统原值，不直接
命名为 P/E。规则依据 [CPU Set 字段语义](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-system_cpu_set_information)。
32 位 WOW64 会折叠高位亲和掩码，因此仅在完整成员域可表示且核对一致时
采用掩码关系；CPU Set 可独立保留已验证的核心，未知的插槽不补零。
相关限制见 [Microsoft 的亲和说明](https://learn.microsoft.com/en-us/windows/win32/winprog64/processor-affinity)。

计数使用按组查询的 NT 100 ns 累计时间；单组旧系统可以使用原 NT 接口，
包括没有 `GetSystemTimes` 的 XP 目标路径。读取按组核对长度和数量，拒绝
负时间与求和溢出，不将部分组的总量当作整个系统。可用时保留其他组的
逐核读数；单组的系统时间回退明确保留来源，逐核缺失不会冒充零。
CPU Set 暂时不可用时，独立计数源仍可继续，身份确认度降低并重建基线。
注册表字符串可接受有界的缺失结束符和旧提供程序的零填充。未知核心/插槽
数量显示为“—”，不会把缺失值显示为零；能效类别在窄面板中保留数字标识。
原生分组参数的依据是 [System Informer 的 NT 定义](https://github.com/winsiderss/phnt/blob/master/ntexapi.h)。
身份、来源与总名册变化后重新预热；内部匹配字段不进入 JSON。
Lua 计算百分比在乘法前使用浮点数，避免大额 64 位增量溢出。

操作系统缓存记录增加共享逻辑 CPU、大小、缓存行和相联度，进入共享树、
详情和 JSON。它与固件缓存记录分开：仅以完整、当前且无歧义的成员集关联
核心或插槽，缓存可作为根节点保留。逻辑 CPU 可向核心、插槽导航，缓存可
查看成员并跳转到已核对的父设备。旧接口的缓存/核心报告仍需与芯片级
CPUID 对照；本轮没有把操作系统报告当作独立的芯片测量证明。

新原生夹具覆盖 CPU Set、扩展/旧接口与缺少接口、多组、64/512 个 CPU、
WOW64 折叠和稀疏编号、停放、读取中变更、重排/重复/交叠、矛盾插槽、
异常长度、容量、坏时间/溢出、按组失败与恢复、系统时间回退和 Lua OOM。
查询缓冲区与注册表句柄在创建 Lua 结果前释放。提供的两台 Windows 均通过
该夹具和另外四组原生硬件回归；实际程序各连续采集 1,000 次 CPU 与 10 次
拓扑，读数保持 fresh，平均每次约 0.12 ms。Intel 主机报告 8 线程、4 核、
13 条缓存；Server 2008 的 AMD 主机报告 6 核、18 条缓存。

本地 `make check test-55` 全部 134 个 Lua 文件通过，含新的组身份、独立核心、
缓存成员/过期/重复、详情、导出和大额计数回归。两台经典控制台通过五种
CLI/JSON、CPU→核心→插槽、缓存→核心、来源/共享 CPU/缓存行详情、无 ANSI
和正常退出。M4 的共享 Lua 改动通过五种 CLI 与真实 CPU 详情 PTY 回归。
XP 仍无运行证据。证据在 `build/hardware-windows-cpu-20261015/`。
提交 `2ef3b97` 的主 CI 16 作业与 Windows CI 均成功；按 SHA-256 核对最终归档后，
Mac 和 Windows 两种打包形态已在上述三台提供主机复验通过。

### 2026-10-15：Mach 逻辑 CPU 身份、计数回绕与主机端口

macOS CPU 计数按 Mach 返回的真实 `slot_num` 命名，不再把数组位置当作
逻辑编号。采样前后读取 `PROCESSOR_BASIC_INFO`，核对数量、顺序、槽号、
CPU 类型、在线状态和主 CPU 标记，再关联同一轮的负载数组。短回复、
异常长度、重复编号、中途变更和超过 512 个 CPU 的结果不建立逐核读数，
并报告部分数据或截断。Mach 数组在创建 Lua 结果前释放，内存不足不会
跳过清理。实现依据 Apple 的 [host_processor_info 源码](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/host.c)
和 [processor_info 源码](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/processor.c)。

CPU 信息增加真实逻辑 CPU、在线/主 CPU 状态、Mach 类型与来源，接入共享
硬件树和 JSON。物理核心、插槽和 P/E 逐核归属没有公开依据时不建立关系；
性能级别与缓存仍是 sysctl 汇总。两次身份读取不一致时只保留可用汇总，
缺少 sysctl 逻辑数量时仍可使用已核对的 Mach 槽号。缓存求和和乘法检查
溢出，共享数量不整除时不推算实例数，异常字符串和整数长度不进入结果。

Mach 的 user/system/nice/idle 分别是 32 位计数，先逐类处理回绕，再派生
总利用率；身份、计数宽度、在线状态或总 CPU 名册改变后重建相应基线。
离线 CPU 不显示当前利用率。CPU、CPU 信息和内存采集共享一个有所有权的
主机发送权，退出时释放，避免每次 `mach_host_self()` 都增加未释放引用。
内部采样纪元和身份匹配键不进入 JSON。

提供的 M4 独立 Mach 探针返回 10 个槽号 0–9，CPU 类型/子类型均相同，
主 CPU 为槽 6，不能以此识别 P/E。实际程序连续采集 2,000 轮 CPU＋内存、
20 次 CPU 信息，主机发送权引用在模块加载后为 2，首次 CPU 信息后为 3，
循环结束仍为 3，平均每轮约 0.039 ms。原生故障夹具与 ASan/UBSan 通过，
覆盖长度/数量、稀疏和重排编号、身份变更、512 个 CPU、异常 sysctl、缓存
溢出、重复清理及 Lua OOM。Lua 回归覆盖逐类回绕、上下线、身份/宽度变化、
真实逻辑树和私有字段排除。本地 `make check test-55` 全部 133 个 Lua 文件、
工作流 actionlint 与差异检查通过。M4 的八组原生硬件回归、五种 CLI 和真实
CPU 详情/来源/在线状态的 PTY 导航、刷新与正常退出均通过。证据在
`build/hardware-cpu-20261015/`。

`b1f5927` 的 [主 CI 38680824963](https://github.com/Water-Run/wtop/actions/runs/38680824963)
已成功结束，16 个作业全部通过；[Windows CI 38680825012](https://github.com/Water-Run/wtop/actions/runs/38680825012)
也已成功。两种 Mac 程序和两种 Windows 程序的精确下载归档在提供的三台主机
再次通过 CLI、JSON 和平台交互路径；Mac 另核对了真实 CPU 树、网卡父设备、
GPU、功率和 43 通道传感器。该增量的运行与最终包验收已完整结束。

### 2026-10-15：IOReport 恢复、采样纪元与功率真实性

GPU、CPU 和能耗分别维护只读订阅、当前身份元数据与上一帧。库加载、分组、
订阅、采样或增量失败后释放本次及缓存引用，下一轮可重新打开。重新订阅、
驱动/通道/单位变化时重建纪元，首帧仅作基线；不跨断流或纪元派生功率。
通道按实际驱动与通道编号排序核对，忽略数据块中的计数与时间戳，拒绝重复
编号和异常类型/大小。缓存身份使用独立的不可变快照，底层复用并修改可变
容器也不会把旧身份一同改掉。最多处理 1024 个通道，避免无界遍历。

订阅的 CoreFoundation 所有权已通过独立 M4 进程与 ASan/UBSan 验证，退出时
统一清理所有订阅、通道字典、上一帧与动态库。
[hashcat 的原始实现](https://github.com/hashcat/hashcat/blob/master/src/ext_iokit.m)
也采用同一订阅释放方式。临时样本在分配 Lua 表前释放，Lua OOM 的清理另有
原生回归。GPU 的 GPUPH 驱动编号必须匹配当前 GPU 实例，换驱动后重新预热。

能耗每轮仅输出本次有效的已知通道，软件累计值只覆盖连续有效的观测。
通道缺失、负增量、重复、坏单位或采集失败不会复用旧累计值产生零功率。
IOReport 失败时仍可单独读取 SMC 系统功率，报告部分数据。功率使用相邻
原生观测的时间间隔，Snapshot 的 `power_interval_ns` 保留该平均窗口；
内部纪元与原始采样时钟不导出。真正观测到的零增量仍可表示空闲零功率。
读取前区分简单计数和状态格式，缺少有效单位或格式不符的通道不进入解码器。

CPU 频率拒绝负驻留时间、状态数量/名称不匹配及矛盾的 DVFS 表，纪元改变后
重新读取表，并单独求上下限。实机 CPU 状态采用 `V0P…` 格式，GPU 的图例
可以只有两项；两种格式均已按实际数据处理。活动状态加权频率在 CPU 表格
中以 `~` 标示，来源显示 IOReport，Agent 同样保留估算质量。逻辑 CPU 归属
仍是按集群顺序和数量估算，并未增加真实亲和关系的声明。

提供的 M4 读取到 GPU 1、CPU 4、能耗 175 个原始通道。三类来源实际关闭、
重订阅后均以新纪元预热，再恢复有效增量；CPU/GPU/能耗和重复清理通过
ASan/UBSan。20 轮联合采集验证 2 个 CPU 频率策略、6 个能耗区域与独立 SMC、
有效功率/真实采样窗口、GPUPH 与私有标识不导出，平均约 20 ms。
原生故障夹具覆盖失败恢复、元数据重排/单位/驱动变更、共享可变元数据、
分配失败、容量、DVFS 冲突、CPU/GPU 重建、能耗缺口与 Lua OOM；普通与
ASan/UBSan 均通过。本地完整 133 个 Lua 文件和最新功率/导出目标检查通过。
Compute 页的 IOReport 估算频率和当前 CPU/系统功率、GPU 频率详情、43 通道
传感器详情及干净退出也通过 PTY；五种 CLI 和七组原生硬件回归通过。
`ff3608f` 的 [主 CI 38676059533](https://github.com/Water-Run/wtop/actions/runs/38676059533)
全部 16 个作业及 [Windows CI 38676059562](https://github.com/Water-Run/wtop/actions/runs/38676059562)
均已成功结束。精确下载归档中的目录包和单文件在提供的 M4、现代 Windows
和 Server 2008 再次通过五种 CLI、JSON 与平台交互验收。Mac 另通过三条
网卡父设备导航、Compute 频率/功率、GPU 与传感器详情；Windows 通过经典
控制台和 PCI/USB 导航。其他 Mac 机型仍缺本轮恢复证据。记录在
`build/hardware-ioreport-20261015/`。

### 2026-10-15：GPU 实例身份、数值校验与驻留频率

macOS IOAccelerator 设备改以 IORegistry 实例 ID 标识，不再按枚举位置编号。
采集前后核对实例、型号、驱动与唯一总线祖先，重复身份、读取中替换或
重挂载的设备不输出混合读数；最多枚举 4096 项、保留 128 个 GPU，超限
报告部分数据。临时 CF/IOKit 引用在构造 Lua 表之前释放，Lua OOM 不会
跳过这些引用的清理。共享硬件树按当前且唯一的注册表实例关联 PCI/USB
设备，拒绝过期、歧义或错总线的关系，不从无域地址补造 PCI 域。

利用率必须是有限的 0–100；缺失指标不冒充零。显存整数保留 64 位精度，
浮点字节数仅接受可精确表示的非负整数，拒绝 NaN、无穷值、负值、分数和
求和溢出。没有可用统计的 GPU 仍可列出身份，其能力与指标质量分别报告。

IOReport 的 GPUPH 驻留频率仅分配给唯一、已确认的 Apple 集成 GPU，身份
变化时重建增量基线。校验状态名称、数量与非负驻留时间，保留频率表的
原始状态顺序：M4 的 15 项频率并非单调排列，不能排序后再对应 P1–P15。
上下限单独扫描求取。该频率是活动状态的驻留加权均值，表格以 `~` 标示，
GPU 频率详情、Snapshot 和 Agent 保留 GPUPH、来源与估算质量；空闲时不
把零均值显示成当前频率。多个候选 GPU 或不能确认的状态表不分配频率。

提供的 M4 连续 20 次采样通过，实例为 `ioreg:4294968276`，10 核、有限利用率、
整数共享显存、338–1578 MHz 的表范围和估算均值均符合校验，平均约 5.07 ms。
这台 SoC GPU 没有 PCI/USB 祖先，未创建虚构归属。五种 CLI、GPU 表格的
身份与估算标记、`k` 打开的 GPUPH 来源/质量详情及单次 Escape 后退出通过。
原生夹具与 ASan/UBSan 覆盖重排、替换、移除、重复、高位 64 位 ID、父链
异常、坏数值、显存精度/溢出、容量、时钟歧义和 Lua OOM；本地 133 个 Lua
文件通过，最新图关系/导出检查另单独通过。真实 AMD/Intel/NVIDIA Mac GPU
与旧 macOS 仍缺本轮运行证据。记录在 `build/hardware-gpu-20261015/`。

`fdc267b` 的 [主 CI](https://github.com/Water-Run/wtop/actions/runs/38668014054)
16 个作业和 [Windows CI](https://github.com/Water-Run/wtop/actions/runs/38668014022)
均成功。最终 Mac 归档 6,959,449 字节，SHA256 为
`9a2ea4c3775006295bd8bf3c7ee4d3d8ffb19112034f9fa30aaaef986807e6f6`；
Windows ZIP 7,237,985 字节，SHA256 为
`022f46d5b4b3241d41ea2835a26b90d3ad253327b4d5197f30cf73bce7f7978a`。
全部内嵌 Mach-O/PE32 门禁通过后，两种 Mac 程序在源码目录外通过五种 CLI、
三条网卡父设备导航、GPU 身份/显存 JSON、估算频率/GPUPH 详情和 43 通道
传感器详情；两种 Windows 程序在 Windows 11/Server 2008 通过五种 CLI、JSON、
无 ANSI 经典控制台及 PCI/USB 导航。

### 2026-10-15：HID 温度服务刷新、实例身份与统计

每次采集重新创建只读 HID 客户端并枚举当前温度服务，不再持有启动时的
服务数组；首次没有服务或创建失败后，下一次采集仍可恢复。通道以服务的
IORegistry ID 为身份，读取前后核对身份和产品名，读取结束时再次检查该
IOService 实例仍在注册表中。同名传感器按各自实例保留统计；消失、替换、
身份重复或无法确认的服务不会沿用其他通道的历史。传感器名称只用于分组
和标签，不据此声明 CPU/GPU 归属。

按 Apple SDK 的 `IOHIDServiceClientGetRegistryID` 签名处理借用的 CFNumber，
不把对象当作整数，也不释放借用对象；缺少该可选接口的系统仍可显示读数，
其通道身份标为部分数据并重新开始统计。UTF-8 名称拒绝截断和内嵌 NUL。
每轮最多遍历 4096 个服务、尝试 256 次事件读取、保留 128 个通道，截断时
明确报告部分数据。HID 采集取得的 CF/IOKit 引用在构造 Lua 表之前释放，Lua 内存
不足也不会遗留这些引用。部分采集中已确认的新鲜通道仍能记录直接观察值。

提供的 M4 Mac 连续 20 次采样均取得 38 个 HID 与 5 个 SMC 通道，实例身份、
各通道采样数和私有标识不导出检查通过，包含注册表存活复核后平均每次
hwmon 约 64.01 ms；五种 CLI 通过。原生夹具与 ASan/UBSan 覆盖服务增减、
重排、重复身份、读取中改名或替换、注册表移除、借用对象、缺失接口、
错误类型、Unicode/NUL、非有限值、容量边界、失败重试及 Lua OOM 清理。
本地完整 133 个 Lua 文件、最新导出/会话的 4 个针对文件与最终 `make check`
均通过；实机传感器详情的 43 通道、重绘、关闭与退出也通过 PTY 验收。
该原生夹具接入 macOS CI，完整记录在 `build/hardware-hid-20261015/`。

`933af69` 的 [主 CI](https://github.com/Water-Run/wtop/actions/runs/38664443367)
16 个作业与 [Windows CI](https://github.com/Water-Run/wtop/actions/runs/38664443343)
均已通过。最终 Mac 归档 6,949,442 字节，SHA256 为
`47c4f89b2e5e058af7ee11745577922946123458e7882c1db198de69a6372e56`；
Windows ZIP 7,233,320 字节，SHA256 为
`6bbfe9f81f69ea95d802ee2257349e01a0e1a1d5e8082937b3259f54f8fb3989`。
校验与全部内嵌 Mach-O/PE32 门禁通过后，两种 Mac 程序在源码目录外通过
五种 CLI、三条网卡父设备导航、43 通道身份质量 JSON 与传感器详情 PTY；
两种 Windows 程序在 Windows 11/Server 2008 通过五种 CLI、JSON、经典控制台
和 PCI/USB 导航。

### 2026-10-14：SMC 数值格式、只读回复与连接恢复

SMC 只发送查询元数据和读取数值的命令，按实际回复长度验证结果、数据
类型与载荷大小。整数类型要求准确的字节数，浮点拒绝 NaN/无穷值；扩展
Intel 的 `fp`/`sp` 固定点布局，并按
[VirtualSMC 的编码实现](https://github.com/acidanthera/VirtualSMC/blob/master/VirtualSMC/kern_vsmcapi.cpp)
处理带独立符号位的 `sp` 值。短回复不再被当作零填充的有效数值。

连接失败后每个采集批次只尝试一次，下一批可恢复；失效客户端及时关闭，
进程退出清理仍存活的连接。重连后传感器统计开始新纪元，内部纪元不导出。
SMC 通道以实际键为身份，其他可选键出现不会使现有通道重新编号。
补充 12 个有温度记录的 SMC 键，保留键名作为标签与来源；
[键描述](https://github.com/acidanthera/VirtualSMC/blob/master/Docs/SMCSensorKeys.txt)
在不同机型间有差异，因此不直接声明 CPU/GPU 设备归属。

提供的 M4 Mac 仍返回 43 个有效通道，其中 SMC 的风扇、功率、电压与电流
共 5 个；新增温度键在这台机器上不提供读数。20 次 hwmon 采集平均约
46.83 ms。两次真实采样验证有限数值、键身份、统计连续性和私有纪元不导出；
五种 CLI 通过。原生夹具在实际 SDK 下通过 ASan/UBSan，覆盖全部固定点
布局、正负值、短/异常回复、未知键、失败恢复及退出清理；本地全量 133 个
Lua 文件通过，最新纪元与导出回归另单独通过。Intel 原生温度仍没有本轮
实机证据。

`179b502` 的 [主 CI](https://github.com/Water-Run/wtop/actions/runs/38548499332)
与 [Windows CI](https://github.com/Water-Run/wtop/actions/runs/38548499768)
均已完整通过。下载的最终 Mac 归档为 6,946,456 字节，SHA256 为
`4886319a57ee12d52123b7f60f64d41c231ce19c804f1f3b579677cdb94b70c9`；
Windows ZIP 为 7,233,025 字节，SHA256 为
`5dfb3ea3001116f532b779707b6ca14cdb0d47aed1ae57f158bf400af9203283`。
两种包通过全部内嵌 Mach-O/PE32 静态门禁后，在源码目录外验收：Mac 的
五种 CLI 与三条网卡父设备导航，以及 Windows 11、Server 2008 的五种 CLI、
JSON、无 ANSI 经典控制台和 PCI/USB 导航均通过。
证据保存在 `build/hardware-smc-20261014/`。

### 2026-10-14：macOS 网卡实例、计数来源与硬件关系

接口 MIB 的名称与路由消息的 BSD 名称、索引必须一致。读取计数前后分别
枚举 IOKit 接口实例并复核当前祖先；实例、名称、索引、提供者或父关系变化
时不发布混合计数。重复配置不选择一个任意设备。PCI/USB 父设备通过注册表
实例精确连接共享设备树，软件接口不凭名称或 MAC 地址推断物理归属。

[XNU 的接口 MIB](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/if_mib.c)
提供 64 位计数；[路由消息实现](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/rtsock.c)
会对普通程序的字节数作量化。提供的 Mac 同一接口实际显示路由字节数与 MIB
字节数不同，虽然两者字段均为 8 字节。回退按单个接口标记为 32 位估算，
不改变其他接口的基线；来源、位宽和计数质量进入 Snapshot 与 Agent。
实例或索引更换、位宽切换以及软件接口状态纪元改变时重建速率基线。

路由解析核对消息、地址、名称和 MAC 的实际边界，短消息和未对齐消息都
不越界；缓冲区增大时只作有界重试。Lua 拥有采集缓冲区，结果分配失败也
不留下 IOKit/CF 句柄。原生夹具在提供的 Mac 下通过 ASan/UBSan，覆盖
重建、重挂接、重复实例、名称与索引复用、混合计数宽度、异常长度、嵌入
NUL、过大计数、缓冲区增长、软件接口和分配失败。

实机读取 25 个接口，12 个有 IOKit 实例，其中 3 个建立 PCI/USB 归属；
20 次平均采集约 4.08 ms。两次采样、计数来源导出、五种 CLI、两个 PCI
网卡和一个 USB 网卡的详情与父设备导航、关闭及退出均通过。库存与磁盘
原生回归同样通过；本地全量 133 个 Lua 文件通过。`639c771` 的
[主 CI 38539171521](https://github.com/Water-Run/wtop/actions/runs/38539171521)
全部 16 个作业和
[Windows CI 38539171236](https://github.com/Water-Run/wtop/actions/runs/38539171236)
完整通过。Mac 归档 SHA-256 为
`85964c3a895a05d53db966b9af13cb5308d9d29e994991d61bfb25c5a40a807a`，
两种程序在提供的 Mac 上通过五种 CLI 和三条网卡父设备导航。Windows ZIP
SHA-256 为 `1d3282f52d2cbc536bb4c14150c18d082bbd2bd63691d2eeda6c9b2ff4f2be6b`，
两种程序在新旧主机通过 CLI、JSON、经典控制台和 PCI/USB 导航；静态门禁
核对 5 个 Mach-O 和 7 个 PE。证据保存在 `build/hardware-macos-net-20261014/`。

### 2026-10-14：macOS 整盘身份、计数基线与硬件归属

磁盘采集枚举驱动的整盘 IOMedia，保留独立的驱动和介质实例。BSD 名称
复用、换卡或驱动替换后重建速率基线；读取前后复核实例、整盘标记、BSD
名称和介质的驱动关系。设备型号的提供者改变时丢弃混合记录。重复名称或
介质不选择一个任意设备。PCI/USB 归属复用设备清单的实例与祖先核对，
内置 SoC 存储没有这类祖先时保留独立节点。

[Apple 的存储驱动统计定义](https://github.com/apple-oss-distributions/IOStorageFamily/blob/main/IOBlockStorageDriver.h)
将字节数、操作数和请求耗时定义为驱动实例的累计值。请求总耗时包含并行
请求，推算的忙碌率在界面以 `~` 标记，Snapshot 和 Agent 保留
`busy_quality: estimated`，该估算不触发“设备忙碌”阈值告警。
静态零值保留，缺失的“可移除”属性保留为未知；缺失或异常计数不变为零。
全部系统资源在创建 Lua 结果前释放，包括分配失败路径。

提供的 Mac 实际读取 3 个整盘，30 次平均采集约 0.85 ms；两块外部 NVMe
磁盘分别关联到两个 PCI 设备，内部 Apple SSD 没有虚构的 PCI/USB 父节点。
两次真实采样通过身份连续性、速率及估算标记检查。五种 CLI、两块磁盘的
详情与按 `p` 到 PCI 设备、关闭浮层及正常退出通过实际 PTY。原生夹具另
覆盖换介质、换驱动、BSD 名称与提供者变化、整盘标记变化、重挂接、重复
名称、多整盘歧义、扫描上限、未知属性、嵌入 NUL、整型溢出与分配失败。
原生库存回归同样通过；本地 133 个 Lua 文件通过。`7fce6b6` 的
[主 CI 38533341295](https://github.com/Water-Run/wtop/actions/runs/38533341295)
全部 16 个作业及
[Windows CI 38533341309](https://github.com/Water-Run/wtop/actions/runs/38533341309)
均完整通过。最终 Mac 归档 SHA-256 为
`fbfafc9c3854b613d222e4e360e6a18690d7622f45d4c80a69cf30f79ba179f1`，
源码树之外的两种程序均在提供的 Mac 上通过五种 CLI 和磁盘父设备导航。
Windows ZIP SHA-256 为
`7709b6cf6cb5f47a743a93f29cd894517efe51a8264521c0034bee52393c1a40`，
两种程序在新旧主机通过相同 CLI、JSON 和经典控制台验收。静态门禁分别
核对 5 个 Mach-O 与 7 个 PE；证据保存在 `build/hardware-macos-disks-20261014/`。

### 2026-10-14：macOS IOKit 设备实例与硬件树

PCI/USB 清单使用 IOKit 实例标识连接共享设备树，经过未列出的驱动层找到
最近的 PCI 或 USB 祖先。两次读取整条路径并核对实例，重复、多父、循环、
断开和超出 64 层的关系不进入图。注册表根本身不属于 IOService 平面，
通过根对象核对识别它，不把正常根设备误报为断开。
[Apple 的实例 ID 文档](https://developer.apple.com/documentation/iokit/1514719-ioregistryentrygetregistryentryi)
说明标识只在本次启动内有效；它不等于设备永久序列号。

有效的设备编号、类别与修订号零值保留。PCI 地址改用十六进制；无 PCI
域信息时，重复或缺失的地址用 `ioreg:` 实例标识区分，不虚构域编号。
USB 缺失或重复的位置同样保留为独立实例。匹配字段不进入 JSON，拓扑
中的公开节点与父关系用于详情和导航。采集行在 Lua 拥有的缓冲区内构造，
释放全部 IOKit/CF 对象后再创建结果表，分配失败不遗留系统句柄。

提供的 arm64 Mac（macOS 26.5）实际读取 16 个 PCI、10 个 USB 设备和
17 条祖先关系，清单为 fresh、图无歧义，20 次平均采集约 4.85 ms。
完整 Snapshot 有 56 个硬件节点；五种 CLI、USB4 SSD 按 `p` 到父集线器、
零地址 PCI 根的搜索与详情、关闭浮层和正常退出均通过真实 PTY。
原生夹具覆盖零值、重复地址、缺失字段、UTF-8 与 CFData 名称、重挂接、
断开、多父、循环、64 层上限、4096 项扫描上限和 Lua 分配失败的释放。
原生夹具已接入 macOS CI。`62de118` 的
[构建与独立下载作业](https://github.com/Water-Run/wtop/actions/runs/38526797391)
均通过；最终归档 SHA-256 为
`fb9e7b390d721ffb9bf04884f69a1ebee6d607b1379c07a3c50c404b56bfe3e7`。
5 个 Mach-O 镜像均为 arm64、最低 macOS 11.0。归档在提供的 Mac 上解到
源码树之外，目录版和单文件版分别通过五种 CLI、上述两条硬件导航路径和
正常退出。该提交的主 CI 已完整通过全部 16 个作业，包括消毒器和两种
Linux 架构的下载复验。本地 `make check test-55` 也通过全部 133 个 Lua 文件。
证据保存在 `build/hardware-macos-20261014/`，不增加 Intel 或旧 macOS 实测声明。

### 2026-10-14：Windows 网络接口到硬件的关联

接口 GUID 与网卡设备的软件配置键 `NetCfgInstanceId` 精确匹配，随后核对
当前设备实例，再与 PCI/USB 清单建立关系。虚拟接口保留其自身标识，缺失、
重复、被替换的实例不选择一个任意父设备；内部匹配字段不进入导出。驱动服务、
接口描述和硬件标记随网络接口导出。接口索引、GUID、PnP 实例或计数器宽度
变化会放弃旧基线，避免将新设备计数当成 32 位回绕。

现代路径使用动态解析的 `GetIfTable2`，XP 回退通过接口名或
`GetAdaptersInfo` 的确切接口索引取得 GUID。旧表按返回缓冲区长度限定行数；
现代表复制有界 Unicode 名称，Lua 分配失败也释放 MIB 表。注册表仅以
`KEY_QUERY_VALUE` 读取设备键，在创建 Lua 结果前关闭句柄。

| 提供的主机 | 接口 / 硬件接口 / 已关联 | 平均采集耗时 |
| --- | --- | --- |
| 现代 Windows，10.0.26100 | 3 / 1 / 1 | 1.314 ms |
| Server 2008，6.0.6003 | 2 / 1 / 1 | 22.275 ms |

两台真实采集均为 fresh、图无歧义；经典控制台验证网卡搜索、详情、按 `p`
打开 PCI 父设备以及正常退出。原生夹具在两台覆盖精确 GUID、同名接口、
虚拟设备、重复 GUID、配置/实例复用、键读取失败、接口索引回退、异常链表、
长中文名称、未终止描述及 MIB 分配失败的释放。共享模型另检查陈旧采样和
私有字段不导出，速率回归检查索引复用、名称变化与 64/32 位路径切换。
`make check test-55` 的 132 个 Lua 文件通过，Windows 导入门禁通过。
新增夹具已接入 Windows CI。控制台截图改为在同一帧验证并保存页面标记，
避免就绪检查后的重绘空白；进程清理验收给 shell 1 s 输出子进程 PID，
仍必须终止 30 s 后台进程。
`5c64236` 的 [Windows CI 38520971716](https://github.com/Water-Run/wtop/actions/runs/38520971716)
及 [主 CI 38520971640](https://github.com/Water-Run/wtop/actions/runs/38520971640)
完整通过，后者含全部 16 个作业与消毒器验收。下载的最终 ZIP SHA-256 为
`3103f6d0f90d267e72466a79b21311ead9270bea3d0cebcf38d1ddbaa1194850`；
静态门禁检查 7 个 PE32 和 841 项命名导入。两种程序在提供的两台主机
通过五种 CLI、原生身份、JSON、网卡父设备、四页经典控制台、缩放、
PCI/USB 详情与父设备导航，以及正常退出。证据保存在
`build/hardware-network-20261014/`，不增加 XP 实测声明。

### 2026-10-14：Windows 磁盘身份与控制器关系

`aed6f53` 的 [Windows CI 38498293973](https://github.com/Water-Run/wtop/actions/runs/38498293973)
与 [完整主 CI 38498293943](https://github.com/Water-Run/wtop/actions/runs/38498293943)
均已成功结束。最终 Windows ZIP 下载后，两种程序在两台提供的主机通过
五种 CLI、版本、JSON、经典控制台与硬件导航。归档为 7221848 字节，SHA-256：
`1efba5a7014d4dc24ba12a7dd5cb73219000b1bdc64e2d1f76ad0fdc495025c7`。

交接留下的 [主 CI 38379325229](https://github.com/Water-Run/wtop/actions/runs/38379325229)
已完整成功结束，包含 16 个作业。本轮继续程序硬件实现。

Windows 磁盘采集使用 `GUID_DEVINTERFACE_DISK` 枚举当前接口，在同一个
零访问权限的设备句柄上核对磁盘编号、读取身份和计数；原来的 32 个编号
探测及型号缓存已移除。输出最多 256 块盘，较大或稀疏编号也能读取；
枚举总数和截断状态进入导出。PnP 祖先遍历核对经过的实例与父设备，
只与当前 PCI/USB 清单中的唯一实例建立关系，不猜测 PCI domain。

Windows 10 的设备 GUID 查询按运行时能力使用，旧系统保留描述符和
实例匹配。公开标识为本次监控会话内的设备周期，不包含序列号；内部
PnP 匹配值也不进入 JSON。型号或身份变化后建立新速率基线，缺少唯一
标识时保留数据并显示身份估算及十语言原因。描述符每次读取，避免将
编号复用后的新设备计数与旧型号组合。

| 提供的主机 | 磁盘 / 设备树关系 | 唯一身份 / 实例身份 | 平均采集耗时 |
| --- | --- | --- | --- |
| 现代 Windows，10.0.26100 | 1 / 1 | 1 / 0 | 0.132 ms |
| Server 2008，6.0.6003 | 3 / 3 | 2 / 1 | 11.131 ms |

每台连续采集 20 次，未变化设备的标识保持一致。两台的真实采集为 fresh，
设备树无歧义。现代主机验证 NVMe 磁盘到 PCI 控制器；旧主机验证 SATA
磁盘到 PCI 控制器，以及 USB 存储到对应 USB 设备。经典控制台通过磁盘
搜索、详情、按 `p` 跳转父设备和干净退出，100×30 屏幕没有原始 ANSI 码。

原生夹具在两台通过稀疏编号、编号/实例复用、序列标识变化、旧 API 缺失、
重复编号、短性能结构、异常长度、256 盘边界、缓存满载重排及内存分配失败
的资源释放。共享 Lua 回归覆盖新设备计数仍然递增时的基线重置、估算原因、
陈旧/重复控制器拒绝关联及私有标识不导出。`make check test-55` 的 132 个
文件通过，x86 开发包的 3 项 PE32 / 395 个具名导入通过。磁盘夹具已接入
Windows 打包 CI；最终包仍需随新提交复验。证据位于
`build/hardware-disks-20261014/`。XP 本身仍没有运行证据。

### 2026-10-13：恢复交接、macOS 打包与 Windows 加载条件

从 `43c96bd` 接续开发，先核对其 CI 已成功结束，再检查保留的 Mac
失败任务；旧 PID 已退出，退出码为 2，没有重复启动该任务。
Network 页缺失标记的原因是测试同时要求 Linux 专属的链路变化列和
softnet 接收积压面板，而 macOS 按设计不显示它们。修正后仍检查两个
平台共有的接口、连接表，并在 Linux 继续要求两项专属指标。

`yymac01` 的 arm64 onedir 和 onefile 均通过五种 CLI、快速 PTY。
随后检查实际 Mach-O 发现，luainstaller 启动器的 `minos` 为 26.0，
原生模块却为 11.0。打包脚本现在向整个编译链传递
`MACOSX_DEPLOYMENT_TARGET`，原生模块的 install name 也不再带构建目录。
在提供的第二台 Mac `yymaclyf` 上从干净源码重建，两个包通过相同检查；
onedir 程序、原生模块及 onefile 的三个镜像全部为 arm64、最低 11.0，
加载依赖仅为系统库和系统框架。归档传到本地后再传回独立目录，两个入口
再次通过 CLI 与快速 PTY。归档 SHA-256 为
`2870e2880565a588d69af1867a5dd1095e8e25c4943b2a2bcd47434900e70212`。
这不是旧 macOS 或 Intel 的运行证据。

`make test-bundles` 汇合 macOS 两种包的检查，静态门禁也检查单文件的
内嵌程序和原生模块，避免只测外壳。CI 增加 macOS 构建与独立下载作业；
两项 macOS 作业已在 [CI 38366443122](https://github.com/Water-Run/wtop/actions/runs/38366443122)
成功结束，该轮总流程后来被新提交取消。便携打包器的复用检查现在从已验证
的源 rock 重新解包作比较基准；同时修改两份缓存不能冒充锁定源码。

Windows 的 binutils 2.46 导入表使用 `Ordinal Hint Member-Name` 表头。
既有解析器只接受旧表头，结果漏读所有函数。修复同时覆盖表头和成员行，
未知表头明确报错。当前 x86 开发包的三个 PE32 镜像与 383 个具名导入
通过检查。原生 MSVC 目录包虽通过五种 CLI，却硬导入 XP 不提供的
`InitializeCriticalSectionEx`，因此新门禁拒绝它；不能把它作为 XP 候选。
Windows 打包入口改为要求 x86 MinGW，检查目录包和单文件的全部 PE。

同批开发运行时在提供的 Windows Server 2008（6.0.6003）通过五种 CLI、
Snapshot/Agent JSON 契约和原生版本检查。经典控制台在 80×25 下显示概览、
进程，在调整为 100×30 后显示网络和系统页；各页专属内容可读、没有原始
ANSI 转义码，按 `q` 后退出码为 0。这是开发运行时的证据，Windows
luainstaller 候选仍需以最终产物重复验证。XP 本身仍未运行。

Windows 硬件清单现使用 `CM_Get_Parent` 和 `CM_Get_Device_IDW` 核对同次
枚举中的直接父设备，通过动态解析调用，保持 XP 目标加载条件。它保留
不含 VID/PID 的根集线器和编号为零的设备；父设备总线显式传给共享模型，
不为 Windows 地址补造 PCI domain。采集中途身份或父设备改变时不发布
该条关系，枚举错误和缺失 API 标记为部分数据。

| 提供的主机 | PCI / USB | 直接父子关系 | USB 根集线器 | 最大树深度 |
| --- | --- | --- | --- | --- |
| Windows Server 2008，6.0.6003 | 25 / 13 | 16 | 7 | 3 |
| 现代 Windows，10.0.26100 | 20 / 9 | 13 | 1 | 4 |

两台的真实采集均为 fresh，JSON 拓扑无歧义；硬件详情显示根集线器的
PCI 父设备。原生夹具在两台上验证 285 字节的中文厂商名称、150 字符
描述、长 USB 实例标识、零编号、缺失硬件编号、枚举错误、设备身份复用、
父设备改变和配置管理器 API 缺失。共享模型与导出回归另外覆盖 Windows
地址、实例 ID 回退、错误总线和重复地址。新增 API 没有成为 DLL 的硬导入；
开发包三项 PE32 检查通过。这些是开发运行时证据，仍不等于 XP 实测。

[Windows 原生打包 38370356053](https://github.com/Water-Run/wtop/actions/runs/38370356053)
已完成并失败：目录包的 3 项 PE32 和 355 个具名导入通过，单文件的提取器
编译由 `cc1.exe` 报内存耗尽。日志确认该 32 位编译器未启用大地址空间；
最终单文件构件尚未生成，不能计为打包验收通过。

后续增量补齐 Windows PCI 类别、修订号和绑定的驱动服务，类别按微软
文档从硬件/兼容标识列表中的六位 `CC_` 字段读取，不把安装类别 GUID
作为 PCI class，也不为四位类别补造接口字节。两台主机全部 PCI 设备均
取得类别和修订号；Server 2008 的 17 项、现代 Windows 的 12 项具有
驱动服务。地址中的总线和设备号改为十六进制，实际 xHCI 控制器显示为
`00:14.0`，此前十进制格式会错误显示为 `00:20.0`。

原生夹具补充多字符串、短/畸形类别、零修订号和十六进制地址检查。
两台真实经典控制台在 100×30 下通过 PCI 搜索和详情、USB 详情、按 `p`
打开 PCI 父控制器、关闭详情并退出；屏幕无原始 ANSI 码、退出码为 0。
共享详情增加硬件 ID、PCI 类别和修订号，修订号标签覆盖十种语言。

[Windows 打包 38373504299](https://github.com/Water-Run/wtop/actions/runs/38373504299)
确认给临时 `cc1.exe` 启用大地址后，两种程序均编译成功，但总流程仍失败：
PE 提取检查截掉了节之后的 COFF 符号/字符串表，`objdump` 因此拒绝镜像。
本地真实 DLL 同样复现（620855 字节被截成 535552 字节）；检查器现保留
符号表、字符串表及证书数据，并测试截断与错误长度。完整包的 CLI/控制台
验收仍待下一轮 CI。Windows 开发传输包改用包含隐藏载荷的 ZIP。

本轮硬件增量通过 `make check test-55`（132 个 Lua 文件）、Linux 硬件
详情与父设备导航 PTY、原生 Windows 回归夹具和两台实机交互。PE 符号表
修复另以真实 DLL 和截断夹具验证，Windows 工作流纳入 `main` 推送检查。

提交 `47bb985` 的两种 Windows 程序均通过 PE 门禁（合计 7 项 PE32、
819 个具名导入）。从其 CI 下载完整构件，在本地按工作流相同方式打成
ZIP，SHA-256 为
`feb5353291a628a87d5f692ae0218cf896e0985a570b4e2d8ca4bd218b3491c8`。
两种包分别在上述两台 Windows 主机的独立目录通过五种 CLI、原生版本、
Snapshot/Agent JSON、四页面经典控制台、100×30 调整，以及 PCI 详情、
USB 向父控制器跳转和干净退出。Server 2008 通过 Cygwin 解压时需要恢复
DLL 执行权限；下载工具把文件权限统一为 0644，造成了首次加载失败。
现代 Windows 原生解压没有这项问题。该 ZIP 来自 CI 的诊断构件，
不是公开发布包；文件摘要及具体来源保存在任务证据目录。

随后自动化暴露的两项问题均在测试工具：控制台工具编译时误用了 runner
已有的汇编器，现将匹配的 x86 工具链目录放在 PATH 首位；80×25 的概览
不一定显示 Host 卡片，启动等待改为检查默认可见的 Memory 卡片，仍检查
概览的 CPU/Memory、各页专属内容、无 ANSI 码与正常退出。完整 CI 的
最终结果另行核对，不将已失败的流程记为成功。

最终 [Windows CI 38377222831](https://github.com/Water-Run/wtop/actions/runs/38377222831)
在 `3fee78c` 完整成功结束，包含原生夹具、两种打包、全部 PE 检查、
五种 CLI、真实控制台、ZIP 归档和上传。下载其正式开发构件后，核对
16 个文件、ZIP CRC、随包校验和和 7 项 PE 镜像，再将**同一份 ZIP**
分别送到 Server 2008 与现代 Windows 的独立目录；两种包在两台主机上
均通过同样的 CLI、JSON、经典控制台及硬件父设备导航检查。
最终 ZIP 为 7206808 字节，SHA-256：
`f0ec2703e090c8aef1118d2d15d3f597de013c683676df1ba4b4fd03ba5d193b`。
本地交付副本为 `dist/wtop-0.2.0-dev-3fee78c-windows-x86.zip`。

同一提交的主 [CI 38377222752](https://github.com/Water-Run/wtop/actions/runs/38377222752)
中，macOS arm64 构建与独立下载复验均已成功；其余主流程仍在运行时
不计为整体通过。XP、Intel/旧 macOS 和新增厂商硬件没有增加实测声明。
该次 Mac 归档下载到本地后再次通过 5 项 Mach-O 检查，全部为 arm64、
最低 macOS 11.0，大小为 6916091 字节，SHA-256 为
`e38c9ff14f894ea0c81dd5c5f7d2edeb1c1e2dbccd7175f7ae769284b35b2b78`。
交付副本为 `dist/wtop-0.2.0-dev-3fee78c-macos-arm64.tar.gz`。

本地基线 `make check test-55` 的 132 个 Lua 文件通过，修改后的 Linux
快速 PTY、两种平台二进制门禁回归、打包器缓存完整性回归、发布证据守卫和
actionlint 均通过。详细状态与原始证据保存在不随 Git 分发的
`build/cross-platform-20261013/`。旧交接目录保留。

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
- 当前源码套件包含 148 个 Lua 测试文件；此前矩阵和按日期记载的
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

当时 `tools/perf_benchmark.py` 的 `measurement_version = 3` 记录首帧、每个
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
页面、窗口时长与延迟样本数，并为首帧、采样进程族 PSS、各页稳态 CPU 和
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
`subject_uid` 指定被测程序用户，`resource_observer` 给出采样间隔、窗口和观测
CPU 的限制；`settings.resource_sample_ms` 与实际采样周期一致。
`maximum` 用 `first_frame_ms`、`family_sampled_pss_peak_kib`、
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
`dist/macos/wtop`。在 Linux 上安装 32 位和 64 位 MinGW 交叉编译器后运行
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
  该性质由 `tests/unit/test_engine.lua` 固定。Linux x86_64 与 aarch64
  已有原生 CI 构建和运行验证；其他架构与更早内核的覆盖仍待确定。
- 面向旧硬件的 CPU、内存、启动和输入延迟的实测预算。

在这些基线选定并验证之前,不应将兼容性目标作为已发布平台的承诺对外
呈现。
