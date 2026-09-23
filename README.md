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

- Ten tabs: Overview, Processes, Compute, Memory, Storage, Network, GPU,
  Workloads, System and Insights.
- A process list with search, sorting, a tree view, and a confirmed
  signal menu.
- Optional deep checks (SMART/NVMe, memory bandwidth, sshd) when the host
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

## Use

| Key | Action |
|---|---|
| `1`–`8`, `Tab` | Switch tabs and focus |
| `f` | Change the update rate |
| `L` | Change language |
| `?` or `F1` | All keys |
| `q` or `Ctrl+C` | Quit |

<details>
<summary><b>Command-line options</b></summary>

| Option | |
|---|---|
| `--snapshot` | Print one JSON snapshot and exit |
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
