# 构建、LuaRocks 安装与 luainstaller 打包

## 1. 当前状态

wtop `0.1.0` 附带一套可用的 Lua 5.5.1 引导、C17 原生模块、确定性的语言区域（locale）编译、LuaRocks rockspec、luainstaller 的 onedir/onefile 目标，以及 PTY 冒烟测试。它不带一份覆盖多种架构、多种 libc、旧版本 glibc 和发行版的正式版本验证矩阵；`CHANGELOG.md` 准确记录了本次发布在什么环境上构建和测试。

构建没有运行时 LuaRock 依赖。`wtop_native.so` 提供交互式终端处理、poll、信号、原子写、受限子进程执行和一组小型 Linux 系统调用。原生文件读取器以非阻塞/不跟随符号链接模式打开，只接受常规文件，默认上限 4 MiB、显式最大 64 MiB，并拒绝符号链接、设备文件、FIFO 和超限内容，同时仍支持以常规文件形式呈现的 procfs/sysfs 伪文件。

## 2. 强制约束

- 只使用官方 PUC Lua；luainstaller 会拒绝 LuaJIT。
- 发布 ABI 是 Lua 5.5。解释器、头文件、链接的运行时和 `wtop_native.so` 必须具有相同的 major.minor 版本。
- luainstaller 不做跨架构或跨 libc 的交叉构建。每个目标都必须在对应主机上原生构建。
- luainstaller 会复制它发现的 `.so` 文件，但不会递归收集这些文件的传递系统依赖、不会重写第三方 RPATH，也不会判断目标机器的 glibc 是否足够新。
- 静态依赖发现依赖字面形式的 `require`。动态模块必须通过注册表或显式 `--include` 加入。
- `--include` 用于 Lua 源文件，不用于任意 YAML/资源打包。
- onefile 可执行文件在运行前会自我解包；它不是完全静态的 ELF。

不要对同一个 `dist/wtop` 或 `dist/wtop-onefile` 路径并发启动多个构建。luainstaller 会拒绝并发构建，也会拒绝被不干净的构建遗留的锁定输出。

在编译或测试之前，Make 入口会先运行一次轻量的资源健康检查。它取宿主机与 cgroup v2 内存/swap 余量中较紧的一个，观测宿主机与 cgroup 的内存 PSI，检查每 CPU 负载，并在默认情况下拒绝不安全的工作。内存必须独立达到配置下限；默认的 Swap 只贡献有限的部分额外余量，而显式设置的 Swap 阈值保持精确。这用于在 OOM 事件之后保护开发主机；它不是基准测试，也不保证任意第三方命令是安全的。

## 3. 构建主机要求

开发、测试和源码运行需要：

- Linux、POSIX shell 和 `make`；
- 支持 C17 的编译器；
- 首次下载需要 `tar`、`sha256sum` 以及 `curl` 或 `wget`；
- Python 3 用于 PTY 冒烟测试，以及 `tools/elf_floors.py` 和 `tools/make_sbom.py`。这两个脚本按 **Python 3.6 或更高版本**编写，不使用更新的特性。这不是苦行主义：本项目进行测量的最旧镜像是 manylinux2014，其自带解释器是 3.6；一个无法在用于验证最旧 libc 的环境中启动的发布工具，就不是面向该 libc 的发布工具。这两个文件的最初版本使用了 `capture_output=`/`text=` 和 `from __future__ import annotations` 头，容器运行时报 `python3: command not found`，波及三个测试文件——而这次运行恰恰是用来判定旧 libc 构建产物是否可用的。

LuaRocks 源码安装与打包要求 LuaRocks 3.13 或更高版本：Lua 5.5 不是 3.12 之前的 LuaRocks 认识的目标，而 Ubuntu 24.04 仍只带 3.8。因此 `tools/bootstrap_luarocks.sh` 把锁定的 3.13.0 版本针对项目自带的 Lua 5.5.1 构建到 `.tools/luarocks`，按记录的 SHA-256 校验下载的归档；每个打包目标都使用该二进制，而不是 `PATH` 上随便哪个 `luarocks`。`tools/bootstrap_luainstaller.sh` 默认从 LuaRocks 把 luainstaller `1.3.0-1` 安装到项目本地的 `.tools/rocks-5.5`，并按 `tools/luainstaller-1.3.0.sha256` 校验固定载荷。仅当既有安装的版本、载荷哈希和 `luai -h` 全部校验通过时才会复用。相邻的 `../luainstaller` 工作树不再被自动选中。

本地集成需要显式的绝对路径：

```bash
WTOP_LUAINSTALLER_ROCKSPEC=/absolute/path/luainstaller-1.3.0-1.rockspec \
  make luainstaller
```

相对路径会被拒绝。这个可选分支使用调用方提供的源码；它不能证明默认锁定的载荷经过校验，因此本身不能作为发布构建的证据。

### 3.1 LuaRocks 源码安装

`wtop-scm-1.rockspec` 是开发分支的安装入口。它沿用 luainstaller 的 rockspec 元数据和命令安装模式，同时为 wtop 完整的 Lua 模块树和 C17 模块使用 LuaRocks 的 `make` 后端。它声明：

- `supported_platforms = { "linux" }`；
- PUC Lua `>= 5.5, < 5.6`；
- EUPL-1.2；
- 无第三方运行时 LuaRock 依赖。

在带有 PUC Lua 5.5 及配套头文件的环境中运行：

```bash
luarocks --lua-version=5.5 make wtop-scm-1.rockspec
```

需要显式 Lua 前缀时，附加 `--lua-dir=/absolute/puc-lua-prefix`。维护者可以在隔离的目录树中进行端到端验证：

```bash
make rockspec-check
make test-luarocks
```

`make test-luarocks` 引导项目的 Lua 5.5.1，把 rock 安装到 `.tools/wtop-rocks-5.5`，然后通过 LuaRocks 生成的包装脚本运行 `--version` 和 `--diagnose`。该 rock 包含 Lua 模块、`wtop_native.so`、`wtop` 命令，以及根目录下的许可证、英文 README、中文 README 和配置示例。`rock-build`/`rock-install` 是 rockspec 后端的入口点，不是面向最终用户的独立安装命令。

权限重执行保留真实进程 argv（包括 LuaRocks 生成的包装脚本），只把 argv[0] 替换为当前可执行文件路径，然后调用固定的系统 `sudo`。它不构造 shell 命令，也不信任 PATH 上任意一个 `sudo`。

## 4. 可复现的 Lua 工具链

`make toolchain` 调用 `tools/bootstrap_lua.sh`：

1. 下载官方 `lua-5.5.1.tar.gz`，或复用 `.tools/downloads` 中已有的文件。
2. 校验脚本中固定的 SHA-256。
3. 从源码构建。
4. 安装到 `.tools/lua-5.5.1`。

这不会替换系统 Lua。标准源码构建：

```bash
make toolchain
make native
make locales
```

或者：

```bash
make all
```

原生模块写入 `build/native/wtop_native.so`，直接针对项目的 Lua 5.5.1 头文件编译。默认 `CFLAGS_NATIVE` 为 `-O2 -g0`，并追加 C17、PIC 和严格警告选项；调用方仍可显式覆盖优化/调试选项。原生目标依赖 `native/wtop_native.c`、Lua 工具链戳记和 `Makefile`，因此修改编译规则会触发重建。该文件不能在 Lua ABI 之间共享。

