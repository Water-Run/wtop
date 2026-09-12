# Building, LuaRocks Installation, and luainstaller Packaging

## 1. Current Status

wtop `0.1.0` ships a working Lua 5.5.1 bootstrap, C17 native module, deterministic locale compilation, LuaRocks rockspec, luainstaller onedir/onefile targets, and PTY smoke tests. It does not ship a formal-release matrix across multiple architectures, libcs, older glibc versions, and distributions; `CHANGELOG.md` records exactly what this release was built and tested on.

The build has no runtime LuaRock dependencies. `wtop_native.so` provides interactive terminal handling, poll, signals, atomic writes, constrained subprocess execution, and a small set of Linux syscalls. The native file reader opens in nonblocking/no-follow mode, accepts regular files only, defaults to 4 MiB with an explicit 64 MiB maximum, and rejects symlinks, devices, FIFOs, and oversized content while still supporting procfs/sysfs pseudo-files presented as regular files.

## 2. Mandatory Constraints

- Use official PUC Lua only; luainstaller rejects LuaJIT.
- The release ABI is Lua 5.5. The interpreter, headers, linked runtime, and `wtop_native.so` must all have the same major.minor version.
- luainstaller does not cross-build between architectures or libcs. Every target must be built natively.
- luainstaller copies discovered `.so` files but does not recursively collect their transitive system dependencies, rewrite third-party RPATH, or determine whether a target machine's glibc is sufficiently new.
- Static dependency discovery requires literal `require`. Dynamic modules must be added through a registry or explicit `--include`.
- `--include` is for Lua source files, not arbitrary YAML/resource packaging.
- A onefile executable extracts itself before running; it is not a fully static ELF.

Do not start multiple builds against the same `dist/wtop` or `dist/wtop-onefile` path. luainstaller rejects concurrent builds and outputs left locked by an unclean build.

Before compiling or testing, the Make entry points run a lightweight resource-health check. It takes the tighter of host and cgroup v2 memory/swap headroom, observes host and cgroup memory PSI, checks load per CPU, and refuses unsafe work by default. Memory must independently meet the profile floor; default Swap contributes only bounded additional headroom, while an explicit Swap threshold remains exact. This protects the development host after an OOM event; it is not a benchmark or a guarantee that arbitrary third-party commands are safe.

## 3. Build-Host Requirements

Development, testing, and source execution require:

- Linux, a POSIX shell, and `make`;
- a C17-capable compiler;
- `tar`, `sha256sum`, and `curl` or `wget` for the initial download;
- Python 3 for PTY smoke tests.

LuaRocks source installation and packaging require LuaRocks 3.13 or later, because Lua 5.5 is not a target LuaRocks understood before 3.12 and Ubuntu 24.04 still ships 3.8. `tools/bootstrap_luarocks.sh` therefore builds the pinned 3.13.0 release against the project's own Lua 5.5.1 into `.tools/luarocks`, verifying the downloaded archive against a recorded SHA-256, and every packaging target uses that binary rather than whatever `luarocks` is on `PATH`. `tools/bootstrap_luainstaller.sh` installs luainstaller `1.3.0-1` from LuaRocks into the project-local `.tools/rocks-5.5` by default and validates the fixed payload against `tools/luainstaller-1.3.0.sha256`. An existing installation is reused only when its version, payload hash, and `luai -h` all validate. An adjacent `../luainstaller` worktree is no longer selected automatically.

Local integration requires an explicit absolute path:

```bash
WTOP_LUAINSTALLER_ROCKSPEC=/absolute/path/luainstaller-1.3.0-1.rockspec \
  make luainstaller
```

Relative paths are rejected. This opt-in branch uses caller-supplied source; it does not prove that the default locked payload was validated and cannot by itself serve as release-build evidence.

### 3.1 LuaRocks Source Installation

`wtop-scm-1.rockspec` is the development-branch installation entry point. It follows luainstaller's rockspec metadata and command-install pattern, while using the LuaRocks `make` backend for wtop's complete Lua module tree and C17 module. It declares:

- `supported_platforms = { "linux" }`;
- PUC Lua `>= 5.5, < 5.6`;
- EUPL-1.2;
- no third-party runtime LuaRock dependencies.

