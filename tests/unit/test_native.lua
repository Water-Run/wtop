package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local native = require("wtop.native")
local Parsers = require("wtop.linux.parsers")
local FS = require("wtop.linux.fs")
local System = require("wtop.system")
local Sysfs = require("wtop.linux.sysfs")

local function assert_process_not_live(pid, message)
    for _ = 1, 40 do
        local stat_file = io.open("/proc/" .. pid .. "/stat", "rb")
        if not stat_file then return end
        local process = Parsers.process_stat(assert(stat_file:read("*a")))
        stat_file:close()
        if not process or process.state == "Z" then return end
        native.sleep_ms(5)
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

assert(native.VERSION == "0.1.0")
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
assert(native.signal_process(native.pid(), 0, self_stat.starttime_ticks))
local identity_signal, identity_error = native.signal_process(
    native.pid(), 0, self_stat.starttime_ticks + 1
)
assert(identity_signal == nil)
assert(tostring(identity_error):find("PID reuse prevented", 1, true))
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
    { timeout_ms = 500, max_output_bytes = 1024 }
)
assert(result.status == "ok")
assert(result.stdout == "argv;is-not-a-shell")
assert(result.exit_code == 0)

local environment = native.run(
    { "/usr/bin/printenv", "LC_ALL" },
    { timeout_ms = 500, max_output_bytes = 1024, env = { LANG = "C", LC_ALL = "C" } }
)
assert(environment.status == "ok")
assert(environment.stdout == "C\n")

local inherited_home = native.run(
    { "/usr/bin/printenv", "HOME" },
    { timeout_ms = 500, max_output_bytes = 1024 }
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
    { timeout_ms = 500, max_output_bytes = 1024 }
)
inherited_file:close()
assert(not inherited_fd.stdout:find("/etc/hostname", 1, true))

local limited = native.run(
    { "/usr/bin/printf", "%s", "123456789" },
    { timeout_ms = 500, max_output_bytes = 4 }
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
    { timeout_ms = 500, max_output_bytes = 64 }
)
assert(redirected_background.status == "ok")
local redirected_pid = tonumber(redirected_background.stdout:match("(%d+)"))
assert(redirected_pid and redirected_pid > 1)
assert_process_not_live(redirected_pid,
    "background descendant that closed capture pipes remained alive")

local missing = native.run(
    { "/definitely/not/a/wtop-command" },
    { timeout_ms = 500, max_output_bytes = 64 }
)
assert(missing.status == "error")
assert(missing.exit_code == 127)

if not native.isatty(0) then
    local started, message = native.terminal_start()
    assert(started == nil)
    assert(message:match("TTY"))
end

return true