## 5. 语言区域构建输入

`locales/*.yml` 是权威的翻译来源。内置目录经过：

```text
YAML profile parser
        ↓
schema / duplicate key / placeholder / plural validation
        ↓
sorted deterministic Lua modules + source SHA-256
        ↓
literal-require registry
        ↓
luainstaller dependency graph
```

运行：

```bash
make locales
```

CI/评审还可以额外验证生成输出是否为最新：

```bash
.tools/lua-5.5.1/bin/lua tools/compile_locales.lua \
  --source locales \
  --output src/wtop/generated/locales \
  --check
```

生成文件位于 `src/wtop/generated/locales`。注册表对每个内置目录使用字面 `require`，Makefile 生成相应的显式 `--include` 参数。onefile/onedir 不在运行时解析内置 YAML。

启动时，TUI 还会扫描 `$XDG_CONFIG_HOME/wtop/locales/*.yml`（或 `~/.config/wtop/locales/*.yml`），并通过同一个受限 YAML 解析器加载覆盖目录。它最多读取 64 个文件、每个文件最多 1 MiB。用户目录不属于包载荷，也不属于确定性的内置语言区域构建。用户目录解析失败会报告 partial/error，加载会继续使用可用目录和内置回退。

## 6. 当前 Make 目标

| 目标 | 行为 |
| --- | --- |
| `make resource-check` | 运行默认预检，在内存/swap/PSI/负载无余量时拒绝工作 |
| `make run` | 构建 native/locales，然后启动 TUI |
| `make diagnose` | 输出能力诊断 |
| `make snapshot` | 输出一份 JSON 快照 |
| `make check` | 校验 Lua、POSIX shell 和 Python，解析 Agent JSON schema，并**将其应用到一次实时的 `--agent` 采集** |
| `make test-fast` | 运行 120 个 Lua 文件和一个有代表性的三用例 PTY 配置 |
| `make test-55` | 120 个 Lua 5.5 单元与夹具测试文件 |
| `make test-54` | 用系统 Lua 5.4 运行同样的 120 个文件，验证纯 Lua 兼容子集 |
| `make test-fuzz` | 用随机按键、鼠标报告、非法转义、无效 UTF-8 和尺寸变化，针对真实终端循环测试 |
| `make test-pty` | 场景台账，然后针对响应式尺寸、翻页切换和四种颜色/字符能力配置运行真实 PTY 冒烟测试。台账（`tests/pty_scenario_ledger.py`）是静态检查：套件运行的每个场景都必须在 `SCENARIOS` 中命名，因此矩阵中的任何失败都可以单独用 `--scenario` 重跑；它存在的原因，是一个没有自己名字、藏在 `main` 内部的步骤，正是一个失败场景变得不可诊断的方式 |
| `make test-pty-isolation` | 18 个 PTY 场景各自独立进程单独运行——这是套件无法回答的问题，因为一个从上一个场景继承了“热”主机的场景并没有真正被测试。列表是 `SCENARIOS` 中的数据，一个没名字的步骤进不了它：八种尺寸的响应式矩阵及其翻页检查变成 `run_responsive`，正是为了这个原因 |
| `make test` | `test-55` 加 `test-pty` |
| `make test-all` | 跨两种 Lua ABI、LuaRocks、onedir、onefile 及其 PTY/JSON 契约的串行发布式验证 |
| `make luarocks-bootstrap` | 将锁定的 LuaRocks 3.13.0 构建到 `.tools/luarocks` |
| `make rockspec-check` | 通过 LuaRocks 校验 `wtop-scm-1.rockspec` |
| `make luarocks-install` | 安装到隔离的项目内 `.tools/wtop-rocks-5.5` 目录树 |
| `make test-luarocks` | 重装隔离的 rock，并运行已安装 CLI 的冒烟测试 |
| `make luainstaller` | 引导锁定的 luainstaller 版本 |
| `make bundle-dir` | 生成 onedir |
| `make bundle-file` | 生成 onefile |
| `make test-bundle-dir` | 重建 onedir，并对其运行 PTY 冒烟测试 |
| `make test-bundle-file` | 原子替换 onefile，并对其运行 PTY 冒烟测试 |
| `make checksums` | 要求两个包都已构建，并针对 onedir 携带的每个文件加上 onefile 生成 `dist/SHA256SUMS` |
| `make test-release-notices` | 询问包是否携带其许可证文本，以及清单是否覆盖它们 |
| `make check-native-warnings` | 在更严格的警告集（`-Wshadow -Wconversion -Wsign-conversion -Wpointer-arith -Werror`）下编译每个原生源文件 |
| `make sanitize-native` / `make test-sanitized` | 用全部原生源文件构建一个 ASan+UBSan 模块，并对它运行采集路径和单元套件 |

## 6.1 发布物及其声明

SBOM 里一个组件的许可证 id，就是在声明该发布物按这些条款分发；再分发者要遵守条款，唯一途径是读到条款原文。因此文档不允许声明一个发布物未携带文本的许可证：`tools/make_sbom.py` 逐个核对已声明的文本，任何一个缺失都**拒绝写出任何内容**，并指明是哪个许可证、哪个路径。这与缺产物检查是同一种拒绝，只是向外一层；它之所以存在，是因为这道检查确实抓住过东西——把 Lua 的 MIT 文本从包里拿走后，旧版生成器照样报告成功，哈希了三个产物并声明 `lua` 采用 MIT。

因此，每个组件都带四个属性，说明它的条款实际在哪里：

| 属性 | 含义 |
| --- | --- |
| `wtop:licence-text:path` | onedir 包内持有该文本的文件 |
| `wtop:licence-text:sha256` | 该文件的哈希，接收方可核对自己收到的东西 |
| `wtop:licence-text:present-in` | 哪些产物形态持有它：`onedir`、`onefile` 或两者 |
| `wtop:licence-text:covers` | 这些条款覆盖什么，用文字说明 |

`present-in` 靠在 onefile 内查找相同字节来测定，不是从打包工具的工作方式推断的，而**两种形态并不一致**：

| 许可证 | 组件 | 在 onedir 中 | 在 onefile 内 |
| --- | --- | --- | --- |
| EUPL-1.2 | `wtop`、`wtop_native` | 有，即 `dist/wtop/LICENSE` | **没有** |
| MIT | `lua` | 有，`.luai/licenses/Lua-MIT.txt` | 有 |
| LGPL-3.0-or-later | `luainstaller` | 有，`.luai/licenses/LGPL-3.0-or-later.txt` | 有 |

onefile 不携带项目自己的许可证，这是打包工具的一个测得的限制，不是疏忽。两条路都试过、都被拒绝：`--include` 是它唯一支持的添加文件的方式，并把路径校验为 Lua 源码（`Manual include must be a Lua source file`）；onedir 树也不能事后塞进一个额外文件，因为 luainstaller 用所有权标记校验输出树，在任意深度拒绝非自有内容。为了携带我们的条款去补丁一个第三方 LGPL 工具不值得，所以 `make bundle-dir` 从空目录重建树、最后把 `LICENSE` 复制进去，SBOM 则直接陈述这个缺口，而不是留给分发者去推断。任何再分发 **onefile** 的人都必须自己把 EUPL 文本带下去；这句话写在文档里。

