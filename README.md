# wtop

[English](README.md) · [中文](README-zh.md) · [Français](README-fr.md) · [Русский](README-ru.md)

**WaterRun's top** is a terminal system monitor that aims to run anywhere:
modern Linux, macOS and Windows, and also old machines and old consoles
that newer tools have left behind.

It shows CPU, memory, disks, network, processes, GPU and more in one
responsive screen, and adapts to what the terminal can actually do, from
a truecolor terminal with a mouse down to a plain `cmd.exe` window with
no color at all.

```bash
wtop                # interactive monitor
wtop --snapshot     # one JSON snapshot, for scripts
wtop --stream --count 60 > samples.jsonl  # 60 JSON snapshots
wtop --report       # English hardware summary in Markdown
wtop --diagnose     # what wtop can see on this machine
```

## Where it runs

| System | Status |
|---|---|
| Linux (x86_64) | Released as 0.1.0, installable with LuaRocks |
| Windows, 32-bit build | In development. Tested on Windows Server 2008 and current Windows; built for XP |
| macOS (Apple silicon, Intel) | In development. Runs on macOS 26 (Apple silicon) |

The Windows build is one 32-bit package that targets everything from XP to
Windows 11. It monitors Windows itself, not a Linux layer on top. XP is a
build target but hasn't been tested on a real XP machine yet.

> [!NOTE]
> Windows and macOS builds come from the source tree for now. The 0.1.0
> release and the LuaRocks package are Linux-only.

## Built for old hardware

- **Plain consoles.** wtop checks what the terminal supports before using
  colors, mouse, Unicode or the alternate screen. On a console without
  ANSI escape support, like `cmd.exe` on older Windows, it draws through
  the Windows console API instead, so escape codes don't end up on screen.
- **Small screens.** The layout reflows down to very small windows, and
  a colorless, keyboard-only ASCII mode stays usable.
- **Low overhead.** Collection runs on a timer with sensible floors, and
  panels you can't see aren't collected or drawn.
- **No dependencies.** It's PUC Lua plus a small C module. No Python, no
  runtime to install, no external helper on the default path.

## What it shows

- Ten built-in tabs: Overview, Processes, Compute, Memory, Storage, Network, GPU,
  Workloads, System and Insights.
- A process list with search, sorting, tree navigation, links to workloads,
  and a confirmed signal menu.
- Linux and Windows development builds list display devices and cached EDID specifications in System. Select a device and press `Enter` for details.
- Linux development builds show the kernel's configured output mode and nominal refresh separately from cached monitor specifications.
- macOS development builds show online displays, current mode dimensions and nominal refresh rates in System.
- On x86 Linux, development builds show CPUID capabilities alongside the kernel’s CPU topology and cache reports.
- Windows development builds can use Intel Sysman for GPU power, reported caps, clocks and throttling reasons.
- Supported AMD Windows drivers can provide chip power, temperature, clocks and fan speed through ADL.
- Windows development builds show NVMe temperature and reported limits in Storage. Press `s` for read-only drive health; ATA SMART is read after selecting a drive.
- Optional deep checks (SMART/NVMe, memory bandwidth, systemd units, sshd) when the host
  tools are available.
- Readings that failed or are incomplete are labeled as such (for example
  `denied` or `partial`) instead of showing up as blank or zero.
- Ten interface languages, switchable at runtime with `L`, and five color
  themes.

## Install

### Linux

With LuaRocks 3.13+ and Lua 5.5:

```bash
git clone https://github.com/Water-Run/wtop.git
cd wtop
luarocks --lua-version=5.5 make wtop-scm-1.rockspec
wtop
```

If LuaRocks can't find Lua 5.5, add `--lua-dir=/path/to/lua`.

Or skip LuaRocks and run from the source tree. This downloads Lua 5.5.1
into the repository, checks its SHA-256, and builds the native module:

```bash
make run
```

You need a C compiler, `make`, and `curl` or `wget`.

### Windows

Build the 32-bit package on Linux with a MinGW cross compiler
(`i686-w64-mingw32-gcc`):

```bash
./tools/build_windows_x86.sh
```

Copy `dist/windows-x86` to the Windows machine and run `wtop.cmd` from
`cmd.exe` or PowerShell. Over a Cygwin/OpenSSH session, use `wtop.sh`
instead.

### macOS

```bash
make run
```

The build lands in `dist/macos/wtop`. It targets macOS 11 on Apple silicon
and 10.13 on Intel.

`make test-bundles` builds and checks the directory and single-file packages
in `dist/macos-bundle/`.

## Use

| Key | Action |
|---|---|
| `1`–`9`, `0`, `Tab` | Switch tabs and focus |
| `e`, then `b` | Show, hide, reorder, create, or copy pages |
| `e`, then `a` | Add a widget to the current page |
| `j`/`k`, `Enter` in hardware tables | Select a device and open its details |
| `F` in process details | Show open file descriptors and their details on Linux |
| `d` / `D` | Inspect systemd units / sshd on Linux |
| `l` in unit details | Read recent journal messages on Linux |
| `u` | Inspect login sessions on Linux |
| `s` in journal or sshd details | Show a log summary on Linux |
| `f` | Change the update rate |
| `p` on Overview, Compute or GPU | Live power, caps, percentages, bars, session statistics and limit reasons |
| `B` | Switch block and Braille charts |
| `z` / `Z` | Show more / less time in charts |
| `L` | Change language |
| `?` or `F1` | All keys |
| `q` or `Ctrl+C` | Quit |

<details>
<summary><b>Command-line options</b></summary>

| Option | |
|---|---|
| `--snapshot` | Print one JSON snapshot and exit |
| `--stream` | Print snapshots as JSON Lines until interrupted |
| `--count N` | With `--stream`, stop after N snapshots |
| `--report` | Print an English hardware summary in Markdown |
| `--unmask-remote-addresses` | With `--snapshot` or `--stream`: export full remote socket addresses |
| `--agent` | Print compact JSON context for scripts and LLM agents |
| `--diagnose` | Show which data sources work on this machine |
| `--lang LOCALE` | Interface language, e.g. `zh-CN`, `fr-FR`, `ru-RU` |
| `--theme NAME` | `lua-blue`, `water-dark`, `water-light`, `high-contrast`, `colorblind` |
| `--interval MS` | Sampling interval, 100 to 10000 (default 1000) |
| `--no-color` | No colors |
| `--safe-mode` | Don't run any optional helper programs |
| `--sudo` | Restart through `sudo` (Linux) |

</details>

Settings can also go in `~/.config/wtop/config.yml`; see
[config.example.yml](config.example.yml).

### Root access

Everyday monitoring works as a normal user. Some details, like other
users' open sockets or SMART data, need root: run `sudo wtop` or
`wtop --sudo`. A root session doesn't read or write your personal config
or layout.

Some Windows drive queries require administrator rights.

## Development

| Command | |
|---|---|
| `make run` | Build and start |
| `make test-fast` | Quick tests |
| `make test` | Unit, fixture and terminal tests |
| `make test-all` | Everything, including LuaRocks and bundles |

Design notes are in [docs/](docs/): [architecture](docs/ARCHITECTURE.md),
[cross-platform](docs/CROSS_PLATFORM.md), [UI](docs/UI.md),
[monitoring](docs/MONITORING.md), [i18n](docs/I18N.md),
[packaging](docs/PACKAGING.md) and the [agent JSON](docs/AGENT.md).

## License

[EUPL-1.2](LICENSE).