In an environment with PUC Lua 5.5 and matching headers, run:

```bash
luarocks --lua-version=5.5 make wtop-scm-1.rockspec
```

Add `--lua-dir=/absolute/puc-lua-prefix` when an explicit Lua prefix is required. Maintainers can perform end-to-end validation in an isolated tree:

```bash
make rockspec-check
make test-luarocks
```

`make test-luarocks` bootstraps the project's Lua 5.5.1, installs the rock into `.tools/wtop-rocks-5.5`, then runs `--version` and `--diagnose` through the LuaRocks-generated wrapper. The rock includes Lua modules, `wtop_native.so`, the `wtop` command, and the root license, English README, Chinese README, and configuration example. `rock-build`/`rock-install` are rockspec backend entry points, not standalone end-user installation commands.

Privilege re-execution preserves the real process argv, including LuaRocks-generated wrappers, and replaces only argv[0] with the current executable path before invoking a fixed system `sudo`. It does not construct a shell command or trust an arbitrary `sudo` from PATH.

## 4. Reproducible Lua Toolchain

`make toolchain` invokes `tools/bootstrap_lua.sh`:

1. Download official `lua-5.5.1.tar.gz`, or reuse the file in `.tools/downloads`.
2. Verify the SHA-256 fixed in the script.
3. Build from source.
4. Install under `.tools/lua-5.5.1`.

This does not replace system Lua. Standard source build:

```bash
make toolchain
make native
make locales
```

Or:

```bash
make all
```

The native module is written to `build/native/wtop_native.so` and compiled directly against the project's Lua 5.5.1 headers. Default `CFLAGS_NATIVE` is `-O2 -g0`, with C17, PIC, and strict warning options appended; callers may still override optimization/debug flags explicitly. The native target depends on `native/wtop_native.c`, the Lua toolchain stamp, and `Makefile`, so edits to compilation rules trigger rebuilding. The file cannot be shared between Lua ABIs.

## 5. Locale Build Inputs

`locales/*.yml` is the authoritative translation source. Built-in catalogs pass through:

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

Run:

```bash
make locales
```

CI/review can additionally verify that generated output is current:

```bash
.tools/lua-5.5.1/bin/lua tools/compile_locales.lua \
  --source locales \
  --output src/wtop/generated/locales \
  --check
```

Generated files live in `src/wtop/generated/locales`. The registry uses literal `require` for each built-in catalog, and the Makefile generates corresponding explicit `--include` arguments. onefile/onedir do not parse built-in YAML at runtime.

At startup, the TUI also scans `$XDG_CONFIG_HOME/wtop/locales/*.yml` (or `~/.config/wtop/locales/*.yml`) and loads overriding catalogs through the same restricted YAML parser. It reads at most 64 files and 1 MiB per file. The user directory is not part of the bundle payload or deterministic built-in locale build. A user-catalog parse failure reports partial/error and loading continues with usable catalogs and built-in fallback.

## 6. Current Make Targets

| Target | Behavior |
| --- | --- |
| `make resource-check` | Run the default preflight and refuse work without memory/swap/PSI/load headroom |
| `make run` | Build native/locales, then start the TUI |
| `make diagnose` | Emit capability diagnostics |
| `make snapshot` | Emit one JSON snapshot |
| `make check` | Validate Lua, POSIX shell, Python, and the Agent JSON schema |
| `make test-fast` | Run the 47 Lua files and a representative three-case PTY profile |
| `make test-55` | 47 Lua 5.5 unit and fixture test files |
| `make test-54` | Run the same 47 files with system Lua 5.4 to validate the pure-Lua-compatible subset |
| `make test-fuzz` | Randomized keys, mouse reports, malformed escapes, invalid UTF-8, and resizes against the real terminal loop |
| `make test-pty` | Real-PTY smoke tests for responsive sizes, page switching, and four color/character-capability profiles |
| `make test` | `test-55` plus `test-pty` |
| `make test-all` | Serial release-style validation across both Lua ABIs, LuaRocks, onedir, onefile, and their PTY/JSON contracts |
| `make luarocks-bootstrap` | Build the pinned LuaRocks 3.13.0 into `.tools/luarocks` |
| `make rockspec-check` | Validate `wtop-scm-1.rockspec` through LuaRocks |
| `make luarocks-install` | Install into the isolated project `.tools/wtop-rocks-5.5` tree |
| `make test-luarocks` | Reinstall the isolated rock and run installed-CLI smoke tests |
| `make luainstaller` | Bootstrap the fixed luainstaller version |
| `make bundle-dir` | Generate onedir |
| `make bundle-file` | Generate onefile |
| `make test-bundle-dir` | Rebuild onedir and run PTY smoke tests against it |
| `make test-bundle-file` | Atomically replace onefile and run PTY smoke tests against it |
| `make checksums` | Require both bundles and generate `dist/SHA256SUMS` |