CI 负责发布这些声明。`release-artifacts` 与 SBOM、清单和基线一起上传 `dist/wtop/LICENSE`、`dist/wtop/THIRD_PARTY_NOTICES.md` 和 `dist/wtop/.luai/licenses/`——此前它不这么做，于是 CI 构建的发布物完整、经过校验、全绿，却不带任何关于自身条款的可读陈述。

那次上传曾把一段解释文字放进自己的 `path: |` 块里，持续了一个 increment，而那段文字是八个文件名。对 YAML 解析器来说，`key: |` 之下全是字面文本，那里的 `#` 不是注释而是路径的第一个字符，于是这个作业发布了八条名为 `# The gate in docs/PLAN.md §9 names third-party notices` 的路径。上传步骤对找不到文件的路径只警告不失败，它就这样作为噪声留在了每次发布运行的日志里。`tests/unit/test_release_evidence.lua` 现在拒绝这种写法，读取工作流的原始文本而非去掉注释后的文本：剥掉路径块内的 `#` 会删掉这条子句存在所要报告的证据。这个发现不是靠读文件得到的——那段文字所在的位置看上去就是一段注释——而是在给新守卫所用的手写读取器做交叉检查时，把一个真正的 YAML 解析器跑在工作流上得到的；它在全部九条真实路径上与手写读取器一致，多出了这八条。

产物缺失是硬错误。生成器不写覆盖文件数少于发布物实际携带数的文档：它指出缺什么、说明哪个目标构建它、非零退出、不创建输出文件。这正是该目标要消除的失败——它曾接受一个从未有规则产出过的 `dist/bundle-dir`，找不到文件，然后写出一份完整、格式良好的 CycloneDX 1.5 文档：三个组件、序列号、licenses 和 purls，却一个哈希都没有，接着打印 `SBOM written` 并以 0 退出。一份唯一依赖文件的部分为空的文档，回答不了它为之存在的问题，而它就坐在 `dist/` 里，看上去像发布证据。`tests/unit/test_sbom.lua` 钉住这个拒绝、按独立 `sha256sum` 核对的逐文件哈希、每个哈希挂在哪个组件上、构建树之外使用的版本回退，以及 `make sbom` 的接线本身。

签名和完整的构建溯源记录，目前仍不由任何目标产出。

`dist/`、`build/` 与 `.tools/` 是本地构建产物；不得当作源码，也不得当作可跨主机复用的发布物。

## 6.2 原生模块的另外两次构建，以及谁来持有文件列表

Linux 模块构建三次：常规一次，更严格的警告集下一次，ASan 和 UBSan 下一次。后两次就是 `make check-native-warnings` 和 `make test-sanitized`，而它们是 Makefile 目标、不是 `.github/workflows/ci.yml` 里的步骤——这件事本身就是全部要点。

两者过去都是自己点名 `native/wtop_native.c` 和 `native/wtop_nvml.c` 的工作流步骤。`NATIVE_SOURCES` 有四个文件，被漏掉的两个是 `wtop_amdsmi.c` 和 `wtop_levelzero.c`——AMD SMI 和 Level Zero 后端，它们通过 `dlopen`/`dlsym` 而非链接期触达厂商库，因而是这个模块里最容易把指针弄错的部分。后果是：工作流里唯一检查内存错误的作业从不加载它们，更严格方言的门也从没看过它们。修复前实测过：四个文件在更严格方言下全部干净编译，在 ASan+UBSan 下全部干净插桩，所以并没有在绕开什么问题——门只是比它们的名字窄，而比名字窄的门，会在未覆盖代码碰巧干净的那段时间里静默通过。

根因与 §10 为另一份清单记录的相同：Makefile 已经持有的事实被抄了第二份。所以源文件列表现在只存在一份；新增一个 `.c` 文件只要加进 `NATIVE_SOURCES`，两道门都会覆盖它。`tests/unit/test_native_gate_coverage.lua` 用 `make -n` 检查每个目标的*展开*而不是配方文本——硬编码了两个名字的目标，仍可能在注释里写着 `NATIVE_SOURCES`——它最强的一条子句是：工作流根本不得点名任何 C 源文件。这让第二份抄本不可能回来，而不是只修掉今天这一份。

关于 sanitized 运行，跑它之前值得知道两件事：

- 插桩模块写到 `build/native-san/`，不覆盖 `build/native/wtop_native.so`。覆盖会让模块比它自己的前置更新，下一次 `make native` 便拒绝重建，之后每个套件都会加载一个它没要过的插桩构建。
- `make test-sanitized` **不**在 `test-all` 里。它需要 ASan 和 UBSan 运行时，而构建主机不被要求安装它们；一道不能到处运行的门，只会在有人记得的地方报告。它还按名排除 `tests/unit/test_benchmark_record.lua`：那个文件断言一个三秒的首帧窗口，插桩之下它会成为整次运行里唯一一个通过与否取决于插桩开销、而不是代码的地方。开发主机没有装 sanitizer 运行时，所以那里引入的 flake 要到 CI 才看得见。

## 7. 产物结构

onedir 是当前的诊断基线，包含：

- `wtop` 启动器；
- `LICENSE`，项目自身的 EUPL-1.2 条款，在包生成之后复制进去；
- `.luai/native/wtop_native.so`；
- `.luai/manifest.lua`；
- `.luai/generated-output.txt`；
- 生成的启动器 C 源码、重链接说明和相关第三方声明。

`bundle-dir` 在构建之前先删除 `dist/wtop`，而不是在旧输出上叠建。两个原因，都实测过：一个会合并进自己上一次输出的伪目标，可能发布陈旧文件；luainstaller 用所有权标记校验输出树、在任意深度拒绝非自有内容——所以把复制进去的 `LICENSE` 留在原地，会让第二次 `make bundle-dir` 以 `Generated output contains an unexpected top-level entry` 失败。从空目录构建，这个目标才可重复。

luainstaller 1.3.0 的 `.luai/generated-output.txt` 是生成产物清单。其 `output_dir=` 有意记录构建时使用的 onedir 输出目录，可能包含绝对构建路径。启动器在运行时不依赖该目录。这个字段仍要作为构建溯源来审查，但不能误当作 ELF 运行时依赖，也不能被一条过宽的"载荷里任何地方都不得出现私有路径"的规则拒绝。

onefile 把同一载荷包进一个自解压可执行文件。它仍依赖目标机的 Linux ELF loader/libc，并可能受不可写或 `noexec` 的临时目录策略影响。onefile 的启动问题先用 onedir 复现。

`bundle-file` 先生成 `dist/.wtop-onefile.next`，成功后才原子替换最终路径。因此重复构建不会仅因旧 onefile 存在而失败，失败的构建也不会毁掉上一个产物。

