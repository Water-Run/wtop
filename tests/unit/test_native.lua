package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local native = require("wtop.native")
local Parsers = require("wtop.linux.parsers")
local FS = require("wtop.linux.fs")
local System = require("wtop.system")
local Sysfs = require("wtop.linux.sysfs")

-- Waiting for a child to be reaped is not a performance measurement: the loop
-- only fails when the process is still live after the whole budget.  The old
-- 200 ms cap made this a load-sensitive flake on a busy machine, which is
-- exactly the signal a release gate must not emit.
local REAP_ATTEMPTS = 200
local REAP_INTERVAL_MS = 10

local function assert_process_not_live(pid, message)
    for _ = 1, REAP_ATTEMPTS do
        local stat_file = io.open("/proc/" .. pid .. "/stat", "rb")
        if not stat_file then return end
        local body = stat_file:read("*a")
        stat_file:close()
        -- Opening the file and reading it are two syscalls, and a reaper can run
        -- between them, so a child that died a moment ago can leave the handle
        -- open and the read empty.  That is the very condition this helper
        -- exists to detect, so it is a reason to stop rather than to fail.
        -- Measured on this host at roughly one run in thirty of the
        -- timed-out-descendant case.
        if not body or body == "" then return end
        local process = Parsers.process_stat(body)
        if not process or process.state == "Z" then return end
        native.sleep_ms(REAP_INTERVAL_MS)
    end
    error(message, 2)
end

