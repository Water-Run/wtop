# Cross-Platform Product Requirements

## Product Direction and Current Baseline

wtop's target is a modern, responsive system monitor that runs natively on Linux,
macOS, and Windows. Windows must monitor the Windows host itself. A native
32-bit x86 build and compatibility with Windows XP are implementation targets.
Windows Server 2008 is the available real-host Windows validation target; an XP
test environment is not available. Compatibility with older hardware and
classic Windows consoles running `cmd.exe`, including consoles without VT/ANSI
support, is a primary requirement.

Version 0.1.0 and its LuaRocks package remain Linux-only releases. The source
tree now includes development builds for macOS and Windows x86, with native
host collectors and shared Snapshot/TUI code. These builds have real-host
smoke evidence below; they have not been shipped as a cross-platform release.

## Required Behavior

1. **Native host monitoring.** On each of Linux, macOS, and Windows, the TUI
   shows CPU, memory, processes, storage, network, and basic system identity.
   `--snapshot`, `--agent`, and `--diagnose` work on the same host. The common
   Snapshot and quality contracts remain consistent across operating systems.
   Metrics with no equivalent source on an operating system report their actual
   availability; they must not appear as zero or as fresh data.
2. **Terminal adaptation.** The UI supports capable VT/ANSI terminals and a
   native Windows console path for consoles without VT/ANSI. It detects actual
   capabilities before enabling alternate screen, mouse input, paste modes,
   color, and Unicode glyphs. A keyboard-only, colorless ASCII presentation
   remains usable on a small console. Terminal input, resize, Ctrl+C, and
   normal/error exit restore the user's console state. A terminal that cannot
   process escape sequences must not display raw escape codes.
3. **Older-device behavior.** Collection and rendering remain bounded, avoid
   unnecessary work for hidden panels, and stay usable at the smallest layout
   sizes already supported by the UI. Performance targets and a minimum hardware
   baseline require measurements on the oldest supported machines.
4. **Platform-specific controls.** Process identity, process actions, privilege
   behavior, configuration paths, and optional inspectors use platform-specific
   implementations. An action is exposed only where the platform can enforce
   its safety checks and report failures accurately.
5. **Native delivery.** Each supported operating system has a build and
   distribution path that can start the TUI and structured-output commands on
   that system. Windows XP compatibility is a code and build target; without an
   XP runtime test, it remains unverified and must not be presented as a tested
   release guarantee.

## Implementation Boundaries

- Keep Snapshot, ViewModel, widgets, layout, and the backend-neutral cell diff
  shared. Select the host collector and native-service implementations by
  operating system; keep Linux `/proc` and `/sys` readers in the Linux backend.
- The terminal backend keeps `start`, `size`, `poll`, `present`, `capabilities`,
  and `stop`. Native Win32 console sessions use screen-buffer APIs and native
  key events; ANSI streams use the shared encoder. The Cygwin/OpenSSH launcher
  sets its PTY to raw mode while the program runs.
- The Windows x86 artifact bundles a matching 32-bit Lua runtime and native
  module. It is built with an XP target macro and PE32 i386 format. Newer API
  calls needed for version, architecture, and uptime are resolved dynamically;
  CPU counters have a dynamically selected pre-SP1 fallback. This is build and
  API evidence, not an XP runtime result.

## Validation Matrix

| Runtime host | Terminal case | Acceptance focus |
| --- | --- | --- |
| Linux | Debian 13 x86_64 SSH PTY; development host | Snapshot, Agent, diagnose, TUI quit; 47 Lua test files and three PTY scenarios on the development host |
| macOS | macOS 26.5 arm64 SSH PTY | Native CPU and per-core utilization, memory, process, storage, network and system data; Snapshot, Agent, diagnose, TUI quit |
| Windows XP, 32-bit x86 | No test environment available | PE32 i386 build and import review; runtime remains unverified |
| Windows Server 2008 | 6.0.6003 x86_64 host running the x86 artifact | Native resources including per-core CPU utilization, Snapshot, Agent, diagnose, configuration/layout I/O, and Cygwin/OpenSSH PTY TUI; forced legacy CPU fallback compared against GetSystemTimes |
| Newer Windows | 10.0.26100 x86_64 host running the x86 artifact | Native resources including per-core CPU utilization, Snapshot, Agent, diagnose, and native Win32 console TUI through PowerShell/OpenSSH ConPTY |
| Server 2008 classic CMD | Direct local console session not available | Win32 screen-buffer and key-event path requires direct visual/keyboard/resize validation on this host |
| Windows with WSL | Linux runtime in WSL | Linux compatibility; this does not establish native Windows support |

The Server 2008 SSH session runs through a Cygwin pipe and does not exercise
its local classic CMD console. A headless SSH session cannot allocate a
desktop console there. The newer Windows ConPTY run exercises the Win32 console
backend, but does not establish old CMD display quality. XP cannot receive a
runtime-tested claim without an XP test environment. macOS deployment targets
are 11.0 for arm64 and 10.13 for x86_64; only arm64 macOS 26.5 has been run.

## Development Builds

On macOS, run `./tools/build_macos.sh`; the executable bundle is
`dist/macos/wtop`. On Linux with a 32-bit MinGW cross compiler, run
`./tools/build_windows_x86.sh` and copy `dist/windows-x86` to Windows.
Run `wtop.cmd` from CMD or PowerShell. In a Cygwin/OpenSSH PTY, use
`wtop.sh` so keyboard input is delivered without line buffering. Both bundles
contain Lua 5.5.1 and their matching native module.

The x86 Windows bundle was built with `_WIN32_WINNT=0x0501`. `lua.exe` and
`wtop_native.dll` are PE32 i386, and the native module does not hard-import
newer APIs such as `GetTickCount64`. The CPU API
[`GetSystemTimes`](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getsystemtimes)
is documented from XP SP1 onward, so the module resolves it dynamically and
has an NT processor-counter fallback for earlier XP. That fallback matched
`GetSystemTimes` counters on Server 2008 when forced for validation. It is
still unverified on XP itself.

## Baselines Still to Decide

- Windows XP service-pack and CPU architecture variants beyond required x86.
- Windows x64 artifact scope and the versions on which it will be validated.
- Earlier macOS versions and Intel hardware runtime validation.
- Minimum Linux kernel, libc, and CPU architectures.
- Measured CPU, memory, startup, and input-latency budgets for older hardware.

Until those baselines are chosen and validated, the compatibility target should
not be presented as a released platform guarantee.