可选的 `smartctl`、`systemctl`、`perf` 和 `sleep` 不打包；它们的检查器在运行时探测 PATH 和固定系统路径。`ss`、`nvidia-smi`、`rocm-smi` 和 `intel_gpu_top` 目前只出现在 `--diagnose` 的可执行文件报告中，不作为数据提供方：wtop 完全不执行外部进程，所以一台装有 `rocm-smi` 却缺少 `libamdsmi.so.1` 的主机，会报告该可执行文件可用而没有 AMD 后端。`--diagnose` 因此还带一个 **GPU 厂商库** 小节，用采集器调用的同一批原生入口回答诊断真正被问的问题——`libnvidia-ml.so.1`、`libamdsmi.so.1`、`libze_loader.so.1`——报告尝试过哪个库、加载成功时的设备数、未加载时原生层自己的原因。共享库不能像源文件那样探测，因为它经由动态加载器的搜索路径、而不是某个固定路径被找到。安全模式把该小节报告为跳过，而不是去加载厂商代码。核心采集器不依赖这些工具，发行版也不包含厂商驱动库。

## 8. 验证

### 8.1 源码与 PTY

先确认资源余量，然后运行这 120 个 Lua 文件：

```bash
make check
make test
make test-54
```

`make test-54` 用系统 Lua 5.4 运行同样的 120 个文件，验证纯 Lua 兼容子集。

PTY 矩阵目前覆盖 `40×10`、`60×20`、`80×24/25`、`80×50`、`160×24`、`200×22`、`180×45` 和 `200×45` 翻页切换，检查中文帧、交互路径、备用屏幕进入/恢复、完整帧和干净退出。额外的配置断言 truecolor、256 色、16 色和无色 ASCII 输出，覆盖 Water Light、High Contrast 和 Colorblind。第 2–8 页各自作为带页面专属语义标记的最终完整帧校验。

Lua 测试还覆盖 JSON 的 4 MiB/深度/100000 节点预算、线性数值解析冒烟、无效 UTF-8 值与键的 U+FFFD 替换、连接导出 ID 的默认脱敏、有界常规文件读取、异构 CPU 标识/拓扑/缓存夹具、powercap 能量差值/回绕/重置/约束、GPU PCI ID/PCIe/fdinfo 利用率、hwmon 哨兵过滤、感知 cgroup 的资源预检，以及 sudo 特权元数据。通过 120 个夹具文件并不是形式化证明——它不覆盖内核、硬件或恶意输入类别。

### 8.2 打包后的 PTY

```bash
make test-bundle-dir
make test-bundle-file
```

### 8.3 干净环境

```bash
empty_path=$(mktemp -d)

env -i \
  PATH="$empty_path" \
  TERM="xterm-256color" \
  LANG="C.UTF-8" \
  dist/wtop/wtop --diagnose

env -i \
  PATH="$empty_path" \
  TERM="xterm-256color" \
  LANG="C.UTF-8" \
  dist/wtop-onefile --diagnose

rmdir "$empty_path"
```

这段代码故意让所有可选辅助程序不可用，并验证包不依赖系统 `lua`、`LUA_PATH`、`LUA_CPATH` 或源码树。交互模式仍需单独的 PTY 冒烟测试。

### 8.4 原生依赖

用以下命令检查每个目标构建：

```bash
ldd build/native/wtop_native.so
ldd dist/wtop/wtop
file build/native/wtop_native.so dist/wtop/wtop dist/wtop-onefile
readelf -dW build/native/wtop_native.so
strings build/native/wtop_native.so dist/wtop/wtop dist/wtop-onefile
```

源码/构建目录不得嵌入 ELF 文件。意外的共享库、RPATH/RUNPATH 或错误的架构，都必须让一次发布失败。该检查针对运行时 ELF 文件；`.luai/generated-output.txt` 的 onedir 例外见上文，其他文本载荷仍需逐一审查。原生模块不链接任何厂商 GPU 库；NVML 在 NVIDIA 驱动提供时于运行时用 `dlopen` 打开，所以链接行上唯一的增加项是 `-ldl`。

sudo 冒烟校验不要在自动化中打开不受控的密码提示。先用 `sudo -n true`；仅当非交互 sudo 已经可用时，再运行有界的 `sudo -n <installed-wtop> --diagnose`。单元测试验证构造和元数据，不需要 root。

## 9. 当前平台边界

0.1 的 LuaRocks rockspec 和 Linux 发布包仅限 Linux。源码树另提供 `tools/build_macos.sh` 和 `tools/build_windows_x86.sh` 用于开发产物；`make` 支持 macOS 源码构建。它们的主机采集器和 TUI 冒烟证据记录在[跨平台产品需求](CROSS_PLATFORM.md)中。现有 Linux `dist/` 来自 Fedora glibc x86_64 开发验证，不是正式发布。当前 Linux 验证不承诺：

- aarch64；
- musl；
- 更旧的 glibc；
- deb/rpm/Arch 包；
- 每一种终端和 GPU 驱动。

这些目标必须在对应的架构/libc 上原生重建，并由各自的 `ldd`、干净环境、PTY 和硬件冒烟证据支撑。`wtop_native.so` 不能跨 libc 或跨 Lua major.minor 版本共享。

### 9.1 glibc 下限是测出来的，测量本身就是这道门

源码里没有一个 glibc 版本号可供构建撞上。wtop 产物的下限，是编译它的那台机器的 glibc 符号版本集：它是构建主机的属性，不是代码的属性——同一棵树在更旧的 glibc 上构建，要的就更少。因此兼容性不能从开发主机上运行成功、ELF interpreter 或 `file` 输出推断；它从发布的二进制里读出来。

`make baseline` 对构建产物运行 `tools/record_baseline.sh` 并写出 `dist/BASELINE.txt`；输出路径是变量（`make baseline BASELINE_OUTPUT=dist/BASELINE-arm64.txt` 用来换名），ELF 清单同理是必填参数而不是默认值——想换名字留证据的调用方不必重新推导该测哪些文件。这不是假设：两个 CI 步骤恰好这么干过并一直失败；而 aarch64 作业在该步骤的整个生命周期里写了基线，工作流里却没有任何上传步骤，于是"发布曾在 README.md 称为发布目标的架构上被测过"的唯一记录，是一个一小时后就被删除的 runner 上的文件。该作业现在把它作为 `aarch64-baseline` 产物发布；`tests/unit/test_release_evidence.lua` §6 解析工作流里每次 `make` 调用的产出路径——命令行覆盖，或没有覆盖时 Makefile 的默认——并要求每条路径都落在某个上传路径里。

交付了也不等于测对了东西，这是两个缺陷里较新的一个。两个作业都跑 `make baseline`，而它的对象是 `$(BASELINE_ELFS)`——`build/native/` 下的模块和 `.tools/` 下引导出的解释器，两个留在 runner 上、不进任何发布物的文件。`make release-baseline` 正为此存在：它测 `$(RELEASE_ELFS)`，即发布的产物形态，因为构建产物不是发布的东西。**此前从未有任何 CI 作业运行过它。**当时公布的下限是关于构建主机的陈述，而两份文档碰巧报告同一个最高要求——2.38——这正是它活下来的原因：一个读起来像一致的巧合。两个作业现在都运行 `make release-baseline`（aarch64 通过 `RELEASE_BASELINE_OUTPUT` 命名输出，并为此付出一次以前没做过的包构建）；测试的 §6d 按名拒绝公布的 `dist/BASELINE.txt`、要求 `dist/BASELINE.release.txt`，两条路径都从 Makefile 里读出，改名时子句跟着走。两个目标保持分离而不合并成一个条件：一个只在碰巧存在时才被测量的产物，就是在一台被遗忘的机器上被静默跳过的产物。