local listed_path, listed_limit
local injected_fs = FS.new({
    root = "/fixture",
    list_dir = function(path, limit)
        listed_path, listed_limit = path, limit
        return { "one", "two" }, nil, true
    end,
})
local injected_entries, injected_error, injected_truncated = injected_fs:list("/items", 2)
assert(#injected_entries == 2 and injected_error == nil and injected_truncated == true)
assert(listed_path == "/fixture/items" and listed_limit == 2)
assert(FS.classify_error("localized", 13) == "denied")
assert(FS.classify_error("localized", 2) == "missing")
assert(injected_fs:list("/items", 0) == nil)
assert(not pcall(FS.new, { read_file = "invalid" }))

-- An option `FS.new` does not know.  It used to ignore one, and the cost was
-- measured in a test file rather than in a report: two doubles spelled their
-- readlink implementation `readlink`, which is not one of the four accessor
-- names, so the key was accepted, stored in the options table, and never read --
-- and `FS.new` substituted the *real* readlink for it.  A double that believes
-- it is hermetic and is not is worse than one that knows it is not, because the
-- machine running the suite decides the answer: `system_info` resolves the
-- timezone through `readlink("/etc/localtime")`, so that test was reading this
-- host's timezone into its sample and asserting nothing about it, and it would
-- have kept passing on a host with no `/etc/localtime` at all.  `FS.new` refuses
-- an unknown key by name now.
--
-- The refusal has to be able to say *which* key, so the assertion reads the
-- message rather than only that something was raised: a bare `error` would
-- satisfy a check for "it refused" and tell a caller nothing about its own
-- mistake.
local ok_unknown, err_unknown = pcall(FS.new, { readlink = function() end })
assert(not ok_unknown and tostring(err_unknown):find("readlink", 1, true),
  "FS.new accepted an option key it does not know (`readlink`, where the "
    .. "accessor is named `read_link`), so the key is kept and never read and "
    .. "the real implementation is substituted for the one the caller believed "
    .. "it was providing.  A test built on that filesystem is not hermetic and "
    .. "does not know it.")
-- And the refusal must not be a blanket: every option the constructor does
-- accept still has to be accepted, or the requirement above is one nothing can
-- meet and every caller is broken instead of one.
for _, key in ipairs({ "root", "read_file", "list_dir", "read_link", "path_type" }) do
  local options = { [key] = (key == "root") and "/prefix" or function() end }
  local accepted, err = pcall(FS.new, options)
  assert(accepted, "FS.new refuses its own option `" .. key .. "`: " .. tostring(err))
end
-- The control for the misspelling above, in the form that matters: the correctly
-- spelled accessor is the one that gets consulted.
local spelled_right = FS.new({
  read_link = function() return "/elsewhere" end,
})
assert(spelled_right:readlink("/anything") == "/elsewhere",
  "a correctly spelled read_link implementation is not being used")

assert(not pcall(function() injected_fs:read("") end))
local number_fs = FS.new({ root = "/fixture", read_file = function() return "12 trailing" end })
assert(number_fs:read_number("/number") == nil)
assert(Sysfs.hex_id(" 0x10de \n") == 0x10de)
assert(Sysfs.hex_id("0x10de trailing") == nil)
assert(Sysfs.millidegrees_to_celsius(math.huge) == nil)
assert(System.find_executable("tool", "relative:/also-relative") == nil)
assert(System.default_executable_path(0, function() return "/tmp/untrusted" end)
    == System.ROOT_EXECUTABLE_PATH,
    "root helper lookup must ignore the caller's PATH")
assert(System.default_executable_path(1000, function() return "/opt/trusted/bin" end)
    == "/opt/trusted/bin")
assert(System.read_file("/proc/self/stat", 0) == nil)
assert(System.read_file("bad\0path", 16) == nil)

if not native.available then
    assert(type(native.error) == "string")
    local unavailable_entries, unavailable_error = native.listdir("/proc/self", 1)
    assert(unavailable_entries == nil and type(unavailable_error) == "string")
    return true
end

-- The declared version, read rather than written.  It used to be the literal
-- "0.1.0" here, which is a fourth copy of the same fact and the reason a
-- version bump meant finding this line: a test that hardcodes the value it is
-- checking agrees with whatever it is checking, and anyone updating the version
-- updates it here in the same breath.  The convergence between the module, the
-- Lua tree and the SBOM is asserted in tests/unit/test_version_convergence.lua;
-- what this line is for is that the module reports a version at all.
local declared_handle = assert(io.open("VERSION", "rb"), "VERSION is missing")
local declared_version = declared_handle:read("*a"):gsub("%s+", "")
declared_handle:close()
assert(native.VERSION == declared_version,
    "the module reports version " .. tostring(native.VERSION) .. " and VERSION says "
        .. declared_version)
assert(type(native.pid()) == "number" and native.pid() > 1)
assert(type(native.monotonic_ns()) == "number")
assert(type(native.realtime_ns()) == "number")

local system = assert(native.uname())
assert(system.sysname == "Linux")
assert(type(system.release) == "string" and system.release ~= "")

local entries, entries_error, entries_truncated = native.listdir("/proc/self")
assert(entries and entries_error == nil and entries_truncated == false)
assert(#entries > 0)
local one_entry, one_entry_error, one_entry_truncated = native.listdir("/proc/self", 1)
assert(one_entry and #one_entry == 1 and one_entry_error == nil and one_entry_truncated == true)
assert(not pcall(native.listdir, "/proc/self", 0))
assert(not pcall(native.listdir, "/proc/self", -1))
assert(not pcall(native.listdir, "/proc/self", 2147483648))
local fs_entry, fs_error, fs_truncated = FS.default:list("/proc/self", 1)
assert(fs_entry and #fs_entry == 1 and fs_error == nil and fs_truncated == true)
assert(type(assert(native.readlink("/proc/self/exe"))) == "string")
assert(type(assert(native.readfile("/proc/self/stat", 65536))) == "string")
assert(type(assert(native.readfile("/sys/devices/system/cpu/online", 256))) == "string",
    "bounded reader must use generated sysfs content instead of its synthetic st_size")
local special_content, special_error, special_errno = native.readfile("/dev/null", 16)
assert(special_content == nil and type(special_error) == "string" and special_errno == 22,
    "bounded reader must reject devices/FIFOs instead of blocking")
local symlink_content, _, symlink_errno = native.readfile("/proc/self/exe", 16)
assert(symlink_content == nil and symlink_errno == 40,
    "bounded reader must not follow a final symlink")

-- The batch reader shares the single-file reader's safety contract, one
-- crossing for a whole process sample.
local batch_contents, batch_denied = native.proc_batch(
    { native.pid(), 4194304 }, "stat")
assert(type(batch_contents[1]) == "string" and batch_contents[1]:find(native.pid(), 1, true),
    "batch reader returns the process stat content")
assert(batch_contents[2] == false and not (batch_denied and batch_denied[2]),
    "a missing pid reports failure without a permission flag")
local batch_missing = native.proc_batch({ native.pid() }, "no_such_file")
assert(batch_missing[1] == false, "a missing file reports failure")
assert(not pcall(native.proc_batch, { native.pid() }, "STAT"),
    "uppercase names are rejected to keep the path fixed")
assert(not pcall(native.proc_batch, { native.pid() }, "stat/../cmdline"),
    "path separators are rejected")
local invalid_entries = native.proc_batch({ native.pid(), 0, -1 }, "stat")
assert(type(invalid_entries[1]) == "string" and invalid_entries[2] == false
    and invalid_entries[3] == false,
    "invalid pid entries fail their slot instead of erroring mid-batch")
local oversized = native.proc_batch({ native.pid() }, "stat", 8)
assert(oversized[1] == false,
    "content beyond the per-file limit reports failure, not truncation")

local filesystem = assert(native.statvfs("/"))
assert(filesystem.block_size > 0)
assert(filesystem.blocks > 0)
assert(type(filesystem.files_available) == "number" and filesystem.files_available >= 0)
local constants = assert(native.system_constants())
assert(type(constants.clock_ticks_per_second) == "number"
    and constants.clock_ticks_per_second > 0)
assert(type(constants.page_size_bytes) == "number" and constants.page_size_bytes >= 1024)
assert(native.wcwidth(string.byte("A")) == 1)
assert(native.wcwidth(0x4E2D) == 2)
assert(not pcall(native.isatty, -1))
assert(not pcall(native.poll, 60001))
assert(not pcall(native.write, "", 2147483648))
assert(not pcall(native.mkdir, "/tmp/wtop-invalid-mode", 4294967296))
assert(not pcall(native.execve, {}, {}))
assert(not pcall(native.execve, { "relative" }, {}))
assert(not pcall(native.execve, { "/does/not/run" }, { "INVALID-NAME=value" }))
assert(not pcall(native.execve, { "/does/not/run\0suffix" }, {}))
assert(not pcall(native.execve, { "/does/not/run", 7 }, {}),
    "execve must reject numeric argv entries instead of coercing them to strings")
assert(not pcall(native.execve, { "/does/not/run" }, { 7 }),
    "execve must reject numeric environment entries instead of coercing them to strings")
local excessive_argv = { "/does/not/run" }
for index = 2, 513 do excessive_argv[index] = "x" end
assert(not pcall(native.execve, excessive_argv, {}))
local excessive_environment = {}
for index = 1, 65 do excessive_environment[index] = "V" .. index .. "=x" end
assert(not pcall(native.execve, { "/does/not/run" }, excessive_environment))
assert(not pcall(native.execve,
    { "/does/not/run", string.rep("x", 1024 * 1024) }, {}),
    "execve must enforce the shared argv/environment byte budget before execution")
assert(not pcall(native.execve, { "/does/not/run" },
    { "VALUE=" .. string.rep("x", 1024 * 1024) }))

local self_stat_file = assert(io.open("/proc/self/stat", "rb"))
local self_stat = assert(Parsers.process_stat(assert(self_stat_file:read("*a"))))
self_stat_file:close()
-- Whether the pidfd path exists is a property of the *build*, not of the
-- running kernel: it is compiled in only where <sys/syscall.h> defines
-- SYS_pidfd_open, and a build against older headers is supposed to say the
-- capability is absent rather than pretend to signal.  This test demanded the
-- pidfd path unconditionally, so it could not pass on any build host whose
-- headers predate Linux 5.1 -- verified by building the whole suite in a
-- glibc 2.17 container, where it failed with the module's own message.  Both
-- branches are asserted in full rather than one being skipped.
local probe_signal, probe_error, probe_errno =
    native.signal_process(native.pid(), 0, self_stat.starttime_ticks)
if probe_signal == true then
    local identity_signal, identity_error = native.signal_process(
        native.pid(), 0, self_stat.starttime_ticks + 1
    )
    assert(identity_signal == nil)
    assert(tostring(identity_error):find("PID reuse prevented", 1, true))
else
    -- A build without pidfd must name that fact.  A bare nil is what a signal
    -- that failed for any other reason also returns, and it is what a broken
    -- implementation would return, so asserting "it returned nil" would
    -- distinguish nothing at all.
    assert(probe_signal == nil)
    assert(tostring(probe_error):find("unavailable on this build", 1, true),
        "a build without pidfd must say so, not fail opaquely: " .. tostring(probe_error))
    assert(probe_errno == 38,
        "and it must report ENOSYS, not a signal failure: " .. tostring(probe_errno))
end
assert(not pcall(native.signal_process, native.pid(), 4294967296, self_stat.starttime_ticks))

local temporary_directory = "/tmp/wtop-native-test-" .. native.pid()
assert(native.mkdir(temporary_directory, 448)) -- 0700
local temporary_file = temporary_directory .. "/state.yml"
assert(native.atomic_write(temporary_file, "first\n", 384)) -- 0600
assert(native.atomic_write(temporary_file, "second\n", 384))
assert(native.path_type(temporary_directory) == "directory")
assert(native.path_type(temporary_file) == "regular")
assert(native.path_type("/proc/self/exe") == "symlink")
assert(native.path_type("/proc/self/exe", true) == "regular")
assert(type(System.find_executable("sh", "/bin:/usr/bin")) == "string")
for _, path_function in ipairs({ native.access, native.mkdir, native.listdir, native.readlink,
    native.readfile, native.path_type, native.statvfs }) do
    assert(not pcall(path_function, "/tmp/wtop\0suffix"), "native path API accepted NUL")
end
assert(native.readfile(temporary_file, 64) == "second\n")
local oversized_content, _, oversized_errno = native.readfile(temporary_file, 3)
assert(oversized_content == nil and oversized_errno == 27)

-- Successful and size-error paths both acquire native resources.  Repeating
-- them catches accidental descriptor lifetime regressions without relying on
-- a platform-specific Lua OOM threshold.
local descriptor_count_before = #assert(native.listdir("/proc/self/fd", 4096))
for _ = 1, 256 do
    assert(native.listdir("/proc/self", 1))
    assert(native.readfile(temporary_file, 64) == "second\n")
    local too_large, _, too_large_errno = native.readfile(temporary_file, 3)
    assert(too_large == nil and too_large_errno == 27)
end
collectgarbage("collect")
local descriptor_count_after = #assert(native.listdir("/proc/self/fd", 4096))
assert(descriptor_count_after == descriptor_count_before,
    "native listdir/readfile leaked file descriptors")
local saved = assert(io.open(temporary_file, "rb"))
assert(saved:read("*a") == "second\n")
saved:close()
assert(os.remove(temporary_file))
assert(os.remove(temporary_directory))

local result = native.run(
    { "/usr/bin/printf", "%s", "argv;is-not-a-shell" },
    { timeout_ms = 5000, max_output_bytes = 1024 }
)
assert(result.status == "ok")
assert(result.stdout == "argv;is-not-a-shell")
assert(result.exit_code == 0)

local environment = native.run(
    { "/usr/bin/printenv", "LC_ALL" },
    { timeout_ms = 5000, max_output_bytes = 1024, env = { LANG = "C", LC_ALL = "C" } }
)
assert(environment.status == "ok")
assert(environment.stdout == "C\n")

local inherited_home = native.run(
    { "/usr/bin/printenv", "HOME" },
    { timeout_ms = 5000, max_output_bytes = 1024 }
)
assert(inherited_home.status == "error")
assert(inherited_home.stdout == "")

local inherited_file = assert(io.open("/etc/hostname", "rb"))
local inherited_fd_argv = { "/usr/bin/readlink" }
for descriptor = 3, 32 do
    inherited_fd_argv[#inherited_fd_argv + 1] = "/proc/self/fd/" .. descriptor
end
local inherited_fd = native.run(
    inherited_fd_argv,
    { timeout_ms = 5000, max_output_bytes = 1024 }
)
inherited_file:close()
assert(not inherited_fd.stdout:find("/etc/hostname", 1, true))

local limited = native.run(
    { "/usr/bin/printf", "%s", "123456789" },
    { timeout_ms = 5000, max_output_bytes = 4 }
)
assert(limited.stdout == "1234")
assert(limited.truncated == true)

local timeout = native.run(
    { "/bin/sh", "-c", "sleep 1" },
    { timeout_ms = 20, max_output_bytes = 64 }
)
assert(timeout.status == "timeout")
assert(timeout.timed_out == true)

local cancellation_checks = 0
local cancelled = native.run(
    { "/usr/bin/sleep", "1" },
    {
        timeout_ms = 1000,
        max_output_bytes = 64,
        cancel = function()
            cancellation_checks = cancellation_checks + 1
            return true
        end,
    }
)
assert(cancelled.status == "cancelled")
assert(cancelled.reason == "cancelled")
assert(cancellation_checks > 0)

local descendant_timeout = native.run(
    { "/bin/sh", "-c", "sleep 30 & echo $!; wait" },
    { timeout_ms = 30, max_output_bytes = 64 }
)
assert(descendant_timeout.status == "timeout")
local descendant_pid = tonumber(descendant_timeout.stdout:match("(%d+)"))
assert(descendant_pid and descendant_pid > 1)
assert_process_not_live(descendant_pid, "timed-out command descendant remained alive")

-- The direct shell exits immediately while its background descendant still
-- holds the capture pipes, so whether the deadline or the pipe bookkeeping
-- wins is a genuine race between fork/exec and a 30 ms timer.  Asserting one
-- side of that race made this file fail roughly one run in five.  The real
-- invariant is the one worth testing: however the run terminates, process
-- group cleanup must leave no descendant behind.
local detached_timeout = native.run(
    { "/bin/sh", "-c", "sleep 30 & echo $!" },
    { timeout_ms = 30, max_output_bytes = 64 }
)
assert(detached_timeout.status == "timeout" or detached_timeout.status == "ok",
    "a background descendant retaining capture pipes must end as timeout or ok, got "
        .. tostring(detached_timeout.status))
local detached_pid = tonumber(detached_timeout.stdout:match("(%d+)"))
assert(detached_pid and detached_pid > 1)
assert_process_not_live(detached_pid, "detached command descendant remained alive")

local redirected_background = native.run(
    { "/bin/sh", "-c", "sleep 30 </dev/null >/dev/null 2>&1 & echo $!" },
    -- Still far below the 30 s the background child would need: a run that
    -- waits for it has to fail here rather than merely run slowly.
    { timeout_ms = 1000, max_output_bytes = 64 }
)
assert(redirected_background.status == "ok")
local redirected_pid = tonumber(redirected_background.stdout:match("(%d+)"))
assert(redirected_pid and redirected_pid > 1)
assert_process_not_live(redirected_pid,
    "background descendant that closed capture pipes remained alive")

local missing = native.run(
    { "/definitely/not/a/wtop-command" },
    { timeout_ms = 5000, max_output_bytes = 64 }
)
assert(missing.status == "error")
assert(missing.exit_code == 127)

if not native.isatty(0) then
    local started, message = native.terminal_start()
    assert(started == nil)
    assert(message:match("TTY"))
end

return true
