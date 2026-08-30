# 构建、LuaRocks 安装与 luainstaller 打包

## 1. 当前状态

wtop 当前版本为 `0.1.0-dev` development preview。仓库已经包含可工作的
Lua 5.5.1 bootstrap、C17 原生模块、确定性 locale 编译、LuaRocks rockspec、
luainstaller onedir/onefile target 和 PTY smoke test，但尚未建立正式发行所需的
多架构、libc、旧 glibc 与发行版矩阵。

当前构建没有运行时 LuaRock 依赖。交互终端、poll、信号、原子写入、受限
子进程执行和少量 Linux syscall 由 `wtop_native.so` 提供。原生文件读取器以
nonblocking/no-follow 方式打开并只接受 regular file，默认 4 MiB、显式最大
64 MiB；symlink、设备、FIFO 和超限内容会拒绝。

## 2. 必须遵守的约束

- 只使用官方 PUC Lua；luainstaller 拒绝 LuaJIT。
- 发布 ABI 固定为 Lua 5.5；解释器、headers、linked runtime 和
  `wtop_native.so` 必须来自同一 major.minor。
- luainstaller 不做跨架构、跨 libc 构建；每个目标必须原生构建。
- luainstaller 会复制发现的 `.so`，不会递归收集其传递系统依赖、重写
  第三方 RPATH 或判断目标机 glibc 是否足够新。
- 静态依赖发现依赖字面量 `require`；动态模块必须通过 registry 或
  `--include` 明确加入。
- `--include` 面向 Lua 源文件，不是任意 YAML/资源打包开关。
- onefile 会自解包后运行，不等于完全静态 ELF。

不要同时对同一个 `dist/wtop` 或 `dist/wtop-onefile` 路径发起多个构建；
luainstaller 会用输出锁拒绝并发或未清理的构建。

## 3. 构建主机要求

开发、测试和源码运行需要：

- Linux、POSIX shell、`make`；
- 支持 C17 的 C 编译器；
- `tar`、`sha256sum`，以及首次下载时的 `curl` 或 `wget`；
- PTY smoke test 使用 Python 3。

LuaRocks 源码安装和打包另外需要系统 LuaRocks 3.13 或更新版本。
`tools/bootstrap_luainstaller.sh`
默认从 LuaRocks 安装 luainstaller `1.3.0-1` 到项目内 `.tools/rocks-5.5`，并用
`tools/luainstaller-1.3.0.sha256` 校验固定 payload；已有安装只有在版本、payload
hash 和 `luai -h` 都通过时才复用。相邻 `../luainstaller` 工作树不再被自动采用。

本地联调只能显式提供绝对路径：

```bash
WTOP_LUAINSTALLER_ROCKSPEC=/absolute/path/luainstaller-1.3.0-1.rockspec \
  make luainstaller
```

相对路径会拒绝。这个 opt-in 分支使用调用者指定的源码，不代表默认锁定 payload
已经验证，不能直接作为发布构建证据。

### 3.1 LuaRocks 源码安装

`wtop-scm-1.rockspec` 是开发分支安装入口，参考 luainstaller 的 rockspec 元数据与
命令安装方式，但针对 wtop 的完整 Lua module 树和 C17 模块使用 LuaRocks `make`
backend。它声明：

- `supported_platforms = { "linux" }`；
- PUC Lua `>= 5.5, < 5.6`；
- MPL-2.0；
- 无第三方运行时 LuaRock 依赖。

在已经配置好 PUC Lua 5.5 与 headers 的环境中执行：

```bash
luarocks --lua-version=5.5 make wtop-scm-1.rockspec
```

需要显式 Lua prefix 时附加 `--lua-dir=/absolute/puc-lua-prefix`。维护者可以用隔离
tree 进行端到端验证：

```bash
make rockspec-check
make test-luarocks
```

`make test-luarocks` 会 bootstrap 项目 Lua 5.5.1，把 rock 安装到
`.tools/wtop-rocks-5.5`，然后从 LuaRocks 生成的 wrapper 运行 `--version` 和
`--diagnose`。rock 安装内容包含 Lua modules、`wtop_native.so`、`wtop` 命令以及
根许可证、README、配置示例。`rock-build`/`rock-install` 只是 rockspec backend
入口，不是面向终端用户的独立安装命令。

## 4. 可复现 Lua toolchain

`make toolchain` 调用 `tools/bootstrap_lua.sh`：

1. 下载官方 `lua-5.5.1.tar.gz`，或复用 `.tools/downloads` 中的文件；
2. 校验脚本内固定的 SHA-256；
3. 从源码构建；
4. 安装到 `.tools/lua-5.5.1`。

该流程不替换系统 Lua。标准源码构建：

```bash
make toolchain
make native
make locales
```

也可以使用：

```bash
make all
```