`make baseline` **不**在 `make test-all` 里，这是上一段的结果而不是疏忽：它测构建主机，而发布下限是 `release-baseline` 的。留在里面会让 `test-all` 产出一篇发布物里没有的文档，守着这件事的两条子句就会对它互相矛盾——一条说 CI 作业不得产出没人收到的证据，另一条说构建主机下限绝不能当作发布证据发布。`make baseline` 仍然可用，仍回答它自己的、关于构建主机的问题。

针对产物的那道门在 CI 里运行。很长时间里它没有：`test-release-notices` 在 `test-all` 里，而 `test-all` 不在工作流里，于是它问的问题——包携带的每个文件都在 `SHA256SUMS` 里，SBOM 与清单对同一批字节仍然一致——没有任何人问过 CI 产物。构建它们的作业跑的是 `sbom`、`checksums` 和 `release-baseline`：三个生产者、零个检查者，读起来像一条能用的证据流水线，其实不是。`release-artifacts` 作业现在运行这道门；`test_release_evidence.lua` §6f 要求 `make test-all` 运行的每道门都作为步骤出现在工作流里，唯一的豁免按名列出而不是被过滤掉：资源预检——它们的存在就是为了在满载主机上拒绝运行重目标，并被其他一切传递引入。

"每道门"曾经是一份只有 11 项的清单。§6f 用一个只匹配固定两行的模式去读 `make test-all`，而那条规则写在三行上，于是 `test-luarocks`、`test-bundle-dir` 和 `test-bundle-file` 从未被对照过任何东西；三者都在 CI 里运行，所以没有变红，子句只是对一份短了三分之一的清单报告了全覆盖。清单现在经 `tests/support/makefile.lua` 的 `prerequisites_of` 从 `make -p` 取得，因为规则的前置列表没有读者能预测的长度；§6h 用真实规则钉住那个读取器——只出现在第三行的三个前置必须回来，而 make 4.4 在 `.NOTPARALLEL` 目标的前置之间插入的 `.WAIT` 不在其中。make 构建不了的目标按名拒绝，而不是报告为"没有要求"。同一文件里另有两条子句（§3 和 §5a）以同样方式读前置、碰巧正确，现在改用同一个读取器；§5b 则对错误的函数问了更难的问题：`test-all` 是否运行 `test-release-notices` 是前置的问题，它问的却是读配方的 `recipe_of`。`test-all` 没有配方，于是子句通过于同一读取器的第二个缺陷——把续行的前置列表当成配方返回。两个错误抵消成一个看似正确的通过，这正是单独修任何一个都会弄坏另一个的原因。

`tests/support/makefile.lua` 被四个测试文件依赖，现在有了自己的测试 `tests/unit/test_makefile_readers.lua`，对象是一个带着本项目不使用的形状的合成 Makefile。这正是要点：本项目的 Makefile 正是这些缺陷沉睡的原因，从它取材的夹具只能证明读取器在藏住缺陷的输入上仍然工作。`expanded` 现在也拒绝畸形表达式而不是返回空字符串——那是未定义变量的返回值——而它的每个调用方都在问发布物携带哪些文件，在那里，"没有"和"查不到"是两个不同的答案。

这道门拒绝给出它没有测过的结论。点名却缺失的 ELF 是错误，无法测量的同样是——第二种曾错着，形状与上面的 SBOM 缺陷相同：一个不可测量的文件对 combined floor 贡献零，零比任何承诺的下限都小，而结论所依据的比较分不清"要求为零"和"没有测量"。于是 `make baseline` 非零退出，它写出的报告却继续说 `status: within the promised floor`。退出码由 CI 读，报告由签署发布的人读，而当时只有报告在断言。报告现在说下限未定、给出有多少个命名文件无法测量、完全不携带结论。`tests/unit/test_native_baseline.lua` 同时断言两半——门失败*且*文档不背书——因为只检查退出码的测试对坏版本照样通过。

一个文件真正要求的，是将在目标上实际执行的每一个 ELF 镜像中最高的 glibc 版本，而这不总是只有文件本身。`tools/elf_floors.py` 测量文件及其携带的一切，原因是 onefile：`dist/wtop-onefile` 是一个 luainstaller 启动器，原生模块和 PUC Lua 解释器附加在其后，启动时解包并运行。按直观的方式测这个发布文件——对它跑 `objdump -T`——报告 GLIBC_2.34，而内嵌在同一文件里的解释器要求 GLIBC_2.38。产物在 2.34 上不能运行，显然测量产出的数字，错在把问题藏起来的那个方向。这与只测原生模块就称之为包的下限是同一个错误，只是深一层、更难看见：未被测量的文件在被测量的文件内部，任何目录清单和同目录路径都找不到它。内嵌镜像的数量总是被打印，所以一个压缩载荷、把它们藏起来的打包器会显示为零，而不是一个悄悄变低的下限。

在当前 Fedora x86_64 构建上：

| 文件 | 由谁产生 | 最高要求 |
| --- | --- | --- |
| `dist/wtop/wtop` | luainstaller | GLIBC_2.38 |
| `dist/wtop/.luai/native/wtop_native.so` | 本项目的 `make native` | GLIBC_2.34 |
| `dist/wtop-onefile` 启动器 | luainstaller | GLIBC_2.34 |
| └ 内嵌其中的解释器 | 锁定的 PUC Lua | GLIBC_2.38 |
| └ 内嵌其中的模块 | 本项目 | GLIBC_2.34 |
| `.tools/lua-5.5.1/bin/lua` | 锁定的 PUC Lua | GLIBC_2.38 |
| **combined floor** | | **glibc 2.38** |

下限由 wtop 不编译的两个文件决定：锁定的解释器和打包器的包装器。本项目从源码构建的一切都低于它们，这是要保持的安排——项目控制得了的下限才是移得动的下限；`tests/unit/test_native_baseline.lua` 现在直接断言这一点，因为模块是这对文件中 wtop 拥有的那一半，它绝不能成为抬高下限的那一方。

报告声称自己描述*哪一个*构建，也修正过一次。头部行过去写作 `revision:`，取自检出里的 `git describe`，这是关于源码树的陈述，不是关于报告内产物的陈述。坐在新树里的旧包，产出了一份写着当前 revision、描述旧字节的报告，里面没有任何东西能说明这一点。该行现在是 `checkout revision:`，每个产物带自己的 SHA-256，原生模块把源 revision 编译进去，于是一个产物可以被问是哪棵树构建的。

