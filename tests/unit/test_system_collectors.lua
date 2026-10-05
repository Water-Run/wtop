package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local FS = require("wtop.linux.fs")
local PowerSupply = require("wtop.collectors.power_supply")
local SystemInfo = require("wtop.collectors.system_info")
local Users = require("wtop.linux.users")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "values differ",
      tostring(expected), tostring(actual)), 2)
  end
end

--- A filesystem backed by a plain path->content table.
--
-- Every accessor is supplied, and the reason is not tidiness.  `FS.new`
-- substitutes the real implementation for any accessor it is not given, and this
-- double used to spell its readlink implementation `readlink` -- not a name
-- `FS.new` knows -- so it was accepted, kept, and never read, and the collector
-- under test (`system_info`, which resolves the timezone through
-- `/etc/localtime`) got a real `readlink(2)` on whichever host was running the
-- suite.  Nothing asserted the timezone, so the host's answer rode along in the
-- sample unnoticed.  `path_type` said `"file"`, which is also not a word the
-- product produces: `native.path_type` answers `regular` for S_ISREG.
local function fake_fs(files, directories, denied, links)
  return FS.new({
    root = "/",
    read_file = function(path)
      if denied and denied[path] then
        return nil, { kind = "denied", message = "permission denied" }
      end
      local content = files[path]
      if content == nil then
        return nil, { kind = "missing", message = "no such file" }
      end
      return content
    end,
    list_dir = function(path)
      local entries = directories and directories[path]
      if not entries then
        return nil, { kind = "missing", message = "no such directory" }
      end
      return entries, nil, false
    end,
    read_link = function(path)
      local target = links and links[path]
      if target == nil then
        return nil, { kind = "missing", message = "not a symlink" }
      end
      return target
    end,
    path_type = function(path)
      if links and links[path] then return "symlink" end
      if files[path] ~= nil then return "regular" end
      if directories and directories[path] then return "directory" end
      return nil, { kind = "missing", message = "no such path" }
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Parsers
-- ---------------------------------------------------------------------------

local os_release = SystemInfo.parse_os_release([[
NAME="Ubuntu"
VERSION="24.04.4 LTS (Noble Numbat)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 24.04.4 LTS"
VERSION_ID="24.04"
# a comment and a blank line follow

HOME_URL="https://www.ubuntu.com/"
]])
equal(os_release.NAME, "Ubuntu", "unquoted-through-quotes value")
equal(os_release.PRETTY_NAME, "Ubuntu 24.04.4 LTS", "quoted value")
equal(os_release.ID, "ubuntu", "bare value")
equal(SystemInfo.parse_os_release("no keys here"), nil, "a file with no keys yields nothing")
equal(SystemInfo.parse_os_release(nil), nil, "non-string input is rejected")

local uptime = SystemInfo.parse_uptime("144348.75 285123.09\n")
equal(uptime.uptime_seconds, 144348.75, "uptime seconds")
equal(uptime.idle_seconds, 285123.09, "idle seconds")
equal(SystemInfo.parse_uptime("garbage"), nil, "malformed uptime is rejected")

local swaps = SystemInfo.parse_swaps(
  "Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n" ..
  "/dev/sdc                                partition\t2097152\t\t1024\t\t-2\n")
equal(#swaps.devices, 1, "one swap device")
equal(swaps.devices[1].name, "/dev/sdc", "device name")
equal(swaps.total_bytes, 2097152 * 1024, "total is scaled from KiB")
equal(swaps.used_bytes, 1024 * 1024, "used is scaled from KiB")
equal(swaps.devices[1].priority, -2, "negative priority parses")

-- The middle column of file-nr counts *free allocated* descriptors, so the
-- number actually in use is allocated minus free.  Reading it as "in use"
-- overstates the figure on every host.
local descriptors = SystemInfo.parse_file_nr("2336\t0\t9223372036854775807\n")
equal(descriptors.open, 2336, "open descriptors")
equal(descriptors.allocated, 2336, "allocated descriptors")
local with_free = SystemInfo.parse_file_nr("1000 250 4096")
equal(with_free.open, 750, "free allocated descriptors are not counted as in use")

-- ---------------------------------------------------------------------------
-- The kernel command line reaches JSON exports, and an export is the thing
-- people paste into tickets.  /proc/cmdline is world-readable, so this is not
-- access control; it keeps a disk-encryption key or a root filesystem UUID out
-- of a document that travels.
local redacted = SystemInfo.redact_command_line(
  "BOOT_IMAGE=/vmlinuz root=UUID=2f9c-dead ro quiet "
    .. "rd.luks.key=/crypto_keyfile.bin splash cryptdevice=/dev/sda2:root "
    .. "systemd.machine_id=0123456789abcdef nosplash")
for _, secret in ipairs({ "2f9c%-dead", "crypto_keyfile", "/dev/sda2", "0123456789abcdef" }) do
  assert(not redacted:find(secret),
    "the command line still contains " .. secret .. ": " .. redacted)
end
for _, kept in ipairs({ "BOOT_IMAGE=/vmlinuz", "ro", "quiet", "splash", "nosplash" }) do
  assert(redacted:find(kept, 1, true),
    "redaction must keep the ordinary parameter " .. kept .. ": " .. redacted)
end
equal(select(2, redacted:gsub("<redacted>", "")), 4,
  "each secret parameter is replaced exactly once")
-- The key must survive so the line still reads as a command line.
assert(redacted:find("root=<redacted>", 1, true), "the parameter name is kept")
equal(SystemInfo.redact_command_line(nil), nil, "non-string input yields nothing")
equal(SystemInfo.redact_command_line(""), "", "an empty command line stays empty")
-- A parameter that merely starts with a redacted name is not itself a secret.
assert(SystemInfo.redact_command_line("rootwait=10"):find("rootwait=10", 1, true),
  "prefix matches must not be redacted")

-- SystemInfo sampling
-- ---------------------------------------------------------------------------

local files = {
  ["/proc/uptime"] = "1000.5 500.25\n",
  ["/proc/sys/kernel/hostname"] = "testhost\n",
  ["/proc/sys/kernel/ostype"] = "Linux\n",
  ["/proc/sys/kernel/osrelease"] = "6.8.0-test\n",
  ["/proc/sys/kernel/version"] = "#1 SMP Test\n",
  ["/proc/sys/kernel/domainname"] = "(none)\n",
  ["/proc/cmdline"] = "BOOT_IMAGE=/vmlinuz ro quiet\n",
  ["/proc/sys/fs/file-nr"] = "1024 0 65536\n",
  ["/proc/sys/kernel/pid_max"] = "4194304\n",
  ["/proc/sys/kernel/threads-max"] = "31262\n",
  ["/proc/sys/vm/max_map_count"] = "65530\n",
  ["/proc/sys/kernel/random/entropy_avail"] = "256\n",
  ["/proc/loadavg"] = "0.50 0.25 0.10 2/300 12345\n",
  ["/proc/stat"] = "cpu  1 2 3 4\nbtime 1700000000\nctxt 999\nprocesses 42\n"
    .. "procs_running 2\nprocs_blocked 1\nintr 777\n",
  ["/proc/vmstat"] = "pgfault 100\npgmajfault 7\noom_kill 0\n",
  ["/proc/swaps"] = "Filename Type Size Used Priority\n/swap file 1024 512 -2\n",
  ["/usr/lib/os-release"] = 'PRETTY_NAME="Test Linux 1.0"\nID=testlinux\n',
  ["/sys/class/dmi/id/sys_vendor"] = "Test Systems\n",
  ["/sys/class/dmi/id/product_name"] = "To Be Filled By O.E.M.\n",
  ["/sys/class/dmi/id/board_name"] = "Mainboard X\n",
  ["/sys/class/dmi/id/chassis_type"] = "9\n",
  ["/sys/class/dmi/id/bios_version"] = "1.2.3\n",
}
local collector = SystemInfo.new({ fs = fake_fs(files) })
local sample = collector:sample({})
equal(sample.status, "ok", "sample succeeds")
local data = sample.data
equal(data.host.hostname, "testhost", "hostname")
equal(data.host.domain, nil, "the literal (none) domain is not a domain")
equal(data.kernel.release, "6.8.0-test", "kernel release")
equal(data.distribution.pretty_name, "Test Linux 1.0",
  "os-release is read from /usr/lib when /etc is a symlink")
equal(data.uptime_seconds, 1000.5, "uptime")
equal(data.boot_time_unix, 1700000000, "boot time comes from /proc/stat btime")
equal(data.counters.ctxt, 999, "context switches")
equal(data.counters.forks, 42, "the processes counter is a fork count")
equal(data.counters.intr, 777, "interrupts")
equal(data.limits.file_descriptors.open, 1024, "descriptor count")
equal(data.limits.entropy_available, 256, "entropy")
equal(data.swap.total_bytes, 1024 * 1024, "swap total")
equal(data.vmstat.pgmajfault, 7, "vmstat field")
equal(data.load.one, 0.50, "load average")

-- The timezone, and why it is asserted at all.  `read_timezone` falls back to
-- `readlink("/etc/localtime")`, and this double used to spell its readlink
-- implementation `readlink` -- a key `FS.new` does not know -- so that accessor
-- silently fell through to the real filesystem and the sample carried whatever
-- timezone the machine running the suite happened to have.  Nothing asserted it,
-- so the host's answer rode along unnoticed: on a host with no `/etc/localtime`
-- the value would be nil and the test would still pass.  Declaring the link and
-- asserting the answer makes it a fact about the fixture, and the second case
-- below is the control that the assertion is not simply reading something.
local linked = SystemInfo.new({
  fs = fake_fs(files, nil, nil, { ["/etc/localtime"] = "../usr/share/zoneinfo/Etc/UTC" }),
})
equal(linked:sample({}).data.timezone, "Etc/UTC",
  "the timezone comes from the declared symlink, not from the host")
local unlinked = SystemInfo.new({ fs = fake_fs(files) })
equal(unlinked:sample({}).data.timezone, nil,
  "a filesystem with no /etc/localtime reports no timezone rather than the host's")
-- And the file form wins over the link form, which is the order the kernel's own
-- convention uses and therefore the order a wrong implementation would get
-- backwards.  The full fixture is extended rather than restated, because a
-- partial tree makes the sample unavailable and the assertion would then be
-- about a failed read.
local with_zone = {}
for path, content in pairs(files) do with_zone[path] = content end
with_zone["/etc/timezone"] = "Etc/Asia/Tokyo\n"
local both = SystemInfo.new({
  fs = fake_fs(with_zone, nil, nil,
    { ["/etc/localtime"] = "../usr/share/zoneinfo/Etc/UTC" }),
})
equal(both:sample({}).data.timezone, "Etc/Asia/Tokyo",
  "/etc/timezone is read before the symlink is followed")

-- Firmware placeholders are worse than nothing: they read like real hardware.
equal(data.firmware.product_name, nil, "an O.E.M. placeholder is discarded")
equal(data.firmware.system_vendor, "Test Systems", "a real vendor survives")
equal(data.firmware.board_name, "Mainboard X", "board name")
equal(data.firmware.chassis_type, "laptop", "chassis code 9 is a laptop")
equal(data.firmware.chassis_type_code, 9, "the raw chassis code is kept")

-- Denied DMI must be reported as denied, not silently as absent.
local denied_collector = SystemInfo.new({
  fs = fake_fs(files, nil, {
    ["/sys/class/dmi/id/sys_vendor"] = true,
    ["/sys/class/dmi/id/product_name"] = true,
    ["/sys/class/dmi/id/board_name"] = true,
    ["/sys/class/dmi/id/chassis_type"] = true,
    ["/sys/class/dmi/id/bios_version"] = true,
  }),
})
local denied_data = denied_collector:sample({}).data
equal(denied_data.firmware, nil, "no readable DMI fields")
local notes = table.concat(denied_data.quality_notes or {}, ",")
assert(notes:find("dmi_denied", 1, true), "denial is distinguished from absence")

-- The system-info collector publishes a reason for its degraded reading, and
-- this one is deliberately a category rather than a cause.  Its `quality_notes`
-- is a list of three members from two independent sources -- the os-release
-- file and the DMI directory -- so no sentence names one of them, and picking
-- the first note would assert a priority the quality field never expresses.
-- "Part of the system identity could not be read" is the one sentence that is
-- true of every case, which is the test a single reason slot has to pass.
--
-- The list is also dead data, measured: across the whole tree
-- `quality_notes` is read by exactly one thing, the assertion above.  No view
-- model, no TUI and no export mentions it.  So the category is all a user gets
-- today, and whether the notes should be rendered or deleted is recorded as the
-- next decision here rather than taken quietly as part of this one.
local denied_result = denied_collector:sample({})
equal(denied_result.quality, "partial",
  "a refused DMI directory degrades the reading rather than failing it")
equal(denied_result.reason, "system_identity_incomplete",
  "and the reason names the category the notes belong to")
-- The other note, from the other source, gives the same reason: the slot is one
-- and the notes are several, so this is what a category is for.
local unaccounted_collector = SystemInfo.new({
  fs = fake_fs({
    ["/proc/uptime"] = "1000.0 500.0\n",
    ["/proc/stat"] = "cpu  1 2 3 4 5 6 7 8\nbtime 1000000\n",
    ["/proc/sys/kernel/hostname"] = "testhost\n",
    ["/proc/sys/kernel/domainname"] = "(none)\n",
    ["/proc/sys/kernel/osrelease"] = "6.8.0-test\n",
    ["/proc/sys/kernel/ostype"] = "Linux\n",
    ["/proc/sys/kernel/version"] = "#1\n",
    ["/proc/cmdline"] = "root=/dev/sda1 ro\n",
    ["/proc/sys/kernel/random/boot_id"] = "0000-1111\n",
  }),
})
local unaccounted = unaccounted_collector:sample({})
equal(unaccounted.quality, "partial",
  "an absent DMI directory degrades it the same way a refused one does")
equal(unaccounted.reason, "system_identity_incomplete",
  "and the single slot carries one answer for both")
-- One note from one source gives the same single answer as two notes from two
-- sources, which is the whole point of a category rather than a cause: the slot
-- is one and the notes are several.
local release_missing = SystemInfo.new({
  fs = fake_fs({
    ["/proc/uptime"] = "1000.5 500.25\n",
    ["/proc/sys/kernel/hostname"] = "testhost\n",
    ["/proc/sys/kernel/ostype"] = "Linux\n",
    ["/proc/sys/kernel/osrelease"] = "6.8.0-test\n",
    ["/proc/sys/kernel/version"] = "#1 SMP Test\n",
    ["/proc/sys/kernel/domainname"] = "(none)\n",
    ["/proc/cmdline"] = "BOOT_IMAGE=/vmlinuz ro quiet\n",
    ["/proc/sys/fs/file-nr"] = "1024 0 65536\n",
    ["/proc/stat"] = "cpu  1 2 3 4\nbtime 1700000000\n",
    ["/proc/loadavg"] = "0.50 0.25 0.10 2/300 12345\n",
    ["/sys/class/dmi/id/sys_vendor"] = "Test Systems\n",
    ["/sys/class/dmi/id/product_name"] = "To Be Filled By O.E.M.\n",
  }),
})
local without_release = release_missing:sample({})
equal(without_release.quality, "partial",
  "an os-release that cannot be read degrades the reading too")
equal(without_release.reason, "system_identity_incomplete",
  "and it lands in the same category as a DMI that cannot be read")
-- A whole reading names no cause, which is the half of the invariant that a
-- reason written as an independent second guess gets wrong.
equal(sample.quality, "fresh", "a complete sample is fresh")
equal(sample.reason, nil, "and names no cause")

-- Without /proc/uptime there is nothing to report at all.
local empty = SystemInfo.new({ fs = fake_fs({}) }):sample({})
equal(empty.status, "unavailable", "a missing /proc/uptime makes the sample unavailable")

-- ---------------------------------------------------------------------------
-- Power supplies
-- ---------------------------------------------------------------------------

local battery_files = {
  ["/sys/class/power_supply/BAT0/type"] = "Battery\n",
  ["/sys/class/power_supply/BAT0/present"] = "1\n",
  ["/sys/class/power_supply/BAT0/status"] = "Discharging\n",
  ["/sys/class/power_supply/BAT0/capacity"] = "62\n",
  ["/sys/class/power_supply/BAT0/energy_now"] = "31000000\n",
  ["/sys/class/power_supply/BAT0/energy_full"] = "50000000\n",
  ["/sys/class/power_supply/BAT0/energy_full_design"] = "60000000\n",
  ["/sys/class/power_supply/BAT0/power_now"] = "10000000\n",
  ["/sys/class/power_supply/BAT0/cycle_count"] = "144\n",
  ["/sys/class/power_supply/AC/type"] = "Mains\n",
  ["/sys/class/power_supply/AC/online"] = "0\n",
}
local supplies = PowerSupply.new({
  fs = fake_fs(battery_files, { ["/sys/class/power_supply"] = { "BAT0", "AC" } }),
}):sample({})
equal(supplies.status, "ok", "power supply sample succeeds")
equal(#supplies.data.batteries, 1, "one battery")
equal(#supplies.data.supplies, 1, "one mains adapter")
local battery = supplies.data.batteries[1]
equal(battery.capacity_percent, 62, "the driver's own capacity wins")
equal(battery.energy_watt_hours, 31.0, "energy is scaled out of micro-units")
-- Health is full-charge against design capacity, which is what tells a user
-- their battery has aged.
assert(math.abs(battery.health_percent - (50 / 60 * 100)) < 0.001, "battery health")
assert(math.abs(battery.time_remaining_seconds - (31 / 10 * 3600)) < 0.001,
  "runtime is only computed while discharging")
equal(supplies.data.summary.state, "discharging", "summary state")
equal(supplies.data.on_ac_power, false, "offline mains means no AC power")

-- Absence must be reported the same way every other collector reports it, so
-- the UI can distinguish "nothing to read" from "read successfully, empty".
local none = PowerSupply.new({
  fs = fake_fs({}, { ["/sys/class/power_supply"] = {} }),
}):sample({})
equal(none.status, "unavailable", "a host with no power supplies reports unavailable")
equal(none.quality, "unavailable", "and its quality matches")
equal(none.reason, "no_power_supplies", "with a reason the Insights page can show")
equal(none.data, nil, "an unavailable sample carries no payload")

-- The same bounded enumeration as the device inventory's, and the same reason.
-- `MAX_DEVICES` is 16 here, so seventeen entries is the shortest list that
-- truncates.  This was the second place in the tree publishing `truncated` as a
-- result quality, and it published it with no reason at all -- the quality said
-- the list was short and nothing said why -- while the same result could also
-- carry `partial` for a different cause, leaving the word as the only
-- distinction.  The two collectors share one code because they share one cause;
-- the reason column is already inside one collector's row.
local many_files, many_entries = {}, {}
for index = 1, 17 do
  local name = string.format("BAT%d", index)
  many_entries[#many_entries + 1] = name
  many_files["/sys/class/power_supply/" .. name .. "/type"] = "Battery\n"
  many_files["/sys/class/power_supply/" .. name .. "/present"] = "1\n"
  many_files["/sys/class/power_supply/" .. name .. "/status"] = "Full\n"
  many_files["/sys/class/power_supply/" .. name .. "/capacity"] = "80\n"
end
local capped = PowerSupply.new({
  fs = fake_fs(many_files, { ["/sys/class/power_supply"] = many_entries }),
}):sample({})
equal(capped.status, "ok", "a capped power supply list is still a successful read")
equal(capped.quality, "truncated", "a list past the cap says so")
equal(capped.reason, "device_enumeration_truncated",
  "and names the cause, with the same code the device inventory uses")
equal(#capped.data.batteries, 16, "the device list stops at the cap")
equal(capped.data.truncated, true, "the per-resource flag agrees")
equal(supplies.reason, nil, "a list inside the cap has no reason to give")
equal(supplies.quality, "fresh", "and stays fresh")

-- ---------------------------------------------------------------------------
-- User name resolution
-- ---------------------------------------------------------------------------

local passwd = "root:x:0:0:root:/root:/bin/bash\n"
  .. "daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\n"
  .. "# comment line\n"
  .. "waterrun:x:1000:1000:,,,:/home/waterrun:/bin/bash\n"
local group = "root:x:0:\nsudo:x:27:waterrun\n"
local resolver = Users.new({
  fs = fake_fs({ ["/etc/passwd"] = passwd, ["/etc/group"] = group }),
})
equal(resolver:user(0, 0), "root", "root resolves")
equal(resolver:user(1000, 0), "waterrun", "a regular user resolves")
equal(resolver:user(4242, 0), nil, "an unknown uid resolves to nothing")
equal(resolver:user_label(4242, 0), "4242", "an unknown uid keeps its number")
equal(resolver:group(27, 0), "sudo", "group resolution")
equal(resolver:user("nope", 0), nil, "a non-numeric uid is rejected")
local users_count, groups_count = resolver:count(0)
equal(users_count, 3, "comment lines are not users")
equal(groups_count, 2, "group count")

return true