原生模块输出为 `build/native/wtop_native.so`，直接使用本项目 Lua 5.5.1
headers 编译。默认 `CFLAGS_NATIVE` 是 `-O2 -g0`，并追加 C17、PIC 和严格 warning
选项；调用者仍可显式覆盖优化/debug flags。native target 同时依赖
`native/wtop_native.c`、Lua toolchain stamp 和 `Makefile`，所以修改 Makefile 中的
编译规则会触发重编译。不同 Lua ABI 不能复用这个文件。

## 5. Locale 构建输入

`locales/*.yml` 是权威翻译源。内置目录在构建期经过：

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

执行：

```bash
make locales
```

CI/审查可以额外验证生成物未过期：

```bash
.tools/lua-5.5.1/bin/lua tools/compile_locales.lua \
  --source locales \
  --output src/wtop/generated/locales \
  --check
```

生成文件位于 `src/wtop/generated/locales`。registry 对每个内置目录使用
字面量 `require`；Makefile 同时根据该目录生成显式 `--include` 参数。
onefile/onedir 运行时不解析内置 YAML。

TUI 启动时还会自动扫描用户目录
`$XDG_CONFIG_HOME/wtop/locales/*.yml`（未设置时为
`~/.config/wtop/locales/*.yml`），通过同一受限 YAML parser 加载覆盖目录；最多
读取 64 个文件，每个文件最多 1 MiB。用户目录不属于 bundle payload，也不参与
内置 locale 的确定性构建。单个用户目录解析失败会报告 partial/error 并继续使用
可用目录与内置回退。

## 6. 当前 Make target

| Target | 行为 |
| --- | --- |
| `make run` | 构建 native/locale 后启动 TUI |
| `make diagnose` | 输出能力诊断 |
| `make snapshot` | 输出一个 JSON snapshot |
| `make check` | 使用项目 Lua 5.5 `luac -p` 检查 Lua 源码 |
| `make test-55` | 36 个 Lua 5.5 单元和 fixture 测试文件 |
| `make test-54` | 使用系统 `lua` 运行同 36 个文件，验证纯 Lua 5.4 兼容子集 |
| `make test-pty` | 八种响应式尺寸、切页和四种色彩/字符能力 profile 的真实 PTY smoke test |
| `make test` | `test-55` 加 `test-pty` |
| `make rockspec-check` | 使用 LuaRocks 校验 `wtop-scm-1.rockspec` |
| `make luarocks-install` | 安装到项目内隔离的 `.tools/wtop-rocks-5.5` tree |
| `make test-luarocks` | 重装隔离 rock 并运行已安装 CLI smoke test |
| `make luainstaller` | bootstrap 固定版本 luainstaller |
| `make bundle-dir` | 生成 onedir |
| `make bundle-file` | 生成 onefile |
| `make test-bundle-dir` | 重建 onedir 并对其运行 PTY smoke test |
| `make test-bundle-file` | 原子替换 onefile 并对其运行 PTY smoke test |
| `make checksums` | 要求两种 bundle 已存在，生成 `dist/SHA256SUMS` |

实际 bundle 命令由 Makefile 维护，入口为 `src/wtop.lua`：

```bash
make luainstaller
make bundle-dir
make bundle-file
make checksums
```

输出路径固定为：

```text
dist/wtop/wtop
dist/wtop-onefile
dist/SHA256SUMS
```

`SHA256SUMS` 当前只列出 `wtop/wtop` 和 `wtop-onefile` 两个可执行入口，不是对
onedir 内每个文件的清单，也不提供签名或 SBOM。运行 target 前必须先成功生成
两种 bundle；每次最终候选重建后都应重新生成。

`dist/`、`build/` 和 `.tools/` 都是本机构建产物，不应被当作源码或跨主机
可复用的发布物。

## 7. 产物结构

onedir 是当前诊断基线，包含：

- `wtop` launcher；
- `.luai/native/wtop_native.so`；
- `.luai/manifest.lua`；
- `.luai/generated-output.txt`；
- 生成的 launcher C 源、relinking 说明和相关第三方通知。

luainstaller 1.3.0 的 `.luai/generated-output.txt` 是生成输出 inventory；其
`output_dir=` 按设计记录构建时的 onedir 输出目录，因此可以包含绝对构建路径。
launcher 运行时不依赖该目录。它仍需作为构建 provenance 审阅，但不能把这个
预期字段误判成 ELF 运行依赖或用“payload 中出现任何私有路径即失败”的过强规则处理。

onefile 把相同 payload 包装成自解包 executable。它仍依赖目标 Linux 的
ELF loader/libc，并可能受到不可写或 `noexec` 临时目录策略影响。出现
onefile 启动问题时，应先用 onedir 重现。

`bundle-file` 先生成 `dist/.wtop-onefile.next`，成功后再原子替换正式路径；
因此重复构建不会因旧 onefile 已存在而失败，也不会在构建失败时破坏上次产物。

可选的 `smartctl`、`systemctl`、`perf` 和 `sleep` 不会被打包；对应 Inspector
只在运行时通过 PATH/固定系统路径探测。`ss`、`nvidia-smi`、`rocm-smi` 和
`intel_gpu_top` 等工具当前只出现在 `--diagnose` 的可执行文件报告中，不是数据
provider。核心 collectors 不依赖这些工具，发行物也不携带厂商驱动库。