最后那半需要模块改动。`src/wtop/build_id.lua` 一直携带 revision，而它是到达 `--version` 的那一半，所以一个包可以装着旧树编译的模块、仍打印新的 revision：字符串来自程序的另一半，没有任何东西能反驳它。`l_system_constants` 现在也报告 `build_revision`，从生成的头文件编译而不是 `-D` 标志，让两侧出自 `tools/write_build_id.sh` 内同一次 `git describe`——两次独立读取可能在一个已构建、另一个未构建的时刻不一致，比较它们就是在比较噪声。头文件可选（`__has_include`），回退为空字符串：构建树之外编译的模块承认自己没有身份，而不是发明一个；`tests/unit/test_build_identity.lua` 同时检查两侧一致和该回退。

onefile 包无法与在它旁边构建的模块做字节比较：luainstaller 会 strip 它内嵌的副本，哈希永不匹配。要比的是模块报告的 revision，不是哈希。

一个包运行它携带的每一个文件，所以下限是其中最高的要求，不是最低的，也不是碰巧先被测到的那个。脚本以参数接收文件清单，正是为了让"报告给出一个数字"不会静默变成"报告测了两个文件中的一个"：那是过去的行为，而因为解释器是两者中较高的，它在唯一一份以发布证据为全部用途的文件里，把要求少报了四个次版本。点名一个不存在的 ELF 现在是硬错误，而不是一个更小的数字。

`tools/baseline.conf` 声明 wtop 承诺的下限，当前是 glibc 2.38。它是承诺，不是测量：产物需要*更多*时门才失败，新主机上的构建不能仅因成功而通过。降低下限意味着在更旧的 glibc 上构建——glibc 2.28 的 AlmaLinux 8 或 Debian 11 容器，或 glibc 2.17 的 manylinux2014 镜像——而不是改这个数字。抬高它则是一个关于支持哪些发行版的决定，`dist/BASELINE.txt` 里的证据必须能支撑它。

定上限的符号组值得点名，因为它们表明下限是构建主机的产物，而不是代码的要求：

- `fmod@GLIBC_2.38`，来自 PUC Lua 的 `lmathlib.c`，落在 `libm.so.6` 上。每个 glibc 都有 `fmod`；2.38 只是这一次给的版本标签。
- `exp`、`log`、`log2` 和 `pow@GLIBC_2.29`，同样来自 Lua 数学库。
- `dlopen`/`dlsym@GLIBC_2.34`，来自原生模块，它加载可选的 NVML、AMD SMI 和 Level Zero 厂商库。glibc 2.34 把 `libdl` 并入 `libc`，2.34 或更新的构建从 `libc.so.6` 解析这些名字，二进制不再携带 `libdl.so.2` 依赖；更旧的主机上，同一条 `-ldl` 链接对 `libdl.so.2@GLIBC_2.2.5` 解析。
- `stat`/`lstat`/`fstat@GLIBC_2.33`，同样是导出形状的变化，不是新函数。

`wtop_native.c:1202` 和 `:1533` 的 `stat`，`:1371` 和 `:1485` 的 `fstat`，是模块里仅有的文件系统元数据调用；wtop 不需要任何晚于最旧在用 glibc 的系统调用或接口。

### 9.1.1 是测出来的，不是争出来的

上面的主张只有在测过的时候才有价值，所以测了。`make cross-libc`（或 `tools/cross_libc_build.sh <image> [suite]`）把树流式送进一个发行版容器，用项目自己的旗标在容器里构建 Lua 和原生模块，并从产物二进制读出下限。同一份源码，两台构建主机：

| 构建主机 | Lua 解释器 | 原生模块 | combined |
| --- | --- | --- | --- |
| Fedora 44，glibc 2.43（开发） | 2.38 | 2.34 | **2.38** |
| manylinux2014，glibc 2.17 | 2.14 | 2.17 | **2.17** |

相差二十一个版本，出自同一棵树。`libdl` 的预测精确成立：glibc 2.17 上，模块的 `DT_NEEDED` 列出 `libdl.so.2`，`dlopen`/`dlsym` 在 `GLIBC_2.2.5` 解析；glibc 2.43 上，同一条 `-ldl` 链接从 `libc.so.6` 以 `GLIBC_2.34` 解析，`libdl.so.2` 完全不出现。加上 `suite` 还会在容器里运行整个单元套件：在 glibc 2.17 上 **通过 120 个测试文件**，并且 `wtop 0.1.0 (rev v0.1.0-43-g9cebfad-dirty)` 能回答 `--version`——所以 2.17 的产物是能用，而不只是能编译。

计数随测试增加而移动，上面的数字是 2026-10-02 那次运行报告的，而且是容器的，不是宿主机的。跑通这次运行不是走过场：这段话上次写 90 时它不是 89，有一阵它还错向另一头。那次运行曾在四个文件上失败了两个 increment 而无人重跑，原因不是 libc：manylinux2014 带 `python2` 不带 `python3`，四个失败里的三个，是 shell 出去调 `tools/elf_floors.py` 和 `tools/make_sbom.py` 的测试报 `python3: command not found`；第四个是 `tools/cross_libc_build.sh` 在容器里编译模块时没有 `build/native/build_revision.h`，模块没有构建身份，`test_build_identity.lua` 正确地拒绝在一个无法与之比较任何东西的模块上通过。两者都已处理——脚本安装 `python3`、暂存宿主机生成的头文件——并且暴露了第三件事：它失败所*穿过*的那道门。`record_baseline.sh` 正确地非零退出，但它已经写出的报告说 `status: within the promised floor`。那就是上一小节。

那两个 Python 工具也是这次运行当初根本跑不起来的原因：它们用了 `capture_output=`/`text=` 和 `from __future__ import annotations` 头，全是 3.7 的特性，而项目测量的最旧镜像自带的解释器是 3.6。一个无法在验证最旧支持 libc 的环境里启动的发布工具，就不是面向该 libc 的发布工具，所以两者现在都按 Python 3.6 编写。

同一次运行暴露了两个我自己的测试 bug，两者都曾在开发主机上因错误的原因通过。`test_elf_floors.lua` 断言组装夹具的下限等于*解释器的*——在本机为真（2.38 对 2.34），在容器里为假：那里两者互换，模块要 2.17、解释器要 2.14。被测的性质是"它携带的镜像中最高的那个"，所以期望值现在从两次测量计算得出，夹具按要求从低到高组装。`test_native_baseline.lua` 断言模块从不抬高下限，这是打包主机的性质，不是源码的：在 2.17 容器里，模块确实设定下限，而这对一个为该 libc 构建的版本是正确的。该检查现在限定在打包主机上——以解释器是发布承诺所针对的文件来识别——不适用时带着数字说明，而不是悄悄通过。在其他主机上不放弃的是对 C23 `__isoc23_*` 符号的直接扫描：它点名该比较所盯的回归的原因，并且在所有地方求值。

容器做不到的两件事，说清楚，免得数字被读得比它大。它共享宿主机内核，所以对最低内核什么也没说——那个问题在 9.2 里从源码回答，不从这里。它也不需要 bind 挂载：项目树从 stdin 流入，所以容器构建原则上不可能修改工作树。

到达那里需要两个真正的修复，两者在当前开发主机上都不可见、在旧主机上都致命——这是可移植性 bug 最坏的形状：

