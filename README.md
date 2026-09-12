# wtop

**English** | [简体中文](README-zh.md)

**WaterRun's top** is a responsive Linux terminal performance workbench built
with PUC Lua 5.5.1 and a small C17 native module; it does not use LuaJIT.

> **Status:** `0.1.0-dev` development preview, not a stable release.
>
> **Linux only:** macOS, Windows, BSD, and Android/Termux are rejected by the
> build and runtime entry points.

## What it does

- Presents overview, processes, compute, memory, storage, network, GPU,
  workloads, system, and insights in a responsive ten-tab TUI.
- Collects CPU identity/topology/cache/core types, memory composition and
  paging counters, PSI, block devices with model/size/scheduler, mounts with
  inode usage, network interfaces with IPv4/IPv6 addresses, sockets, processes,
  CPU frequency, hwmon sensors, powercap, cgroup v2, DRM/PCI/fdinfo GPU data,
  host/kernel/distribution/firmware identity, and power supplies — all directly
  from Linux, with no external helper on the default path.
- Provides process search, eleven sort columns in both directions, trees,
  resolved user names, TIME+/VIRT/NI/thread columns, details, and a
  confirmation-gated signal menu (`SIGTERM`, `SIGKILL`, `SIGSTOP`, `SIGCONT`)
  protected against PID reuse.
- Offers on-demand SMART/NVMe, RAM-bandwidth, and sshd inspection when optional
  host tools and permissions are available.
- Uses a Lua-blue default palette with differential rendering, multi-row
  charts, per-core bar arrays, severity colouring, in-cell bars, mouse
  selection and click-to-sort, runtime theme switching, terminal colour
  fallbacks, display-width-correct CJK text, ten fully translated interface
  languages switchable at runtime, and persistent layouts.
- Exports complete JSON snapshots (`--snapshot`), compact automation context
  (`--agent`), and capability reports (`--diagnose`).
- Bounds expensive collection and reports unavailable, denied, partial,
  truncated, and counter-reset states explicitly.

## Requirements and installation

You need Linux with usable `/proc` and `/sys`, a POSIX shell, `make`, a C17
compiler, and bootstrap tools (`curl` or `wget`, `tar`, and `sha256sum`).
LuaRocks installation requires LuaRocks 3.13 or newer and PUC Lua
`>= 5.5, < 5.6`.

```bash
git clone https://github.com/Water-Run/wtop.git
cd wtop
luarocks --lua-version=5.5 make wtop-scm-1.rockspec
wtop --diagnose
```

Pass `--lua-dir=/path/to/lua-prefix` if LuaRocks cannot locate Lua 5.5.
`make luarocks-install` instead creates an isolated tree under `.tools/`.

## Run and test from source

The source build downloads official Lua 5.5.1, verifies its pinned SHA-256, and
keeps it inside the repository.

```bash
make run            # build and start the TUI
make check          # syntax checks
make test-fast      # isolated Lua tests and a small PTY smoke set
make test           # Lua 5.5 unit/fixture tests and PTY matrix
make test-all       # both Lua ABIs, LuaRocks, and both bundle forms
make test-54        # pure-Lua compatibility subset on system Lua 5.4
make test-luarocks  # isolated installation and CLI smoke test
make test-fuzz      # randomized input against the real terminal loop
```

Every push runs the same targets in CI across Ubuntu 22.04 and 24.04 with
both gcc and clang, plus sanitizers, the fuzzer, and both bundle forms.

Interactive mode requires stdin and stdout to be TTYs. For scripts, use
`wtop --snapshot` or `wtop --agent`. Run `wtop --help` for all options;
inside the TUI, press `?`/`F1` for keys and `q`/`Ctrl+C` to exit.

## Privileges

Core monitoring works as a regular user. `sudo wtop` starts elevated, while
`wtop --sudo` (alias: `--elevate`) asks wtop to relaunch through the system
`sudo` before collection; help and version output never prompt for a password.
Root state is reported in the TUI and structured output, and sudo-launched
sessions ignore file configuration, user locale catalogs, and persisted
layouts. Elevate only when needed; `--safe-mode` disables optional helpers.

## Documentation

See [Plan](docs/PLAN.md), [Architecture](docs/ARCHITECTURE.md),
[UI](docs/UI.md), [Monitoring](docs/MONITORING.md),
[Deep Inspection](docs/DEEP_INSPECTION.md), [i18n](docs/I18N.md),
[Packaging](docs/PACKAGING.md), and [Agent API](docs/AGENT.md).

## License

wtop uses the [EUPL-1.2](LICENSE): a strong copyleft license that is not the
GPL. The complete terms in `LICENSE` control.
