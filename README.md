# wtop

[中文](README-zh.md)

**WaterRun's top** is a responsive Linux terminal performance workbench built
with PUC Lua 5.5.1 and a small C17 native module; it doesn't use LuaJIT.

> This release supports Linux.

## What it does

- Shows overview, processes, compute, memory, storage, network, GPU,
  workloads, system, and insights in a ten-tab TUI.
- Reads CPU, memory, disks, mounts, network interfaces, sockets, processes,
  sensors, cgroup v2, GPU, and power straight from `/proc` and `/sys` — no
  external helper on the default path.
- Process search, eleven sort columns in both directions, trees, resolved user
  names, details, and a confirmation-gated signal menu (`SIGTERM`, `SIGKILL`,
  `SIGSTOP`, `SIGCONT`) that guards against PID reuse.
- On-demand SMART/NVMe, RAM-bandwidth, and sshd inspection when the host tools
  and permissions are available.
- Lua-blue palette with charts, per-core bars, severity colouring, mouse
  selection, click-to-sort, runtime theme switching, terminal colour
  fallbacks, display-width-correct CJK text, ten interface languages
  switchable at runtime, and persistent layouts.
- Exports JSON snapshots (`--snapshot`), compact automation context
  (`--agent`), and capability reports (`--diagnose`).
- Expensive collection is bounded; when a read fails or is incomplete, wtop
  reports it — unavailable, denied, partial, truncated, or counter-reset —
  instead of showing blanks.

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

Pass `--lua-dir=/path/to/lua-prefix` if LuaRocks can't find Lua 5.5.
`make luarocks-install` installs into an isolated tree under `.tools/`
instead.

## Run and test from source

The source build downloads official Lua 5.5.1, verifies its pinned SHA-256,
and keeps it inside the repository.

| Target | What it does |
|---|---|
| `make run` | Build and start the TUI |
| `make check` | Syntax checks |
| `make test-fast` | Isolated Lua tests and a small PTY smoke set |
| `make test` | Lua 5.5 unit/fixture tests and PTY matrix |
| `make test-all` | Both Lua ABIs, LuaRocks, and both bundle forms |
| `make test-54` | Pure-Lua compatibility subset on system Lua 5.4 |
| `make test-luarocks` | Isolated installation and CLI smoke test |
| `make test-fuzz` | Randomized input against the real terminal loop |

Every push runs the same targets in CI on Ubuntu 22.04 and 24.04 with both
gcc and clang, plus sanitizers, the fuzzer, and both bundle forms.
`make test-fuzz` isn't part of `make test`: it's slow and non-deterministic
by design.

Interactive mode needs stdin and stdout to be TTYs. For scripts, use
`wtop --snapshot` or `wtop --agent`. Run `wtop --help` for all options;
inside the TUI, press `?`/`F1` for keys and `q`/`Ctrl+C` to exit.

## Privileges

Core monitoring works as a regular user. `sudo wtop` starts elevated, while
`wtop --sudo` (alias: `--elevate`) asks wtop to relaunch through the system
`sudo` before collection; help and version output don't prompt for a
password. Root state is shown in the TUI and structured output, and
sudo-launched sessions ignore file configuration, user locale catalogs, and
persisted layouts. Elevate only when needed; `--safe-mode` disables optional
helpers.

## Documentation

See [Plan](docs/PLAN.md), [Architecture](docs/ARCHITECTURE.md),
[UI](docs/UI.md), [Monitoring](docs/MONITORING.md),
[Deep Inspection](docs/DEEP_INSPECTION.md), [i18n](docs/I18N.md),
[Packaging](docs/PACKAGING.md), and [Agent API](docs/AGENT.md).

## License

wtop uses the [EUPL-1.2](LICENSE): a strong copyleft license that isn't the
GPL. The complete terms in `LICENSE` control.