- 模块在 glibc 2.17 上根本**编译**不过。它的特性宏在 `_POSIX_C_SOURCE` 和 `_XOPEN_SOURCE` 之外还要了 `_DEFAULT_SOURCE`，而 `_DEFAULT_SOURCE` 在 glibc 2.19 之前不存在——它正是那次为"在其他特性宏被显式定义时暴露默认声明"而添加的，也就是此处的情形。没有它，`__USE_MISC` 不会出现，给出六个 `IFF_* undeclared` 错误和一个隐式 `syscall` 声明。

  对它的修复本身是第二个缺陷，而第一次尝试错在只有测量能抓到的地方。`_GNU_SOURCE` 是显然的答案：它是每个 glibc 都认的那个宏，也是让旧 libc 构建跑通期间这个文件所带的。它付出一个 glibc 版本：`_GNU_SOURCE` 之下，2.38 或更新的 glibc 把 `strtol` 和 `strtoull` 重定向到 C23 拼写 `__isoc23_strtol` 和 `__isoc23_strtoull`，于是模块的下限从 GLIBC_2.34 升到 GLIBC_2.38。没有任何东西失败：combined floor 没有动，因为解释器一直以来就要求 2.38；构建在 2.43 和 2.17 两台主机上都在 `-Werror` 下干净。唯一显出它的，是去读基线报告点名*哪个文件*设定了 combined floor。在一台 2.34 到 2.37 的主机上，它会白白发布一个比所需高一个版本的模块。

  现在在那里的是 pre-2.19 默认集的完整写出，加上同一思想的现代拼写：`_DEFAULT_SOURCE`、`_BSD_SOURCE`、`_SVID_SOURCE`、`_POSIX_C_SOURCE 200809L`、`_XOPEN_SOURCE 700`。每一个都在某处承重，又在任何单台主机上显得多余。`_DEFAULT_SOURCE` 是 2.19+ 的拼写，在 2.17 上什么都不做；`_BSD_SOURCE` 和 `_SVID_SOURCE` 是 2.17 的拼写，自 2.20 起作为弃用警告——除非同时定义了 `_DEFAULT_SOURCE`，也就是此处的安排；`_POSIX_C_SOURCE` 配 `_XOPEN_SOURCE 700` 是声明 `wcwidth` 的组合。在 glibc 2.43 和 2.17 上都验证过：各自在 `-Werror` 下干净，新者上下限 GLIBC_2.34，模块不引用任何 C23 符号。`tests/unit/test_native_build.lua` 钉住全部五个，并断言 `_GNU_SOURCE` 留在外面，理由写在做出这个选择的地方。

- 两条**受守卫的**代码路径在系统调用号缺失时留下残余：`signal_number` 在 pidfd 分支之前赋值、只在分支内读取；`read_process_starttime` 无条件定义，而它唯一的调用方在那个分支里。两者都是警告，而项目带 `-Werror` 构建，所以在旧工具链上，模块是构建失败，而不是缺了特性地构建成功。`tests/unit/test_native_build.lua` 现在用 shim 头文件摘掉系统调用宏、把模块编译四次，守卫分支因此在每台主机上都被检查，而不只在拥有那些头文件的机型上。该测试用 `-c` 而不是 `-fsyntax-only`，有具体原因：`-fsyntax-only` 发出抓第一个缺陷的未用变量警告，却静默跳过抓第二个的未用函数警告，一道语法检查会覆盖它声称的一半、并因与漏掉的那一半无关的原因通过。特性宏那一半根本无法这样检查——坏组合在当前主机上干净编译——测试说明这一点，转而断言已知坏的组合不存在，容器运行才是真正的证明。

wtop 承诺的下限仍是 glibc 2.38，因为那是项目自己文档化的构建路径产出的，而 `tools/baseline.conf` 是对发布产物的承诺。上面的测量是降低它所要的东西，而且是一份两部分的工作：在更旧的 glibc 上构建，降低的是模块的要求；但在锁定的 Lua 解释器和 luainstaller 包装器也被替换之前，包的下限仍是 2.38，因为是它们设定的。所以降低承诺意味着更换解释器版本或打包器，不只是更换构建主机——这值得在有人把"在旧 glibc 上构建"读成一行修复之前先知道。

### 9.2 没有最低内核要求

wtop 没有最低 Linux 内核，这是程序的性质，不是分析的缺席。没有任何东西把启动门在内核接口上：`Scheduler:probe_all` 在 `pcall` 之下运行每个采集器的探测，失败成为一条能力记录而不是致命错误，内核满足不了的能力，恰好只损失它自己的面板。一个*抛出*的探测——在一个从未铺出它想要路径的内核上，这正是最可能的形状——同样被接住，所以一个采集器带不倒程序。`Snapshot.merge` 只在该结果为 `ok` 时安装采集器的数据，并且无论哪样都写一条质量记录，于是来源缺失的面板会带着原因说明，而不是被塞一个数字。

`tests/unit/test_engine.lua` 对一个没有 cgroup v2、没有 PSI、没有 hwmon、DRM、powercap 和 cpufreq 的模拟旧内核钉住这一切：引擎仍探测、仍滴答、仍报告有来源的采集器，把每个缺失面板标为 `unavailable` 并带上采集器给出的原因，不为它安装数据，并记录图表空隙而不是编造的零。同一文件还钉住：抛出的探测仍然只是一条能力；带着非 `ok` 状态返回数据的采集器，不得改写它正在写入的快照。

对打包的后果是：最低内核选不出来，能发布的只有一组按来源的可用性陈述。[MONITORING.md](MONITORING.md) 列出每个来源喂哪个面板、内核不提供时面板显示什么。需要数字预期时，诚实的形态是按发行版验证过的范围，不是单个数字。[跨平台](CROSS_PLATFORM.md)验证矩阵记录了 wtop 0.1 实际运行过的主机——Fedora 44 x86_64、Ubuntu 24.04 aarch64 和 Debian 13 x86_64——其中没有一条记录运行时的内核版本，所以从中推不出任何数字下限，这里也不主张有。在每个已验证主机旁记录内核，是缺失的证据，而那是每行一句话，不是一项分析。

原生层是最低内核最可能藏身的地方，因为裸 `syscall(2)` 完全绕过 glibc，ELF 上没有 libc 版本可读。它用了三个，每一个都有守卫：

- `pidfd_open` 和 `pidfd_send_signal`（Linux 5.1 和 5.3）在 `#if defined(SYS_pidfd_open)` 之后，替代分支推送 `pidfd signaling is unavailable on this build`，而不是让调用失败。
- `close_range`（Linux 5.9）是 `close_extra_fds` 里的加速，不是机制本身。该函数回退到用 `getdents64` 枚举 `/proc/self/fd`——它自身带 `#ifdef` 守卫和一个 `ENOSYS` 分支——再回退到一个有界的 `close()` 循环，于是 pre-5.9 内核走慢路关闭描述符，而不是泄漏它们。
- `getdents64` 老到无需考虑。

三者若有任何一个被无守卫地调用，那个调用就是最低内核，而且它不会出现在 `dist/BASELINE.txt` 里——这就是这个主张从源码做出、而不是从报告做出的原因。

### 9.3 版本只写一次