Resource-sensitive build/check/test targets are nonparallel at the Make orchestration layer. `tools/check_resources.sh` exposes explicit `build`, `test`, and `full` profiles and honors cgroup v2 ancestor limits. Fixture-only `WTOP_RESOURCE_PROC_ROOT`, `WTOP_RESOURCE_CGROUP_ROOT`, and `WTOP_RESOURCE_CPU_COUNT` inputs make this logic deterministic in tests. The explicit `WTOP_SKIP_RESOURCE_CHECK=1` override is reserved for an operator who has independently verified headroom; automated validation should not set it.

The actual bundle command is maintained by the Makefile, with `src/wtop.lua` as its entry point:

```bash
make luainstaller
make bundle-dir
make bundle-file
make checksums
```

Output paths are fixed:

```text
dist/wtop/wtop
dist/wtop-onefile
dist/SHA256SUMS
```

`SHA256SUMS` currently lists only the `wtop/wtop` and `wtop-onefile` executable entry points. It is not a manifest of every onedir file and provides neither signatures nor an SBOM. Both bundles must be generated successfully before this target runs, and checksums should be regenerated after every final-candidate rebuild.

`dist/`, `build/`, and `.tools/` are local build artifacts; they must not be treated as source or reusable cross-host releases.

## 7. Artifact Structure

onedir is the current diagnostic baseline and contains:

- the `wtop` launcher;
- `.luai/native/wtop_native.so`;
- `.luai/manifest.lua`;
- `.luai/generated-output.txt`;
- generated launcher C source, relinking instructions, and relevant third-party notices.

luainstaller 1.3.0's `.luai/generated-output.txt` is the generated-output inventory. Its `output_dir=` intentionally records the onedir output directory used during the build and may contain an absolute build path. The launcher does not depend on that directory at runtime. The field must still be reviewed as build provenance, but it must not be mistaken for an ELF runtime dependency or rejected by an overbroad “no private path anywhere in the payload” rule.

onefile wraps the same payload in a self-extracting executable. It still depends on the target Linux ELF loader/libc and can be affected by an unwritable or `noexec` temporary-directory policy. Reproduce onefile startup problems with onedir first.

`bundle-file` first generates `dist/.wtop-onefile.next`, then atomically replaces the final path only after success. Repeated builds therefore do not fail merely because an old onefile exists, and a failed build does not destroy the previous artifact.

Optional `smartctl`, `systemctl`, `perf`, and `sleep` are not bundled. Their Inspectors probe PATH/fixed system paths at runtime. `ss`, `nvidia-smi`, `rocm-smi`, and `intel_gpu_top` currently appear only in the `--diagnose` executable report, not as data providers. Core collectors do not depend on these tools, and distributions do not include vendor driver libraries.

## 8. Validation

### 8.1 Source and PTY

First confirm resource headroom, then run:

```bash
make check
make test
make test-54
```

The PTY matrix currently covers `40×10`, `60×20`, `80×24/25`, `80×50`, `160×24`, `200×22`, `180×45`, and `200×45` page switching. It checks Chinese frames, interaction paths, alternate-screen entry/restoration, complete frames, and clean exit. Additional profiles assert truecolor, 256-color, 16-color, and colorless ASCII output and cover Water Light, High Contrast, and Colorblind. Pages 2–8 are each validated as the final complete frame with page-specific semantic markers.