## 8. 验证

### 8.1 源码与 PTY

```bash
make check
make test
make test-54
```

PTY matrix 当前覆盖 `40×10`、`60×20`、`80×24/25`、`80×50`、`160×24`、
`200×22`、`180×45` 和 `200×45` 切页，并检查中文帧、交互路径、alternate
screen 进入/恢复、完整帧与正常退出。额外 profile 分别断言 truecolor、256 色、
16 色和无色 ASCII 输出，并覆盖 Water Light、High Contrast 与 Colorblind 主题；
2–8 页还会分别作为最终终屏验证完整绘制和页面语义标记。

Lua 测试还覆盖 JSON 4 MiB/深度/100000-node 预算、数字线性解析 smoke、非法
UTF-8 值与 key 的 U+FFFD 替换、默认连接导出 ID 脱敏，以及 bounded regular-file
reader。测试通过不把 36 个 fixture 文件扩大为跨内核、硬件或恶意输入形式化证明。

### 8.2 打包后 PTY

```bash
make test-bundle-dir
make test-bundle-file
```

### 8.3 clean environment

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

该检查故意让所有可选 helper 变为 unavailable，并验证 bundle 不依赖系统
`lua`、`LUA_PATH`、`LUA_CPATH` 或源码目录。交互模式仍应另跑 PTY smoke。

### 8.4 原生依赖

每个目标构建都检查：

```bash
ldd build/native/wtop_native.so
ldd dist/wtop/wtop
file build/native/wtop_native.so dist/wtop/wtop dist/wtop-onefile
readelf -dW build/native/wtop_native.so
strings build/native/wtop_native.so dist/wtop/wtop dist/wtop-onefile
```

ELF 中不应嵌入源码树或构建目录，意外共享库、RPATH/RUNPATH 或错误架构也应使
发布失败。这个检查针对运行 ELF；onedir 的 `.luai/generated-output.txt` 例外如上，
其他文本 payload 仍应逐项审阅。当前原生模块不链接 NVML、AMD SMI 或 Level Zero。

## 9. 当前平台边界

项目在五处落实 Linux-only：rockspec 平台 allowlist、Makefile 解析期检查、两个
bootstrap 脚本、C 模块编译期检查以及统一 CLI 运行入口。现有 Makefile 会为
“当前 Linux 构建主机”生成产物。仓库当前 `dist/` 来自 Fedora
glibc x86_64 开发验证，不是正式发布物；尚未选择或验证最低 glibc 版本，不能从
该产物在开发机可运行、ELF interpreter 或 `file` 输出推导兼容基线。当前验证也
不构成以下发布承诺：

- aarch64；
- musl；
- 旧 glibc；
- 任意指定最低内核；
- deb/rpm/Arch 包；
- 所有终端与 GPU 驱动。

这些目标必须在对应架构/libc 上原生重建，并以各自的 `ldd`、clean-env、
PTY 和硬件 smoke test 为证据。不同 libc 或 Lua major.minor 之间不能共享
`wtop_native.so`。

## 10. 发布前仍需完成

- [x] 固定并校验 Lua 5.5.1 toolchain。
- [x] 生成确定性 locale Lua modules 与字面量 registry。
- [x] 提供 onedir、onefile 及两种产物的 PTY target。
- [x] 提供 native module ABI、bundle 入口和 PTY 测试路径。
- [x] onefile PTY 纳入标准 Make target。
- [x] 提供为两个 bundle 可执行入口生成 `dist/SHA256SUMS` 的 target。
- [x] 提供 Linux-only LuaRocks rockspec、隔离安装 target 与已安装 CLI smoke test。
- [x] 采用 MPL-2.0 并在源码、rock 安装文档和 README 中声明。
- [ ] 在最终 release commit 上清理或隔离旧产物并重跑全部 bundle target；仓库中
  已存在的 `dist/` 不能当作与当前源码同步的证据。
- [ ] 对最终 onedir/onefile 运行 CLI、snapshot、PTY、clean-env、`ldd` 和 `file`
  验证并保存日志。
- [ ] 选择并验证最低 glibc 与 Linux kernel 基线。
- [ ] 在 glibc aarch64 上原生构建和测试。
- [ ] 为计划支持的 musl 目标独立构建和测试。
- [ ] 建立真实 NVIDIA、AMD、Intel 和无 GPU smoke matrix。
- [ ] 在最终候选上重跑 `make checksums`，并另行产出 SBOM、签名和完整构建来源记录。
- [ ] 在发布主机复核所有第三方通知和 relinking 材料。

## 11. 参考

- [luainstaller README](https://github.com/Water-Run/luainstaller)
- [Usage](https://github.com/Water-Run/luainstaller/blob/main/docs/USAGE.adoc)
- [Platforms and native modules](https://github.com/Water-Run/luainstaller/blob/main/docs/PLATFORMS-NATIVE-LIMITS.adoc)