同一个生成器现在也携带版本，因为版本曾有同样的问题，只是早一步，而且没人注意过。它被写了三次——在 `src/wtop/version.lua`、作为 `native/wtop_native.c` 里的字面量、作为 `tools/make_sbom.py` 里的回退字面量——而三处中的两处由用户运行的命令打印。`--version` 打印 Lua 树的版本，`--diagnose` 打印模块的版本，在同一份报告里、相邻两行。一次 bump 了一处没 bump 另一处的发布，就声明了两个不同的版本，而两个命令都没有说出来。

树顶的 `VERSION` 现在是人唯一编辑的地方。`tools/write_build_id.sh` 运行一次读取它，写出 `src/wtop/version.lua` 和 `build/native/build_version.h`，连同同一次运行的两个 revision 输出。C 模块推送生成的宏，不含自己的版本字面量。`tools/make_sbom.py` 读同一个文件；缺了它的树是硬错误，而不是一次猜测：一个发明版本号的回退，正是三份副本开始漂移的方式，因为 SBOM 那一份从未被与任何东西比较过。

`--version` 以报告 revision 不一致的方式报告版本不一致；这个报告被测试，尽管收敛意味着它在一个正确构建的树里不会触发。值得测试的原因，是守卫的第一次尝试如何失败：它比较模块的版本与声明的版本，并且**在 C 源码里把字面量恢复回去时照样通过**，因为那天字面量和声明版本是同一个字符串。一个与被守卫者永远一致的守卫，正是项目此前的安排——C 的那份副本，被钉在一个任何人 bump 版本都会顺手一起更新的测试里的字面量上。所以 `tests/unit/test_version_convergence.lua` 断言出处而不是相等：C 源码完全不得包含版本字符串，Lua 模块必须标记为生成，头文件的 Makefile 规则必须既依赖 `VERSION` 又依赖脚本，原生模块必须依赖版本头文件。值检查分不清派生的数字和抄来的数字；只有副本的缺席能。

一个值得点名的陷阱，因为构建现在依赖它：`VERSION` 是生成头文件规则的前置，而不只是脚本的输入。脚本无论版本是否变化都写 revision 头文件，于是只依赖脚本的规则会让一次版本 bump 什么都不重建——而一个到不了二进制文件的版本，正是本节所讲的失败。

## 10. 发布前仍需完成

- [x] 锁定并校验 Lua 5.5.1 工具链。
- [x] 生成确定性的语言区域 Lua 模块和字面注册表。
- [x] 为两种产物提供 onedir、onefile 和 PTY 目标。
- [x] 提供原生模块 ABI、包入口和 PTY 测试路径。
- [x] 把 onefile PTY 纳入标准 Make 目标。
- [x] 提供一个对发布物携带的一切生成 `dist/SHA256SUMS` 的目标：两个包的可执行入口、发布携带的原生模块，以及包携带的每一份声明。
- [x] 携带发布据以分发的条款，并让条款缺失导致失败。已于 2026-10-02 完成：此前 SBOM 对 `wtop` 和 `wtop_native` 声明 EUPL-1.2、对 `lua` 声明 MIT、对 `luainstaller` 声明 LGPL-3.0-or-later，而发布物**三者一个文本都没带**，`SHA256SUMS` 只覆盖两个可执行文件，两个 CI 上传作业发布的都是证据和程序而没有一份许可证文件——CI 产出的发布物完整、验证过、全绿，却没有自身条款的可读陈述。现在 `make bundle-dir` 把 `LICENSE` 复制进包，生成器拒绝声明文本缺失的许可证，`make test-release-notices` 直接询问包，CI 发布它们。onefile 仍不携带 EUPL 文本，不补丁第三方 LGPL 工具就无法做到；SBOM 以 `wtop:licence-text:present-in` 按许可证记录这一点，让分发者看见缺口而不是去推断。
- [x] 提供仅 Linux 的 LuaRocks rockspec、隔离安装目标和已安装 CLI 冒烟测试。
- [x] 采用 EUPL-1.2，并在源码、rock 安装文档和 README 文件中声明。
- [ ] 在最终发布提交上清理或隔离旧产物，并重跑每个打包目标；仓库里现有的 `dist/` 内容，不是产物与当前源码一致的证据。
- [ ] 对最终的 onedir/onefile 产物运行 CLI、快照、PTY、干净环境、`ldd` 和 `file` 校验，并保留日志。
- [x] 选定并验证最低 glibc 与 Linux 内核基线。glibc 下限按产物测量，并对 `tools/baseline.conf` 把门；最低内核的回答是"没有"，退化性质由 `tests/unit/test_engine.lua` 和 `MONITORING.md` 的按来源表格钉住。发行版级别的内核主张，仍需上一条中的按发行版运行。
- [ ] 在 glibc aarch64 上原生构建并测试。
- [ ] 每个计划中的 musl 目标独立构建并测试。
- [ ] 建立真实的 NVIDIA、AMD、Intel 和无 GPU 冒烟矩阵。
- [x] 在最终候选上重跑 `make checksums` 和 `make sbom`。SBOM 生成器在任何发布产物缺失、**或任何声明的许可证在发布中没有文本**时拒绝写出文档，因此一次成功的 `make sbom` 同时陈述了三份被哈希的文件都在，以及四个组件上声明的条款都能从包里读到。
- [ ] 为最终候选产出签名和完整的构建溯源记录。于 2026-10-02 从上一条拆出：上一条当时自己打着勾，而它正文四行之后写着相反的话——"it says nothing about signatures, which no target produces"——`docs/PLAN.md` §10 也始终把该能力列为待决问题。清单恰好乐观在计划悲观的地方，这是存活得最久的安排：清单是照着框读的，框下面的正文是没人重读的部分。`tests/unit/test_release_checklist.lua` 现在拒绝为计划仍列为待决的任何能力打勾；反方向上，计划关闭问题后，要求存在一条调用签名器的 Makefile 配方，因为关闭的问题和答不上它的构建，是两种不同的陈述。

- [x] 每份发布证据文档，拒绝为它无法测量的发布背书。门在点名的 ELF 缺失或不可测量时非零退出，报告此时**不**携带任何结论，而不是一个从没人得到的数字推出的下限。写下这条，是因为一道门曾非零退出、它的报告却仍说 `status: within the promised floor`；也是因为两个 CI 步骤无参数调用 `tools/record_baseline.sh`（自 ELF 清单成为必填起，这便是用法错误），而 shell 重定向已经创建了零字节的 `dist/BASELINE.txt`——发布作业上传的正是这个文件。`tests/unit/test_release_evidence.lua` 现在要求 `tools/` 里的每个脚本被分类，要求每个证据工具经由 Makefile 目标到达而不是被直接调用，要求 `make test-all` 依赖全部，并断言拒绝本身。
- [ ] 在发布主机上审查所有第三方声明和重链接材料。

## 11. 参考资料

- [luainstaller README](https://github.com/Water-Run/luainstaller)
- [Usage](https://github.com/Water-Run/luainstaller/blob/main/docs/USAGE.adoc)
- [Platforms and native modules](https://github.com/Water-Run/luainstaller/blob/main/docs/PLATFORMS-NATIVE-LIMITS.adoc)