Lua tests also cover JSON's 4 MiB/depth/100000-node budgets, linear numeric parsing smoke, U+FFFD replacement for invalid UTF-8 values and keys, default redaction of connection-export IDs, bounded regular-file reads, heterogeneous CPU identity/topology/cache fixtures, powercap energy delta/wrap/reset/constraints, GPU PCI IDs/PCIe/fdinfo utilization, hwmon sentinel filtering, cgroup-aware resource preflight, and sudo privilege metadata. Passing 47 fixture files is not formal proof across kernels, hardware, or malicious-input classes.

### 8.2 Post-Packaging PTY

```bash
make test-bundle-dir
make test-bundle-file
```

### 8.3 Clean Environment

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

This intentionally makes every optional helper unavailable and verifies that bundles do not depend on system `lua`, `LUA_PATH`, `LUA_CPATH`, or the source tree. Interactive mode still needs a separate PTY smoke test.

### 8.4 Native Dependencies

Check every target build with:

```bash
ldd build/native/wtop_native.so
ldd dist/wtop/wtop
file build/native/wtop_native.so dist/wtop/wtop dist/wtop-onefile
readelf -dW build/native/wtop_native.so
strings build/native/wtop_native.so dist/wtop/wtop dist/wtop-onefile
```

Source/build directories must not be embedded in ELF files. Unexpected shared libraries, RPATH/RUNPATH, or the wrong architecture must fail a release. This check applies to runtime ELF files; the `.luai/generated-output.txt` onedir exception is described above, and other text payloads still require individual review. The native module currently links no NVML, AMD SMI, or Level Zero.

For sudo smoke validation, never open an uncontrolled password prompt in automation. First use `sudo -n true`; run a bounded `sudo -n <installed-wtop> --diagnose` only when noninteractive sudo is already available. Unit tests validate construction and metadata without requiring root.

## 9. Current Platform Boundary

Linux-only is enforced at five points: the rockspec platform allowlist, Makefile parse-time check, two bootstrap scripts, C-module compile-time check, and unified CLI runtime entry. The Makefile builds for the current Linux host. The repository's current `dist/` comes from Fedora glibc x86_64 development validation and is not a formal release. No minimum glibc version has been selected or validated, and compatibility cannot be inferred from successful execution on the development host, the ELF interpreter, or `file` output. Current validation does not promise:

- aarch64;
- musl;
- older glibc;
- any specified minimum kernel;
- deb/rpm/Arch packages;
- every terminal and GPU driver.

These targets must be rebuilt natively on the corresponding architecture/libc and supported by their own `ldd`, clean-environment, PTY, and hardware smoke evidence. `wtop_native.so` cannot be shared between libcs or Lua major.minor versions.

## 10. Remaining Work Before Release

- [x] Lock and validate the Lua 5.5.1 toolchain.
- [x] Generate deterministic locale Lua modules and a literal registry.
- [x] Provide onedir, onefile, and PTY targets for both artifacts.
- [x] Provide native-module ABI, bundle-entry, and PTY test paths.
- [x] Include onefile PTY in a standard Make target.
- [x] Provide a target that generates `dist/SHA256SUMS` for both bundle executable entry points.
- [x] Provide a Linux-only LuaRocks rockspec, isolated-install target, and installed-CLI smoke test.
- [x] Adopt EUPL-1.2 and declare it in source, rock-installation documentation, and README files.
- [ ] Clean or isolate old artifacts at the final release commit and rerun every bundle target; existing repository `dist/` content is not evidence that artifacts match current source.
- [ ] Run CLI, snapshot, PTY, clean-environment, `ldd`, and `file` validation against final onedir/onefile artifacts and retain logs.
- [ ] Select and validate minimum glibc and Linux-kernel baselines.
- [ ] Build and test natively on glibc aarch64.
- [ ] Build and test each planned musl target independently.
- [ ] Establish real NVIDIA, AMD, Intel, and no-GPU smoke matrices.
- [ ] Rerun `make checksums` on the final candidate and separately produce an SBOM, signatures, and a complete build-provenance record.
- [ ] Review all third-party notices and relinking material on the release host.

## 11. References

- [luainstaller README](https://github.com/Water-Run/luainstaller)
- [Usage](https://github.com/Water-Run/luainstaller/blob/main/docs/USAGE.adoc)
- [Platforms and native modules](https://github.com/Water-Run/luainstaller/blob/main/docs/PLATFORMS-NATIVE-LIMITS.adoc)
